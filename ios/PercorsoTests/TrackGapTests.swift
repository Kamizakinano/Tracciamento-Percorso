import XCTest
import CoreLocation
@testable import Percorso

/// Buchi nel tracciato quando iOS sospende il GPS durante la guida.
final class TrackGapTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func point(_ meters: Double, _ seconds: Double) -> TrackPoint {
        TrackPoint(lat: 45.0 + meters / 111_195, lon: 9.0, time: t0.addingTimeInterval(seconds))
    }

    func testGapWhileDrivingIsBridged() {
        // 5 km in 5 minuti (60 km/h): GPS sospeso al semaforo e riattivato più avanti.
        XCTAssertTrue(LocationTracker.isBridgeableGap(last: point(0, 0), next: point(5000, 300)))
        // Galleria di 800 m a 80 km/h.
        XCTAssertTrue(LocationTracker.isBridgeableGap(last: point(0, 0), next: point(800, 36)))
        // Anche a piedi veloce o in bici (oltre 7 km/h).
        XCTAssertTrue(LocationTracker.isBridgeableGap(last: point(0, 0), next: point(600, 200)))
    }

    func testRealStopsAreNotBridged() {
        // Fermo un'ora e poi 2 km: sono due viaggi.
        XCTAssertFalse(LocationTracker.isBridgeableGap(last: point(0, 0), next: point(2000, 3600)))
        // Passo normale tra due punti GPS.
        XCTAssertFalse(LocationTracker.isBridgeableGap(last: point(0, 0), next: point(30, 1)))
        // Troppo veloce (aereo) o troppo lontano.
        XCTAssertFalse(LocationTracker.isBridgeableGap(last: point(0, 0), next: point(50_000, 150)))
        XCTAssertFalse(LocationTracker.isBridgeableGap(last: point(0, 0), next: point(80_000, 3000)))
        // Giorno diverso: resta la divisione a mezzanotte.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let night = TrackPoint(lat: 45, lon: 9, time: cal.date(from: DateComponents(year: 2026, month: 5, day: 1, hour: 23, minute: 58))!)
        let after = TrackPoint(lat: 45 + 2000 / 111_195.0, lon: 9, time: night.time.addingTimeInterval(240))
        XCTAssertFalse(LocationTracker.isBridgeableGap(last: night, next: after, calendar: cal))
    }

    func testBridgePointsFollowRoadWithInterpolatedTimes() {
        let a = point(0, 0), b = point(1000, 100)
        // Strada a "L": prima verso est, poi verso nord.
        let path = [a.coordinate,
                    CLLocationCoordinate2D(latitude: 45.0, longitude: 9.003),
                    CLLocationCoordinate2D(latitude: 45.0 + 500 / 111_195, longitude: 9.003),
                    b.coordinate]
        let added = LocationTracker.bridgePoints(path, from: a, to: b)
        XCTAssertEqual(added.count, 2, "gli estremi coincidono con i punti registrati e non si ripetono")
        XCTAssertEqual(added[0].lon, 9.003, accuracy: 1e-9)
        XCTAssertTrue(a.time < added[0].time && added[0].time < added[1].time && added[1].time < b.time)
        XCTAssertTrue(LocationTracker.isPlausibleBridge(path, from: a, to: b))
    }

    func testDetourTooLongIsRejected() {
        let a = point(0, 0), b = point(1000, 100)
        let far = CLLocationCoordinate2D(latitude: 45.1, longitude: 9.1) // giro di oltre 20 km
        XCTAssertFalse(LocationTracker.isPlausibleBridge([a.coordinate, far, b.coordinate], from: a, to: b))
        XCTAssertFalse(LocationTracker.isPlausibleBridge([a.coordinate], from: a, to: b))
    }

    func testFalseParkingAtTrafficLightIsCancelled() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ParkingStore(directory: dir, systemServices: false)
        let home = store.park(at: point(0, 0).coordinate, date: t0, source: .manual)
        // GPS sospeso al semaforo: sembra un parcheggio...
        let light = point(9000, 3600)
        store.park(at: light.coordinate, date: light.time, source: .speed)
        XCTAssertNotEqual(store.current?.id, home?.id)
        // ...ma riparti subito: annullato, l'auto torna dov'era.
        store.cancelAutomatic(at: light.time)
        XCTAssertEqual(store.spots.count, 1)
        XCTAssertEqual(store.current?.id, home?.id)
    }
}
