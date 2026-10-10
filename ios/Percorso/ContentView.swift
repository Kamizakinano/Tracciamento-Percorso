import SwiftUI
import MapKit

struct ContentView: View {
    @EnvironmentObject private var store: TripStore
    @EnvironmentObject private var tracker: LocationTracker
    @AppStorage("showHistory") private var showHistory = true
    @AppStorage("alertEnabled") private var alertEnabled = true
    @AppStorage("mapStyle") private var mapStyle = 0

    @State private var follow = true
    @State private var focus: Trip?
    @State private var showTrips = false
    @State private var askName = false
    @State private var tripName = ""
    @State private var showSearch = false
    @State private var place: Place?
    @State private var searchQuery = ""

    var body: some View {
        ZStack {
            MapView(trips: store.trips,
                    historyVersion: store.version,
                    showHistory: showHistory,
                    currentPoints: tracker.points,
                    mapType: mapType,
                    place: place,
                    follow: $follow,
                    focus: $focus)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                stats
                HStack(alignment: .top) {
                    if let place { placeChip(place) }
                    Spacer()
                    VStack(spacing: 10) {
                        roundButton("magnifyingglass") { showSearch = true }
                        mapStyleMenu
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
                controls
            }
            .padding()
            .animation(.easeInOut(duration: 0.2), value: tracker.onOldRoad)
        }
        .onAppear {
            follow = store.trips.isEmpty || tracker.isRecording
            #if DEBUG
            // Parametri di avvio usati per gli screenshot automatici (ios/scripts/screenshots.sh).
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-showTrips") { showTrips = true }
            if let i = args.firstIndex(of: "-search"), i + 1 < args.count {
                searchQuery = args[i + 1]
                showSearch = true
            }
            #endif
        }
        .sheet(isPresented: $showSearch) {
            SearchView(onSelect: { place = $0 }, initialQuery: searchQuery)
        }
        .sheet(isPresented: $showTrips) {
            TripsView(focus: $focus)
                .environmentObject(store)
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
            Text("Consenti l'accesso alla posizione per registrare i viaggi.")
        }
    }

    private var stats: some View {
        HStack(spacing: 14) {
            Label(tracker.isRecording ? "Registrazione" : "Fermo",
                  systemImage: tracker.isRecording ? "record.circle" : "pause.circle")
                .foregroundStyle(tracker.isRecording ? .red : .secondary)
            Text(Geo.formatKm(tracker.distance))
            Text("Nuove: \(newPercent)")
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
    }

    private var newPercent: String {
        guard tracker.distance > 0 else { return "–" }
        return "\(Int((tracker.newRoadMeters / tracker.distance * 100).rounded()))%"
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                if tracker.isRecording {
                    tripName = ""
                    askName = true
                } else {
                    follow = true
                    tracker.start()
                }
            } label: {
                Label(tracker.isRecording ? "Ferma" : "Avvia",
                      systemImage: tracker.isRecording ? "stop.fill" : "play.fill")
                    .font(.headline)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                    .foregroundStyle(.white)
                    .background(tracker.isRecording ? Color.red : Color.blue, in: Capsule())
            }

            roundButton("location.fill") { follow = true }
            roundButton("list.bullet") { showTrips = true }
        }
        .shadow(radius: 4)
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

    private func placeChip(_ place: Place) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "mappin.circle.fill").foregroundStyle(.red)
            Text(place.name).lineLimit(1)
            Button {
                self.place = nil
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

    private func roundButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { circleIcon(icon) }
    }

    private func circleIcon(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.title3)
            .frame(width: 52, height: 52)
            .background(.regularMaterial, in: Circle())
    }
}
