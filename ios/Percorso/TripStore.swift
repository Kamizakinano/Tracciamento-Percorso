import Foundation
import CoreLocation

/// Viaggi salvati, memorizzati in Documents/trips.json
/// (visibile anche dall'app File grazie a UIFileSharingEnabled).
final class TripStore: ObservableObject {
    @Published private(set) var trips: [Trip] = []
    /// Strade già percorse (solo i viaggi che rientrano nel filtro), divise per frequenza.
    @Published private(set) var lines = HistoryLines()
    /// Cambia ogni volta che `lines` viene ricalcolato: la mappa lo usa per ridisegnare.
    @Published private(set) var version = 0
    private(set) var index = SpatialIndex()
    private(set) var filter = Settings.filter

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private let fileURL = TripStore.documents.appendingPathComponent("trips.json")
    private let queue = DispatchQueue(label: "percorso.index", qos: .userInitiated)
    private var rebuildToken = 0
    private var geocoding = false

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Trip].self, from: data) {
            trips = saved
        }
        // Indice subito disponibile (serve agli avvisi anche se l'app parte in background).
        index = Self.makeIndex(trips.filter { filter.includes($0) })
        rebuild()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.geocodeMissing() }
    }

    // MARK: - Modifiche

    func add(_ trip: Trip) {
        trips.append(trip)
        changed()
        geocodeMissing()
    }

    func add(contentsOf newTrips: [Trip]) {
        let existing = Set(trips.map(\.id))
        trips.append(contentsOf: newTrips.filter { !existing.contains($0.id) })
        trips.sort { $0.start < $1.start }
        changed()
        geocodeMissing()
    }

    func delete(ids: Set<UUID>) {
        trips.removeAll { ids.contains($0.id) }
        changed()
    }

    func setFilter(_ newFilter: TripFilter) {
        guard newFilter != filter else { return }
        filter = newFilter
        rebuild()
    }

    private func changed() {
        save()
        rebuild()
        BackupManager.shared.scheduleBackup(trips)
    }

    private func save() {
        do {
            try JSONEncoder().encode(trips).write(to: fileURL, options: .atomic)
        } catch {
            print("Salvataggio viaggi non riuscito: \(error)")
        }
    }

    // MARK: - Indice e colori (in background)

    static func makeIndex(_ trips: [Trip]) -> SpatialIndex {
        var idx = SpatialIndex()
        for t in trips { idx.add(t.points) }
        return idx
    }

    private func rebuild() {
        rebuildToken += 1
        let token = rebuildToken
        let selected = trips.filter { filter.includes($0) }
        queue.async { [weak self] in
            let idx = Self.makeIndex(selected)
            let lines = HistoryLines.build(trips: selected, index: idx)
            DispatchQueue.main.async {
                guard let self, token == self.rebuildToken else { return }
                self.index = idx
                self.lines = lines
                self.version += 1
            }
        }
    }

    // MARK: - Città dei viaggi (per le statistiche)

    func geocodeMissing() {
        guard !geocoding, trips.contains(where: { $0.locality == nil && $0.points.count > 1 }) else { return }
        geocoding = true
        Task { @MainActor in
            let geocoder = CLGeocoder()
            var updated = false
            let pending = trips.filter { $0.locality == nil && $0.points.count > 1 }
            for trip in pending {
                let mid = trip.points[trip.points.count / 2]
                let placemark: CLPlacemark?
                do {
                    placemark = try await geocoder.reverseGeocodeLocation(CLLocation(latitude: mid.lat, longitude: mid.lon)).first
                } catch {
                    break // niente rete o troppe richieste: si riprova al prossimo avvio
                }
                // I viaggi possono essere cambiati durante l'attesa: cerca di nuovo per id.
                guard let i = trips.firstIndex(where: { $0.id == trip.id }) else { continue }
                // Stringa vuota = provato senza risultato, per non ritentare all'infinito.
                trips[i].locality = placemark?.locality ?? placemark?.subAdministrativeArea ?? ""
                updated = true
                try? await Task.sleep(nanoseconds: 1_500_000_000) // limite di Apple sulle richieste
            }
            if updated { save() }
            geocoding = false
        }
    }
}
