import SwiftUI

@main
struct PercorsoApp: App {
    @StateObject private var store: TripStore
    @StateObject private var tracker: LocationTracker

    init() {
        let store = TripStore()
        _store = StateObject(wrappedValue: store)
        _tracker = StateObject(wrappedValue: LocationTracker(store: store))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(tracker)
        }
    }
}
