import ActivityKit
import Foundation

/// Live Activity del parcheggio: conto alla rovescia del ticket o del disco orario.
/// Il file è condiviso tra l'app e l'estensione che disegna la Live Activity.
struct ParkingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Scadenza del ticket.
        var expiry: Date
        /// Minuti di preavviso (per mostrare l'ora dell'avviso).
        var reminderMinutes: Int
        var address: String
        var note: String?
    }

    var parkedAt: Date
}

extension ParkingActivityAttributes.ContentState {
    var warningDate: Date { expiry.addingTimeInterval(-Double(reminderMinutes) * 60) }
}
