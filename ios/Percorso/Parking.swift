import Foundation
import CoreLocation
import UIKit
import AVFoundation
import ActivityKit
import UserNotifications

// MARK: - Parcheggio

/// Come è stato salvato il parcheggio.
enum ParkingSource: String, Codable {
    /// Pulsante "Ho parcheggiato qui".
    case manual
    /// Passaggio da auto a piedi (velocità) o fine di un viaggio in auto.
    case speed
    /// Scollegamento dal Bluetooth o da CarPlay dell'auto.
    case bluetooth

    var icon: String {
        switch self {
        case .manual: return "hand.tap"
        case .speed: return "speedometer"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        }
    }

    var label: String {
        switch self {
        case .manual: return "Salvato a mano"
        case .speed: return "Rilevato dalla velocità"
        case .bluetooth: return "Rilevato dal Bluetooth"
        }
    }
}

struct ParkingSpot: Codable, Identifiable, Hashable {
    var id = UUID()
    var lat: Double
    var lon: Double
    var date: Date
    var source: ParkingSource
    var address: String?
    /// Nota libera (piano, colonna, via…).
    var note: String?
    /// Nome del file della foto in Documents/Parcheggi.
    var photo: String?
    /// Scadenza del ticket o del disco orario.
    var expiry: Date?
    /// Minuti di preavviso prima della scadenza.
    var reminderMinutes: Int?
    /// Quando hai ripreso l'auto (nil = auto ancora parcheggiata qui).
    var retrieved: Date?

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    var isActive: Bool { retrieved == nil }
    var title: String {
        if let address, !address.isEmpty { return address }
        return "Parcheggio"
    }

    func duration(now: Date = Date()) -> TimeInterval {
        max(0, (retrieved ?? now).timeIntervalSince(date))
    }

    /// Quando arriva l'avviso del ticket.
    var reminderDate: Date? {
        guard let expiry else { return nil }
        return expiry.addingTimeInterval(-Double(reminderMinutes ?? 10) * 60)
    }
}

/// Segnalazione dei parcheggi trovati altre volte vicino a una destinazione.
struct ParkingHint: Equatable {
    var count: Int
    /// Distanza dalla destinazione del parcheggio più vicino.
    var nearest: Double

    var text: String {
        let times = count == 1 ? "1 volta" : "\(count) volte"
        return "🅿️ Qui vicino hai già parcheggiato \(times) · il posto più vicino è a \(Geo.formatShort(nearest))"
    }
}

// MARK: - Rilevamento dalla velocità

enum ParkingEvent {
    /// Hai parcheggiato qui. `left` = sei già ripartito (va solo nello storico).
    case parked(TrackPoint, left: Bool)
    /// Hai ripreso a guidare partendo da qui.
    case departed(TrackPoint)
    /// Il parcheggio salvato qui era un falso allarme (es. GPS sospeso al semaforo).
    case cancelled(TrackPoint)
}

/// Capisce dalla velocità quando lasci l'auto: dopo almeno 500 m in auto,
/// cammini per 2 minuti allontanandoti di almeno 60 m. Il parcheggio è
/// l'ultimo punto percorso in auto.
struct ParkingDetector {
    static let minDrive = 500.0
    static let confirmWalkTime: TimeInterval = 120
    static let confirmWalkDistance = 60.0
    /// Sopra questa velocità media (m/s) sei in auto (~22 km/h).
    static let driveSpeed = 6.0
    /// Sotto questa velocità media (m/s) stai camminando (~7 km/h).
    static let walkSpeed = 2.0
    /// Mentre guidi, sopra questa velocità (m/s) sei ancora in auto (~11 km/h).
    static let carMinSpeed = 3.0

    private var speeds: [Double] = []
    private var previous: TrackPoint?
    private var walkStart: TrackPoint?
    private var departureSent = false
    private(set) var driven = 0.0
    private(set) var driveStart: TrackPoint?
    private(set) var lastCarPoint: TrackPoint?

    private var average: Double {
        speeds.isEmpty ? 0 : speeds.reduce(0, +) / Double(speeds.count)
    }

    mutating func feed(_ p: TrackPoint, speed: Double) -> ParkingEvent? {
        defer { previous = p }
        guard speed >= 0 else { return nil }
        speeds.append(speed)
        if speeds.count > 8 { speeds.removeFirst() }

        guard let car = lastCarPoint else {
            // Inizi a guidare quando la velocità media supera quella di una bici.
            guard average > Self.driveSpeed else { return nil }
            driveStart = previous ?? p
            lastCarPoint = p
            return nil
        }
        if speed >= Self.carMinSpeed {
            // Ancora in auto (anche nel traffico lento).
            if let previous { driven += Geo.distance(previous, p) }
            lastCarPoint = p
            walkStart = nil
            if driven >= Self.minDrive && !departureSent {
                departureSent = true
                return .departed(driveStart ?? p)
            }
            return nil
        }
        // Lento o fermo: semaforo, coda, oppure sei sceso a piedi.
        guard driven >= Self.minDrive else { return nil }
        if walkStart == nil { walkStart = p }
        if let w = walkStart, average < Self.walkSpeed,
           p.time.timeIntervalSince(w.time) >= Self.confirmWalkTime,
           Geo.distance(car, p) >= Self.confirmWalkDistance {
            reset()
            return .parked(car, left: false)
        }
        return nil
    }

    /// Il viaggio è finito (fermo a lungo, Ferma, GPS sospeso): se stavi guidando hai parcheggiato.
    /// `next` è la posizione attuale, se nota: lontana dall'auto vuol dire che sei già ripartito.
    mutating func tripEnded(next: TrackPoint? = nil) -> ParkingEvent? {
        defer { reset() }
        guard driven >= Self.minDrive, let car = lastCarPoint else { return nil }
        // Ancora in movimento veloce (es. Ferma premuto guidando): non è un parcheggio.
        if next == nil, average > Self.driveSpeed { return nil }
        let left = next.map { Geo.distance($0, car) > 200 } ?? false
        return .parked(car, left: left)
    }

    mutating func reset() {
        speeds = []
        previous = nil
        walkStart = nil
        departureSent = false
        driven = 0
        driveStart = nil
        lastCarPoint = nil
    }
}

// MARK: - Archivio dei parcheggi

/// Parcheggi salvati in Documents/parking.json, foto in Documents/Parcheggi.
final class ParkingStore: ObservableObject {
    /// Tutti i parcheggi, dal più vecchio al più recente.
    @Published private(set) var spots: [ParkingSpot] = []
    /// Cambia a ogni modifica (la mappa lo usa per ridisegnare).
    @Published private(set) var version = 0

    static let backupFileName = "Percorso-parcheggi.json"
    /// Due parcheggi automatici così vicini e ravvicinati sono lo stesso.
    static let duplicateDistance = 100.0
    static let duplicateTime: TimeInterval = 1800

    private let fileURL: URL
    let photosDir: URL
    /// Notifiche e Live Activity (spente nei test).
    private let systemServices: Bool

    init(directory: URL = TripStore.documents, systemServices: Bool = true) {
        fileURL = directory.appendingPathComponent("parking.json")
        photosDir = directory.appendingPathComponent("Parcheggi", isDirectory: true)
        self.systemServices = systemServices
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([ParkingSpot].self, from: data) {
            spots = saved
        }
    }

    var current: ParkingSpot? { spots.last(where: \.isActive) }

    /// Storico, dal più recente.
    var history: [ParkingSpot] { spots.reversed() }

    func spot(_ id: UUID) -> ParkingSpot? { spots.first { $0.id == id } }

    // MARK: Modifiche

    /// Salva un nuovo parcheggio; quello precedente passa nello storico.
    /// Restituisce nil se è un doppione di un parcheggio automatico appena salvato.
    @discardableResult
    func park(at coordinate: CLLocationCoordinate2D, date: Date = Date(), source: ParkingSource,
              alreadyLeft: Bool = false) -> ParkingSpot? {
        if source != .manual, let last = spots.last,
           Geo.distance(last.coordinate, coordinate) < Self.duplicateDistance,
           abs(date.timeIntervalSince(last.date)) < Self.duplicateTime {
            return nil
        }
        if !alreadyLeft {
            for i in spots.indices where spots[i].retrieved == nil {
                spots[i].retrieved = max(date, spots[i].date)
            }
        }
        var spot = ParkingSpot(lat: coordinate.latitude, lon: coordinate.longitude, date: date, source: source)
        if alreadyLeft { spot.retrieved = Date() }
        spots.append(spot)
        spots.sort { $0.date < $1.date }
        changed()
        if systemServices { geocode(spot.id) }
        return spot
    }

    /// Hai ripreso l'auto.
    func retrieve(now: Date = Date()) {
        guard current != nil else { return }
        for i in spots.indices where spots[i].retrieved == nil { spots[i].retrieved = now }
        changed()
    }

    /// Hai ripreso a guidare partendo da `point`: se è vicino all'auto, l'hai ripresa.
    func departed(from point: CLLocationCoordinate2D, now: Date = Date()) {
        guard let cur = current, Geo.distance(cur.coordinate, point) < 250, now > cur.date else { return }
        retrieve(now: now)
    }

    /// Annulla un parcheggio automatico sbagliato (salvato a `date`) e rimette l'auto
    /// dov'era prima, se quel parcheggio l'aveva spostata nello storico.
    func cancelAutomatic(at date: Date) {
        guard let i = spots.lastIndex(where: { $0.date == date && $0.source == .speed && $0.isActive }) else { return }
        spots.remove(at: i)
        if let j = spots.lastIndex(where: { $0.retrieved == date }) { spots[j].retrieved = nil }
        changed()
    }

    func setNote(_ note: String, for id: UUID) {
        modify(id) { $0.note = note.isEmpty ? nil : note }
    }

    /// Imposta (o toglie, con nil) la scadenza del ticket.
    func setExpiry(_ expiry: Date?, reminderMinutes: Int, for id: UUID, now: Date = Date()) {
        modify(id) {
            $0.expiry = expiry.map { Self.normalizedExpiry($0, now: now) }
            $0.reminderMinutes = reminderMinutes
        }
    }

    func setPhoto(_ image: UIImage?, for id: UUID) {
        guard let i = spots.firstIndex(where: { $0.id == id }) else { return }
        if let old = spots[i].photo { try? FileManager.default.removeItem(at: photosDir.appendingPathComponent(old)) }
        spots[i].photo = nil
        if let image, let data = Self.resized(image, maxSide: 1600).jpegData(compressionQuality: 0.7) {
            let name = "\(id.uuidString)-\(Int(Date().timeIntervalSince1970)).jpg"
            try? FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
            if (try? data.write(to: photosDir.appendingPathComponent(name), options: .atomic)) != nil {
                spots[i].photo = name
            }
        }
        changed()
    }

    func image(for spot: ParkingSpot) -> UIImage? {
        guard let name = spot.photo else { return nil }
        return UIImage(contentsOfFile: photosDir.appendingPathComponent(name).path)
    }

    func delete(ids: Set<UUID>) {
        for spot in spots where ids.contains(spot.id) {
            if let name = spot.photo { try? FileManager.default.removeItem(at: photosDir.appendingPathComponent(name)) }
        }
        spots.removeAll { ids.contains($0.id) }
        changed()
    }

    private func modify(_ id: UUID, _ body: (inout ParkingSpot) -> Void) {
        guard let i = spots.firstIndex(where: { $0.id == id }) else { return }
        body(&spots[i])
        changed()
    }

    private func changed() {
        version += 1
        save()
        guard systemServices else { return }
        ParkingReminders.schedule(for: current)
        ParkingActivityManager.shared.update(for: current)
        BackupManager.shared.scheduleParkingBackup(self)
    }

    private func save() {
        try? JSONEncoder().encode(spots).write(to: fileURL, options: .atomic)
    }

    // MARK: Indirizzo

    private func geocode(_ id: UUID) {
        guard let spot = spot(id) else { return }
        Task { @MainActor in
            let placemark = try? await CLGeocoder()
                .reverseGeocodeLocation(CLLocation(latitude: spot.lat, longitude: spot.lon)).first
            let address = placemark.flatMap(Self.address)
            if let address { modify(id) { $0.address = address } }
            if systemServices, spot.source != .manual, spot.retrieved == nil {
                ParkingReminders.notifyParked(address: address)
            }
        }
    }

    static func address(_ p: CLPlacemark) -> String? {
        if let street = p.thoroughfare {
            return [street, p.subThoroughfare].compactMap { $0 }.joined(separator: " ")
        }
        return p.name ?? p.locality
    }

    // MARK: Calcoli

    /// Parcheggi passati entro `meters` da un punto, dal più vicino.
    static func nearby(_ spots: [ParkingSpot], to point: CLLocationCoordinate2D, within meters: Double) -> [ParkingSpot] {
        spots.map { ($0, Geo.distance($0.coordinate, point)) }
            .filter { $0.1 <= meters }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// Dove avevi trovato posto altre volte vicino alla destinazione (senza l'auto parcheggiata ora).
    static func hint(for destination: CLLocationCoordinate2D, spots: [ParkingSpot], within meters: Double = 400) -> ParkingHint? {
        let near = nearby(spots.filter { !$0.isActive }, to: destination, within: meters)
        guard let first = near.first else { return nil }
        return ParkingHint(count: near.count, nearest: Geo.distance(first.coordinate, destination))
    }

    /// Dal selettore dell'ora: un'ora già passata vuol dire domani (es. alle 23 scegli 01:00).
    static func normalizedExpiry(_ date: Date, now: Date) -> Date {
        var d = date
        while d < now.addingTimeInterval(-60) { d = d.addingTimeInterval(86400) }
        return d
    }

    static func resized(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height, 1))
        guard scale < 1 else { return image }
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    // MARK: Backup

    struct Backup: Codable {
        var spots: [ParkingSpot]
        /// Foto ridotte, per nome del file.
        var photos: [String: Data]
    }

    func backupData() -> Data? {
        var photos: [String: Data] = [:]
        for spot in spots {
            guard let name = spot.photo, let image = image(for: spot) else { continue }
            photos[name] = Self.resized(image, maxSide: 800).jpegData(compressionQuality: 0.5)
        }
        return try? JSONEncoder().encode(Backup(spots: spots, photos: photos))
    }

    /// Ripristina da un backup; restituisce quanti parcheggi sono stati aggiunti.
    @discardableResult
    func restore(_ data: Data) throws -> Int {
        let backup = try JSONDecoder().decode(Backup.self, from: data)
        let existing = Set(spots.map(\.id))
        let added = backup.spots.filter { !existing.contains($0.id) }
        try? FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
        for spot in added {
            if let name = spot.photo, let photo = backup.photos[name] {
                try? photo.write(to: photosDir.appendingPathComponent(name), options: .atomic)
            }
        }
        spots.append(contentsOf: added)
        spots.sort { $0.date < $1.date }
        // Una sola auto parcheggiata: la più recente.
        let active = spots.filter(\.isActive)
        for old in active.dropLast() {
            if let i = spots.firstIndex(where: { $0.id == old.id }) { spots[i].retrieved = old.date }
        }
        changed()
        return added.count
    }

    // MARK: Dati di prova per gli screenshot

    #if DEBUG
    func loadDemo(near home: CLLocationCoordinate2D) {
        let now = Date()
        func spot(_ dLat: Double, _ dLon: Double, daysAgo: Double, hours: Double, _ address: String, note: String? = nil) -> ParkingSpot {
            let date = now.addingTimeInterval(-daysAgo * 86400)
            return ParkingSpot(lat: 45.4859 + dLat, lon: 9.2048 + dLon, date: date, source: .speed, address: address,
                               note: note, retrieved: date.addingTimeInterval(hours * 3600))
        }
        spots = [
            spot(0.0012, -0.0008, daysAgo: 20, hours: 2, "Via Vittor Pisani 22"),
            spot(-0.0009, 0.0011, daysAgo: 12, hours: 1.5, "Via Napo Torriani 7"),
            spot(0.0016, 0.0019, daysAgo: 6, hours: 3, "Via Fabio Filzi 15", note: "Strisce blu"),
            ParkingSpot(lat: 45.4520, lon: 9.1735, date: now.addingTimeInterval(-3 * 86400), source: .bluetooth,
                        address: "Ripa di Porta Ticinese 41", retrieved: now.addingTimeInterval(-3 * 86400 + 5400)),
            ParkingSpot(lat: home.latitude + 0.0013, lon: home.longitude + 0.0030,
                        date: now.addingTimeInterval(-65 * 60), source: .speed, address: "Via Santa Radegonda 10",
                        note: "Garage, piano -2, colonna B7", expiry: now.addingTimeInterval(47 * 60), reminderMinutes: 10),
        ]
        save()
        version += 1
        // Foto di prova: un cartello disegnato.
        let image = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 600)).image { ctx in
            UIColor(red: 0.2, green: 0.25, blue: 0.32, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
            UIColor.systemYellow.setFill()
            ctx.fill(CGRect(x: 0, y: 420, width: 900, height: 40))
            let text = "P -2  ·  B7" as NSString
            text.draw(at: CGPoint(x: 160, y: 170), withAttributes: [
                .font: UIFont.systemFont(ofSize: 150, weight: .heavy), .foregroundColor: UIColor.white,
            ])
        }
        if let id = spots.last?.id { setPhoto(image, for: id) }
    }
    #endif
}

// MARK: - Notifiche del parcheggio

enum ParkingReminders {
    static let reminderID = "parking-reminder"
    static let expiredID = "parking-expired"
    static let parkedID = "parking-saved"

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Avviso prima della scadenza e alla scadenza del ticket.
    static func schedule(for spot: ParkingSpot?, now: Date = Date()) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [reminderID, expiredID])
        guard let spot, let expiry = spot.expiry, expiry > now else { return }
        let time = expiry.formatted(date: .omitted, time: .shortened)
        if let warn = spot.reminderDate, warn > now {
            let content = UNMutableNotificationContent()
            content.title = "Ticket in scadenza"
            content.body = "Il parcheggio in \(spot.title) scade alle \(time) (tra \(spot.reminderMinutes ?? 10) min)."
            content.sound = .default
            center.add(UNNotificationRequest(identifier: reminderID, content: content,
                                             trigger: UNTimeIntervalNotificationTrigger(timeInterval: warn.timeIntervalSince(now), repeats: false)))
        }
        let content = UNMutableNotificationContent()
        content.title = "Ticket scaduto"
        content.body = "Il parcheggio in \(spot.title) è scaduto alle \(time)."
        content.sound = .default
        center.add(UNNotificationRequest(identifier: expiredID, content: content,
                                         trigger: UNTimeIntervalNotificationTrigger(timeInterval: expiry.timeIntervalSince(now), repeats: false)))
    }

    /// "Auto parcheggiata": compare quando il parcheggio viene salvato da solo.
    static func notifyParked(address: String?) {
        let content = UNMutableNotificationContent()
        content.title = "Auto parcheggiata"
        content.body = (address.map { "In \($0). " } ?? "") + "Tocca per aggiungere ticket, foto o nota."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: parkedID, content: content, trigger: nil))
    }
}

/// Riceve i tocchi sulle notifiche e le mostra anche con l'app aperta.
final class NotificationHandler: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationHandler()

    /// Cambia quando va aperta la scheda del parcheggio (tocco su una sua notifica).
    @Published var openParking = 0

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier.hasPrefix("parking") {
            DispatchQueue.main.async { self.openParking += 1 }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

// MARK: - Live Activity del ticket

/// Conto alla rovescia del ticket sul blocco schermo. iOS permette di avviarla
/// solo con l'app aperta: se il ticket viene impostato prima, parte alla prossima apertura.
final class ParkingActivityManager {
    static let shared = ParkingActivityManager()

    private var shownID: UUID?
    private var shownState: ParkingActivityAttributes.ContentState?

    func update(for spot: ParkingSpot?) {
        guard !ProcessInfo.processInfo.arguments.contains("-screenshots") else { return }
        guard let spot, let expiry = spot.expiry, expiry > Date() else {
            endAll()
            return
        }
        let state = ParkingActivityAttributes.ContentState(expiry: expiry, reminderMinutes: spot.reminderMinutes ?? 10,
                                                           address: spot.title, note: spot.note)
        let running = Activity<ParkingActivityAttributes>.activities
        if shownID == spot.id, let activity = running.first {
            if state != shownState {
                shownState = state
                Task { await activity.update(ActivityContent(state: state, staleDate: expiry)) }
            }
            return
        }
        guard UIApplication.shared.applicationState == .active,
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        endAll()
        let attributes = ParkingActivityAttributes(parkedAt: spot.date)
        if (try? Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: expiry),
                                  pushType: nil)) != nil {
            shownID = spot.id
            shownState = state
        }
    }

    private func endAll() {
        shownID = nil
        shownState = nil
        for activity in Activity<ParkingActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}

// MARK: - Bluetooth e CarPlay dell'auto

/// Si accorge quando l'iPhone si scollega dall'auto (CarPlay o il Bluetooth scelto come
/// "auto"). Funziona solo mentre l'app è attiva o registra in background.
final class CarAudioMonitor: ObservableObject {
    static let shared = CarAudioMonitor()

    /// Dispositivo Bluetooth nuovo per cui chiedere "È la tua auto?".
    @Published var askName: String?

    var onDisconnect: (() -> Void)?
    var onConnect: (() -> Void)?

    private static let bluetoothPorts: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE]

    private init() {
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                               object: nil, queue: nil) { [weak self] n in self?.routeChanged(n) }
    }

    /// Da chiamare all'avvio, così il monitor viene creato.
    func start() {}

    static func isCar(_ port: AVAudioSession.Port, name: String, carName: String) -> Bool {
        if port == .carAudio { return true }
        return bluetoothPorts.contains(port) && !carName.isEmpty && name == carName
    }

    /// Nomi dei dispositivi Bluetooth collegati ora.
    static var connectedBluetoothNames: [String] {
        let session = AVAudioSession.sharedInstance()
        let ports = session.currentRoute.outputs + (session.availableInputs ?? [])
        var names: [String] = []
        for p in ports where bluetoothPorts.contains(p.portType) && !names.contains(p.portName) {
            names.append(p.portName)
        }
        return names
    }

    private func routeChanged(_ n: Notification) {
        guard Settings.parkingDetect != 0,
              let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        let carName = Settings.carBluetooth
        switch reason {
        case .oldDeviceUnavailable:
            guard let previous = n.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription else { return }
            if previous.outputs.contains(where: { Self.isCar($0.portType, name: $0.portName, carName: carName) }) {
                DispatchQueue.main.async { self.onDisconnect?() }
            }
        case .newDeviceAvailable:
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
            if outputs.contains(where: { Self.isCar($0.portType, name: $0.portName, carName: carName) }) {
                DispatchQueue.main.async { self.onConnect?() }
            } else if carName.isEmpty,
                      let bt = outputs.first(where: { Self.bluetoothPorts.contains($0.portType) }),
                      !Settings.askedBluetooth.contains(bt.portName) {
                Settings.askedBluetooth.append(bt.portName)
                DispatchQueue.main.async { self.askName = bt.portName }
            }
        default:
            break
        }
    }
}
