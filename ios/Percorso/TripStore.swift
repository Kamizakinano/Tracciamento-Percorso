import Foundation

/// Viaggi salvati, memorizzati in Documents/trips.json
/// (visibile anche dall'app File grazie a UIFileSharingEnabled).
final class TripStore: ObservableObject {
    @Published private(set) var trips: [Trip] = []
    /// Cambia a ogni modifica: la mappa lo usa per ridisegnare lo storico.
    @Published private(set) var version = 0
    private(set) var index = SpatialIndex()

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private let fileURL = TripStore.documents.appendingPathComponent("trips.json")

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Trip].self, from: data) {
            trips = saved
        }
        rebuildIndex()
    }

    func add(_ trip: Trip) {
        trips.append(trip)
        changed()
    }

    func add(contentsOf newTrips: [Trip]) {
        trips.append(contentsOf: newTrips)
        changed()
    }

    func delete(ids: Set<UUID>) {
        trips.removeAll { ids.contains($0.id) }
        changed()
    }

    private func changed() {
        rebuildIndex()
        version += 1
        do {
            try JSONEncoder().encode(trips).write(to: fileURL, options: .atomic)
        } catch {
            print("Salvataggio viaggi non riuscito: \(error)")
        }
    }

    private func rebuildIndex() {
        var idx = SpatialIndex()
        for t in trips { idx.add(t.points) }
        index = idx
    }
}
