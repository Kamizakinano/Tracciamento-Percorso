import SwiftUI
import MapKit

/// Suggerimenti di indirizzi e luoghi mentre si scrive (prima quelli vicini).
final class SearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query = "" {
        didSet {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                results = []
            } else {
                completer.queryFragment = query
            }
        }
    }
    @Published private(set) var results: [MKLocalSearchCompletion] = []

    private let completer = MKLocalSearchCompleter()

    init(query: String = "", region: MKCoordinateRegion? = nil) {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        if let region { completer.region = region }
        if !query.isEmpty {
            self.query = query // didSet non scatta dentro init: imposta il frammento a mano
            completer.queryFragment = query
        }
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }
}

/// Ricerca di tutti i luoghi corrispondenti (es. tutti i Lidl della zona).
enum PlaceSearch {
    /// Scorciatoie mostrate quando il campo della destinazione è vuoto.
    static let categories: [(label: String, query: String, icon: String)] = [
        ("Supermercati", "supermercato", "cart.fill"),
        ("Benzina", "distributore di benzina", "fuelpump.fill"),
        ("Farmacie", "farmacia", "cross.case.fill"),
        ("Bar", "bar caffè", "cup.and.saucer.fill"),
        ("Ristoranti", "ristorante", "fork.knife"),
        ("Parcheggi", "parcheggio", "parkingsign.circle.fill"),
        ("Bancomat", "bancomat", "banknote.fill"),
    ]

    static func search(_ text: String, region: MKCoordinateRegion?) async -> [Place] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = [.pointOfInterest, .address]
        if let region { request.region = region }
        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
        var seen = Set<String>()
        return response.mapItems.compactMap { item in
            let c = item.placemark.coordinate
            // Stesso negozio restituito due volte: tienine uno.
            let key = "\((c.latitude * 2000).rounded()),\((c.longitude * 2000).rounded())"
            guard seen.insert(key).inserted else { return nil }
            return Place(name: item.name ?? text, coordinate: c,
                         address: address(of: item.placemark) ?? item.placemark.title)
        }
    }

    static func address(of p: MKPlacemark) -> String? {
        let street = [p.thoroughfare, p.subThoroughfare].compactMap { $0 }.joined(separator: " ")
        let parts = [street.isEmpty ? nil : street, p.locality].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Ordina per distanza da un punto.
    static func sorted(_ places: [Place], from origin: CLLocationCoordinate2D?) -> [Place] {
        guard let origin else { return places }
        return places.sorted { Geo.distance(origin, $0.coordinate) < Geo.distance(origin, $1.coordinate) }
    }
}

/// Ultime destinazioni cercate.
enum RecentPlaces {
    private static let key = "recentPlaces"
    private struct Item: Codable { let name: String; let lat: Double; let lon: Double }

    static func load() -> [Place] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
        return items.map { Place(name: $0.name, coordinate: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)) }
    }

    static func add(_ place: Place) {
        var items = load().filter { $0.name != place.name }.map {
            Item(name: $0.name, lat: $0.coordinate.latitude, lon: $0.coordinate.longitude)
        }
        items.insert(Item(name: place.name, lat: place.coordinate.latitude, lon: place.coordinate.longitude), at: 0)
        if let data = try? JSONEncoder().encode(Array(items.prefix(6))) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// "Dove vuoi andare?": partenza (di solito la tua posizione) e destinazione.
struct RouteSearchView: View {
    enum Field { case from, to }

    let region: MKCoordinateRegion?
    /// `from` nil = la mia posizione.
    let onPlan: (_ from: Place?, _ to: Place, _ mode: TravelMode) -> Void
    /// Mostra sulla mappa tutti i risultati di una ricerca (es. tutti i Lidl).
    let onShowAll: (_ query: String, _ results: [Place]) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var completer: SearchCompleter
    @State private var fromText = ""
    @State private var toText: String
    @State private var from: Place?
    @State private var to: Place?
    @State private var mode: TravelMode
    @State private var message: String?
    @State private var searching = false
    @State private var recents = RecentPlaces.load()
    @FocusState private var focus: Field?

    init(region: MKCoordinateRegion?, initialDestination: String = "", mode: TravelMode,
         onShowAll: @escaping (_ query: String, _ results: [Place]) -> Void,
         onPlan: @escaping (_ from: Place?, _ to: Place, _ mode: TravelMode) -> Void) {
        self.region = region
        self.onPlan = onPlan
        self.onShowAll = onShowAll
        _completer = StateObject(wrappedValue: SearchCompleter(query: initialDestination, region: region))
        _toText = State(initialValue: initialDestination)
        _mode = State(initialValue: mode)
    }

    private var activeField: Field { focus ?? .to }
    private var activeText: String { activeField == .from ? fromText : toText }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                fields
                Picker("Mezzo", selection: $mode) {
                    ForEach(TravelMode.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                List {
                    if let message {
                        Text(message).foregroundStyle(.secondary)
                    }
                    if activeField == .from {
                        Button(action: useMyLocation) {
                            Label("La mia posizione", systemImage: "location.fill")
                        }
                    }
                    if activeField == .to {
                        let query = toText.trimmingCharacters(in: .whitespaces)
                        if query.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(PlaceSearch.categories, id: \.query) { cat in
                                        Button { showAll(cat.query, title: cat.label) } label: {
                                            Label(cat.label, systemImage: cat.icon)
                                                .font(.subheadline)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                                .background(Color.secondary.opacity(0.12), in: Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .listRowSeparator(.hidden)
                        } else if to == nil {
                            Button { showAll(query, title: query) } label: {
                                Label("Mostra tutti i risultati per «\(query)» sulla mappa", systemImage: "magnifyingglass")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                    }
                    if activeText.isEmpty && !recents.isEmpty {
                        Section("Recenti") {
                            ForEach(recents) { place in
                                Button { choose(place) } label: {
                                    Label(place.name, systemImage: "clock.arrow.circlepath")
                                        .foregroundStyle(.primary)
                                }
                            }
                        }
                    }
                    ForEach(completer.results, id: \.self) { item in
                        Button { resolve(MKLocalSearch.Request(completion: item), fallbackName: item.title) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).foregroundStyle(.primary)
                                if !item.subtitle.isEmpty {
                                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .padding(.top, 8)
            .overlay { if searching { ProgressView() } }
            .navigationTitle("Dove vuoi andare?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
            .onAppear { focus = .to }
            .onChange(of: fromText) { text in
                if let from, text != from.name { self.from = nil }
                if focus == .from { completer.query = text }
            }
            .onChange(of: toText) { text in
                if let to, text != to.name { self.to = nil }
                if focus == .to { completer.query = text }
            }
            .onChange(of: focus) { field in
                completer.query = field == .from ? fromText : toText
            }
        }
    }

    private var fields: some View {
        HStack(spacing: 10) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "location.circle.fill").foregroundStyle(.blue).font(.title3)
                    TextField("La mia posizione", text: $fromText)
                        .focused($focus, equals: .from)
                        .submitLabel(.next)
                        .onSubmit { focus = .to }
                }
                .padding(.vertical, 10)
                Divider().padding(.leading, 36)
                HStack(spacing: 12) {
                    Image(systemName: "mappin.circle.fill").foregroundStyle(.red).font(.title3)
                    TextField("Dove vuoi andare?", text: $toText)
                        .focused($focus, equals: .to)
                        .submitLabel(.search)
                        .onSubmit { showAll(toText, title: toText) }
                }
                .padding(.vertical, 10)
            }
            Button(action: swap) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.title3)
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel("Scambia partenza e destinazione")
        }
        .padding(.horizontal, 14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }

    private func useMyLocation() {
        from = nil
        fromText = ""
        if to == nil { focus = .to } else { plan() }
    }

    private func swap() {
        (from, to) = (to, from)
        (fromText, toText) = (toText, fromText)
    }

    private func choose(_ place: Place) {
        message = nil
        if activeField == .from {
            from = place
            fromText = place.name
            if to == nil { focus = .to } else { plan() }
        } else {
            to = place
            toText = place.name
            plan()
        }
    }

    private func plan() {
        guard let to else { return }
        RecentPlaces.add(to)
        onPlan(from, to, mode)
        dismiss()
    }

    /// Cerca tutti i luoghi corrispondenti e li mostra sulla mappa.
    private func showAll(_ text: String, title: String) {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        searching = true
        message = nil
        Task {
            let results = await PlaceSearch.search(query, region: region)
            await MainActor.run {
                searching = false
                if results.isEmpty {
                    message = "Nessun risultato per «\(query)» in questa zona."
                } else {
                    onShowAll(title, results)
                    dismiss()
                }
            }
        }
    }

    private func searchText(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        if let region { request.region = region }
        resolve(request, fallbackName: text)
    }

    private func resolve(_ request: MKLocalSearch.Request, fallbackName: String) {
        searching = true
        message = nil
        MKLocalSearch(request: request).start { response, _ in
            searching = false
            guard let item = response?.mapItems.first else {
                message = "Nessun risultato."
                return
            }
            choose(Place(name: item.name ?? fallbackName, coordinate: item.placemark.coordinate))
        }
    }
}
