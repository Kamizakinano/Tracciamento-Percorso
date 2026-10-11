import Foundation
import CoreLocation

struct TrackPoint: Codable, Hashable {
    var lat: Double
    var lon: Double
    var time: Date

    init(lat: Double, lon: Double, time: Date) {
        self.lat = lat
        self.lon = lon
        self.time = time
    }

    init(_ location: CLLocation) {
        self.init(lat: location.coordinate.latitude, lon: location.coordinate.longitude, time: location.timestamp)
    }

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

// MARK: - Mezzo di trasporto

enum TravelMode: String, Codable, CaseIterable, Identifiable {
    case car, bike, foot

    var id: String { rawValue }

    var label: String {
        switch self {
        case .car: return "Auto"
        case .bike: return "Bici"
        case .foot: return "A piedi"
        }
    }

    var icon: String {
        switch self {
        case .car: return "car.fill"
        case .bike: return "bicycle"
        case .foot: return "figure.walk"
        }
    }

    /// Distanza entro cui una strada conta come "già percorsa".
    var threshold: Double {
        switch self {
        case .car: return 25
        case .bike: return 18
        case .foot: return 12
        }
    }

    /// Spostamento minimo tra due punti registrati.
    var minStep: Double {
        switch self {
        case .car: return 10
        case .bike: return 5
        case .foot: return 3
        }
    }

    /// Ricava il mezzo dalla velocità media (m/s).
    static func infer(speed: Double) -> TravelMode {
        if speed > 7 { return .car }   // > 25 km/h
        if speed > 2.2 { return .bike } // > 8 km/h
        return .foot
    }

    /// Ricava il mezzo di un viaggio da quanta strada è stata fatta a ogni velocità
    /// (non dalla media, che le soste e la camminata dopo il parcheggio abbassano).
    /// Auto: almeno un quarto della strada sopra i 29 km/h, o un decimo sopra i 40 km/h.
    static func infer(points: [TrackPoint]) -> TravelMode? {
        guard points.count > 1 else { return nil }
        var moving = 0.0, fast = 0.0, veryFast = 0.0, cycling = 0.0
        for i in 1..<points.count {
            let dt = points[i].time.timeIntervalSince(points[i - 1].time)
            guard dt > 0 else { continue }
            let d = Geo.distance(points[i - 1], points[i])
            let v = d / dt
            guard v >= 0.8, v < 70 else { continue } // fermo, oppure errore del GPS
            moving += d
            if v > 8 { fast += d }
            if v > 11 { veryFast += d }
            if v > 2.5 { cycling += d }
        }
        guard moving >= 50 else { return nil }
        if fast >= moving * 0.25 || veryFast >= moving * 0.1 { return .car }
        if cycling >= moving * 0.5 { return .bike }
        return .foot
    }
}

// MARK: - Viaggio

struct Trip: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String?
    var start: Date
    var end: Date?
    var points: [TrackPoint]
    var mode: TravelMode?
    /// Registrato automaticamente (senza premere Avvia).
    var automatic: Bool?
    /// Frazione del viaggio su strade nuove al momento della registrazione (0...1).
    var newFraction: Double?
    /// Città o paese, ricavato dalla posizione per le statistiche.
    var locality: String?

    var distance: Double { Geo.length(of: points) }

    var duration: TimeInterval {
        guard let first = points.first, let last = points.last else { return 0 }
        return max(0, last.time.timeIntervalSince(first.time))
    }

    /// Mezzo salvato, oppure ricavato dalla velocità media.
    var effectiveMode: TravelMode {
        if let mode { return mode }
        if let inferred = TravelMode.infer(points: points) { return inferred }
        let t = duration
        return TravelMode.infer(speed: t > 0 ? distance / t : 0)
    }

    var title: String {
        if let name, !name.isEmpty { return name }
        return start.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Impostazioni

/// Chiavi e valori delle impostazioni (le viste usano @AppStorage con le stesse chiavi).
enum Settings {
    static let showHistory = "showHistory"
    static let alertEnabled = "alertEnabled"
    static let threshold = "threshold"         // 0 = in base al mezzo
    static let travelMode = "travelMode"       // "" = rilevamento automatico
    static let historyDays = "historyDays"     // 0 = sempre
    static let modeFilter = "modeFilter"       // "" = tutti i mezzi
    static let autoRecord = "autoRecord"
    static let voiceAlert = "voiceAlert"       // 0 mai, 1 cuffie/CarPlay, 2 sempre
    static let mapStyle = "mapStyle"
    static let navigationVoice = "navigationVoice"
    static let parkingDetectKey = "parkingDetect"     // 0 no, 1 velocità e Bluetooth, 2 solo Bluetooth
    static let carBluetoothKey = "carBluetooth"       // nome del Bluetooth dell'auto
    static let parkingReminder = "parkingReminder"    // minuti di preavviso del ticket
    private static let askedBluetoothKey = "askedBluetooth"

    private static var d: UserDefaults { .standard }

    static var alertsOn: Bool { d.object(forKey: alertEnabled) as? Bool ?? true }
    static var autoRecordOn: Bool { d.bool(forKey: autoRecord) }
    static var fixedMode: TravelMode? { TravelMode(rawValue: d.string(forKey: travelMode) ?? "") }
    static var voiceMode: Int { d.object(forKey: voiceAlert) as? Int ?? 1 }
    static var navigationVoiceOn: Bool { d.object(forKey: navigationVoice) as? Bool ?? true }
    static var parkingDetect: Int { d.object(forKey: parkingDetectKey) as? Int ?? 1 }
    static var carBluetooth: String { d.string(forKey: carBluetoothKey) ?? "" }
    static var parkingReminderMinutes: Int { d.object(forKey: parkingReminder) as? Int ?? 10 }
    /// Dispositivi Bluetooth per cui è già stato chiesto "È la tua auto?".
    static var askedBluetooth: [String] {
        get { d.stringArray(forKey: askedBluetoothKey) ?? [] }
        set { d.set(newValue, forKey: askedBluetoothKey) }
    }

    static func threshold(for mode: TravelMode) -> Double {
        let v = d.double(forKey: threshold)
        return v > 0 ? v : mode.threshold
    }

    static var filter: TripFilter {
        TripFilter(days: d.integer(forKey: historyDays), mode: TravelMode(rawValue: d.string(forKey: modeFilter) ?? ""))
    }
}

/// Quali viaggi contano come "strade già fatte".
struct TripFilter: Equatable {
    var days: Int = 0
    var mode: TravelMode?

    func includes(_ trip: Trip, now: Date = Date()) -> Bool {
        if days > 0, (trip.end ?? trip.start) < now.addingTimeInterval(-Double(days) * 86400) { return false }
        if let mode, trip.effectiveMode != mode { return false }
        return true
    }
}

// MARK: - Geometria

enum Geo {
    /// Distanza in metri tra due punti (formula dell'emisenoverso).
    static func distance(_ a: TrackPoint, _ b: TrackPoint) -> Double {
        distance(a.lat, a.lon, b.lat, b.lon)
    }

    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        distance(a.latitude, a.longitude, b.latitude, b.longitude)
    }

    static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) +
            cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    static func length(of points: [TrackPoint]) -> Double {
        guard points.count > 1 else { return 0 }
        var d = 0.0
        for i in 1..<points.count { d += distance(points[i - 1], points[i]) }
        return d
    }

    static func length(of coords: [CLLocationCoordinate2D]) -> Double {
        guard coords.count > 1 else { return 0 }
        var d = 0.0
        for i in 1..<coords.count { d += distance(coords[i - 1], coords[i]) }
        return d
    }

    /// Punti intermedi ogni `step` metri lungo una linea (estremi compresi).
    static func densify(_ coords: [CLLocationCoordinate2D], step: Double) -> [CLLocationCoordinate2D] {
        guard let first = coords.first else { return [] }
        var out = [first]
        for i in 1..<max(1, coords.count) {
            let a = coords[i - 1], b = coords[i]
            let n = Int(distance(a, b) / step)
            if n > 1 {
                for s in 1..<n {
                    let f = Double(s) / Double(n)
                    out.append(CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * f,
                                                      longitude: a.longitude + (b.longitude - a.longitude) * f))
                }
            }
            out.append(b)
        }
        return out
    }

    /// Frazione (0...1) di una linea che passa su strade non ancora percorse.
    static func newFraction(of coords: [CLLocationCoordinate2D], index: SpatialIndex, within meters: Double) -> Double {
        let samples = densify(coords, step: 15)
        guard !samples.isEmpty else { return 1 }
        let new = samples.filter { !index.isNear($0, within: meters) }.count
        return Double(new) / Double(samples.count)
    }

    /// Distanza (metri) da un punto a una linea spezzata, in proiezione locale.
    static func distance(from p: CLLocationCoordinate2D, toPolyline coords: [CLLocationCoordinate2D]) -> Double {
        guard let first = coords.first else { return .infinity }
        guard coords.count > 1 else { return distance(p, first) }
        let mLat = 111_195.0
        let mLon = 111_195.0 * cos(p.latitude * .pi / 180)
        func xy(_ c: CLLocationCoordinate2D) -> (Double, Double) {
            ((c.longitude - p.longitude) * mLon, (c.latitude - p.latitude) * mLat)
        }
        var best = Double.infinity
        for i in 1..<coords.count {
            let (ax, ay) = xy(coords[i - 1]), (bx, by) = xy(coords[i])
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? max(0, min(1, -(ax * dx + ay * dy) / len2)) : 0
            let x = ax + t * dx, y = ay + t * dy
            best = min(best, sqrt(x * x + y * y))
        }
        return best
    }

    /// "250 m" oppure "1,2 km" (per le indicazioni di navigazione).
    static func formatShort(_ meters: Double) -> String {
        if meters < 1000 {
            let rounded = meters < 100 ? (meters / 10).rounded() * 10 : (meters / 50).rounded() * 50
            return "\(Int(max(0, rounded))) m"
        }
        return (meters / 1000).formatted(.number.precision(.fractionLength(1))) + " km"
    }

    static func formatKm(_ meters: Double) -> String {
        (meters / 1000).formatted(.number.precision(.fractionLength(meters < 100_000 ? 2 : 0))) + " km"
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        return m < 60 ? "\(m) min" : "\(m / 60) h \(m % 60) min"
    }
}

// MARK: - Indice spaziale

/// Indice a griglia dei punti già percorsi: dice velocemente se una posizione
/// è vicina a una strada già fatta e quante volte (in quanti viaggi) ci sei passato.
struct SpatialIndex {
    private struct Cell: Hashable { let i: Int; let j: Int }
    private struct Entry { let lat: Double; let lon: Double; let trip: Int32 }

    private static let cellDeg = 0.0007   // ~55-75 m
    private static let densifyStep = 10.0 // metri tra punti interpolati

    private var cells: [Cell: [Entry]] = [:]
    private(set) var tripCount = 0

    var isEmpty: Bool { cells.isEmpty }

    private func cell(_ lat: Double, _ lon: Double) -> Cell {
        Cell(i: Int(floor(lat / Self.cellDeg)), j: Int(floor(lon / Self.cellDeg)))
    }

    private mutating func insert(_ lat: Double, _ lon: Double, trip: Int32) {
        cells[cell(lat, lon), default: []].append(Entry(lat: lat, lon: lon, trip: trip))
    }

    /// Aggiunge un tracciato inserendo punti intermedi, così anche i tratti
    /// registrati ad alta velocità (punti radi) vengono riconosciuti.
    mutating func add(_ points: [TrackPoint]) {
        let id = Int32(tripCount)
        tripCount += 1
        for p in Geo.densify(points.map(\.coordinate), step: Self.densifyStep) {
            insert(p.latitude, p.longitude, trip: id)
        }
    }

    func isNear(_ p: TrackPoint, within meters: Double) -> Bool {
        isNear(p.coordinate, within: meters)
    }

    func isNear(_ p: CLLocationCoordinate2D, within meters: Double) -> Bool {
        var found = false
        visit(p, within: meters) { _ in found = true; return false }
        return found
    }

    /// In quanti viaggi diversi sei passato entro `meters` da questo punto.
    func visits(near p: CLLocationCoordinate2D, within meters: Double) -> Int {
        var trips = Set<Int32>()
        visit(p, within: meters) { trips.insert($0.trip); return true }
        return trips.count
    }

    /// Chiama `body` per ogni punto entro `meters`; se `body` restituisce false si ferma.
    private func visit(_ p: CLLocationCoordinate2D, within meters: Double, _ body: (Entry) -> Bool) {
        let c = cell(p.latitude, p.longitude)
        for di in -1...1 {
            for dj in -1...1 {
                guard let entries = cells[Cell(i: c.i + di, j: c.j + dj)] else { continue }
                for e in entries where Geo.distance(p.latitude, p.longitude, e.lat, e.lon) <= meters {
                    if !body(e) { return }
                }
            }
        }
    }
}

/// Linee delle strade già percorse, divise per frequenza di passaggio.
struct HistoryLines {
    /// Livello 0: una volta · 1: 2-3 volte · 2: 4 o più volte.
    var levels: [[[CLLocationCoordinate2D]]] = [[], [], []]

    static func level(forVisits n: Int) -> Int {
        n >= 4 ? 2 : (n >= 2 ? 1 : 0)
    }

    static func build(trips: [Trip], index: SpatialIndex, within meters: Double = 15) -> HistoryLines {
        var out = HistoryLines()
        for trip in trips where trip.points.count > 1 {
            var run: [CLLocationCoordinate2D] = []
            var runLevel = -1
            for p in trip.points {
                let lvl = level(forVisits: index.visits(near: p.coordinate, within: meters))
                if lvl != runLevel {
                    if run.count > 1 { out.levels[runLevel].append(run) }
                    // Il nuovo tratto riparte dall'ultimo punto, così la linea resta continua.
                    run = run.last.map { [$0] } ?? []
                    runLevel = lvl
                }
                run.append(p.coordinate)
            }
            if run.count > 1 && runLevel >= 0 { out.levels[runLevel].append(run) }
        }
        return out
    }
}

/// Luogo trovato con la ricerca, mostrato sulla mappa con un segnaposto.
struct Place: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let coordinate: CLLocationCoordinate2D
    /// Indirizzo (per i risultati della ricerca).
    var address: String? = nil

    static func == (a: Place, b: Place) -> Bool { a.id == b.id }
}
