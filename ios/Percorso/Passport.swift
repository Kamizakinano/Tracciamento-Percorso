import Foundation
import CoreLocation
import UserNotifications

// MARK: - Luoghi visitati

enum PlaceKind: String, Codable, CaseIterable, Identifiable {
    case comune, provincia, regione, stato

    var id: String { rawValue }

    var plural: String {
        switch self {
        case .comune: return "Comuni"
        case .provincia: return "Province"
        case .regione: return "Regioni"
        case .stato: return "Stati"
        }
    }

    var singular: String {
        switch self {
        case .comune: return "comune"
        case .provincia: return "provincia"
        case .regione: return "regione"
        case .stato: return "stato"
        }
    }

    var icon: String {
        switch self {
        case .comune: return "building.2.fill"
        case .provincia: return "map.fill"
        case .regione: return "mountain.2.fill"
        case .stato: return "globe.europe.africa.fill"
        }
    }
}

struct VisitedPlace: Codable, Identifiable, Hashable {
    var kind: PlaceKind
    var name: String
    /// Regione (per comuni e province) o stato (per le regioni), per raggrupparli.
    var parent: String?
    var country: String?
    var firstVisit: Date
    /// Giorni (inizio giornata) in cui ci sei stato: per "Seconda visita" e "Esploratore metodico".
    var visitDays: [Date]?

    var id: String { Self.key(kind, name, country) }

    static func key(_ kind: PlaceKind, _ name: String, _ country: String?) -> String {
        "\(kind.rawValue)|\(country ?? "")|\(name.lowercased())"
    }
}

/// Dove si trovava un punto del viaggio (dal geocoder di Apple).
struct PlaceSample: Codable, Equatable {
    var comune: String?
    var provincia: String?
    var regione: String?
    var stato: String?
    var countryCode: String?

    init(comune: String?, provincia: String?, regione: String?, stato: String?, countryCode: String?) {
        self.comune = comune
        self.provincia = provincia
        self.regione = regione
        self.stato = stato
        self.countryCode = countryCode
    }

    init(_ p: CLPlacemark) {
        self.init(comune: p.locality ?? p.subLocality, provincia: p.subAdministrativeArea,
                  regione: p.administrativeArea, stato: p.country, countryCode: p.isoCountryCode)
    }
}

// MARK: - Medaglie

enum MedalLevel: Int, Comparable {
    case locked, bronze, silver, gold, platinum, diamond

    static func < (a: MedalLevel, b: MedalLevel) -> Bool { a.rawValue < b.rawValue }

    var name: String {
        switch self {
        case .locked: return "Da sbloccare"
        case .bronze: return "Bronzo"
        case .silver: return "Argento"
        case .gold: return "Oro"
        case .platinum: return "Platino"
        case .diamond: return "Diamante"
        }
    }
}

enum MedalGroup: String, CaseIterable {
    case places = "Luoghi visitati a piedi"
    case exploration = "Esplorazione"
    case distance = "Chilometri"
    case records = "Imprese"
    case nature = "Natura"
    case special = "Sfide speciali"
}

/// Dati per le medaglie che non vengono dai luoghi del Passaporto.
struct MedalExtras: Equatable {
    /// Inizio di ogni "strada nuova" percorsa (tratto nuovo continuo di almeno 150 m).
    var newStreetRuns: [Date] = []
    /// Luoghi di "Scopri" raggiunti.
    var sights: [SightVisit] = []
}

struct MedalDefinition {
    let id: String
    let title: String
    let icon: String
    let group: MedalGroup
    /// Soglie per bronzo, argento, oro, platino e diamante (anche meno di cinque).
    let thresholds: [Double]
    let unit: String

    static let all: [MedalDefinition] = [
        // Luoghi (solo a piedi)
        MedalDefinition(id: "comune", title: "Comuni", icon: PlaceKind.comune.icon, group: .places, thresholds: [5, 25, 100, 250, 500], unit: "comuni"),
        MedalDefinition(id: "provincia", title: "Province", icon: PlaceKind.provincia.icon, group: .places, thresholds: [2, 5, 15, 40, 80], unit: "province"),
        MedalDefinition(id: "regione", title: "Regioni", icon: PlaceKind.regione.icon, group: .places, thresholds: [2, 5, 10, 20, 40], unit: "regioni"),
        MedalDefinition(id: "stato", title: "Stati", icon: PlaceKind.stato.icon, group: .places, thresholds: [2, 5, 10, 20, 40], unit: "stati"),
        MedalDefinition(id: "giornata", title: "Giornata da esploratore", icon: "sun.max.fill", group: .places, thresholds: [3, 5, 10, 20], unit: "comuni nuovi in un giorno"),
        // Chilometri
        MedalDefinition(id: "km", title: "Km totali", icon: "speedometer", group: .distance, thresholds: [100, 500, 1000, 5000, 10000], unit: "km"),
        MedalDefinition(id: "kmPiedi", title: "A piedi", icon: "figure.walk", group: .distance, thresholds: [10, 50, 100, 500, 1000], unit: "km a piedi"),
        MedalDefinition(id: "kmBici", title: "In bici", icon: "bicycle", group: .distance, thresholds: [25, 100, 500, 1000, 3000], unit: "km in bici"),
        MedalDefinition(id: "kmAuto", title: "In auto", icon: "car.fill", group: .distance, thresholds: [500, 2000, 5000, 10000, 25000], unit: "km in auto"),
        MedalDefinition(id: "nuove", title: "Strade nuove", icon: "sparkles", group: .distance, thresholds: [10, 100, 500, 1000, 2500], unit: "km su strade nuove"),
        // Imprese
        MedalDefinition(id: "lungo", title: "Viaggio lungo", icon: "road.lanes", group: .records, thresholds: [50, 100, 300, 500, 1000], unit: "km in un viaggio"),
        MedalDefinition(id: "mese", title: "Mese da record", icon: "calendar", group: .records, thresholds: [100, 300, 600, 1000, 2000], unit: "km in un mese"),
        MedalDefinition(id: "viaggi", title: "Viaggiatore", icon: "point.topleft.down.curvedto.point.bottomright.up", group: .records, thresholds: [10, 50, 100, 250, 500], unit: "viaggi"),
        // Esplorazione
        MedalDefinition(id: "strade", title: "Cacciatore di strade", icon: "signpost.right.fill", group: .exploration, thresholds: [10, 25, 50, 100, 250], unit: "strade mai percorse"),
        MedalDefinition(id: "ritorno", title: "Seconda visita", icon: "arrow.uturn.backward.circle.fill", group: .exploration, thresholds: [1, 5, 10, 25, 50], unit: "comuni rivisitati"),
        MedalDefinition(id: "metodico", title: "Esploratore metodico", icon: "calendar.badge.checkmark", group: .exploration, thresholds: [1, 3, 5, 10], unit: "comuni in 3+ giornate"),
        MedalDefinition(id: "attrazioni", title: "Occhio attento", icon: "eye.fill", group: .exploration, thresholds: [5, 20, 50, 100, 250], unit: "attrazioni raggiunte"),
        // Natura
        MedalDefinition(id: "parchi", title: "Parchi", icon: "leaf.fill", group: .nature, thresholds: [3, 10, 25, 50], unit: "parchi visitati"),
        MedalDefinition(id: "laghi", title: "Laghi", icon: "water.waves", group: .nature, thresholds: [1, 5, 10, 20], unit: "laghi raggiunti"),
        MedalDefinition(id: "panorami", title: "Punti panoramici", icon: "binoculars.fill", group: .nature, thresholds: [1, 5, 15, 30], unit: "panorami raggiunti"),
        // Sfide speciali
        MedalDefinition(id: "autunno", title: "Autunno in viaggio", icon: "leaf.arrow.triangle.circlepath", group: .special, thresholds: [3, 5, 10], unit: "comuni in un autunno"),
        MedalDefinition(id: "weekend", title: "Weekend esplorativo", icon: "sun.and.horizon.fill", group: .special, thresholds: [5, 10, 20, 40], unit: "strade nuove in un weekend"),
    ]
}

/// Record personali: le "classifiche" dei tuoi viaggi.
struct PersonalRecords: Equatable {
    struct Entry: Equatable, Identifiable {
        let id: String
        let title: String
        let date: Date
        let km: Double
    }

    var longestTrips: [Entry] = []
    var bestMonths: [Entry] = []
    var bestDays: [Entry] = []

    static func compute(_ trips: [Trip], top: Int = 3, calendar: Calendar = .current) -> PersonalRecords {
        var r = PersonalRecords()
        r.longestTrips = trips.filter { $0.distance > 0 }.sorted { $0.distance > $1.distance }.prefix(top).map {
            Entry(id: $0.id.uuidString, title: $0.title, date: $0.start, km: $0.distance / 1000)
        }
        func best(_ component: Calendar.Component, title: (Date) -> String) -> [Entry] {
            var totals: [Date: Double] = [:]
            for t in trips {
                let key = calendar.dateInterval(of: component, for: t.start)?.start ?? t.start
                totals[key, default: 0] += t.distance / 1000
            }
            return totals.filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(top).map {
                Entry(id: "\(component)-\($0.key.timeIntervalSince1970)", title: title($0.key), date: $0.key, km: $0.value)
            }
        }
        r.bestMonths = best(.month) { $0.formatted(.dateTime.month(.wide).year()) }
        r.bestDays = best(.day) { $0.formatted(date: .abbreviated, time: .omitted) }
        return r
    }
}

struct MedalProgress: Identifiable, Equatable {
    let id: String
    let title: String
    let icon: String
    let group: MedalGroup
    let unit: String
    let value: Double
    let level: MedalLevel
    /// Prossima soglia (nil = livello massimo raggiunto).
    let next: Double?
    /// Soglia del livello raggiunto (0 se nessuno).
    let reached: Double

    /// 0...1 verso la prossima soglia.
    var progress: Double {
        guard let next else { return 1 }
        return max(0, min(1, (value - reached) / max(1, next - reached)))
    }

    var valueText: String { Self.format(value) }

    static func format(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0))) }
}

// MARK: - Passaporto

/// Raccolta dei luoghi visitati e delle medaglie. Funzioni pure: facili da provare.
struct Passport: Codable {
    var places: [String: VisitedPlace] = [:]
    /// Viaggi già analizzati.
    var processedTrips: Set<UUID> = []
    /// Medaglie già sbloccate ("comune.2" = comuni livello argento), con la data.
    var earned: [String: Date] = [:]
    /// Risultati del geocoder per celle di ~500 m (per non ripetere le richieste).
    var cache: [String: PlaceSample] = [:]
    /// Versione delle regole: con la 2 contano solo i luoghi visitati a piedi.
    var version: Int?

    static let currentVersion = 3
    /// Un luogo conta se ci cammini per almeno questi metri.
    static let minWalk = 200.0
    /// Oltre questa velocità (m/s, ~9 km/h) non stai camminando.
    static let walkMaxSpeed = 2.5

    /// Regole cambiate: ricalcola luoghi e medaglie dai viaggi (la cache dei nomi resta).
    mutating func migrateIfNeeded() -> Bool {
        guard version != Self.currentVersion else { return false }
        places = [:]
        processedTrips = []
        earned = [:]
        version = Self.currentVersion
        return true
    }

    /// Tratti del viaggio percorsi a piedi per almeno `minWalk` metri.
    /// Nei viaggi in auto o in bici contano solo quelli all'inizio o alla fine
    /// (prima di salire o dopo il parcheggio): le code in mezzo non sono visite.
    static func walkingStretches(of points: [TrackPoint], mode: TravelMode) -> [[TrackPoint]] {
        guard points.count > 1 else { return [] }
        var out: [[TrackPoint]] = []
        var start = 0, walked = 0.0
        func close(at end: Int) {
            if end > start, walked >= minWalk,
               mode == .foot || start == 0 || end == points.count - 1 {
                out.append(Array(points[start...end]))
            }
        }
        for i in 1..<points.count {
            let dt = points[i].time.timeIntervalSince(points[i - 1].time)
            let d = Geo.distance(points[i - 1], points[i])
            if dt > 0 && d / dt <= walkMaxSpeed {
                walked += d
            } else {
                close(at: i - 1)
                start = i
                walked = 0
            }
        }
        close(at: points.count - 1)
        return out
    }

    /// Punti da analizzare: solo dove hai camminato (inizio, uno ogni km, fine di ogni tratto).
    static func walkingSamples(of trip: Trip) -> [TrackPoint] {
        walkingStretches(of: trip.points, mode: trip.effectiveMode).flatMap { samples(of: $0, every: 1000) }
    }

    func list(_ kind: PlaceKind) -> [VisitedPlace] {
        places.values.filter { $0.kind == kind }.sorted { $0.firstVisit > $1.firstVisit }
    }

    func count(_ kind: PlaceKind) -> Int { places.values.filter { $0.kind == kind }.count }

    /// Registra un punto visitato; restituisce i luoghi nuovi.
    @discardableResult
    mutating func record(_ s: PlaceSample, at date: Date) -> [VisitedPlace] {
        var added: [VisitedPlace] = []
        func add(_ kind: PlaceKind, _ name: String?, parent: String?) {
            guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            let country = kind == .stato ? s.countryCode ?? name : s.countryCode
            let key = VisitedPlace.key(kind, name, country)
            let day = Calendar.current.startOfDay(for: date)
            if var existing = places[key] {
                if date < existing.firstVisit { existing.firstVisit = date }
                if !(existing.visitDays ?? []).contains(day) { existing.visitDays = (existing.visitDays ?? []) + [day] }
                places[key] = existing
            } else {
                let place = VisitedPlace(kind: kind, name: name, parent: parent, country: country, firstVisit: date,
                                         visitDays: [day])
                places[key] = place
                added.append(place)
            }
        }
        add(.stato, s.stato, parent: nil)
        add(.regione, s.regione, parent: s.stato)
        add(.provincia, s.provincia, parent: s.regione)
        add(.comune, s.comune, parent: s.provincia ?? s.regione)
        return added
    }

    /// Il massimo di comuni visitati per la prima volta nello stesso giorno.
    func bestDay(calendar: Calendar = .current) -> Int {
        var perDay: [Date: Int] = [:]
        for p in places.values where p.kind == .comune {
            perDay[calendar.startOfDay(for: p.firstVisit), default: 0] += 1
        }
        return perDay.values.max() ?? 0
    }

    /// Comuni visitati in almeno `days` giornate diverse.
    func comuni(visitedOnDays days: Int) -> Int {
        places.values.filter { $0.kind == .comune && ($0.visitDays?.count ?? 1) >= days }.count
    }

    /// Il massimo di comuni visitati durante uno stesso autunno (23 settembre – 20 dicembre).
    func bestAutumn(calendar: Calendar = .current) -> Int {
        var perYear: [Int: Set<String>] = [:]
        for p in places.values where p.kind == .comune {
            for d in p.visitDays ?? [p.firstVisit] where Self.isAutumn(d, calendar: calendar) {
                perYear[calendar.component(.year, from: d), default: []].insert(p.id)
            }
        }
        return perYear.values.map(\.count).max() ?? 0
    }

    static func isAutumn(_ date: Date, calendar: Calendar = .current) -> Bool {
        let m = calendar.component(.month, from: date), d = calendar.component(.day, from: date)
        return (m == 9 && d >= 23) || m == 10 || m == 11 || (m == 12 && d <= 20)
    }

    /// Il massimo di strade nuove in uno stesso weekend.
    static func bestWeekend(_ runs: [Date], calendar: Calendar = .current) -> Int {
        var perWeekend: [Date: Int] = [:]
        for r in runs {
            guard let w = calendar.dateIntervalOfWeekend(containing: r) else { continue }
            perWeekend[w.start, default: 0] += 1
        }
        return perWeekend.values.max() ?? 0
    }

    /// "Strade nuove": tratti continui di almeno `minLength` metri lontani da tutto
    /// quello che avevi percorso prima (viaggi in ordine di data).
    static func newStreetRuns(_ trips: [Trip], minLength: Double = 150, within meters: Double = 20) -> [Date] {
        var index = SpatialIndex()
        var runs: [Date] = []
        for trip in trips.sorted(by: { $0.start < $1.start }) where trip.points.count > 1 {
            var runStart: Date?
            var runLength = 0.0
            for i in 1..<trip.points.count {
                let p = trip.points[i]
                if index.isNear(p, within: meters) {
                    if runLength >= minLength, let s = runStart { runs.append(s) }
                    runStart = nil
                    runLength = 0
                } else {
                    if runStart == nil { runStart = trip.points[i - 1].time }
                    runLength += Geo.distance(trip.points[i - 1], p)
                }
            }
            if runLength >= minLength, let s = runStart { runs.append(s) }
            index.add(trip.points)
        }
        return runs
    }

    func medals(trips: [Trip], extras: MedalExtras = MedalExtras()) -> [MedalProgress] {
        func seen(_ kinds: Set<SightKind>) -> Double { Double(extras.sights.filter { kinds.contains($0.kind) }.count) }
        let nature: Set<SightKind> = [.park, .lake, .viewpoint]
        let newKm = trips.reduce(0.0) { $0 + $1.distance * ($1.newFraction ?? 0) } / 1000
        let longestKm = (trips.map(\.distance).max() ?? 0) / 1000
        func km(_ mode: TravelMode?) -> Double {
            trips.filter { mode == nil || $0.effectiveMode == mode }.reduce(0.0) { $0 + $1.distance } / 1000
        }
        let bestMonth = PersonalRecords.compute(trips, top: 1).bestMonths.first?.km ?? 0
        return MedalDefinition.all.map { def in
            let value: Double
            switch def.id {
            case "giornata": value = Double(bestDay())
            case "nuove": value = newKm
            case "lungo": value = longestKm
            case "km": value = km(nil)
            case "kmPiedi": value = km(.foot)
            case "kmBici": value = km(.bike)
            case "kmAuto": value = km(.car)
            case "mese": value = bestMonth
            case "viaggi": value = Double(trips.count)
            case "strade": value = Double(extras.newStreetRuns.count)
            case "ritorno": value = Double(comuni(visitedOnDays: 2))
            case "metodico": value = Double(comuni(visitedOnDays: 3))
            case "attrazioni": value = seen(Set(SightKind.allCases).subtracting(nature))
            case "parchi": value = seen([.park])
            case "laghi": value = seen([.lake])
            case "panorami": value = seen([.viewpoint])
            case "autunno": value = Double(bestAutumn())
            case "weekend": value = Double(Self.bestWeekend(extras.newStreetRuns))
            default: value = Double(PlaceKind(rawValue: def.id).map(count) ?? 0)
            }
            let reachedCount = def.thresholds.filter { value >= $0 }.count
            let level = MedalLevel(rawValue: reachedCount) ?? .locked
            return MedalProgress(id: def.id, title: def.title, icon: def.icon, group: def.group, unit: def.unit, value: value,
                                 level: level,
                                 next: reachedCount < def.thresholds.count ? def.thresholds[reachedCount] : nil,
                                 reached: reachedCount > 0 ? def.thresholds[reachedCount - 1] : 0)
        }
    }

    /// Medaglie sbloccate adesso e non ancora registrate (le segna come ottenute).
    mutating func unlockNew(_ medals: [MedalProgress], now: Date = Date()) -> [MedalProgress] {
        var unlocked: [MedalProgress] = []
        for m in medals where m.level > .locked {
            for raw in 1...m.level.rawValue {
                let key = "\(m.id).\(raw)"
                if earned[key] == nil {
                    earned[key] = now
                    if raw == m.level.rawValue { unlocked.append(m) }
                }
            }
        }
        return unlocked
    }

    /// Punti del viaggio da analizzare: inizio, uno ogni `every` metri, fine.
    static func samples(of points: [TrackPoint], every: Double = 1500) -> [TrackPoint] {
        guard let first = points.first else { return [] }
        var out = [first]
        var run = 0.0
        for i in 1..<max(1, points.count) {
            run += Geo.distance(points[i - 1], points[i])
            if run >= every {
                out.append(points[i])
                run = 0
            }
        }
        if let last = points.last, points.count > 1, out.last != last { out.append(last) }
        return out
    }

    /// Cella di ~500 m per la cache del geocoder.
    static func cell(_ c: CLLocationCoordinate2D) -> String {
        "\(Int((c.latitude / 0.005).rounded())):\(Int((c.longitude / 0.005).rounded()))"
    }
}

// MARK: - Archivio e analisi

/// Passaporto salvato in Documents/passport.json; analizza i viaggi in background.
final class PassportStore: ObservableObject {
    @Published private(set) var passport = Passport()
    /// Viaggi ancora da analizzare (per la scritta di avanzamento).
    @Published private(set) var pendingTrips = 0

    private let fileURL: URL
    private let notify: Bool
    private var running = false
    private var latestTrips: [Trip] = []
    private var lastLive: CLLocation?
    private var liveBusy = false
    /// Dove hai iniziato a camminare (per il controllo dal vivo).
    private var walkStart: CLLocation?

    init(directory: URL = TripStore.documents, notify: Bool = true) {
        fileURL = directory.appendingPathComponent("passport.json")
        self.directory = directory
        self.notify = notify
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(Passport.self, from: data) {
            passport = saved
        }
        if passport.migrateIfNeeded() { save() }
    }

    /// Strade nuove (ricalcolate quando cambiano i viaggi).
    @Published private(set) var newStreetRuns: [Date] = []
    private var streetsToken = 0
    private let directory: URL

    var extras: MedalExtras {
        MedalExtras(newStreetRuns: newStreetRuns, sights: DiscoverService.loadVisits(directory: directory))
    }

    var medals: [MedalProgress] { passport.medals(trips: latestTrips, extras: extras) }
    var records: PersonalRecords { PersonalRecords.compute(latestTrips) }

    /// Analizza i viaggi nuovi (pochi alla volta: Apple limita le richieste).
    func update(with trips: [Trip]) {
        latestTrips = trips
        computeStreets(trips)
        pendingTrips = trips.filter { !passport.processedTrips.contains($0.id) && $0.points.count > 1 }.count
        guard !running, pendingTrips > 0 else {
            checkMedals()
            return
        }
        running = true
        Task { @MainActor in
            let geocoder = CLGeocoder()
            let firstRun = passport.processedTrips.isEmpty
            var newPlaces: [VisitedPlace] = []
            let todo = latestTrips.filter { !passport.processedTrips.contains($0.id) && $0.points.count > 1 }
                .sorted { $0.start < $1.start }
            tripLoop: for trip in todo {
                for p in Passport.walkingSamples(of: trip) {
                    let cell = Passport.cell(p.coordinate)
                    var sample = passport.cache[cell]
                    if sample == nil {
                        do {
                            let placemark = try await geocoder
                                .reverseGeocodeLocation(CLLocation(latitude: p.lat, longitude: p.lon)).first
                            sample = placemark.map(PlaceSample.init) ?? PlaceSample(comune: nil, provincia: nil, regione: nil, stato: nil, countryCode: nil)
                            passport.cache[cell] = sample
                        } catch {
                            break tripLoop // niente rete o troppe richieste: si riprova più tardi
                        }
                        try? await Task.sleep(nanoseconds: 1_300_000_000) // limite di Apple
                    }
                    if let sample { newPlaces += passport.record(sample, at: p.time) }
                }
                passport.processedTrips.insert(trip.id)
                pendingTrips = max(0, pendingTrips - 1)
                save()
                // Un viaggio appena finito: avvisa dei comuni nuovi (non per i vecchi viaggi).
                if !firstRun, Date().timeIntervalSince(trip.end ?? trip.start) < 3600 {
                    notifyNewComuni(newPlaces.filter { $0.kind == .comune })
                }
                newPlaces = []
            }
            running = false
            checkMedals(summary: firstRun)
            save()
        }
    }

    /// Durante la registrazione: avvisa appena visiti a piedi un comune nuovo
    /// (dopo almeno 200 m camminati).
    func live(_ location: CLLocation, onFoot: Bool) {
        guard onFoot, location.speed <= Passport.walkMaxSpeed else {
            walkStart = nil
            return
        }
        guard let start = walkStart else {
            walkStart = location
            return
        }
        guard !liveBusy, location.horizontalAccuracy >= 0, location.horizontalAccuracy < 100,
              location.distance(from: start) >= Passport.minWalk else { return }
        if let last = lastLive, location.distance(from: last) < 500 || location.timestamp.timeIntervalSince(last.timestamp) < 90 { return }
        lastLive = location
        let cell = Passport.cell(location.coordinate)
        if let cached = passport.cache[cell] {
            apply(live: cached, at: location.timestamp)
            return
        }
        liveBusy = true
        Task { @MainActor in
            let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
            liveBusy = false
            guard let placemark else { return }
            let sample = PlaceSample(placemark)
            passport.cache[cell] = sample
            apply(live: sample, at: location.timestamp)
        }
    }

    private func apply(live sample: PlaceSample, at date: Date) {
        let added = passport.record(sample, at: date)
        guard !added.isEmpty else { return }
        save()
        notifyNewComuni(added.filter { $0.kind == .comune })
        checkMedals()
    }

    private func computeStreets(_ trips: [Trip]) {
        streetsToken += 1
        let token = streetsToken
        Task.detached(priority: .utility) {
            let runs = Passport.newStreetRuns(trips)
            await MainActor.run {
                guard token == self.streetsToken else { return }
                self.newStreetRuns = runs
                self.checkMedals(summary: true)
            }
        }
    }

    /// Chiamato quando "Scopri" segna un luogo come raggiunto.
    func sightsChanged() { checkMedals() }

    private func checkMedals(summary: Bool = false) {
        let unlocked = passport.unlockNew(medals)
        guard !unlocked.isEmpty else { return }
        save()
        guard notify else { return }
        if summary && unlocked.count > 1 {
            send(id: "medal-summary", title: "🏅 Hai sbloccato \(unlocked.count) medaglie",
                 body: "Guardale nel Passaporto (menu ☰).")
        } else {
            for m in unlocked {
                send(id: "medal-\(m.id)", title: "🏅 Medaglia \(m.level.name): \(m.title)",
                     body: "\(m.valueText) \(m.unit). Guardala nel Passaporto (menu ☰).")
            }
        }
    }

    private func notifyNewComuni(_ comuni: [VisitedPlace]) {
        guard notify, !comuni.isEmpty else { return }
        let total = passport.count(.comune)
        if comuni.count == 1, let c = comuni.first {
            send(id: "new-comune", title: "Nuovo comune: \(c.name) 🎉", body: "È il \(total)° comune che visiti.")
        } else {
            send(id: "new-comune", title: "\(comuni.count) comuni nuovi 🎉",
                 body: comuni.map(\.name).joined(separator: ", ") + ". In tutto \(total) comuni.")
        }
    }

    private func send(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private func save() {
        try? JSONEncoder().encode(passport).write(to: fileURL, options: .atomic)
    }

    // MARK: Prove

    /// Usato nei test: registra un punto senza geocoder.
    func record(_ sample: PlaceSample, at date: Date) {
        passport.record(sample, at: date)
    }

    #if DEBUG
    /// Dati di prova per gli screenshot.
    func loadDemo() {
        var p = Passport()
        p.version = Passport.currentVersion
        let now = Date()
        func day(_ n: Double) -> Date { now.addingTimeInterval(-n * 86400) }
        let lombardia: [(String, String, Double)] = [
            ("Milano", "Milano", 40), ("Sesto San Giovanni", "Milano", 38), ("Monza", "Monza e della Brianza", 35),
            ("Bergamo", "Bergamo", 30), ("Brescia", "Brescia", 20), ("Villa Carcina", "Brescia", 2),
            ("Concesio", "Brescia", 2), ("Gardone Val Trompia", "Brescia", 2), ("Lumezzane", "Brescia", 1),
            ("Desenzano del Garda", "Brescia", 12), ("Sirmione", "Brescia", 12), ("Como", "Como", 25),
        ]
        for (c, prov, d) in lombardia {
            p.record(PlaceSample(comune: c, provincia: prov, regione: "Lombardia", stato: "Italia", countryCode: "IT"), at: day(d))
        }
        for (c, prov, reg, d) in [("Verona", "Verona", "Veneto", 15.0), ("Peschiera del Garda", "Verona", "Veneto", 12.0),
                                  ("Torino", "Torino", "Piemonte", 60.0)] {
            p.record(PlaceSample(comune: c, provincia: prov, regione: reg, stato: "Italia", countryCode: "IT"), at: day(d))
        }
        p.record(PlaceSample(comune: "Lugano", provincia: "Lugano", regione: "Ticino", stato: "Svizzera", countryCode: "CH"), at: day(50))
        passport = p
        _ = passport.unlockNew(medals)
        save()
    }
    #endif
}
