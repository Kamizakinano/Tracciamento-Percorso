import SwiftUI
import MapKit

/// Ultima regione visibile e posizione dell'utente sulla mappa
/// (classe, così aggiornarle non ridisegna la vista).
final class MapState {
    var region: MKCoordinateRegion?
    var userLocation: CLLocationCoordinate2D?
}

struct SearchRequest: Identifiable {
    let id = UUID()
    let query: String
}

struct ContentView: View {
    @EnvironmentObject private var store: TripStore
    @EnvironmentObject private var tracker: LocationTracker
    @StateObject private var explore = ExploreService()
    @StateObject private var planner = RoutePlanner()
    @AppStorage(Settings.showHistory) private var showHistory = true
    @AppStorage(Settings.alertEnabled) private var alertEnabled = true
    @AppStorage(Settings.mapStyle) private var mapStyle = 0
    @AppStorage(Settings.travelMode) private var travelMode = ""

    @State private var mapState = MapState()
    @State private var follow = true
    @State private var focus: Trip?
    @State private var zoomRequest: MKCoordinateRegion?
    @State private var showTrips = false
    @State private var showStats = false
    @State private var askName = false
    @State private var tripName = ""
    @State private var search: SearchRequest?
    @State private var place: Place?
    @State private var info: String?

    /// Mezzo usato per strade nuove e percorsi.
    private var mode: TravelMode { TravelMode(rawValue: travelMode) ?? tracker.currentMode }

    var body: some View {
        ZStack {
            MapView(history: store.lines,
                    historyVersion: store.version,
                    showHistory: showHistory,
                    currentPoints: tracker.points,
                    exploreLines: explore.lines,
                    exploreVersion: explore.version,
                    route: planner.current,
                    mapType: mapType,
                    place: place,
                    follow: $follow,
                    focus: $focus,
                    zoomRequest: $zoomRequest,
                    onRegionChange: regionChanged,
                    onUserLocation: { mapState.userLocation = $0 })
                .ignoresSafeArea()

            VStack(spacing: 10) {
                statusBar
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let place { placeChip(place) }
                        if let text = info ?? explore.message ?? planner.message { infoChip(text) }
                    }
                    Spacer()
                    VStack(spacing: 10) {
                        roundButton("magnifyingglass") { search = SearchRequest(query: "") }
                        mapStyleMenu
                        exploreButton
                    }
                    .shadow(radius: 4)
                }
                if tracker.isRecording && tracker.onOldRoad && alertEnabled {
                    Text("⚠️ Strada già percorsa")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 12))
                        .shadow(radius: 4)
                        .transition(.opacity)
                }
                Spacer()
                if planner.destination != nil { routeCard }
                controls
            }
            .padding()
            .animation(.easeInOut(duration: 0.2), value: tracker.onOldRoad)
        }
        .onAppear {
            follow = store.trips.isEmpty || tracker.isRecording
            store.setFilter(Settings.filter)
            tracker.requestPermissionIfNeeded()
            handleLaunchArguments()
        }
        .onChange(of: store.version) { _ in
            if let r = mapState.region { explore.refresh(region: r, mode: mode, index: store.index) }
        }
        .sheet(item: $search) { request in
            SearchView(onSelect: { selected in
                planner.clear()
                place = selected
            }, initialQuery: request.query)
        }
        .sheet(isPresented: $showTrips) {
            TripsView(focus: $focus)
                .environmentObject(store)
                .environmentObject(tracker)
        }
        .sheet(isPresented: $showStats) {
            StatsView().environmentObject(store)
        }
        .alert("Salva viaggio", isPresented: $askName) {
            TextField("Nome (facoltativo)", text: $tripName)
            Button("Salva") { tracker.stop(name: tripName, keep: true) }
            Button("Scarta", role: .destructive) { tracker.stop(name: nil, keep: false) }
            Button("Continua", role: .cancel) {}
        } message: {
            Text(Geo.formatKm(tracker.distance))
        }
        .alert("Posizione non consentita", isPresented: $tracker.showDeniedAlert) {
            Button("Apri Impostazioni") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Consenti l'accesso alla posizione (\"Sempre\" per la registrazione automatica).")
        }
    }

    // MARK: - Barra di stato

    private var statusBar: some View {
        HStack(spacing: 12) {
            if tracker.isAutomatic {
                Label("Auto", systemImage: "infinity").foregroundStyle(.green)
            } else {
                Label(tracker.isRecording ? "Registrazione" : "Fermo",
                      systemImage: tracker.isRecording ? "record.circle" : "pause.circle")
                    .foregroundStyle(tracker.isRecording ? .red : .secondary)
            }
            if tracker.isRecording {
                Image(systemName: tracker.currentMode.icon).foregroundStyle(.blue)
            }
            Text(Geo.formatKm(tracker.distance))
            Text("Nuove: \(newText)")
        }
        .font(.subheadline.weight(.medium))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
    }

    // MARK: - Pulsanti

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                if tracker.isAutomatic {
                    showTrips = true
                } else if tracker.isRecording {
                    tripName = ""
                    askName = true
                } else {
                    follow = true
                    tracker.start()
                }
            } label: {
                Label(mainLabel.0, systemImage: mainLabel.1)
                    .font(.headline)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                    .foregroundStyle(.white)
                    .background(mainLabel.2, in: Capsule())
            }

            roundButton("location.fill") { follow = true }
            roundButton("list.bullet") { showTrips = true }
        }
        .shadow(radius: 4)
    }

    private var newText: String {
        guard let p = tracker.newPercent else { return "–" }
        return "\(p)%"
    }

    private var mainLabel: (String, String, Color) {
        if tracker.isAutomatic { return ("Automatico", "infinity", .green) }
        return tracker.isRecording ? ("Ferma", "stop.fill", .red) : ("Avvia", "play.fill", .blue)
    }

    private var mapType: MKMapType {
        switch mapStyle {
        case 1: return .hybrid
        case 2: return .satellite
        default: return .standard
        }
    }

    private var mapStyleMenu: some View {
        Menu {
            Picker("Tipo di mappa", selection: $mapStyle) {
                Label("Standard", systemImage: "map").tag(0)
                Label("Satellite con strade", systemImage: "map.fill").tag(1)
                Label("Satellite", systemImage: "globe.europe.africa.fill").tag(2)
            }
        } label: {
            circleIcon("square.stack.3d.up")
        }
    }

    private var exploreButton: some View {
        Button(action: toggleExplore) {
            ZStack {
                circleIcon("sparkles", tint: explore.isOn ? .white : .accentColor,
                           background: explore.isOn ? AnyShapeStyle(Color.green) : AnyShapeStyle(Material.regularMaterial))
                if explore.isLoading { ProgressView().tint(.white) }
            }
        }
        .accessibilityLabel("Strade nuove vicino a te")
    }

    // MARK: - Luogo e percorso

    private func placeChip(_ place: Place) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "mappin.circle.fill").foregroundStyle(.red)
            Text(place.name).lineLimit(1)
            if planner.destination == nil {
                Button {
                    planRoute(to: place)
                } label: {
                    Label("Percorso", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.purple)
                }
            }
            Button {
                self.place = nil
                planner.clear()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 4)
    }

    private func infoChip(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .onTapGesture { info = nil }
    }

    private var routeCard: some View {
        VStack(spacing: 10) {
            if planner.isLoading {
                ProgressView("Cerco il percorso con più strade nuove…")
            } else if let r = planner.current {
                HStack {
                    Button { planner.previous() } label: { Image(systemName: "chevron.left") }
                        .disabled(planner.options.count < 2)
                    Spacer()
                    VStack(spacing: 2) {
                        Text(planner.selected == 0 ? "Consigliato · 1 di \(planner.options.count)"
                                                   : "Alternativa · \(planner.selected + 1) di \(planner.options.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(Geo.formatKm(r.distance)) · \(Geo.formatDuration(r.time))")
                            .font(.headline)
                        Text("\(Int((r.newFraction * 100).rounded()))% strade nuove")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                    Spacer()
                    Button { planner.next() } label: { Image(systemName: "chevron.right") }
                        .disabled(planner.options.count < 2)
                }
                .font(.title3)
            }
            HStack {
                Button {
                    openInMaps()
                } label: {
                    Label("Naviga con Mappe", systemImage: "location.north.line.fill")
                }
                .disabled(planner.destination == nil)
                Spacer()
                Button("Chiudi") { planner.clear() }
            }
            .font(.subheadline)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 4)
    }

    private func planRoute(to place: Place) {
        guard let start = mapState.userLocation ?? tracker.currentLocation?.coordinate else {
            info = "Posizione attuale non disponibile."
            return
        }
        planner.plan(from: start, to: place, mode: mode, index: store.index)
    }

    private func openInMaps() {
        guard let dest = planner.destination else { return }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: dest.coordinate))
        item.name = dest.name
        item.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: mode == .car ? MKLaunchOptionsDirectionsModeDriving
                                                           : MKLaunchOptionsDirectionsModeWalking,
        ])
    }

    // MARK: - Strade nuove

    private func toggleExplore() {
        guard var region = mapState.region ?? userRegion else {
            info = "Posizione attuale non disponibile."
            return
        }
        // Mappa troppo lontana: avvicinati alla tua posizione (o al centro della mappa).
        if !explore.isOn && ExploreService.isTooWide(region) {
            let center = mapState.userLocation ?? region.center
            region = MKCoordinateRegion(center: center, latitudinalMeters: 1500, longitudinalMeters: 1500)
            zoomRequest = region
        }
        explore.toggle(region: region, mode: mode, index: store.index)
    }

    private var userRegion: MKCoordinateRegion? {
        (mapState.userLocation ?? tracker.currentLocation?.coordinate).map {
            MKCoordinateRegion(center: $0, latitudinalMeters: 1500, longitudinalMeters: 1500)
        }
    }

    private func regionChanged(_ region: MKCoordinateRegion) {
        mapState.region = region
        explore.regionChanged(region, mode: mode, index: store.index)
    }

    // MARK: - Utilità

    private func roundButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { circleIcon(icon) }
    }

    private func circleIcon(_ icon: String, tint: Color = .accentColor,
                            background: AnyShapeStyle = AnyShapeStyle(Material.regularMaterial)) -> some View {
        Image(systemName: icon)
            .font(.title3)
            .foregroundStyle(tint)
            .frame(width: 52, height: 52)
            .background(background, in: Circle())
    }

    /// Parametri di avvio usati solo per gli screenshot automatici (ios/scripts/screenshots.sh).
    private func handleLaunchArguments() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        func value(_ key: String) -> String? {
            guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if args.contains("-showTrips") { showTrips = true }
        if args.contains("-stats") { showStats = true }
        if let q = value("-search") { search = SearchRequest(query: q) }
        if args.contains("-explore") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { toggleExplore() }
        }
        if let target = value("-routeTo") {
            let parts = target.split(separator: ",", maxSplits: 2).map(String.init)
            if parts.count == 3, let lat = Double(parts[0]), let lon = Double(parts[1]) {
                let p = Place(name: parts[2], coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                place = p
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { planRoute(to: p) }
            }
        }
        #endif
    }
}
