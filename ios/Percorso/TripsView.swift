import SwiftUI
import UniformTypeIdentifiers

struct TripsView: View {
    @EnvironmentObject private var store: TripStore
    @EnvironmentObject private var tracker: LocationTracker
    @ObservedObject private var backup = BackupManager.shared
    @Binding var focus: Trip?
    @Environment(\.dismiss) private var dismiss

    @AppStorage(Settings.showHistory) private var showHistory = true
    @AppStorage(Settings.alertEnabled) private var alertEnabled = true
    @AppStorage(Settings.threshold) private var threshold = 0.0
    @AppStorage(Settings.travelMode) private var travelMode = ""
    @AppStorage(Settings.historyDays) private var historyDays = 0
    @AppStorage(Settings.modeFilter) private var modeFilter = ""
    @AppStorage(Settings.voiceAlert) private var voiceAlert = 1
    @AppStorage(Settings.autoRecord) private var autoRecord = false
    @AppStorage(Settings.navigationVoice) private var navigationVoice = true

    private enum FileAction { case importGPX, restore, chooseFolder }
    @State private var fileAction: FileAction?
    @State private var showImporter = false
    @State private var share: ShareItem?
    @State private var message: String?
    @State private var showStats = false

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private static let gpxTypes: [UTType] = [UTType(filenameExtension: "gpx") ?? .xml, .xml]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showStats = true
                    } label: {
                        Label("Statistiche", systemImage: "chart.bar.xaxis")
                    }
                }

                Section {
                    Toggle(isOn: Binding(get: { autoRecord }, set: { tracker.setAutoRecord($0) })) {
                        Label("Registra sempre", systemImage: "infinity")
                    }
                    Picker(selection: $travelMode) {
                        Text("Rilevamento automatico").tag("")
                        ForEach(TravelMode.allCases) { Label($0.label, systemImage: $0.icon).tag($0.rawValue) }
                    } label: {
                        Label("Mezzo", systemImage: "car.side")
                    }
                } header: {
                    Text("Registrazione")
                } footer: {
                    Text(autoRecord
                         ? "Ogni spostamento viene registrato da solo, anche senza aprire l'app. Consenti la posizione \"Sempre\". Consuma più batteria."
                         : "Registra solo tra Avvia e Ferma.")
                }

                Section("Avvisi") {
                    Toggle("Avvisami sulle strade già fatte", isOn: $alertEnabled)
                    Picker("Distanza di avviso", selection: $threshold) {
                        Text("In base al mezzo").tag(0.0)
                        Text("15 m").tag(15.0)
                        Text("25 m").tag(25.0)
                        Text("40 m").tag(40.0)
                    }
                    Picker("Avviso vocale", selection: $voiceAlert) {
                        Text("Mai").tag(0)
                        Text("Con cuffie o CarPlay").tag(1)
                        Text("Sempre").tag(2)
                    }
                    Toggle("Guida vocale in navigazione", isOn: $navigationVoice)
                }

                Section {
                    Toggle("Mostra strade già percorse", isOn: $showHistory)
                    Picker("Considera i viaggi", selection: $historyDays) {
                        Text("Di sempre").tag(0)
                        Text("Degli ultimi 12 mesi").tag(365)
                        Text("Degli ultimi 6 mesi").tag(182)
                        Text("Degli ultimi 30 giorni").tag(30)
                    }
                    Picker("Mezzo", selection: $modeFilter) {
                        Text("Tutti").tag("")
                        ForEach(TravelMode.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    HStack(spacing: 14) {
                        legend(0, "1 volta")
                        legend(1, "2-3 volte")
                        legend(2, "4+ volte")
                    }
                    .font(.caption)
                } header: {
                    Text("Strade già percorse")
                } footer: {
                    Text("I viaggi esclusi non vengono mostrati e non fanno scattare gli avvisi.")
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
                            tripRow(trip)
                        }
                    }
                    .onDelete { offsets in
                        store.delete(ids: Set(offsets.map { list[$0].id }))
                    }
                }

                Section {
                    if let folder = backup.folderName {
                        LabeledContent("Cartella", value: folder)
                        if let last = backup.lastBackup {
                            LabeledContent("Ultimo backup", value: last.formatted(date: .abbreviated, time: .shortened))
                        }
                        Button("Esegui backup ora") {
                            message = backup.backup(store.trips) ? "Backup completato." : (backup.lastError ?? "Backup non riuscito.")
                        }
                        Button("Cambia cartella") { pick(.chooseFolder) }
                        Button("Disattiva backup automatico", role: .destructive) { backup.removeFolder() }
                    } else {
                        Button("Attiva backup automatico…") { pick(.chooseFolder) }
                    }
                    Button("Ripristina da backup…") { pick(.restore) }
                    Button("Esporta tutto (GPX)", action: export)
                        .disabled(store.trips.isEmpty)
                    Button("Importa GPX…") { pick(.importGPX) }
                } header: {
                    Text("Backup")
                } footer: {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Scegli una cartella in iCloud Drive: a ogni viaggio salvato viene aggiornato il file \(BackupManager.fileName).")
                        Text("Percorso versione \(Self.appVersion)")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 12)
                    }
                }
            }
            .navigationTitle("Viaggi")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: allowedTypes,
                          allowsMultipleSelection: fileAction == .importGPX,
                          onCompletion: handleFiles)
            .sheet(item: $share) { item in
                ActivityView(items: [item.url])
            }
            .sheet(isPresented: $showStats) {
                StatsView().environmentObject(store)
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil },
                                                       set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .onChange(of: historyDays) { _ in store.setFilter(Settings.filter) }
            .onChange(of: modeFilter) { _ in store.setFilter(Settings.filter) }
            .onAppear {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-stats") { showStats = true }
                #endif
            }
        }
    }

    private func pick(_ action: FileAction) {
        fileAction = action
        showImporter = true
    }

    private var allowedTypes: [UTType] {
        switch fileAction {
        case .chooseFolder: return [.folder]
        case .restore: return [.json]
        default: return Self.gpxTypes
        }
    }

    private func legend(_ level: Int, _ text: String) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(Color(MapView.levelColors[level])).frame(width: 18, height: 6)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private func tripRow(_ trip: Trip) -> some View {
        HStack(spacing: 12) {
            Image(systemName: trip.effectiveMode.icon)
                .frame(width: 26)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(trip.title).foregroundStyle(.primary)
                    if trip.automatic == true {
                        Image(systemName: "infinity").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(subtitle(trip))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func subtitle(_ trip: Trip) -> String {
        var parts = [trip.start.formatted(date: .abbreviated, time: .shortened), Geo.formatKm(trip.distance)]
        if let f = trip.newFraction { parts.append("\(Int((f * 100).rounded()))% nuove") }
        if let place = trip.locality, !place.isEmpty { parts.append(place) }
        return parts.joined(separator: " · ")
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

    private func handleFiles(_ result: Result<[URL], Error>) {
        let action = fileAction
        let urls: [URL]
        switch result {
        case .failure(let error):
            message = error.localizedDescription
            return
        case .success(let u):
            urls = u
        }
        switch action {
        case .chooseFolder:
            guard let folder = urls.first else { return }
            backup.setFolder(folder)
            if backup.isConfigured {
                message = backup.backup(store.trips) ? "Backup automatico attivo." : (backup.lastError ?? "Backup non riuscito.")
            } else {
                message = backup.lastError
            }
        case .restore:
            guard let url = urls.first else { return }
            do {
                let trips = try BackupManager.readBackup(at: url)
                let before = store.trips.count
                store.add(contentsOf: trips)
                message = "Ripristinati \(store.trips.count - before) viaggi (quelli già presenti sono stati saltati)."
            } catch {
                message = "File di backup non valido: \(error.localizedDescription)"
            }
        default:
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
