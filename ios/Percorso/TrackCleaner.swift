import Foundation
import MapKit

/// Raddrizza i tracciati: toglie i salti del GPS, ammorbidisce il tremolio e
/// (se c'è internet) li aggancia alle strade con i percorsi di Apple.
enum TrackCleaner {
    /// Versione della pulizia: i viaggi con una versione più vecchia vengono ripuliti.
    static let version = 1

    // MARK: - Pulizia (senza rete)

    /// Toglie i punti "a punta": salto lontano e subito ritorno (riflessi del GPS tra i palazzi).
    static func removeSpikes(_ pts: [TrackPoint], maxSpeed: Double) -> [TrackPoint] {
        guard pts.count > 2 else { return pts }
        var out = [pts[0]]
        for i in 1..<(pts.count - 1) {
            let prev = out.last!, p = pts[i], next = pts[i + 1]
            let dtIn = max(1, p.time.timeIntervalSince(prev.time))
            let dtOut = max(1, next.time.timeIntervalSince(p.time))
            let spike = Geo.distance(prev, p) / dtIn > maxSpeed && Geo.distance(p, next) / dtOut > maxSpeed
                && Geo.distance(prev, next) < Geo.distance(prev, p)
            if !spike { out.append(p) }
        }
        out.append(pts[pts.count - 1])
        return out
    }

    /// Media mobile sulle coordinate (gli estremi restano dove sono).
    static func smooth(_ pts: [TrackPoint], window: Int = 5) -> [TrackPoint] {
        guard pts.count > 2, window > 1 else { return pts }
        let half = window / 2
        return pts.indices.map { i in
            if i == 0 || i == pts.count - 1 { return pts[i] }
            let lo = max(0, i - half), hi = min(pts.count - 1, i + half)
            let slice = pts[lo...hi]
            let n = Double(slice.count)
            return TrackPoint(lat: slice.reduce(0) { $0 + $1.lat } / n,
                              lon: slice.reduce(0) { $0 + $1.lon } / n, time: pts[i].time)
        }
    }

    /// Semplificazione di Douglas-Peucker: tiene solo i punti che cambiano la forma oltre `tolerance` metri.
    static func simplify(_ pts: [TrackPoint], tolerance: Double = 3) -> [TrackPoint] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true
        keep[pts.count - 1] = true
        var stack = [(0, pts.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            let line = [pts[a].coordinate, pts[b].coordinate]
            var maxD = 0.0, idx = a
            for i in (a + 1)..<b {
                let d = Geo.distance(from: pts[i].coordinate, toPolyline: line)
                if d > maxD { maxD = d; idx = i }
            }
            if maxD > tolerance {
                keep[idx] = true
                stack.append((a, idx))
                stack.append((idx, b))
            }
        }
        return pts.indices.filter { keep[$0] }.map { pts[$0] }
    }

    /// Pulizia completa senza rete.
    static func clean(_ pts: [TrackPoint], mode: TravelMode) -> [TrackPoint] {
        let maxSpeed: Double = mode == .car ? 60 : (mode == .bike ? 15 : 4)
        return simplify(smooth(removeSpikes(pts, maxSpeed: maxSpeed), window: mode == .car ? 3 : 5),
                        tolerance: mode == .car ? 5 : 3)
    }

    // MARK: - Aggancio alle strade (con rete)

    /// Divide il tracciato in tratti di circa `length` metri (estremi condivisi).
    static func chunks(_ pts: [TrackPoint], length: Double) -> [[TrackPoint]] {
        guard pts.count > 1 else { return [] }
        var out: [[TrackPoint]] = []
        var cur = [pts[0]]
        var run = 0.0
        for i in 1..<pts.count {
            run += Geo.distance(pts[i - 1], pts[i])
            cur.append(pts[i])
            if run >= length {
                out.append(cur)
                cur = [pts[i]]
                run = 0
            }
        }
        if cur.count > 1 { out.append(cur) }
        return out
    }

    /// Il percorso di Apple segue davvero il tratto registrato? (non troppo più lungo e mai lontano)
    static func routeMatches(_ route: [CLLocationCoordinate2D], chunk: [TrackPoint], tolerance: Double) -> Bool {
        guard route.count > 1, chunk.count > 1 else { return false }
        let recorded = Geo.length(of: chunk)
        guard Geo.length(of: route) <= recorded * 1.35 + 40 else { return false }
        // Ogni punto registrato deve stare vicino al percorso proposto.
        return chunk.allSatisfy { Geo.distance(from: $0.coordinate, toPolyline: route) <= tolerance }
    }

    /// Risposta di Apple per un tratto.
    enum RoadAnswer {
        case route([CLLocationCoordinate2D])
        case noRoute
        /// Niente rete o troppe richieste: meglio riprovare più tardi.
        case failed
    }

    /// Pulisce e aggancia alle strade; i tratti che non combaciano restano solo puliti.
    /// Restituisce nil se manca la rete (il viaggio si riprova più tardi, senza toccarlo).
    static func process(_ raw: [TrackPoint], mode: TravelMode,
                        road: (CLLocationCoordinate2D, CLLocationCoordinate2D, TravelMode) async -> RoadAnswer = roadPath,
                        pause: UInt64 = 1_300_000_000) async -> [TrackPoint]? {
        let cleaned = clean(raw, mode: mode)
        let parts = chunks(cleaned, length: mode == .car ? 600 : 250)
        // Viaggi molto lunghi: solo pulizia, per non fare centinaia di richieste.
        guard !parts.isEmpty, parts.count <= 80 else { return cleaned }
        var out: [TrackPoint] = [cleaned[0]]
        for part in parts {
            if Task.isCancelled { return nil }
            let a = part.first!, b = part.last!
            var matched = false
            if Geo.distance(a, b) >= 30 {
                switch await road(a.coordinate, b.coordinate, mode) {
                case .failed:
                    return nil
                case .route(let route) where routeMatches(route, chunk: part, tolerance: mode == .car ? 35 : 25):
                    out += LocationTracker.bridgePoints(route, from: a, to: b) + [b]
                    matched = true
                default:
                    break
                }
                if pause > 0 { try? await Task.sleep(nanoseconds: pause) } // Apple limita le richieste
            }
            if !matched { out += part.dropFirst() }
        }
        return out
    }

    static func roadPath(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D, mode: TravelMode) async -> RoadAnswer {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: a))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: b))
        request.transportType = mode == .car ? .automobile : .walking
        do {
            guard let route = try await MKDirections(request: request).calculate().routes.first else { return .noRoute }
            return .route(RoutePlanner.coordinates(of: route.polyline))
        } catch let error as MKError where error.code == .directionsNotFound {
            return .noRoute
        } catch {
            return .failed
        }
    }
}
