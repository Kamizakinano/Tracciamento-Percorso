import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: TripStore
    @EnvironmentObject private var tracker: LocationTracker
    @AppStorage("showHistory") private var showHistory = true
    @AppStorage("alertEnabled") private var alertEnabled = true

    @State private var follow = true
    @State private var focus: Trip?
    @State private var showTrips = false
    @State private var askName = false
    @State private var tripName = ""

    var body: some View {
        ZStack {
            MapView(trips: store.trips,
                    historyVersion: store.version,
                    showHistory: showHistory,
                    currentPoints: tracker.points,
                    follow: $follow,
                    focus: $focus)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                stats
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
        .onAppear { follow = store.trips.isEmpty || tracker.isRecording }
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

    private func roundButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 52, height: 52)
                .background(.regularMaterial, in: Circle())
        }
    }
}
