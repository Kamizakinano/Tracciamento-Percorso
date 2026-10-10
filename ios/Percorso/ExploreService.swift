import Foundation
import MapKit

/// "Strade nuove vicino a te": scarica le strade della zona da OpenStreetMap
/// (Overpass API) e tiene quelle su cui non sei ancora passato.
final class ExploreService: ObservableObject {
    @Published private(set) var lines: [[CLLocationCoordinate2D]] = []
    @Published private(set) var version = 0
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    @Published private(set) var isOn = false

    private var loadedRegion: MKCoordinateRegion?
    private var task: Task<Void, Never>?
    private var debounce: DispatchWorkItem?

    /// Lato massimo dell'area scaricata (gradi, ~3 km) per non sovraccaricare il servizio.
    static let maxSpan = 0.03
    /// Server Overpass: se il primo è sovraccarico si prova il successivo.
    static let endpoints = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
        "https://overpass.private.coffee/api/interpreter",
    ].compactMap(URL.init(string:))

    func toggle(region: MKCoordinateRegion, mode: TravelMode, index: SpatialIndex) {
        if isOn {
            isOn = false
            task?.cancel()
            lines = []
            version += 1
            message = nil
            isLoading = false
        } else {
            isOn = true
            load(region: region, mode: mode, index: index)
        }
    }

    /// Ricarica quando sposti la mappa abbastanza lontano.
    func regionChanged(_ region: MKCoordinateRegion, mode: TravelMode, index: SpatialIndex) {
        guard isOn else { return }
        if let old = loadedRegion,
           abs(old.center.latitude - region.center.latitude) < old.span.latitudeDelta / 3,
           abs(old.center.longitude - region.center.longitude) < old.span.longitudeDelta / 3 {
            return
        }
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.load(region: region, mode: mode, index: index) }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// Le strade cambiano (nuovo viaggio salvato): ricalcola senza riscaricare.
    func refresh(region: MKCoordinateRegion, mode: TravelMode, index: SpatialIndex) {
        guard isOn else { return }
        load(region: region, mode: mode, index: index)
    }

    private func load(region: MKCoordinateRegion, mode: TravelMode, index: SpatialIndex) {
        let span = min(Self.maxSpan, max(region.span.latitudeDelta, 0.005))
        let spanLon = min(Self.maxSpan, max(region.span.longitudeDelta, 0.005))
        let clamped = MKCoordinateRegion(center: region.center,
                                         span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: spanLon))
        loadedRegion = clamped
        isLoading = true
        message = nil
        task?.cancel()
        task = Task {
            do {
                let data = try await Self.download(region: clamped, mode: mode)
                let threshold = Settings.threshold(for: mode)
                let result = try await Task.detached(priority: .userInitiated) {
                    try Self.newStreets(from: data, index: index, within: threshold)
                }.value
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.lines = result
                    self.version += 1
                    self.isLoading = false
                    self.message = result.isEmpty ? "Hai già percorso tutte le strade di questa zona!" : nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                let text = (error as? URLError)?.code == .notConnectedToInternet
                    ? "Strade nuove non disponibili: serve internet."
                    : "Il servizio OpenStreetMap non risponde, riprova tra poco."
                await MainActor.run {
                    self.isLoading = false
                    self.message = text
                }
            }
        }
    }

    // MARK: - OpenStreetMap

    /// Tipi di strada adatti al mezzo.
    static func highwayTypes(for mode: TravelMode) -> String {
        switch mode {
        case .car:
            return "primary|secondary|tertiary|unclassified|residential|living_street|trunk|primary_link|secondary_link|tertiary_link"
        case .bike:
            return "primary|secondary|tertiary|unclassified|residential|living_street|cycleway|track|path"
        case .foot:
            return "secondary|tertiary|unclassified|residential|living_street|pedestrian|footway|path|track|steps"
        }
    }

    static func query(region: MKCoordinateRegion, mode: TravelMode) -> String {
        let s = region.center.latitude - region.span.latitudeDelta / 2
        let n = region.center.latitude + region.span.latitudeDelta / 2
        let w = region.center.longitude - region.span.longitudeDelta / 2
        let e = region.center.longitude + region.span.longitudeDelta / 2
        return """
        [out:json][timeout:25];
        way["highway"~"^(\(highwayTypes(for: mode)))$"](\(s),\(w),\(n),\(e));
        out geom;
        """
    }

    private static func download(region: MKCoordinateRegion, mode: TravelMode) async throws -> Data {
        var lastError: Error = URLError(.badServerResponse)
        for endpoint in endpoints {
            if Task.isCancelled { throw CancellationError() }
            do {
                return try await download(region: region, mode: mode, from: endpoint)
            } catch let error as URLError where error.code == .notConnectedToInternet {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func download(region: MKCoordinateRegion, mode: TravelMode, from endpoint: URL) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Percorso iOS (uso personale)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = "data=" + (query(region: region, mode: mode).addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        // Overpass a volte risponde 200 con un errore testuale invece del JSON.
        guard data.first == UInt8(ascii: "{") else { throw URLError(.cannotParseResponse) }
        return data
    }

    private struct OverpassResponse: Decodable {
        struct Element: Decodable {
            struct Point: Decodable { let lat: Double; let lon: Double }
            let type: String
            let geometry: [Point]?
        }
        let elements: [Element]
    }

    /// Strade (dalla risposta di Overpass) percorse per meno del 30%.
    static func newStreets(from data: Data, index: SpatialIndex, within meters: Double) throws -> [[CLLocationCoordinate2D]] {
        let response = try JSONDecoder().decode(OverpassResponse.self, from: data)
        return response.elements.compactMap { el -> [CLLocationCoordinate2D]? in
            guard el.type == "way", let geom = el.geometry, geom.count > 1 else { return nil }
            let coords = geom.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            return Geo.newFraction(of: coords, index: index, within: meters) > 0.7 ? coords : nil
        }
    }
}
