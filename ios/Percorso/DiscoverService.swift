import Foundation
import MapKit

// MARK: - Luoghi da vedere

enum SightKind: String, Codable, CaseIterable {
    case monument, church, castle, museum, viewpoint, artwork, park, square, fountain, ruins, attraction

    var label: String {
        switch self {
        case .monument: return "Monumento"
        case .church: return "Chiesa"
        case .castle: return "Castello"
        case .museum: return "Museo"
        case .viewpoint: return "Panorama"
        case .artwork: return "Opera d'arte"
        case .park: return "Parco"
        case .square: return "Piazza"
        case .fountain: return "Fontana"
        case .ruins: return "Rovine"
        case .attraction: return "Da vedere"
        }
    }

    var icon: String {
        switch self {
        case .monument: return "building.columns.fill"
        case .church: return "bell.fill"
        case .castle: return "crown.fill"
        case .museum: return "building.columns"
        case .viewpoint: return "binoculars.fill"
        case .artwork: return "paintpalette.fill"
        case .park: return "leaf.fill"
        case .square: return "square.grid.2x2.fill"
        case .fountain: return "drop.fill"
        case .ruins: return "hammer.fill"
        case .attraction: return "star.fill"
        }
    }

    /// Tipo di luogo dai tag di OpenStreetMap (nil = non interessante).
    static func from(tags t: [String: String]) -> SightKind? {
        switch t["historic"] {
        case "castle", "fort", "palace", "city_gate", "tower": return .castle
        case "ruins", "archaeological_site": return .ruins
        case "church", "monastery": return .church
        case "monument", "memorial": return .monument
        default: break
        }
        switch t["tourism"] {
        case "museum", "gallery": return .museum
        case "viewpoint": return .viewpoint
        case "artwork": return .artwork
        case "attraction": return t["amenity"] == "place_of_worship" ? .church : .attraction
        default: break
        }
        if t["amenity"] == "place_of_worship" { return .church }
        if t["amenity"] == "fountain" { return .fountain }
        if t["leisure"] == "park" || t["leisure"] == "garden" { return .park }
        if t["place"] == "square" { return .square }
        if t["historic"] != nil { return .monument }
        return nil
    }
}

struct Sight: Identifiable, Hashable {
    let id: String
    let name: String
    let kind: SightKind
    let lat: Double
    let lon: Double
    /// Importanza: luoghi con voce su Wikipedia/Wikidata e attrazioni turistiche prima.
    let score: Int

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

/// Suggerimento "c'è qualcosa da vedere qui vicino".
struct SightSuggestion: Equatable {
    let sight: Sight
    let distance: Double

    /// Minuti a piedi per arrivarci (~4,8 km/h).
    var walkMinutes: Int { max(1, Int((distance / 80).rounded())) }
    var text: String { "\(Geo.formatShort(distance)) · +\(walkMinutes) min a piedi" }
}

// MARK: - Servizio

/// "Scopri": monumenti, chiese, musei, panorami… vicino a te, da OpenStreetMap.
final class DiscoverService: ObservableObject {
    @Published private(set) var isOn = false
    @Published private(set) var sights: [Sight] = []
    @Published private(set) var version = 0
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    /// Luoghi già visti (ci sei passato vicino).
    @Published private(set) var visited: Set<String> = []
    /// Suggerimenti chiusi con la ✕ in questa sessione.
    @Published private(set) var dismissed: Set<String> = []

    static let radius = 900.0
    static let suggestRadius = 600.0
    static let seenRadius = 40.0

    private var loadedCenter: CLLocationCoordinate2D?
    private var task: Task<Void, Never>?
    private let visitedURL: URL

    init(directory: URL = TripStore.documents) {
        visitedURL = directory.appendingPathComponent("sights-visited.json")
        if let data = try? Data(contentsOf: visitedURL), let ids = try? JSONDecoder().decode([String].self, from: data) {
            visited = Set(ids)
        }
    }

    func toggle(center: CLLocationCoordinate2D?) {
        if isOn {
            isOn = false
            task?.cancel()
            sights = []
            version += 1
            message = nil
            isLoading = false
        } else {
            isOn = true
            if let center { load(around: center) } else { message = "Posizione attuale non disponibile." }
        }
    }

    /// Ricarica quando ti sposti (o sposti la mappa) di qualche centinaio di metri.
    func moved(to center: CLLocationCoordinate2D) {
        guard isOn else { return }
        if let old = loadedCenter, Geo.distance(old, center) < Self.radius / 2 { return }
        load(around: center)
    }

    /// Posizione attuale: segna come visti i luoghi a pochi metri.
    func update(location: CLLocationCoordinate2D) {
        let near = sights.filter { !visited.contains($0.id) && Geo.distance($0.coordinate, location) <= Self.seenRadius }
        guard !near.isEmpty else { return }
        visited.formUnion(near.map(\.id))
        version += 1
        try? JSONEncoder().encode(Array(visited)).write(to: visitedURL, options: .atomic)
    }

    func dismiss(_ sight: Sight) {
        dismissed.insert(sight.id)
    }

    func isVisited(_ sight: Sight) -> Bool { visited.contains(sight.id) }

    func suggestion(from location: CLLocationCoordinate2D?, heading: Double?) -> SightSuggestion? {
        guard isOn, let location else { return nil }
        return Self.bestSuggestion(sights.filter { !visited.contains($0.id) && !dismissed.contains($0.id) },
                                   from: location, heading: heading)
    }

    private func load(around center: CLLocationCoordinate2D) {
        loadedCenter = center
        isLoading = true
        message = nil
        task?.cancel()
        task = Task {
            do {
                let data = try await Self.download(around: center)
                let found = try Self.parse(data)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.sights = found
                    self.version += 1
                    self.isLoading = false
                    self.message = found.isEmpty ? "Nessun monumento trovato in questa zona." : nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                let text = (error as? URLError)?.code == .notConnectedToInternet
                    ? "Scopri: serve internet per cercare i luoghi da vedere."
                    : "OpenStreetMap non risponde, riprova tra poco."
                await MainActor.run {
                    self.isLoading = false
                    self.message = text
                }
            }
        }
    }

    // MARK: Calcoli (funzioni pure, provate nei test)

    /// Il luogo più comodo: vicino, importante e nella direzione in cui stai andando.
    static func bestSuggestion(_ candidates: [Sight], from p: CLLocationCoordinate2D, heading: Double?) -> SightSuggestion? {
        var best: (Double, SightSuggestion)?
        for s in candidates {
            let d = Geo.distance(p, s.coordinate)
            guard d <= suggestRadius, d > seenRadius else { continue }
            var cost = d - Double(s.score) * 60
            if let heading {
                let diff = abs(angleDifference(heading, bearing(from: p, to: s.coordinate)))
                cost += diff / 180 * 250 // dietro di te: come se fosse 250 m più lontano
            }
            if best == nil || cost < best!.0 { best = (cost, SightSuggestion(sight: s, distance: d)) }
        }
        return best?.1
    }

    /// Direzione (gradi da nord) da un punto a un altro.
    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    static func angleDifference(_ a: Double, _ b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    /// Direzione di marcia dagli ultimi punti (nil se sei fermo).
    static func heading(of points: [TrackPoint]) -> Double? {
        guard let last = points.last,
              let from = points.last(where: { Geo.distance($0, last) >= 25 }) else { return nil }
        return bearing(from: from.coordinate, to: last.coordinate)
    }

    // MARK: OpenStreetMap

    static func query(around c: CLLocationCoordinate2D, radius: Double = radius) -> String {
        let a = "(around:\(Int(radius)),\(c.latitude),\(c.longitude))"
        return """
        [out:json][timeout:25];
        (
          nwr["tourism"~"^(attraction|museum|gallery|viewpoint|artwork)$"]["name"]\(a);
          nwr["historic"~"^(monument|memorial|castle|fort|palace|city_gate|tower|ruins|archaeological_site|church|monastery)$"]["name"]\(a);
          nwr["amenity"="place_of_worship"]["name"]["wikidata"]\(a);
          nwr["amenity"="fountain"]["name"]\(a);
          nwr["leisure"~"^(park|garden)$"]["name"]["wikidata"]\(a);
          nwr["place"="square"]["name"]\(a);
        );
        out center tags;
        """
    }

    private struct OverpassResponse: Decodable {
        struct Point: Decodable { let lat: Double; let lon: Double }
        struct Element: Decodable {
            let type: String
            let id: Int64
            let lat: Double?
            let lon: Double?
            let center: Point?
            let tags: [String: String]?
        }
        let elements: [Element]
    }

    /// Luoghi dalla risposta di Overpass, i più importanti prima (al massimo 60).
    static func parse(_ data: Data, language: String = Locale.current.language.languageCode?.identifier ?? "it") throws -> [Sight] {
        let response = try JSONDecoder().decode(OverpassResponse.self, from: data)
        var seen = Set<String>()
        var out: [Sight] = []
        for el in response.elements {
            guard let tags = el.tags, let kind = SightKind.from(tags: tags),
                  let name = tags["name:\(language)"] ?? tags["name"], !name.isEmpty,
                  let lat = el.lat ?? el.center?.lat, let lon = el.lon ?? el.center?.lon else { continue }
            // Lo stesso luogo può comparire due volte (es. chiesa come edificio e come punto).
            let key = name.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            var score = 0
            if tags["wikidata"] != nil || tags["wikipedia"] != nil { score += 3 }
            if tags["tourism"] == "attraction" || tags["tourism"] == "museum" { score += 2 }
            if tags["historic"] != nil { score += 1 }
            out.append(Sight(id: "\(el.type)/\(el.id)", name: name, kind: kind, lat: lat, lon: lon, score: score))
        }
        return Array(out.sorted { $0.score > $1.score }.prefix(60))
    }

    private static func download(around c: CLLocationCoordinate2D) async throws -> Data {
        var lastError: Error = URLError(.badServerResponse)
        for endpoint in ExploreService.endpoints {
            if Task.isCancelled { throw CancellationError() }
            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.timeoutInterval = 30
                request.setValue("Percorso iOS (uso personale)", forHTTPHeaderField: "User-Agent")
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                var allowed = CharacterSet.alphanumerics
                allowed.insert(charactersIn: "-._~")
                request.httpBody = Data(("data=" + (query(around: c).addingPercentEncoding(withAllowedCharacters: allowed) ?? "")).utf8)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.first == UInt8(ascii: "{") else {
                    throw URLError(.badServerResponse)
                }
                return data
            } catch let error as URLError where error.code == .notConnectedToInternet {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    #if DEBUG
    /// Luoghi di prova intorno al Duomo di Milano (screenshot, senza rete).
    func loadDemo() {
        isOn = true
        sights = [
            Sight(id: "d/1", name: "Duomo di Milano", kind: .church, lat: 45.4641, lon: 9.1919, score: 6),
            Sight(id: "d/2", name: "Galleria Vittorio Emanuele II", kind: .attraction, lat: 45.4659, lon: 9.1900, score: 5),
            Sight(id: "d/3", name: "Teatro alla Scala", kind: .museum, lat: 45.4674, lon: 9.1895, score: 5),
            Sight(id: "d/4", name: "Palazzo Reale", kind: .castle, lat: 45.4632, lon: 9.1915, score: 5),
            Sight(id: "d/5", name: "Piazza dei Mercanti", kind: .square, lat: 45.4650, lon: 9.1878, score: 3),
            Sight(id: "d/6", name: "Chiesa di San Fedele", kind: .church, lat: 45.4665, lon: 9.1922, score: 4),
            Sight(id: "d/7", name: "Monumento a Leonardo", kind: .monument, lat: 45.4668, lon: 9.1899, score: 3),
        ]
        visited = ["d/1"]
        loadedCenter = CLLocationCoordinate2D(latitude: 45.4642, longitude: 9.1900) // niente download
        version += 1
    }
    #endif
}
