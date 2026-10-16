import Foundation
import CoreLocation
import MapKit
import UIKit
import UserNotifications

/// Registra i viaggi, anche con l'app in background o lo schermo spento.
/// Due modalità: manuale (Avvia/Ferma) e automatica (sempre attiva: ogni
/// spostamento diventa un viaggio, senza aprire l'app).
final class LocationTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var isAutomatic = false
    @Published private(set) var points: [TrackPoint] = []
    @Published private(set) var distance = 0.0
    @Published private(set) var newRoadMeters = 0.0
    @Published private(set) var onOldRoad = false
    @Published private(set) var currentMode: TravelMode = .car
    @Published var showDeniedAlert = false

    private let manager = CLLocationManager()
    private let store: TripStore
    private var tripStart = Date()
    private var pendingStart = false
    private var pendingAuto = false
    /// In pausa per risparmiare batteria: GPS spento, "recinto" intorno a dove sei fermo.
    private var resting = false
    private var restDetector = RestDetector()
    private var restTimer: Timer?
    /// Dopo una pausa: il primo punto nuovo si collega al punto di sosta lungo le strade.
    private var restAnchor: TrackPoint?
    private var wokeFromRest = false
    private var unsavedPoints = 0
    private var recentSpeeds: [Double] = []
    private var lastNotification = Date.distantPast
    private var lastVoice = Date.distantPast
    private var parkingDetector = ParkingDetector()
    private var pendingFixes: [(CLLocation) -> Void] = []
    /// Parcheggio salvato quando iOS ha sospeso il GPS: se riparti senza esserti fermato
    /// davvero (era un semaforo) viene annullato.
    private var pauseParking: TrackPoint?

    private let maxAccuracy = 50.0
    private let currentURL = TripStore.documents.appendingPathComponent("current.json")
    private let screenshots = ProcessInfo.processInfo.arguments.contains("-screenshots")

    /// In modalità automatica un viaggio si chiude dopo 5 minuti senza spostamenti,
    /// un salto di oltre 2 km o il cambio di giorno.
    static let autoGap: TimeInterval = 300
    static let autoJump = 2000.0
    static let autoMinDistance = 150.0
    /// Buco nel tracciato (GPS sospeso, galleria) da ricostruire lungo le strade.
    static let bridgeMinGap = 300.0
    static let bridgeMaxGap = 60_000.0
    /// Pausa: raggio del recinto intorno al punto di sosta.
    static let restRegionRadius = 80.0
    static let restRegionID = "percorso-sosta"

    private struct CurrentTrip: Codable {
        var start: Date
        var points: [TrackPoint]
        var newRoadMeters: Double?
    }

    var currentLocation: CLLocation? { manager.location }

    /// Riceve ogni posizione valida (usato dalla navigazione).
    var onLocation: ((CLLocation) -> Void)?
    /// Parcheggio rilevato dalla velocità (auto → piedi) o ripartenza in auto.
    var onParking: ((ParkingEvent) -> Void)?
    /// Prossima svolta da mostrare nella Live Activity durante la navigazione.
    var navigationInfo: (instruction: String, distance: Double, icon: String)?
    var authorization: CLAuthorizationStatus { manager.authorizationStatus }

    init(store: TripStore) {
        self.store = store
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 5
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        currentMode = Settings.fixedMode ?? .car

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(persistCurrent), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(persistCurrent), name: UIApplication.willTerminateNotification, object: nil)
        nc.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)

        // Riprendi il viaggio interrotto (app chiusa o riavviata da iOS).
        if let data = try? Data(contentsOf: currentURL),
           let saved = try? JSONDecoder().decode(CurrentTrip.self, from: data) {
            tripStart = saved.start
            points = saved.points
            distance = Geo.length(of: saved.points)
            newRoadMeters = saved.newRoadMeters ?? 0
        }
        // Dopo l'avvio dell'app (qui UIApplication potrebbe non essere ancora pronta).
        DispatchQueue.main.async { [self] in
            if Settings.shouldAutoRecord {
                startAuto()
            } else if !points.isEmpty {
                start()
            }
            refreshSchedule()
        }
    }

    // MARK: - Permessi

    func requestPermissionIfNeeded() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    private func requestNotifications() {
        guard !screenshots else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Registrazione manuale

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            pendingStart = true
            manager.requestWhenInUseAuthorization()
            return
        case .denied, .restricted:
            showDeniedAlert = true
            return
        default:
            break
        }
        requestNotifications()
        parkingDetector.reset()
        if points.isEmpty { resetTrip() }
        configure(automatic: false)
        manager.startUpdatingLocation()
        isRecording = true
        isAutomatic = false
        persistCurrent()
        startLiveActivity()
    }

    /// Ferma la registrazione manuale; se `keep` è vero il viaggio viene salvato.
    func stop(name: String?, keep: Bool) {
        endParkingDetection(next: nil)
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        isRecording = false
        if keep {
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            saveTrip(name: (trimmed?.isEmpty ?? true) ? nil : trimmed, automatic: false, minDistance: 0)
        }
        resetTrip()
        LiveActivityManager.shared.end()
        refreshSchedule() // nel frattempo può essere iniziato un periodo programmato
    }

    // MARK: - Registrazione automatica

    func setAutoRecord(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Settings.autoRecord)
        refreshSchedule(convertManual: true)
    }

    /// Accende o spegne la registrazione automatica secondo "Registra sempre" e il periodo
    /// programmato. `convertManual`: un viaggio manuale in corso diventa automatico.
    func refreshSchedule(now: Date = Date(), convertManual: Bool = false) {
        let want = Settings.autoRecordOn || (Settings.period?.contains(now) ?? false)
        if want && !isAutomatic {
            if isRecording {
                guard convertManual else { return } // finisci prima il viaggio manuale (es. navigazione)
                // Salva il viaggio manuale in corso e passa alla modalità automatica.
                saveTrip(name: nil, automatic: false, minDistance: 0)
                resetTrip()
            }
            startAuto()
        } else if !want && isAutomatic {
            stopAuto()
        }
        // Periodo in arrivo: i cambi di posizione significativi risvegliano l'app
        // anche se è chiusa, così la registrazione parte da sola il giorno giusto.
        if !isAutomatic {
            if let period = Settings.period, period.isUpcoming(now) {
                if manager.authorizationStatus == .authorizedAlways {
                    manager.startMonitoringSignificantLocationChanges()
                } else if UIApplication.shared.applicationState == .active {
                    manager.requestAlwaysAuthorization()
                }
            } else {
                manager.stopMonitoringSignificantLocationChanges()
            }
        }
        if !screenshots { PeriodReminders.schedule(Settings.period, now: now) }
    }

    private func startAuto() {
        switch manager.authorizationStatus {
        case .notDetermined:
            pendingAuto = true
            manager.requestAlwaysAuthorization()
            return
        case .denied, .restricted:
            showDeniedAlert = true
            return
        case .authorizedWhenInUse:
            // Serve "Sempre" perché iOS possa riattivare l'app da sola.
            manager.requestAlwaysAuthorization()
        default:
            break
        }
        requestNotifications()
        // Recinto rimasto da una pausa prima che l'app venisse chiusa: riparti da lì.
        if let old = manager.monitoredRegions.first(where: { $0.identifier == Self.restRegionID }) as? CLCircularRegion {
            restAnchor = TrackPoint(lat: old.center.latitude, lon: old.center.longitude, time: Date())
            wokeFromRest = true
        }
        stopRestRegion()
        resting = false
        restDetector.reset()
        configure(automatic: true)
        manager.startUpdatingLocation()
        manager.startMonitoringSignificantLocationChanges()
        isRecording = true
        isAutomatic = true
        startRestTimer()
        startLiveActivity()
    }

    private func stopAuto() {
        endParkingDetection(next: nil)
        finishAutoSegment()
        restTimer?.invalidate()
        restTimer = nil
        resting = false
        stopRestRegion()
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        manager.allowsBackgroundLocationUpdates = false
        isRecording = false
        isAutomatic = false
        resetTrip()
        LiveActivityManager.shared.end()
    }

    private func configure(automatic: Bool) {
        manager.allowsBackgroundLocationUpdates = true
        // In automatico iOS sospende il GPS quando sei fermo e lo riattiva al primo spostamento.
        manager.pausesLocationUpdatesAutomatically = automatic
        manager.activityType = automatic ? .other : .otherNavigation
        manager.distanceFilter = automatic ? 8 : currentMode.minStep
        // In automatico basta la precisione "alta": quella da navigatore consuma molto di più.
        manager.desiredAccuracy = automatic ? kCLLocationAccuracyBest : kCLLocationAccuracyBestForNavigation
    }

    /// Buco nel tracciato percorso senza fermarsi: velocità media tra 7 e 250 km/h.
    /// In quel caso il tratto mancante si ricostruisce invece di spezzare il viaggio.
    static func isBridgeableGap(last: TrackPoint, next: TrackPoint, calendar: Calendar = .current) -> Bool {
        let d = Geo.distance(last, next)
        let t = next.time.timeIntervalSince(last.time)
        guard d >= bridgeMinGap, d <= bridgeMaxGap, t > 0, calendar.isDate(last.time, inSameDayAs: next.time) else { return false }
        let speed = d / t
        return speed >= 2 && speed <= 70
    }

    /// Punti del tratto ricostruito, con l'ora stimata in proporzione alla distanza.
    static func bridgePoints(_ path: [CLLocationCoordinate2D], from a: TrackPoint, to b: TrackPoint) -> [TrackPoint] {
        var coords = path
        // Togli gli estremi che coincidono con i punti già registrati.
        if let f = coords.first, Geo.distance(f, a.coordinate) < 15 { coords.removeFirst() }
        if let l = coords.last, Geo.distance(l, b.coordinate) < 15 { coords.removeLast() }
        guard !coords.isEmpty else { return [] }
        let all = [a.coordinate] + coords + [b.coordinate]
        let total = max(1, Geo.length(of: all))
        let span = b.time.timeIntervalSince(a.time)
        var done = 0.0
        var out: [TrackPoint] = []
        for i in 1..<(all.count - 1) {
            done += Geo.distance(all[i - 1], all[i])
            out.append(TrackPoint(lat: all[i].latitude, lon: all[i].longitude,
                                  time: a.time.addingTimeInterval(span * done / total)))
        }
        return out
    }

    /// Il percorso stradale trovato è credibile (non molto più lungo della linea d'aria).
    static func isPlausibleBridge(_ path: [CLLocationCoordinate2D], from a: TrackPoint, to b: TrackPoint) -> Bool {
        guard path.count >= 2 else { return false }
        let straight = Geo.distance(a, b)
        return Geo.length(of: path) <= straight * 3 + 1000
    }

    /// Decide se un nuovo punto appartiene a un nuovo viaggio automatico.
    static func shouldSplit(last: TrackPoint, next: TrackPoint, calendar: Calendar = .current) -> Bool {
        next.time.timeIntervalSince(last.time) > autoGap
            || Geo.distance(last, next) > autoJump
            || !calendar.isDate(last.time, inSameDayAs: next.time)
    }

    private func finishAutoSegment() {
        saveTrip(name: nil, automatic: true, minDistance: Self.autoMinDistance)
        resetTrip()
    }

    @objc private func didBecomeActive() {
        if isAutomatic, let last = points.last, Date().timeIntervalSince(last.time) > Self.autoGap {
            endParkingDetection(next: manager.location.map(TrackPoint.init))
            finishAutoSegment()
        }
        refreshSchedule()
        // App aperta: GPS di nuovo acceso (se resti fermo, tra 5 minuti torna in pausa).
        if resting { exitRest() }
        if isRecording { startLiveActivity() }
    }

    // MARK: - Salvataggio

    private func saveTrip(name: String?, automatic: Bool, minDistance: Double) {
        guard points.count > 1, distance >= minDistance else { return }
        var trip = Trip(name: name, start: points.first?.time ?? tripStart, end: points.last?.time ?? Date(), points: points)
        trip.mode = Settings.fixedMode ?? trip.effectiveMode
        trip.automatic = automatic
        trip.newFraction = distance > 0 ? min(1, newRoadMeters / distance) : nil
        store.add(trip)
    }

    private func resetTrip() {
        points = []
        distance = 0
        newRoadMeters = 0
        onOldRoad = false
        tripStart = Date()
        try? FileManager.default.removeItem(at: currentURL)
    }

    @objc func persistCurrent() {
        guard isRecording, !points.isEmpty else { return }
        unsavedPoints = 0
        let current = CurrentTrip(start: tripStart, points: points, newRoadMeters: newRoadMeters)
        try? JSONEncoder().encode(current).write(to: currentURL, options: .atomic)
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if pendingStart { pendingStart = false; start() }
            if pendingAuto { pendingAuto = false; startAuto() }
            if manager.authorizationStatus == .authorizedAlways { refreshSchedule() }
        case .denied, .restricted:
            if pendingStart || pendingAuto || isRecording {
                pendingStart = false
                pendingAuto = false
                showDeniedAlert = true
            }
        default:
            break
        }
    }

    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        // iOS sospende il GPS quando resti fermo.
        if isAutomatic { enterRest() }
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == Self.restRegionID else { return }
        exitRest()
    }

    // MARK: - Pausa per risparmiare batteria

    private func startRestTimer() {
        restTimer?.invalidate()
        // Il timer gira solo mentre il GPS tiene sveglia l'app: basta per accorgersi della sosta.
        restTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, self.isAutomatic, !self.resting, self.navigationInfo == nil,
                  self.restDetector.isResting(now: Date()) else { return }
            self.enterRest()
        }
    }

    /// Fermo da qualche minuto: spegni il GPS e metti un recinto intorno a dove sei.
    /// Quando ne esci iOS risveglia l'app (anche se è chiusa) e il GPS riparte.
    private func enterRest() {
        // Senza il permesso "Sempre" iOS non risveglierebbe l'app: niente pausa.
        guard !resting, manager.authorizationStatus == .authorizedAlways else { return }
        resting = true
        // Se stavi guidando hai parcheggiato (salvo ripartire subito: vedi pauseParking).
        if detectsParking, case let .parked(point, left)? = parkingDetector.tripEnded(next: nil) {
            onParking?(.parked(point, left: left))
            pauseParking = point
        } else {
            parkingDetector.reset()
        }
        persistCurrent()
        let anchor = restDetector.anchor ?? points.last ?? manager.location.map(TrackPoint.init)
        restAnchor = anchor
        manager.stopUpdatingLocation()
        if let anchor, CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) {
            let region = CLCircularRegion(center: anchor.coordinate, radius: Self.restRegionRadius,
                                          identifier: Self.restRegionID)
            region.notifyOnEntry = false
            region.notifyOnExit = true
            manager.startMonitoring(for: region)
        }
    }

    private func exitRest() {
        stopRestRegion()
        guard resting else { return }
        resting = false
        wokeFromRest = true
        restDetector.reset()
        if isAutomatic { manager.startUpdatingLocation() }
    }

    private func stopRestRegion() {
        for region in manager.monitoredRegions where region.identifier == Self.restRegionID {
            manager.stopMonitoring(for: region)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let last = locations.last, !pendingFixes.isEmpty {
            let fixes = pendingFixes
            pendingFixes = []
            fixes.forEach { $0(last) }
        }
        // Inizio o fine del periodo programmato (anche quando iOS risveglia l'app).
        if (!isRecording || isAutomatic) && isAutomatic != Settings.shouldAutoRecord {
            refreshSchedule()
        }
        guard isRecording else { return }
        if isAutomatic && resting {
            // Risvegliati da un cambio di posizione significativo: riattiva il GPS preciso.
            if let a = restAnchor, let loc = locations.last,
               Geo.distance(a, TrackPoint(loc)) < Self.restRegionRadius { return } // ancora lì
            exitRest()
        }
        for loc in locations {
            guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= maxAccuracy,
                  loc.timestamp.timeIntervalSinceNow > -30 else { continue }
            updateMode(speed: loc.speed)
            onLocation?(loc)
            let p = TrackPoint(loc)
            restDetector.feed(p)
            // Primo punto dopo una pausa: collegalo al punto di sosta lungo le strade.
            let afterRest = wokeFromRest
            wokeFromRest = false
            var gapFrom: TrackPoint?
            if afterRest, let last = points.last, Geo.distance(last, p) >= 30,
               !(isAutomatic && Self.shouldSplit(last: last, next: p)) {
                gapFrom = last
                // Ferma pochi minuti (coda, semaforo lungo): non era un parcheggio.
                if let pp = pauseParking, p.time.timeIntervalSince(last.time) < 600 {
                    onParking?(.cancelled(pp))
                    pauseParking = nil
                }
            } else if let last = points.last, Self.isBridgeableGap(last: last, next: p) {
                // GPS sospeso o perso mentre ti muovevi: ricostruisci il tratto, non spezzare il viaggio.
                gapFrom = last
                if let pp = pauseParking {
                    onParking?(.cancelled(pp))
                    pauseParking = nil
                }
            } else if isAutomatic, let last = points.last, Self.shouldSplit(last: last, next: p) {
                pauseParking = nil
                endParkingDetection(next: p)
                finishAutoSegment()
            }
            if afterRest, points.isEmpty, let a = restAnchor {
                // Il nuovo viaggio parte da dove eri fermo, non da dove il GPS si è riacceso.
                let d = Geo.distance(a, p)
                if d >= 30 && d <= 5000 {
                    let start = TrackPoint(lat: a.lat, lon: a.lon, time: p.time.addingTimeInterval(-max(10, d / 8)))
                    points.append(start)
                    tripStart = start.time
                    gapFrom = start
                }
            }
            feedParking(p, speed: loc.speed)
            let near = store.index.isNear(p, within: Settings.threshold(for: currentMode))
            if let from = gapFrom {
                // La distanza del tratto mancante si aggiunge quando è ricostruito.
                points.append(p)
                setOldRoad(near)
                requestBridge(from: from, to: p)
                continue
            } else if let last = points.last {
                pauseParking = nil // ripartito senza salti: il parcheggio era vero
                let step = Geo.distance(last, p)
                guard step >= (isAutomatic ? 5 : currentMode.minStep) else { continue }
                distance += step
                if !near { newRoadMeters += step }
            } else {
                tripStart = p.time
            }
            setOldRoad(near)
            points.append(p)
            unsavedPoints += 1
        }
        if unsavedPoints >= 20 { persistCurrent() }
        LiveActivityManager.shared.update(activityState)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown è temporaneo: il GPS riproverà da solo.
    }

    private func updateMode(speed: Double) {
        if let fixed = Settings.fixedMode {
            currentMode = fixed
            return
        }
        guard speed >= 0 else { return }
        recentSpeeds.append(speed)
        if recentSpeeds.count > 15 { recentSpeeds.removeFirst() }
        let avg = recentSpeeds.reduce(0, +) / Double(recentSpeeds.count)
        let mode = TravelMode.infer(speed: avg)
        if mode != currentMode {
            currentMode = mode
            if isAutomatic {
                // In auto iOS sospende il GPS molto meno (es. fermo al semaforo o in coda).
                manager.activityType = mode == .car ? .automotiveNavigation : .other
            } else {
                manager.distanceFilter = mode.minStep
            }
        }
    }

    // MARK: - Parcheggio

    /// Il rilevamento dalla velocità è attivo (non con mezzo fisso bici o piedi).
    private var detectsParking: Bool {
        Settings.parkingDetect == 1 && (Settings.fixedMode ?? .car) == .car
    }

    private func feedParking(_ p: TrackPoint, speed: Double) {
        guard detectsParking else { return }
        if let event = parkingDetector.feed(p, speed: speed) { onParking?(event) }
    }

    private func endParkingDetection(next: TrackPoint?) {
        guard detectsParking else {
            parkingDetector.reset()
            return
        }
        if let event = parkingDetector.tripEnded(next: next) { onParking?(event) }
    }

    /// Posizione recente (meno di 2 minuti), oppure ne chiede una nuova al GPS.
    func freshLocation(_ completion: @escaping (CLLocation) -> Void) {
        if let loc = manager.location, loc.timestamp.timeIntervalSinceNow > -120, loc.horizontalAccuracy <= 100 {
            completion(loc)
            return
        }
        pendingFixes.append(completion)
        if !isRecording { manager.requestLocation() }
    }

    // MARK: - Tratti mancanti

    private func requestBridge(from a: TrackPoint, to b: TrackPoint) {
        let car = currentMode == .car || Geo.distance(a, b) / max(1, b.time.timeIntervalSince(a.time)) > 7
        Task {
            let path = await Self.roadPath(from: a.coordinate, to: b.coordinate, car: car)
            await MainActor.run { self.applyBridge(from: a, to: b, path: path) }
        }
    }

    private static func roadPath(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D, car: Bool) async -> [CLLocationCoordinate2D]? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: a))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: b))
        request.transportType = car ? .automobile : .walking
        guard let route = try? await MKDirections(request: request).calculate().routes.first else { return nil }
        return RoutePlanner.coordinates(of: route.polyline)
    }

    /// Inserisce il tratto ricostruito; se non si trova un percorso, in automatico il
    /// viaggio viene spezzato lì (come prima), in manuale resta una linea dritta.
    private func applyBridge(from a: TrackPoint, to b: TrackPoint, path: [CLLocationCoordinate2D]?) {
        guard let ia = points.lastIndex(where: { $0.time == a.time }), ia + 1 < points.count,
              points[ia + 1].time == b.time else { return } // il viaggio è già stato chiuso
        let straight = Geo.distance(a, b)
        let threshold = Settings.threshold(for: currentMode)
        if let path, Self.isPlausibleBridge(path, from: a, to: b) {
            let added = Self.bridgePoints(path, from: a, to: b)
            points.insert(contentsOf: added, at: ia + 1)
            let segment = [a.coordinate] + added.map(\.coordinate) + [b.coordinate]
            let length = Geo.length(of: segment)
            distance += length
            newRoadMeters += length * Geo.newFraction(of: segment, index: store.index, within: threshold)
        } else if isAutomatic {
            let head = Array(points[...ia])
            let tail = Array(points[(ia + 1)...])
            points = head
            distance = Geo.length(of: head)
            newRoadMeters = distance * Geo.newFraction(of: head.map(\.coordinate), index: store.index, within: threshold)
            saveTrip(name: nil, automatic: true, minDistance: Self.autoMinDistance)
            points = tail
            tripStart = tail.first?.time ?? Date()
            distance = Geo.length(of: tail)
            newRoadMeters = distance * Geo.newFraction(of: tail.map(\.coordinate), index: store.index, within: threshold)
        } else {
            distance += straight
            if !store.index.isNear(b, within: threshold) { newRoadMeters += straight }
        }
        persistCurrent()
        LiveActivityManager.shared.update(activityState)
    }

    // MARK: - Avviso strada già percorsa

    private func setOldRoad(_ near: Bool) {
        if near && !onOldRoad && Settings.alertsOn { warn() }
        onOldRoad = near
    }

    private func warn() {
        if Date().timeIntervalSince(lastVoice) > 60 {
            lastVoice = Date()
            VoiceAlert.shared.speakIfEnabled("Strada già percorsa", setting: Settings.voiceMode)
        }
        if UIApplication.shared.applicationState == .active {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        // In background: notifica locale, al massimo una al minuto.
        guard Date().timeIntervalSince(lastNotification) > 60 else { return }
        lastNotification = Date()
        let content = UNMutableNotificationContent()
        content.title = "↺ Strada già percorsa"
        content.body = "Ci sei già passato: se vuoi, cerca una strada nuova ✨"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "old-road", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Live Activity

    var newPercent: Int? {
        distance > 0 ? Int((newRoadMeters / distance * 100).rounded()) : nil
    }

    private var activityState: TripActivityAttributes.ContentState {
        TripActivityAttributes.ContentState(distance: distance, newPercent: newPercent,
                                            onOldRoad: onOldRoad, modeIcon: currentMode.icon,
                                            instruction: navigationInfo?.instruction,
                                            maneuverDistance: navigationInfo?.distance,
                                            maneuverIcon: navigationInfo?.icon)
    }

    private func startLiveActivity() {
        guard UIApplication.shared.applicationState == .active, !screenshots else { return }
        LiveActivityManager.shared.start(startDate: isAutomatic ? Date() : tripStart,
                                         automatic: isAutomatic, state: activityState)
    }
}

/// Notifiche di inizio e fine della registrazione programmata.
enum PeriodReminders {
    static let startID = "period-start"
    static let endID = "period-end"

    static func schedule(_ period: RecordingPeriod?, now: Date = Date()) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [startID, endID])
        guard let period else { return }
        let b = period.bounds()
        if b.from > now {
            let content = UNMutableNotificationContent()
            content.title = "Inizia la registrazione programmata"
            content.body = "Percorso registra tutti i tuoi spostamenti \(period.text). Apri l'app una volta per essere sicuro che sia attiva."
            content.sound = .default
            center.add(UNNotificationRequest(identifier: startID, content: content,
                                             trigger: UNTimeIntervalNotificationTrigger(timeInterval: b.from.timeIntervalSince(now), repeats: false)))
        }
        if b.to > now {
            let content = UNMutableNotificationContent()
            content.title = "Registrazione programmata finita"
            content.body = "Il periodo \(period.text) è terminato: Percorso non registra più da solo."
            content.sound = .default
            center.add(UNNotificationRequest(identifier: endID, content: content,
                                             trigger: UNTimeIntervalNotificationTrigger(timeInterval: b.to.timeIntervalSince(now), repeats: false)))
        }
    }
}

/// Capisce quando sei fermo: nessuno spostamento oltre 40 m per 5 minuti.
/// I punti poco precisi non vengono passati, così il GPS che "balla" in casa non conta.
struct RestDetector {
    static let radius = 40.0
    static let restTime: TimeInterval = 300

    private(set) var anchor: TrackPoint?
    private(set) var since: Date?

    mutating func feed(_ p: TrackPoint) {
        if let a = anchor, Geo.distance(a, p) <= Self.radius { return }
        anchor = p
        since = p.time
    }

    func isResting(now: Date) -> Bool {
        guard let since else { return false }
        return now.timeIntervalSince(since) >= Self.restTime
    }

    mutating func reset() {
        anchor = nil
        since = nil
    }
}
