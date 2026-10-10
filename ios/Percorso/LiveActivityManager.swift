import ActivityKit
import Foundation

/// Avvia, aggiorna e chiude la Live Activity sul blocco schermo.
/// iOS permette di avviarla solo con l'app in primo piano; gli aggiornamenti
/// funzionano anche in background.
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var activity: Activity<TripActivityAttributes>?
    private var lastState: TripActivityAttributes.ContentState?
    private var lastUpdate = Date.distantPast

    var isRunning: Bool { activity != nil }

    func start(startDate: Date, automatic: Bool, state: TripActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if activity != nil { return }
        // Chiudi eventuali Live Activity rimaste da un avvio precedente.
        for old in Activity<TripActivityAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        activity = try? Activity.request(attributes: TripActivityAttributes(startDate: startDate, automatic: automatic),
                                         content: ActivityContent(state: state, staleDate: nil),
                                         pushType: nil)
        lastState = state
        lastUpdate = Date()
    }

    /// Aggiorna al massimo ogni 10 secondi, subito se cambia l'avviso.
    func update(_ state: TripActivityAttributes.ContentState) {
        guard let activity, state != lastState else { return }
        let urgent = state.onOldRoad != lastState?.onOldRoad
        guard urgent || Date().timeIntervalSince(lastUpdate) >= 10 else { return }
        lastState = state
        lastUpdate = Date()
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
