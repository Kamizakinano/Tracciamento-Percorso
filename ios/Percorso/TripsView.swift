import SwiftUI
import UniformTypeIdentifiers

struct TripsView: View {
    @EnvironmentObject private var store: TripStore
    @EnvironmentObject private var tracker: LocationTracker
    @EnvironmentObject private var parking: ParkingStore
    @EnvironmentObject private var passport: PassportStore
    @ObservedObject private var backup = BackupManager.shared
    @Binding var focus: Trip?
    /// "Ho parcheggiato qui" e apertura della scheda del parcheggio (gestiti dalla mappa).
    var onPark: () -> Void = {}
    var onOpenParking: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    @AppStorage(Settings.showHistory) private var showHistory = true
    @AppStorage(Settings.alertEnabled) private var alertEnabled = true
    @AppStorage(Settings.threshold) private var threshold = 0.0
    @AppStorage(Settings.travelMode) private var travelMode = ""
    @AppStorage(Settings.historyDays) private var historyDays = 0
    @AppStorage(Settings.modeFilter) private var modeFilter = ""
    @AppStorage(Settings.voiceAlert) private var voiceAlert = 1
    @AppStorage(Settings.autoRecord) private var autoRecord = false
    @AppStorage(Settings.periodOn) private var periodOn = false
    @AppStorage(Settings.periodStart) private var periodStart = 0.0
    @AppStorage(Settings.periodEnd) private var periodEnd = 0.0
    @AppStorage(Settings.navigationVoice) private var navigationVoice = true

    private enum FileAction { case importGPX, restore, chooseFolder }
    @State private var fileAction: FileAction?
    @State private var showImporter = false
    @State private var share: ShareItem?
    @State private var message: String?
    @State private var showStats = false
    @State private var showPassport = false
    @State private var askDeleteAll = false

    /// Sezione del Passaporto da mostrare negli screenshot.
    private static var passportScrollTarget: String? {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-passportPlaces") { return "luoghi" }
        if args.contains("-passportKm") { return "km" }
        return nil
    }

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
                    Button {
                        showPassport = true
                    } label: {
                        HStack {
                            Label("Passaporto e medaglie", systemImage: "medal.fill")
                            Spacer()
                            Text("\(passport.passport.count(.comune)) comuni")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    if parking.current == nil {
                        Button {
                            dismiss()
                            onPark()
                        } label: {
                            Label("Ho parcheggiato qui", systemImage: "parkingsign.circle.fill")
                        }
                    }
                    Button {
                        dismiss()
                        onOpenParking()
                    } label: {
                        Label(parking.current.map { "Auto parcheggiata in \($0.title)" } ?? "Parcheggi e storico",
                              systemImage: "car.fill")
                    }
                } header: {
                    Text("Parcheggio")
                }

                Section {
                    Toggle(isOn: Binding(get: { autoRecord }, set: { tracker.setAutoRecord($0) })) {
                        Label("Registra sempre", systemImage: "infinity")
                    }
                    Toggle(isOn: Binding(get: { periodOn }, set: setPeriodOn)) {
                        Label("Registra in un periodo", systemImage: "calendar")
                    }
                    .disabled(autoRecord)
                    if periodOn && !autoRecord {
                        DatePicker("Dal", selection: periodDate($periodStart, other: $periodEnd, isStart: true),
                                   displayedComponents: .date)
                        DatePicker("Al (compreso)", selection: periodDate($periodEnd, other: $periodStart, isStart: false),
                                   in: Date(timeIntervalSinceReferenceDate: periodStart)...,
                                   displayedComponents: .date)
                        if let period = Settings.period {
                            Text(periodStatus(period))
                                .font(.footnote)
                                .foregroundStyle(period.contains(Date()) ? .green : .secondary)
                        }
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
                         : periodOn
                         ? "Nei giorni scelti ogni spostamento viene registrato da solo, come con \"Registra sempre\"; poi la registrazione si ferma. Serve la posizione \"Sempre\". Se l'app è chiusa del tutto, parte al primo spostamento del primo giorno (riceverai una notifica): aprila una volta per sicurezza."
                         : "Registra solo tra Avvia e Ferma, oppure in un periodo scelto da te.")
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

                Section {
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
                        .contextMenu {
                            Section("Mezzo") {
                                ForEach(TravelMode.allCases) { m in
                                    Button { store.setMode(m, for: trip.id) } label: {
                                        Label(m.label, systemImage: m.icon)
                                    }
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        store.delete(ids: Set(offsets.map { list[$0].id }))
                    }
                } header: {
                    HStack {
                        Text("Viaggi (\(store.trips.count))")
                        Spacer()
                        Button(role: .destructive) {
                            askDeleteAll = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.body)
                                .foregroundColor(store.trips.isEmpty ? .secondary : .red)
                        }
                        .disabled(store.trips.isEmpty)
                        .accessibilityLabel("Cancella tutti i viaggi")
                    }
                } footer: {
                    Text("Tieni premuto un viaggio per correggere il mezzo (auto, bici, a piedi).")
                }

                Section {
                    if let folder = backup.folderName {
                        LabeledContent("Cartella", value: folder)
                        if let last = backup.lastBackup {
                            LabeledContent("Ultimo backup", value: last.formatted(date: .abbreviated, time: .shortened))
                        }
                        Button("Esegui backup ora") {
                            message = backup.backup(store.trips, parking: parking) ? "Backup completato." : (backup.lastError ?? "Backup non riuscito.")
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
                        Text("Scegli una cartella in iCloud Drive: a ogni viaggio salvato viene aggiornato il file \(BackupManager.fileName); i parcheggi (con le foto ridotte) vanno in \(ParkingStore.backupFileName). Per ripristinare puoi sceglierli tutti e due.")
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
                          allowsMultipleSelection: fileAction != .chooseFolder,
                          onCompletion: handleFiles)
            .sheet(item: $share) { item in
                ActivityView(items: [item.url])
            }
            .sheet(isPresented: $showStats) {
                StatsView().environmentObject(store)
            }
            .confirmationDialog("Cancellare tutti i viaggi?", isPresented: $askDeleteAll, titleVisibility: .visible) {
                Button("Cancella tutti i \(store.trips.count) viaggi", role: .destructive) {
                    let count = store.trips.count
                    let copy = store.deleteAll()
                    message = copy.map { "Cancellati \(count) viaggi. Una copia del backup è stata salvata come \($0): puoi recuperarli con \"Ripristina da backup…\"." }
                        ?? "Cancellati \(count) viaggi."
                }
                Button("Annulla", role: .cancel) {}
            } message: {
                Text(backup.isConfigured
                     ? "Le strade colorate e le statistiche ripartono da zero. Prima viene salvata una copia del backup, così potrai recuperarli."
                     : "Le strade colorate e le statistiche ripartono da zero. Non hai il backup automatico attivo: i viaggi non si potranno recuperare.")
            }
            .sheet(isPresented: $showPassport) {
                PassportView(scrollTarget: Self.passportScrollTarget)
                    .environmentObject(passport)
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
                if ProcessInfo.processInfo.arguments.contains("-showPassport") { showPassport = true }
                #endif
            }
        }
    }

    // MARK: - Registrazione programmata

    private func setPeriodOn(_ on: Bool) {
        if on && (periodStart == 0 || Settings.period.map { $0.isOver(Date()) } == true) {
            // Prima volta (o periodo già passato): da oggi per una settimana.
            let today = Calendar.current.startOfDay(for: Date())
            periodStart = today.timeIntervalSinceReferenceDate
            periodEnd = today.addingTimeInterval(6 * 86400).timeIntervalSinceReferenceDate
        }
        periodOn = on
        tracker.refreshSchedule()
    }

    /// Data del periodo; se la fine finisce prima dell'inizio, si sposta anche l'altra.
    private func periodDate(_ value: Binding<Double>, other: Binding<Double>, isStart: Bool) -> Binding<Date> {
        Binding(get: { Date(timeIntervalSinceReferenceDate: value.wrappedValue) }, set: { date in
            let day = Calendar.current.startOfDay(for: date).timeIntervalSinceReferenceDate
            value.wrappedValue = day
            if (isStart ? other.wrappedValue < day : other.wrappedValue > day) { other.wrappedValue = day }
            tracker.refreshSchedule()
        })
    }

    private func periodStatus(_ period: RecordingPeriod) -> String {
        let now = Date()
        if period.contains(now) { return "● Registrazione in corso \(period.text)" }
        if period.isUpcoming(now) { return "Partirà da sola \(period.text)" }
        return "Periodo finito (\(period.text))"
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
                message = backup.backup(store.trips, parking: parking) ? "Backup automatico attivo." : (backup.lastError ?? "Backup non riuscito.")
            } else {
                message = backup.lastError
            }
        case .restore:
            // Si possono scegliere insieme il backup dei viaggi e quello dei parcheggi.
            var lines: [String] = []
            for url in urls {
                do {
                    let data = try BackupManager.readFile(at: url)
                    if let trips = try? JSONDecoder().decode([Trip].self, from: data) {
                        let before = store.trips.count
                        store.add(contentsOf: trips)
                        lines.append("Ripristinati \(store.trips.count - before) viaggi (quelli già presenti sono stati saltati).")
                    } else {
                        let added = try parking.restore(data)
                        lines.append("Ripristinati \(added) parcheggi.")
                    }
                } catch {
                    lines.append("\(url.lastPathComponent): file di backup non valido.")
                }
            }
            message = lines.joined(separator: "\n")
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
