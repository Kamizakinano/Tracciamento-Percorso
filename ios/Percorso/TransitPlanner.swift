import Foundation
import MapKit
import SwiftUI

/// Un tratto dell'itinerario con i mezzi pubblici (a piedi, bus, tram, metro, treno…).
struct TransitLeg: Identifiable {
    let id = UUID()
    let mode: String
    let line: String?
    let headsign: String?
    let colorHex: String?
    let from: String
    let to: String
    let departure: Date?
    let arrival: Date?
    let duration: TimeInterval
    let distance: Double?
    let stops: Int
    let coords: [CLLocationCoordinate2D]

    var isWalk: Bool { mode == "WALK" }

    var icon: String {
        switch mode {
        case "WALK": return "figure.walk"
        case "BIKE": return "bicycle"
        case "TRAM", "CABLE_CAR": return "tram.fill"
        case "SUBWAY", "METRO": return "tram.fill.tunnel"
        case "FERRY": return "ferry.fill"
        case "AIRPLANE": return "airplane"
        case "AERIAL_LIFT", "FUNICULAR": return "cablecar.fill"
        case let m where m.contains("RAIL") || m == "TRAIN": return "train.side.front.car"
        default: return "bus.fill"
        }
    }

    var modeName: String {
        switch mode {
        case "WALK": return "A piedi"
        case "BUS", "COACH": return "Bus"
        case "TRAM", "CABLE_CAR": return "Tram"
        case "SUBWAY", "METRO": return "Metro"
        case "FERRY": return "Traghetto"
        case "AERIAL_LIFT", "FUNICULAR": return "Funivia"
        case let m where m.contains("RAIL") || m == "TRAIN": return "Treno"
        default: return "Mezzo"
        }
    }

    /// Colore della linea (se l'azienda lo pubblica), altrimenti uno per tipo di mezzo.
    var uiColor: UIColor {
        if let hex = colorHex, let c = UIColor(hex: hex) { return c }
        switch mode {
        case "WALK": return .systemGray
        case "TRAM", "CABLE_CAR": return .systemOrange
        case "SUBWAY", "METRO": return .systemRed
        case let m where m.contains("RAIL"): return .systemIndigo
        default: return .systemBlue
        }
    }
}

struct TransitItinerary: Identifiable {
    let id = UUID()
    let start: Date
    let end: Date
    let duration: TimeInterval
    let transfers: Int
    let legs: [TransitLeg]

    var walkingTime: TimeInterval { legs.filter(\.isWalk).reduce(0) { $0 + $1.duration } }
}

/// Itinerari con i mezzi pubblici da Transitous (servizio gratuito con gli orari
/// pubblici dei trasporti europei e di altri paesi).
final class TransitPlanner: ObservableObject {
    @Published private(set) var itineraries: [TransitItinerary] = []
    @Published var selected = 0
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?

    static let endpoint = URL(string: "https://api.transitous.org/api/v5/plan")!

    private var task: Task<Void, Never>?

    var current: TransitItinerary? { itineraries.indices.contains(selected) ? itineraries[selected] : nil }
    var bestDuration: TimeInterval? { itineraries.map(\.duration).min() }

    func clear() {
        task?.cancel()
        itineraries = []
        selected = 0
        isLoading = false
        message = nil
    }

    func plan(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D, at time: Date = Date()) {
        clear()
        isLoading = true
        task = Task {
            do {
                let data = try await Self.download(from: a, to: b, at: time)
                let result = try Self.parse(data)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.itineraries = result
                    self.isLoading = false
                    self.message = result.isEmpty ? "Nessun mezzo pubblico trovato per questo tragitto." : nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.isLoading = false
                    self.message = "Orari dei mezzi pubblici non disponibili, prova con Apple Mappe."
                }
            }
        }
    }

    func next() { if !itineraries.isEmpty { selected = (selected + 1) % itineraries.count } }
    func previous() { if !itineraries.isEmpty { selected = (selected - 1 + itineraries.count) % itineraries.count } }

    // MARK: - Transitous

    static func url(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D, at time: Date) -> URL {
        var c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "fromPlace", value: "\(a.latitude),\(a.longitude)"),
            URLQueryItem(name: "toPlace", value: "\(b.latitude),\(b.longitude)"),
            URLQueryItem(name: "time", value: ISO8601DateFormatter().string(from: time)),
        ]
        return c.url!
    }

    private static func download(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D, at time: Date) async throws -> Data {
        var request = URLRequest(url: url(from: a, to: b, at: time))
        request.timeoutInterval = 30
        request.setValue("Percorso iOS (uso personale)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private struct Response: Decodable {
        struct Itinerary: Decodable {
            let duration: Double
            let startTime: String
            let endTime: String
            let transfers: Int?
            let legs: [Leg]
        }
        struct Leg: Decodable {
            struct Place: Decodable {
                let name: String?
                let departure: String?
                let arrival: String?
            }
            struct Geometry: Decodable {
                let points: String
                let precision: Int?
            }
            let mode: String
            let from: Place
            let to: Place
            let duration: Double?
            let startTime: String?
            let endTime: String?
            let distance: Double?
            let routeShortName: String?
            let headsign: String?
            let routeColor: String?
            let legGeometry: Geometry?
            let intermediateStops: [Place]?
        }
        let itineraries: [Itinerary]
    }

    static func parse(_ data: Data) throws -> [TransitItinerary] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        return response.itineraries.compactMap { it in
            guard let start = date(it.startTime), let end = date(it.endTime) else { return nil }
            let legs = it.legs.map { leg -> TransitLeg in
                let from = leg.from.name == "START" ? "Partenza" : (leg.from.name ?? "")
                let to = leg.to.name == "END" ? "Destinazione" : (leg.to.name ?? "")
                return TransitLeg(mode: leg.mode,
                                  line: leg.routeShortName.flatMap { $0.isEmpty ? nil : $0 },
                                  headsign: leg.headsign,
                                  colorHex: leg.routeColor,
                                  from: from, to: to,
                                  departure: leg.startTime.flatMap(date),
                                  arrival: leg.endTime.flatMap(date),
                                  duration: leg.duration ?? 0,
                                  distance: leg.distance,
                                  stops: (leg.intermediateStops?.count ?? 0) + (leg.mode == "WALK" ? 0 : 1),
                                  coords: leg.legGeometry.map { decodePolyline($0.points, precision: $0.precision ?? 6) } ?? [])
            }
            // Tragitti fatti solo a piedi li copre già la modalità "A piedi".
            guard legs.contains(where: { !$0.isWalk }) else { return nil }
            return TransitItinerary(start: start, end: end, duration: it.duration, transfers: it.transfers ?? 0, legs: legs)
        }
    }

    private static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    /// Decodifica una polyline in formato Google (precisione 5, 6 o 7 cifre decimali).
    static func decodePolyline(_ encoded: String, precision: Int) -> [CLLocationCoordinate2D] {
        let bytes = Array(encoded.utf8)
        let factor = pow(10.0, Double(precision))
        var coords: [CLLocationCoordinate2D] = []
        var i = 0, lat = 0, lon = 0
        func next() -> Int? {
            var result = 0, shift = 0, b = 0
            repeat {
                guard i < bytes.count else { return nil }
                b = Int(bytes[i]) - 63
                i += 1
                result |= (b & 0x1f) << shift
                shift += 5
            } while b >= 0x20
            return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
        }
        while i < bytes.count {
            guard let dLat = next(), let dLon = next() else { break }
            lat += dLat
            lon += dLon
            coords.append(CLLocationCoordinate2D(latitude: Double(lat) / factor, longitude: Double(lon) / factor))
        }
        return coords
    }

    /// Apre Apple Mappe con le indicazioni con i mezzi pubblici.
    static func openInAppleMaps(from origin: Place?, to destination: Place) {
        let dest = MKMapItem(placemark: MKPlacemark(coordinate: destination.coordinate))
        dest.name = destination.name
        let source: MKMapItem
        if let origin {
            source = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
            source.name = origin.name
        } else {
            source = MKMapItem.forCurrentLocation()
        }
        MKMapItem.openMaps(with: [source, dest],
                           launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeTransit])
    }
}

extension UIColor {
    /// "E30613" oppure "#E30613".
    convenience init?(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}

/// Dettaglio dell'itinerario: dove salire, quale linea, quante fermate, dove scendere.
struct TransitDetailView: View {
    let itinerary: TransitItinerary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Partenza", value: itinerary.start.formatted(date: .omitted, time: .shortened))
                    LabeledContent("Arrivo", value: itinerary.end.formatted(date: .omitted, time: .shortened))
                    LabeledContent("Durata", value: Geo.formatDuration(itinerary.duration))
                    LabeledContent("Cambi", value: "\(itinerary.transfers)")
                }
                Section("Itinerario") {
                    ForEach(itinerary.legs) { leg in
                        if leg.isWalk {
                            Label {
                                Text(walkText(leg))
                            } icon: {
                                Image(systemName: "figure.walk").foregroundStyle(.secondary)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    TransitBadge(leg: leg)
                                    if let headsign = leg.headsign, !headsign.isEmpty {
                                        Text("direzione \(headsign)").font(.subheadline).foregroundStyle(.secondary)
                                    }
                                }
                                Text("Sali a **\(leg.from)**\(at(leg.departure))")
                                Text("\(leg.stops) \(leg.stops == 1 ? "fermata" : "fermate") · \(Geo.formatDuration(leg.duration))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("Scendi a **\(leg.to)**\(at(leg.arrival))")
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                Section {
                    Text("Orari da Transitous (dati pubblici delle aziende di trasporto): possono non includere ritardi o variazioni dell'ultimo minuto.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Con i mezzi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
        }
    }
}

private func walkText(_ leg: TransitLeg) -> String {
    var text = "Cammina \(Geo.formatDuration(leg.duration))"
    if let d = leg.distance { text += " (\(Geo.formatShort(d)))" }
    return text + " fino a \(leg.to)"
}

private func at(_ date: Date?) -> String {
    guard let date else { return "" }
    return " alle " + date.formatted(date: .omitted, time: .shortened)
}

/// Etichetta colorata della linea (es. "M3", "Bus 58").
struct TransitBadge: View {
    let leg: TransitLeg

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: leg.icon)
            Text(leg.line ?? leg.modeName)
        }
        .font(.subheadline.weight(.bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(leg.uiColor), in: RoundedRectangle(cornerRadius: 6))
    }
}
