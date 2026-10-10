import SwiftUI
import PhotosUI
import CoreLocation

/// Scheda del parcheggio: dov'è l'auto, ticket, nota, foto, storico e impostazioni.
struct ParkingView: View {
    @EnvironmentObject private var parking: ParkingStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Settings.parkingDetectKey) private var detect = 1
    @AppStorage(Settings.carBluetoothKey) private var carBluetooth = ""
    @AppStorage(Settings.parkingReminder) private var defaultReminder = 10

    let userLocation: CLLocationCoordinate2D?
    /// Apri subito lo storico (usato dagli screenshot).
    var startWithHistory = false
    var onPark: () -> Void
    var onWalk: (ParkingSpot) -> Void
    var onShow: (ParkingSpot) -> Void

    @State private var note = ""
    @State private var noteSpotID: UUID?
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showPhoto = false
    @State private var showHistory = false

    private static let reminderChoices = [5, 10, 15, 30]

    var body: some View {
        NavigationStack {
            List {
                if let spot = parking.current {
                    carSection(spot)
                    ticketSection(spot)
                    noteSection(spot)
                    Section {
                        Button {
                            parking.retrieve()
                        } label: {
                            Label("Ho ripreso l'auto", systemImage: "checkmark.circle")
                        }
                        Button {
                            onPark()
                        } label: {
                            Label("Ho parcheggiato da un'altra parte (qui)", systemImage: "location.fill")
                        }
                    } footer: {
                        Text("Quando riprendi l'auto il parcheggio resta nello storico.")
                    }
                } else {
                    Section {
                        Button(action: onPark) {
                            Label("Ho parcheggiato qui", systemImage: "parkingsign.circle.fill")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.blue, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                    } footer: {
                        Text("Salva la posizione attuale come parcheggio. Poi potrai aggiungere ticket, foto e nota.")
                    }
                }

                Section {
                    NavigationLink(isActive: $showHistory) {
                        ParkingHistoryView(onShow: { spot in
                            dismiss()
                            onShow(spot)
                        })
                    } label: {
                        Label("Storico parcheggi (\(parking.spots.count))", systemImage: "clock.arrow.circlepath")
                    }
                }

                settingsSection
            }
            .navigationTitle("Parcheggio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
            .onAppear {
                loadNote()
                if startWithHistory {
                    // Il passaggio allo storico funziona solo a scheda già aperta.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { showHistory = true }
                }
            }
            .onChange(of: parking.current?.id) { _ in loadNote() }
            .onChange(of: note) { text in
                if let id = noteSpotID, parking.spot(id)?.note ?? "" != text { parking.setNote(text, for: id) }
            }
            .onChange(of: photoItem) { item in
                guard let item, let id = parking.current?.id else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        await MainActor.run { parking.setPhoto(image, for: id) }
                    }
                    await MainActor.run { photoItem = nil }
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraPicker { image in
                    if let id = parking.current?.id { parking.setPhoto(image, for: id) }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showPhoto) {
                if let spot = parking.current, let image = parking.image(for: spot) {
                    PhotoViewer(image: image)
                }
            }
        }
    }

    private func loadNote() {
        noteSpotID = parking.current?.id
        note = parking.current?.note ?? ""
    }

    // MARK: - Dov'è l'auto

    private func carSection(_ spot: ParkingSpot) -> some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "car.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(Color.blue, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(spot.title).font(.headline)
                    Text("Dalle \(spot.date.formatted(date: .omitted, time: .shortened)) · da \(Geo.formatDuration(spot.duration()))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let d = distanceText(spot) {
                        Text(d).font(.subheadline.weight(.semibold)).foregroundStyle(.blue)
                    }
                }
            }
            .padding(.vertical, 4)
            Button {
                dismiss()
                onWalk(spot)
            } label: {
                Label("Portami all'auto", systemImage: "figure.walk")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.green, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            Button {
                dismiss()
                onShow(spot)
            } label: {
                Label("Mostra sulla mappa", systemImage: "map")
            }
        } footer: {
            Label(spot.source.label, systemImage: spot.source.icon)
        }
    }

    private func distanceText(_ spot: ParkingSpot) -> String? {
        guard let me = userLocation else { return nil }
        return "A \(Geo.formatShort(Geo.distance(me, spot.coordinate))) da te"
    }

    // MARK: - Ticket

    private func ticketSection(_ spot: ParkingSpot) -> some View {
        Section {
            Toggle(isOn: Binding(get: { spot.expiry != nil }, set: { on in
                if on { ParkingReminders.requestPermission() }
                parking.setExpiry(on ? Date().addingTimeInterval(3600) : nil,
                                  reminderMinutes: spot.reminderMinutes ?? defaultReminder, for: spot.id)
            })) {
                Label("Ticket o disco orario", systemImage: "timer")
            }
            if let expiry = spot.expiry {
                DatePicker("Scade alle", selection: Binding(get: { expiry }, set: {
                    parking.setExpiry($0, reminderMinutes: spot.reminderMinutes ?? defaultReminder, for: spot.id)
                }), displayedComponents: .hourAndMinute)
                HStack(spacing: 8) {
                    ForEach([30, 60, 120], id: \.self) { minutes in
                        Button(minutes < 60 ? "+\(minutes) min" : "+\(minutes / 60) h") {
                            parking.setExpiry(expiry.addingTimeInterval(Double(minutes) * 60),
                                              reminderMinutes: spot.reminderMinutes ?? defaultReminder, for: spot.id)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Picker("Avvisami", selection: Binding(get: { spot.reminderMinutes ?? defaultReminder }, set: {
                    defaultReminder = $0
                    parking.setExpiry(expiry, reminderMinutes: $0, for: spot.id)
                })) {
                    ForEach(Self.reminderChoices, id: \.self) { Text("\($0) min prima").tag($0) }
                }
                if expiry > Date() {
                    HStack {
                        Text("Scade tra")
                        Spacer()
                        Text(timerInterval: Date()...expiry, countsDown: true)
                            .monospacedDigit()
                            .foregroundStyle(.orange)
                            .font(.headline)
                    }
                } else {
                    Text("Ticket scaduto").foregroundStyle(.red).font(.headline)
                }
            }
        } header: {
            Text("Scadenza")
        } footer: {
            if spot.expiry != nil {
                Text("Riceverai una notifica prima della scadenza e il conto alla rovescia compare sul blocco schermo (Live Activity).")
            }
        }
    }

    // MARK: - Nota e foto

    private func noteSection(_ spot: ParkingSpot) -> some View {
        Section("Nota e foto") {
            TextField("Piano, colonna, via…", text: $note, axis: .vertical)
                .lineLimit(1...4)
            if let image = parking.image(for: spot) {
                Button { showPhoto = true } label: {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 170)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 10) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { showCamera = true } label: {
                        Label("Scatta foto", systemImage: "camera")
                    }
                    .buttonStyle(.bordered)
                }
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Galleria", systemImage: "photo")
                }
                .buttonStyle(.bordered)
                if spot.photo != nil {
                    Spacer()
                    Button(role: .destructive) {
                        parking.setPhoto(nil, for: spot.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Impostazioni

    private var settingsSection: some View {
        Section {
            Picker("Rileva da solo", selection: $detect) {
                Text("Velocità e Bluetooth").tag(1)
                Text("Solo Bluetooth / CarPlay").tag(2)
                Text("No, solo a mano").tag(0)
            }
            Picker("Bluetooth dell'auto", selection: $carBluetooth) {
                Text("Nessuno").tag("")
                ForEach(bluetoothChoices, id: \.self) { Text($0).tag($0) }
            }
        } header: {
            Text("Rilevamento automatico")
        } footer: {
            Text("""
            Velocità: quando dopo un viaggio in auto prosegui a piedi, oppure alla fine di un viaggio in auto. \
            Funziona solo mentre l'app registra (Avvia o "Registra sempre"). Anche scendere da un autobus può sembrare un parcheggio.
            Bluetooth: scegli il Bluetooth dell'auto mentre è collegato; CarPlay viene riconosciuto da solo. \
            Funziona solo se l'app è aperta o sta registrando in background.
            """)
        }
    }

    private var bluetoothChoices: [String] {
        var names = CarAudioMonitor.connectedBluetoothNames
        if !carBluetooth.isEmpty && !names.contains(carBluetooth) { names.insert(carBluetooth, at: 0) }
        return names
    }
}

// MARK: - Storico

struct ParkingHistoryView: View {
    @EnvironmentObject private var parking: ParkingStore
    var onShow: (ParkingSpot) -> Void

    var body: some View {
        List {
            let list = parking.history
            if list.isEmpty {
                Text("Nessun parcheggio salvato.").foregroundStyle(.secondary)
            }
            ForEach(list) { spot in
                Button { onShow(spot) } label: { row(spot) }
                    .buttonStyle(.plain)
            }
            .onDelete { offsets in
                parking.delete(ids: Set(offsets.map { list[$0].id }))
            }
        }
        .navigationTitle("Storico parcheggi")
    }

    private func row(_ spot: ParkingSpot) -> some View {
        HStack(spacing: 12) {
            if let image = parking.image(for: spot) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: spot.isActive ? "car.fill" : "parkingsign")
                    .font(.title3)
                    .foregroundStyle(spot.isActive ? Color.white : Color.blue)
                    .frame(width: 46, height: 46)
                    .background(spot.isActive ? Color.blue : Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(spot.title).font(.subheadline.weight(.semibold))
                    if spot.isActive {
                        Text("ORA")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.green, in: Capsule())
                    }
                }
                Text("\(spot.date.formatted(date: .abbreviated, time: .shortened)) · \(Geo.formatDuration(spot.duration()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let note = spot.note {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: spot.source.icon)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Foto

/// Fotocamera (serve il permesso, chiesto la prima volta).
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

struct PhotoViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } }
                }
        }
    }
}
