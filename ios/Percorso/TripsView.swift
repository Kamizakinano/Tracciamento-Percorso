import SwiftUI
import UniformTypeIdentifiers

struct TripsView: View {
    @EnvironmentObject private var store: TripStore
    @Binding var focus: Trip?
    @Environment(\.dismiss) private var dismiss

    @AppStorage("showHistory") private var showHistory = true
    @AppStorage("alertEnabled") private var alertEnabled = true
    @AppStorage("threshold") private var threshold = 25.0

    @State private var importing = false
    @State private var share: ShareItem?
    @State private var message: String?

    private static let gpxTypes: [UTType] = [UTType(filenameExtension: "gpx") ?? .xml, .xml]

    var body: some View {
        NavigationStack {
            List {
                Section("Impostazioni") {
                    Toggle("Mostra strade già percorse", isOn: $showHistory)
                    Toggle("Avvisami sulle strade già fatte", isOn: $alertEnabled)
                    Picker("Distanza di avviso", selection: $threshold) {
                        Text("15 m").tag(15.0)
                        Text("25 m").tag(25.0)
                        Text("40 m").tag(40.0)
                    }
                }

                Section("Viaggi (\(store.trips.count))") {
                    let list = Array(store.trips.reversed())
                    if list.isEmpty {
                        Text("Nessun viaggio salvato.").foregroundStyle(.secondary)
                    }
                    ForEach(list) { trip in
                        Button {
                            focus = trip
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(trip.title).foregroundStyle(.primary)
                                Text("\(trip.start.formatted(date: .abbreviated, time: .shortened)) · \(Geo.formatKm(trip.distance))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        store.delete(ids: Set(offsets.map { list[$0].id }))
                    }
                }

                Section("Backup") {
                    Button("Esporta tutto (GPX)", action: export)
                        .disabled(store.trips.isEmpty)
                    Button("Importa GPX") { importing = true }
                }
            }
            .navigationTitle("Viaggi")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: Self.gpxTypes,
                          allowsMultipleSelection: true, onCompletion: importFiles)
            .sheet(item: $share) { item in
                ActivityView(items: [item.url])
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil },
                                                       set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    private func export() {
        let day = Date().formatted(.iso8601.year().month().day())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("percorsi-\(day).gpx")
        do {
            try GPX.export(store.trips).write(to: url, atomically: true, encoding: .utf8)
            share = ShareItem(url: url)
        } catch {
            message = "Esportazione non riuscita: \(error.localizedDescription)"
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            message = error.localizedDescription
        case .success(let urls):
            var imported: [Trip] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    imported += GPX.parse(data)
                }
            }
            if !imported.isEmpty { store.add(contentsOf: imported) }
            message = imported.isEmpty ? "Nessun percorso trovato nei file." : "Importati \(imported.count) viaggi."
        }
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
