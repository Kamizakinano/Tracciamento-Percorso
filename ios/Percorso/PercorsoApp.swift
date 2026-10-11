import SwiftUI
import UserNotifications

@main
struct PercorsoApp: App {
    @StateObject private var store: TripStore
    @StateObject private var tracker: LocationTracker
    @StateObject private var navigation: NavigationSession
    @StateObject private var parking: ParkingStore

    init() {
        let store = TripStore()
        let tracker = LocationTracker(store: store)
        let navigation = NavigationSession(store: store)
        let parking = ParkingStore()
        // La navigazione segue le posizioni della registrazione (anche in background).
        tracker.onLocation = { [weak tracker] location in
            navigation.update(location)
            tracker?.navigationInfo = navigation.isActive
                ? (navigation.instruction, navigation.distanceToManeuver, navigation.maneuverIcon)
                : nil
        }
        // Parcheggio rilevato dalla velocità (auto → piedi, fine di un viaggio in auto).
        tracker.onParking = { event in
            switch event {
            case let .parked(point, left):
                parking.park(at: point.coordinate, date: point.time, source: .speed, alreadyLeft: left)
            case let .departed(point):
                parking.departed(from: point.coordinate)
            case let .cancelled(point):
                parking.cancelAutomatic(at: point.time)
            }
        }
        // Scollegato dall'auto (Bluetooth o CarPlay): parcheggiato qui.
        let monitor = CarAudioMonitor.shared
        monitor.onDisconnect = { [weak tracker] in
            tracker?.freshLocation { loc in
                parking.park(at: loc.coordinate, date: Date(), source: .bluetooth)
            }
        }
        monitor.onConnect = { parking.retrieve() }
        UNUserNotificationCenter.current().delegate = NotificationHandler.shared
        _store = StateObject(wrappedValue: store)
        _tracker = StateObject(wrappedValue: tracker)
        _navigation = StateObject(wrappedValue: navigation)
        _parking = StateObject(wrappedValue: parking)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(tracker)
                .environmentObject(navigation)
                .environmentObject(parking)
        }
    }
}
