import Foundation
import CoreLocation
import UIKit
import UserNotifications

/// Registra il viaggio in corso, anche con l'app in background o lo schermo spento.
final class LocationTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var points: [TrackPoint] = []
    @Published private(set) var distance = 0.0
    @Published private(set) var newRoadMeters = 0.0
    @Published private(set) var onOldRoad = false
    @Published var showDeniedAlert = false

    private let manager = CLLocationManager()
    private let store: TripStore
    private var tripStart = Date()
    private var pendingStart = false
    private var unsavedPoints = 0
    private var lastNotification = Date.distantPast

    private let maxAccuracy = 50.0  // scarta letture GPS imprecise
    private let minStep = 5.0       // ignora il rumore GPS da fermi
    private let currentURL = TripStore.documents.appendingPathComponent("current.json")

    private struct CurrentTrip: Codable {
        var start: Date
        var points: [TrackPoint]
    }

    var alertsEnabled: Bool { UserDefaults.standard.object(forKey: "alertEnabled") as? Bool ?? true }
    var threshold: Double {
        let v = UserDefaults.standard.double(forKey: "threshold")
        return v > 0 ? v : 25
    }

    init(store: TripStore) {
        self.store = store
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = minStep
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(persistCurrent), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(persistCurrent), name: UIApplication.willTerminateNotification, object: nil)

        // Se l'app era stata chiusa durante un viaggio, riprendi la registrazione.
        if let data = try? Data(contentsOf: currentURL),
           let saved = try? JSONDecoder().decode(CurrentTrip.self, from: data) {
            tripStart = saved.start
            points = saved.points
            distance = Geo.length(of: saved.points)
            start()
        }
    }

    // MARK: - Comandi

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            pendingStart = true
            manager.requestWhenInUseAuthorization()
            return
        case .denied, .restricted:
            showDeniedAlert = true
            return
        default:
            break
        }

        if !ProcessInfo.processInfo.arguments.contains("-screenshots") {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        if points.isEmpty {
            tripStart = Date()
            distance = 0
            newRoadMeters = 0
        }
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        isRecording = true
        persistCurrent()
    }

    /// Ferma la registrazione; se `keep` è vero il viaggio viene salvato.
    func stop(name: String?, keep: Bool) {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        isRecording = false

        if keep && points.count > 1 {
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            store.add(Trip(name: (trimmed?.isEmpty ?? true) ? nil : trimmed,
                           start: tripStart, end: Date(), points: points))
        }
        points = []
        distance = 0
        newRoadMeters = 0
        onOldRoad = false
        try? FileManager.default.removeItem(at: currentURL)
    }

    @objc func persistCurrent() {
        guard isRecording else { return }
        unsavedPoints = 0
        let current = CurrentTrip(start: tripStart, points: points)
        try? JSONEncoder().encode(current).write(to: currentURL, options: .atomic)
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if pendingStart {
                pendingStart = false
                start()
            }
        case .denied, .restricted:
            if pendingStart || isRecording {
                pendingStart = false
                showDeniedAlert = true
            }
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isRecording else { return }
        for loc in locations {
            guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= maxAccuracy,
                  loc.timestamp.timeIntervalSinceNow > -30 else { continue }
            let p = TrackPoint(loc)
            let near = store.index.isNear(p, within: threshold)
            if let last = points.last {
                let step = Geo.distance(last, p)
                guard step >= minStep else { continue }
                distance += step
                if !near { newRoadMeters += step }
            }
            setOldRoad(near)
            points.append(p)
            unsavedPoints += 1
        }
        if unsavedPoints >= 20 { persistCurrent() }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown è temporaneo: il GPS riproverà da solo.
    }

    // MARK: - Avviso strada già percorsa

    private func setOldRoad(_ near: Bool) {
        if near && !onOldRoad && alertsEnabled { warn() }
        onOldRoad = near
    }

    private func warn() {
        if UIApplication.shared.applicationState == .active {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        // In background: notifica locale, al massimo una al minuto.
        guard Date().timeIntervalSince(lastNotification) > 60 else { return }
        lastNotification = Date()
        let content = UNMutableNotificationContent()
        content.title = "Strada già percorsa"
        content.body = "Stai passando su una strada che hai già fatto."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "old-road", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
