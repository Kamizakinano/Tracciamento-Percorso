import Foundation
import CoreLocation
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
    private var paused = false
    private var unsavedPoints = 0
    private var recentSpeeds: [Double] = []
    private var lastNotification = Date.distantPast
    private var lastVoice = Date.distantPast

    private let maxAccuracy = 50.0
    private let currentURL = TripStore.documents.appendingPathComponent("current.json")
    private let screenshots = ProcessInfo.processInfo.arguments.contains("-screenshots")

    /// In modalità automatica un viaggio si chiude dopo 5 minuti senza spostamenti,
    /// un salto di oltre 2 km o il cambio di giorno.
    static let autoGap: TimeInterval = 300
    static let autoJump = 2000.0
    static let autoMinDistance = 150.0

    private struct CurrentTrip: Codable {
        var start: Date
        var points: [TrackPoint]
        var newRoadMeters: Double?
    }

    var currentLocation: CLLocation? { manager.location }
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
            if Settings.autoRecordOn {
                startAuto()
            } else if !points.isEmpty {
                start()
            }
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
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        isRecording = false
        if keep {
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            saveTrip(name: (trimmed?.isEmpty ?? true) ? nil : trimmed, automatic: false, minDistance: 0)
        }
        resetTrip()
        LiveActivityManager.shared.end()
    }

    // MARK: - Registrazione automatica

    func setAutoRecord(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Settings.autoRecord)
        if on {
            if isRecording && !isAutomatic {
                // Salva il viaggio manuale in corso e passa alla modalità automatica.
                saveTrip(name: nil, automatic: false, minDistance: 0)
                resetTrip()
            }
            startAuto()
        } else {
            stopAuto()
        }
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
        configure(automatic: true)
        manager.startUpdatingLocation()
        manager.startMonitoringSignificantLocationChanges()
        isRecording = true
        isAutomatic = true
        startLiveActivity()
    }

    private func stopAuto() {
        finishAutoSegment()
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
        manager.distanceFilter = automatic ? 5 : currentMode.minStep
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
            finishAutoSegment()
        }
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
        paused = true
        persistCurrent()
    }

    func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        paused = false
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isRecording else { return }
        if isAutomatic && paused {
            // Risvegliati da un cambio di posizione significativo: riattiva il GPS preciso.
            paused = false
            manager.startUpdatingLocation()
        }
        for loc in locations {
            guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= maxAccuracy,
                  loc.timestamp.timeIntervalSinceNow > -30 else { continue }
            updateMode(speed: loc.speed)
            let p = TrackPoint(loc)
            if isAutomatic, let last = points.last, Self.shouldSplit(last: last, next: p) {
                finishAutoSegment()
            }
            let near = store.index.isNear(p, within: Settings.threshold(for: currentMode))
            if let last = points.last {
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
            if !isAutomatic { manager.distanceFilter = mode.minStep }
        }
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
        content.title = "Strada già percorsa"
        content.body = "Stai passando su una strada che hai già fatto."
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
                                            onOldRoad: onOldRoad, modeIcon: currentMode.icon)
    }

    private func startLiveActivity() {
        guard UIApplication.shared.applicationState == .active, !screenshots else { return }
        LiveActivityManager.shared.start(startDate: isAutomatic ? Date() : tripStart,
                                         automatic: isAutomatic, state: activityState)
    }
}
