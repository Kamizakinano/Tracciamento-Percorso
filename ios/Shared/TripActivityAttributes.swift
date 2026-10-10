import ActivityKit
import Foundation

/// Dati della Live Activity mostrata sul blocco schermo durante la registrazione.
/// Il file è condiviso tra l'app e l'estensione che disegna la Live Activity.
struct TripActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var distance: Double
        var newPercent: Int?
        var onOldRoad: Bool
        var modeIcon: String
    }

    var startDate: Date
    var automatic: Bool
}

extension TripActivityAttributes.ContentState {
    var distanceText: String {
        (distance / 1000).formatted(.number.precision(.fractionLength(distance < 100_000 ? 2 : 0))) + " km"
    }
}
