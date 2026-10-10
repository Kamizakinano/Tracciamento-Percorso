import SwiftUI

/// Statistiche calcolate sui viaggi salvati.
struct TripStats: Equatable {
    struct ModeTotal: Equatable { let mode: TravelMode; let distance: Double; let trips: Int }
    struct PlaceTotal: Equatable { let name: String; let distance: Double }

    var trips = 0
    var distance = 0.0
    var duration: TimeInterval = 0
    /// Km percorsi su strade mai fatte prima (in ordine di tempo).
    var newDistance = 0.0
    var byMode: [ModeTotal] = []
    var topPlaces: [PlaceTotal] = []
    var longest: Trip?

    var newPercent: Int { distance > 0 ? Int((newDistance / distance * 100).rounded()) : 0 }

    static func compute(_ all: [Trip], since: Date?) -> TripStats {
        var s = TripStats()
        var index = SpatialIndex()
        var modes: [TravelMode: (Double, Int)] = [:]
        var places: [String: Double] = [:]
        for trip in all.sorted(by: { $0.start < $1.start }) {
            defer { index.add(trip.points) }
            guard since.map({ trip.start >= $0 }) ?? true else { continue }
            let d = trip.distance
            s.trips += 1
            s.distance += d
            s.duration += trip.duration
            // Tratti lontani da tutti i viaggi precedenti = strade nuove.
            for i in 1..<max(1, trip.points.count) {
                let a = trip.points[i - 1], b = trip.points[i]
                let mid = TrackPoint(lat: (a.lat + b.lat) / 2, lon: (a.lon + b.lon) / 2, time: b.time)
                if !index.isNear(mid, within: 20) { s.newDistance += Geo.distance(a, b) }
            }
            let m = trip.effectiveMode
            modes[m, default: (0, 0)].0 += d
            modes[m, default: (0, 0)].1 += 1
            if let place = trip.locality, !place.isEmpty { places[place, default: 0] += d }
            if d > (s.longest?.distance ?? 0) { s.longest = trip }
        }
        s.byMode = TravelMode.allCases.compactMap { m in
            modes[m].map { ModeTotal(mode: m, distance: $0.0, trips: $0.1) }
        }
        s.topPlaces = places.sorted { $0.value > $1.value }.prefix(5).map { PlaceTotal(name: $0.key, distance: $0.value) }
        return s
    }
}

struct StatsView: View {
    @EnvironmentObject private var store: TripStore
    @Environment(\.dismiss) private var dismiss

    enum Period: String, CaseIterable, Identifiable {
        case week = "Settimana", month = "Mese", year = "Anno", all = "Sempre"
        var id: String { rawValue }

        var since: Date? {
            let cal = Calendar.current
            switch self {
            case .week: return cal.date(byAdding: .day, value: -7, to: Date())
            case .month: return cal.date(byAdding: .month, value: -1, to: Date())
            case .year: return cal.date(byAdding: .year, value: -1, to: Date())
            case .all: return nil
            }
        }
    }

    @State private var period: Period = .all
    @State private var stats: TripStats?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Periodo", selection: $period) {
                        ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                if let s = stats {
                    if s.trips == 0 {
                        Text("Nessun viaggio in questo periodo.").foregroundStyle(.secondary)
                    } else {
                        Section("Totale") {
                            row("Viaggi", "\(s.trips)", icon: "point.topleft.down.curvedto.point.bottomright.up")
                            row("Distanza", Geo.formatKm(s.distance), icon: "ruler")
                            row("Tempo in movimento", Geo.formatDuration(s.duration), icon: "clock")
                            row("Su strade nuove", "\(Geo.formatKm(s.newDistance)) (\(s.newPercent)%)", icon: "sparkles")
                            if let longest = s.longest {
                                row("Viaggio più lungo", "\(longest.title) · \(Geo.formatKm(longest.distance))", icon: "trophy")
                            }
                        }
                        Section("Per mezzo") {
                            ForEach(s.byMode, id: \.mode) { m in
                                row(m.mode.label, "\(Geo.formatKm(m.distance)) · \(m.trips) viaggi", icon: m.mode.icon)
                            }
                        }
                        if !s.topPlaces.isEmpty {
                            Section("Zone più esplorate") {
                                ForEach(Array(s.topPlaces.enumerated()), id: \.offset) { i, p in
                                    row("\(i + 1). \(p.name)", Geo.formatKm(p.distance), icon: "mappin.and.ellipse")
                                }
                            }
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Statistiche")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
            .task(id: "\(period.rawValue)-\(store.trips.count)") {
                let trips = store.trips
                let since = period.since
                stats = await Task.detached(priority: .userInitiated) {
                    TripStats.compute(trips, since: since)
                }.value
            }
        }
    }

    private func row(_ title: String, _ value: String, icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
