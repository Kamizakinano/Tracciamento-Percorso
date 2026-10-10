import Foundation
import MapKit

/// Una svolta del percorso: l'indicazione vale per il punto iniziale del tratto.
struct RouteStep {
    let instruction: String
    /// Lunghezza del tratto che segue la svolta (metri).
    let distance: Double
    let coords: [CLLocationCoordinate2D]
}

/// Un percorso proposto verso la destinazione.
struct RouteOption: Identifiable {
    let id = UUID()
    let coords: [CLLocationCoordinate2D]
    let distance: Double
    let time: TimeInterval
    var steps: [RouteStep] = []
    /// Frazione del percorso su strade mai fatte (0...1).
    var newFraction: Double = 1
    var score: Double = 0
}

/// Mezzo scelto nella scheda del percorso (i mezzi pubblici hanno un itinerario a parte).
enum RouteMode: String, CaseIterable, Identifiable {
    case car, bike, foot, transit

    var id: String { rawValue }

    init(_ mode: TravelMode) {
        switch mode {
        case .car: self = .car
        case .bike: self = .bike
        case .foot: self = .foot
        }
    }

    var travelMode: TravelMode? {
        switch self {
        case .car: return .car
        case .bike: return .bike
        case .foot: return .foot
        case .transit: return nil
        }
    }

    var icon: String {
        switch self {
        case .car: return "car.fill"
        case .bike: return "bicycle"
        case .foot: return "figure.walk"
        case .transit: return "tram.fill"
        }
    }

    var label: String {
        switch self {
        case .car: return "Auto"
        case .bike: return "Bici"
        case .foot: return "A piedi"
        case .transit: return "Mezzi"
        }
    }
}

/// Velocità media in bici (m/s): Apple non fornisce percorsi in bici alle app,
/// si usa il percorso pedonale con i tempi di una bici (~16 km/h).
let bikeSpeed = 4.4

/// Calcola percorsi verso una destinazione e propone quello che passa di più
/// su strade nuove, senza allungare troppo il tragitto.
final class RoutePlanner: ObservableObject {
    @Published private(set) var options: [RouteOption] = []
    @Published var selected = 0
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    @Published private(set) var destination: Place?
    @Published private(set) var origin: Place?
    @Published private(set) var mode: TravelMode = .car
    /// Tempi stimati per ogni mezzo (riga in cima alla scheda del percorso).
    @Published private(set) var etas: [RouteMode: TimeInterval] = [:]
    /// Punto di partenza dell'ultimo calcolo (per ricalcolare con un altro mezzo).
    private(set) var start: CLLocationCoordinate2D?
    private var etaTask: Task<Void, Never>?

    private var task: Task<Void, Never>?

    var current: RouteOption? { options.indices.contains(selected) ? options[selected] : nil }

    func clear() {
        task?.cancel()
        etaTask?.cancel()
        options = []
        selected = 0
        destination = nil
        origin = nil
        start = nil
        etas = [:]
        message = nil
        isLoading = false
    }

    /// Tempi con auto, bici e a piedi (Apple) e con i mezzi pubblici (Apple, se disponibile).
    func computeETAs(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) {
        etaTask?.cancel()
        etas = [:]
        etaTask = Task {
            async let car = Self.eta(a, b, .automobile)
            async let walk = Self.eta(a, b, .walking)
            async let transit = Self.eta(a, b, .transit)
            let (c, w, t) = await (car, walk, transit)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if let c { self.etas[.car] = c.time }
                if let w {
                    self.etas[.foot] = w.time
                    self.etas[.bike] = w.distance / bikeSpeed
                }
                if let t, self.etas[.transit] == nil { self.etas[.transit] = t.time }
            }
        }
    }

    /// Tempo dei mezzi pubblici calcolato da Transitous (più preciso di quello di Apple).
    func setTransitETA(_ time: TimeInterval) {
        etas[.transit] = time
    }

    private static func eta(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D,
                            _ type: MKDirectionsTransportType) async -> (time: TimeInterval, distance: Double)? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: a))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: b))
        request.transportType = type
        guard let r = try? await MKDirections(request: request).calculateETA() else { return nil }
        return (r.expectedTravelTime, r.distance)
    }

    /// `origin` nil = parti dalla posizione attuale (`start`).
    func plan(from start: CLLocationCoordinate2D, origin: Place? = nil, to place: Place, mode: TravelMode, index: SpatialIndex) {
        task?.cancel()
        options = []
        selected = 0
        message = nil
        self.start = start
        destination = place
        self.origin = origin
        self.mode = mode
        isLoading = true
        task = Task {
            let routes = await Self.candidates(from: start, to: place.coordinate, mode: mode)
            guard !Task.isCancelled else { return }
            let threshold = Settings.threshold(for: mode)
            let ranked = await Task.detached(priority: .userInitiated) {
                Self.rank(routes, index: index, within: threshold)
            }.value
            await MainActor.run {
                self.isLoading = false
                self.options = ranked
                self.selected = 0
                self.message = ranked.isEmpty ? "Nessun percorso trovato." : nil
            }
        }
    }

    func next() { if !options.isEmpty { selected = (selected + 1) % options.count } }
    func previous() { if !options.isEmpty { selected = (selected - 1 + options.count) % options.count } }

    // MARK: - Calcolo

    /// Ordina i percorsi: più strade nuove, penalizzando quelli molto più lunghi.
    static func rank(_ routes: [RouteOption], index: SpatialIndex, within meters: Double) -> [RouteOption] {
        guard let shortest = routes.map(\.distance).min(), shortest > 0 else { return [] }
        var scored: [RouteOption] = routes.map { r in
            var r = r
            r.newFraction = Geo.newFraction(of: r.coords, index: index, within: meters)
            r.score = r.newFraction - 0.6 * max(0, r.distance / shortest - 1)
            return r
        }
        scored.sort { $0.score > $1.score }
        // Togli i doppioni (stessa lunghezza e stessa quota di strade nuove).
        var unique: [RouteOption] = []
        for r in scored where !unique.contains(where: {
            abs($0.distance - r.distance) / r.distance < 0.01 && abs($0.newFraction - r.newFraction) < 0.02
        }) {
            unique.append(r)
        }
        return unique
    }

    private static func transport(for mode: TravelMode) -> MKDirectionsTransportType {
        mode == .car ? .automobile : .walking // Apple non offre percorsi in bici alle app
    }

    private static func directions(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D,
                                   mode: TravelMode, alternatives: Bool) async -> [MKRoute] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: a))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: b))
        request.transportType = transport(for: mode)
        request.requestsAlternateRoutes = alternatives
        return (try? await MKDirections(request: request).calculate().routes) ?? []
    }

    /// Percorsi di Apple più due varianti che passano a destra e a sinistra della linea diretta.
    static func candidates(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D, mode: TravelMode) async -> [RouteOption] {
        var result = await directions(a, b, mode: mode, alternatives: true).map { option($0, mode: mode) }
        let straight = Geo.distance(a, b)
        guard straight > 300 else { return result }
        let offset = min(3000, max(300, straight * 0.3))
        for side in [-1.0, 1.0] {
            if Task.isCancelled { break }
            let via = waypoint(a, b, offset: offset * side)
            let first = await directions(a, via, mode: mode, alternatives: false)
            let second = await directions(via, b, mode: mode, alternatives: false)
            guard let r1 = first.first, let r2 = second.first else { continue }
            // Il primo tratto finisce con "sei arrivato" (al punto intermedio) e il secondo
            // comincia con un passo vuoto: si tolgono per unire le indicazioni.
            result.append(RouteOption(coords: coordinates(of: r1.polyline) + coordinates(of: r2.polyline).dropFirst(),
                                      distance: r1.distance + r2.distance,
                                      time: mode == .bike ? (r1.distance + r2.distance) / bikeSpeed
                                                          : r1.expectedTravelTime + r2.expectedTravelTime,
                                      steps: Array(steps(of: r1).dropLast()) + steps(of: r2).drop(while: { $0.instruction.isEmpty })))
        }
        return result
    }

    private static func option(_ r: MKRoute, mode: TravelMode) -> RouteOption {
        RouteOption(coords: coordinates(of: r.polyline), distance: r.distance,
                    time: mode == .bike ? r.distance / bikeSpeed : r.expectedTravelTime, steps: steps(of: r))
    }

    private static func steps(of r: MKRoute) -> [RouteStep] {
        r.steps.map { RouteStep(instruction: $0.instructions, distance: $0.distance, coords: coordinates(of: $0.polyline)) }
    }

    static func coordinates(of polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: polyline.pointCount)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polyline.pointCount))
        return coords
    }

    /// Punto a metà strada spostato di `offset` metri perpendicolarmente alla linea a→b.
    static func waypoint(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, offset: Double) -> CLLocationCoordinate2D {
        let midLat = (a.latitude + b.latitude) / 2
        let midLon = (a.longitude + b.longitude) / 2
        let mPerLat = 111_320.0
        let mPerLon = 111_320.0 * cos(midLat * .pi / 180)
        let dx = (b.longitude - a.longitude) * mPerLon
        let dy = (b.latitude - a.latitude) * mPerLat
        let len = max(1, sqrt(dx * dx + dy * dy))
        // Perpendicolare (-dy, dx) normalizzata.
        return CLLocationCoordinate2D(latitude: midLat + (dx / len) * offset / mPerLat,
                                      longitude: midLon + (-dy / len) * offset / mPerLon)
    }
}
