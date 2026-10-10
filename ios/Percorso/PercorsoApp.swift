import SwiftUI

@main
struct PercorsoApp: App {
    @StateObject private var store: TripStore
    @StateObject private var tracker: LocationTracker
    @StateObject private var navigation: NavigationSession

    init() {
        let store = TripStore()
        let tracker = LocationTracker(store: store)
        let navigation = NavigationSession(store: store)
        // La navigazione segue le posizioni della registrazione (anche in background).
        tracker.onLocation = { [weak tracker] location in
            navigation.update(location)
            tracker?.navigationInfo = navigation.isActive
                ? (navigation.instruction, navigation.distanceToManeuver, navigation.maneuverIcon)
                : nil
        }
        _store = StateObject(wrappedValue: store)
        _tracker = StateObject(wrappedValue: tracker)
        _navigation = StateObject(wrappedValue: navigation)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(tracker)
                .environmentObject(navigation)
        }
    }
}
