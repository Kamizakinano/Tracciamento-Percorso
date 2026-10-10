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
    @EnvironmentObject private var navigation: NavigationSession
    @StateObject private var explore = ExploreService()
    @StateObject private var planner = RoutePlanner()
    @StateObject private var transit = TransitPlanner()
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
    @State private var routeMode: RouteMode = .car
    @State private var showTransitDetail = false

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
                    route: navigation.route ?? (routeMode == .transit ? nil : planner.current),
                    transit: routeMode == .transit && !navigation.isActive && planner.destination != nil ? transit.current : nil,
                    mapType: mapType,
                    place: place,
                    navigating: navigation.isActive,
                    follow: $follow,
                    focus: $focus,
                    zoomRequest: $zoomRequest,
                    onRegionChange: regionChanged,
                    onUserLocation: { mapState.userLocation = $0 })
                .ignoresSafeArea()

            if navigation.isActive {
                navigationOverlay
            } else {
                mainOverlay
            }
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
            RouteSearchView(region: mapState.region ?? userRegion, initialDestination: request.query, mode: mode) { from, to, mode in
                place = to
                planRoute(to: to, from: from, mode: mode)
            }
        }
        .onReceive(transit.$itineraries) { its in
            if let best = its.map(\.duration).min() { planner.setTransitETA(best) }
        }
        .sheet(isPresented: $showTransitDetail) {
            if let it = transit.current { TransitDetailView(itinerary: it) }
        }
        .onChange(of: navigation.arrived) { arrived in
            // Arrivato: chiudi la navigazione da solo dopo un po'.
            guard arrived else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                if navigation.arrived { endNavigation() }
            }
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

    // MARK: - Schermata normale

    private var mainOverlay: some View {
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
            oldRoadBanner
            Spacer()
            if planner.destination != nil { routeCard }
            controls
        }
        .padding()
        .animation(.easeInOut(duration: 0.2), value: tracker.onOldRoad)
    }

    @ViewBuilder
    private var oldRoadBanner: some View {
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
    }

    // MARK: - Navigazione

    private var navigationOverlay: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: navigation.maneuverIcon)
                    .font(.system(size: 44, weight: .bold))
                    .frame(width: 60)
                VStack(alignment: .leading, spacing: 4) {
                    if navigation.rerouting {
                        Text("Ricalcolo del percorso…").font(.title3.weight(.semibold))
                    } else {
                        if !navigation.arrived {
                            Text(Geo.formatShort(navigation.distanceToManeuver))
                                .font(.system(size: 32, weight: .bold))
                        }
                        Text(navigation.instruction)
                            .font(.title3.weight(.semibold))
                            .lineLimit(3)
                            .minimumScaleFactor(0.8)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding()
            .background(Color(red: 0.08, green: 0.42, blue: 0.28), in: RoundedRectangle(cornerRadius: 20))
            .shadow(radius: 6)

            oldRoadBanner
            Spacer()

            if !follow {
                Button {
                    follow = true
                } label: {
                    Label("Ricentra", systemImage: "location.north.line.fill")
                        .font(.headline)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                }
                .shadow(radius: 4)
            }

            HStack(spacing: 0) {
                navStat(Date().addingTimeInterval(navigation.remainingTime).formatted(date: .omitted, time: .shortened), "arrivo")
                navStat(Geo.formatDuration(navigation.remainingTime), "tempo")
                navStat(Geo.formatKm(navigation.remainingDistance), "distanza")
                Button(action: endNavigation) {
                    Text("Fine")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(Color.red, in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .shadow(radius: 6)
        }
        .padding()
        .animation(.easeInOut(duration: 0.2), value: tracker.onOldRoad)
    }

    private func navStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func startNavigation() {
        guard let route = planner.current, let destination = planner.destination else { return }
        if tracker.isRecording {
            navigation.startedRecording = false
        } else {
            tracker.start()
            navigation.startedRecording = true
        }
        navigation.start(route: route, destination: destination, mode: planner.mode)
        planner.clear()
        transit.clear()
        follow = true
    }

    private func endNavigation() {
        let destination = navigation.destination
        let startedRecording = navigation.startedRecording
        navigation.stop()
        tracker.navigationInfo = nil
        place = nil
        if startedRecording && tracker.isRecording && !tracker.isAutomatic {
            tracker.stop(name: destination.map { "Verso \($0.name)" }, keep: true)
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
            // Con un percorso aperto il pulsante verde "Avvia" della scheda basta:
            // niente secondo "Avvia" (registrazione) per non confondere.
            if planner.destination == nil || tracker.isRecording {
                recordButton
            }
            roundButton("location.fill") { follow = true }
            roundButton("list.bullet") { showTrips = true }
        }
        .shadow(radius: 4)
    }

    private var recordButton: some View {
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
                transit.clear()
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
            if let origin = planner.origin, let dest = planner.destination {
                Text("\(origin.name) → \(dest.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            modeRow
            if routeMode == .transit {
                transitContent
            } else {
                driveContent
            }
            HStack(spacing: 12) {
                Button("Chiudi", action: closeRoute)
                    .font(.subheadline)
                Spacer()
                if routeMode == .transit {
                    if transit.current != nil {
                        Button("Dettagli") { showTransitDetail = true }
                            .font(.subheadline.weight(.semibold))
                    }
                    Button {
                        if let dest = planner.destination {
                            TransitPlanner.openInAppleMaps(from: planner.origin, to: dest)
                        }
                    } label: {
                        Label("Apple Mappe", systemImage: "arrow.up.forward.app")
                            .font(.subheadline)
                    }
                } else {
                    Button(action: startNavigation) {
                        Label("Avvia", systemImage: "location.north.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 12)
                            .background(planner.current == nil ? Color.gray : Color.green, in: Capsule())
                    }
                    .disabled(planner.current == nil)
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 4)
    }

    /// Riga con auto, bici, a piedi e mezzi pubblici, ognuno con il suo tempo.
    private var modeRow: some View {
        HStack(spacing: 6) {
            ForEach(RouteMode.allCases) { m in
                Button { selectMode(m) } label: {
                    VStack(spacing: 2) {
                        Image(systemName: m.icon).font(.headline)
                        Text(planner.etas[m].map { Geo.formatDuration($0) } ?? "–")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .foregroundStyle(routeMode == m ? Color.white : Color.primary)
                    .background(routeMode == m ? Color.accentColor : Color.secondary.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 10))
                }
                .accessibilityLabel(m.label)
            }
        }
    }

    @ViewBuilder
    private var driveContent: some View {
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
                    Text(routeSummary(r))
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
    }

    @ViewBuilder
    private var transitContent: some View {
        if transit.isLoading {
            ProgressView("Cerco autobus, tram e metro…")
        } else if let it = transit.current {
            HStack {
                Button { transit.previous() } label: { Image(systemName: "chevron.left") }
                    .disabled(transit.itineraries.count < 2)
                    .font(.title3)
                Spacer()
                VStack(spacing: 6) {
                    Text("\(it.start.formatted(date: .omitted, time: .shortened)) → \(it.end.formatted(date: .omitted, time: .shortened)) · \(Geo.formatDuration(it.duration))")
                        .font(.headline)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Array(it.legs.enumerated()), id: \.element.id) { i, leg in
                                if i > 0 {
                                    Image(systemName: "chevron.compact.right").foregroundStyle(.secondary)
                                }
                                if leg.isWalk {
                                    Label("\(max(1, Int(leg.duration / 60)))'", systemImage: "figure.walk")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                } else {
                                    TransitBadge(leg: leg)
                                }
                            }
                        }
                    }
                    Text(it.transfers == 0 ? "Nessun cambio" : (it.transfers == 1 ? "1 cambio" : "\(it.transfers) cambi"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { transit.next() } label: { Image(systemName: "chevron.right") }
                    .disabled(transit.itineraries.count < 2)
                    .font(.title3)
            }
        } else {
            Text(transit.message ?? "Nessun mezzo pubblico trovato.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func routeSummary(_ r: RouteOption) -> String {
        let text = "\(Geo.formatKm(r.distance)) · \(Geo.formatDuration(r.time))"
        return routeMode == .bike ? text + " (stima)" : text
    }

    private func selectMode(_ m: RouteMode) {
        routeMode = m
        guard let travel = m.travelMode, let start = planner.start, let dest = planner.destination else { return }
        if travel != planner.mode || planner.options.isEmpty {
            planner.plan(from: start, origin: planner.origin, to: dest, mode: travel, index: store.index)
        }
    }

    private func closeRoute() {
        planner.clear()
        transit.clear()
        place = nil
    }

    /// `from` nil = parti dalla posizione attuale.
    private func planRoute(to place: Place, from origin: Place? = nil, mode routeMode: TravelMode? = nil) {
        guard let start = origin?.coordinate ?? mapState.userLocation ?? tracker.currentLocation?.coordinate else {
            info = "Posizione attuale non disponibile."
            return
        }
        let travel = routeMode ?? mode
        self.routeMode = RouteMode(travel)
        planner.plan(from: start, origin: origin, to: place, mode: travel, index: store.index)
        planner.computeETAs(from: start, to: place.coordinate)
        transit.plan(from: start, to: place.coordinate)
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
                if args.contains("-transit") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 14) { selectMode(.transit) }
                }
                if args.contains("-navigate") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 12) { startNavigation() }
                }
            }
        }
        #endif
    }
}
