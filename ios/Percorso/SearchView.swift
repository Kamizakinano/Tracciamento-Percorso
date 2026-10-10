import SwiftUI
import MapKit

/// Suggerimenti di indirizzi e luoghi mentre si scrive.
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

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }
}

struct SearchView: View {
    let onSelect: (Place) -> Void
    var initialQuery = ""

    @StateObject private var completer = SearchCompleter()
    @Environment(\.dismiss) private var dismiss
    @State private var searching = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                if let message {
                    Text(message).foregroundStyle(.secondary)
                }
                ForEach(completer.results, id: \.self) { item in
                    Button {
                        run(MKLocalSearch.Request(completion: item))
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).foregroundStyle(.primary)
                            if !item.subtitle.isEmpty {
                                Text(item.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .overlay {
                if searching { ProgressView() }
            }
            .searchable(text: $completer.query,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Indirizzo o luogo")
            .onSubmit(of: .search) {
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = completer.query
                run(request)
            }
            .onAppear {
                if !initialQuery.isEmpty { completer.query = initialQuery }
            }
            .navigationTitle("Cerca")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
        }
    }

    private func run(_ request: MKLocalSearch.Request) {
        searching = true
        message = nil
        MKLocalSearch(request: request).start { response, _ in
            searching = false
            guard let item = response?.mapItems.first else {
                message = "Nessun risultato."
                return
            }
            onSelect(Place(name: item.name ?? completer.query, coordinate: item.placemark.coordinate))
            dismiss()
        }
    }
}
