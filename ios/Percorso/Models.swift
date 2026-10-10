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

struct Trip: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String?
    var start: Date
    var end: Date?
    var points: [TrackPoint]

    var distance: Double { Geo.length(of: points) }

    var title: String {
        if let name, !name.isEmpty { return name }
        return start.formatted(date: .abbreviated, time: .shortened)
    }
}

enum Geo {
    /// Distanza in metri tra due punti (formula dell'emisenoverso).
    static func distance(_ a: TrackPoint, _ b: TrackPoint) -> Double {
        let r = 6_371_000.0
        let dLat = (b.lat - a.lat) * .pi / 180
        let dLon = (b.lon - a.lon) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) +
            cos(a.lat * .pi / 180) * cos(b.lat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    static func length(of points: [TrackPoint]) -> Double {
        guard points.count > 1 else { return 0 }
        var d = 0.0
        for i in 1..<points.count { d += distance(points[i - 1], points[i]) }
        return d
    }

    static func formatKm(_ meters: Double) -> String {
        (meters / 1000).formatted(.number.precision(.fractionLength(2))) + " km"
    }
}

/// Indice a griglia dei punti già percorsi, per sapere velocemente
/// se una posizione è vicina a una strada già fatta.
struct SpatialIndex {
    private struct Cell: Hashable { let i: Int; let j: Int }

    private static let cellDeg = 0.0007   // ~55-75 m
    private static let densifyStep = 10.0 // metri tra punti interpolati

    private var cells: [Cell: [TrackPoint]] = [:]

    private func cell(_ p: TrackPoint) -> Cell {
        Cell(i: Int(floor(p.lat / Self.cellDeg)), j: Int(floor(p.lon / Self.cellDeg)))
    }

    private mutating func insert(_ p: TrackPoint) {
        cells[cell(p), default: []].append(p)
    }

    /// Aggiunge un tracciato inserendo punti intermedi, così anche i tratti
    /// registrati ad alta velocità (punti radi) vengono riconosciuti.
    mutating func add(_ points: [TrackPoint]) {
        for (i, p) in points.enumerated() {
            insert(p)
            guard i > 0 else { continue }
            let prev = points[i - 1]
            let steps = Int(Geo.distance(prev, p) / Self.densifyStep)
            guard steps > 1 else { continue }
            for s in 1..<steps {
                let f = Double(s) / Double(steps)
                insert(TrackPoint(lat: prev.lat + (p.lat - prev.lat) * f,
                                  lon: prev.lon + (p.lon - prev.lon) * f,
                                  time: p.time))
            }
        }
    }

    func isNear(_ p: TrackPoint, within meters: Double) -> Bool {
        let c = cell(p)
        for di in -1...1 {
            for dj in -1...1 {
                guard let pts = cells[Cell(i: c.i + di, j: c.j + dj)] else { continue }
                if pts.contains(where: { Geo.distance(p, $0) <= meters }) { return true }
            }
        }
        return false
    }
}
