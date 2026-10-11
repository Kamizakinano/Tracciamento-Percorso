import XCTest
@testable import Percorso

/// Pausa del GPS quando sei fermo (risparmio batteria).
final class RestDetectorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func point(_ meters: Double, _ seconds: Double) -> TrackPoint {
        TrackPoint(lat: 45.0 + meters / 111_195, lon: 9.0, time: t0.addingTimeInterval(seconds))
    }

    func testStillForFiveMinutesIsRest() {
        var d = RestDetector()
        XCTAssertFalse(d.isResting(now: t0), "nessuna posizione ancora")
        d.feed(point(0, 0))
        // Il GPS in casa "balla" di 10-30 m: non è movimento.
        d.feed(point(15, 60))
        d.feed(point(-20, 120))
        XCTAssertFalse(d.isResting(now: t0.addingTimeInterval(290)))
        XCTAssertTrue(d.isResting(now: t0.addingTimeInterval(305)))
        XCTAssertEqual(d.anchor?.lat ?? 0, 45.0, accuracy: 1e-9, "il punto di sosta resta il primo")
    }

    func testMovingIsNotRest() {
        var d = RestDetector()
        for i in 0...20 { d.feed(point(Double(i) * 50, Double(i) * 30)) } // a piedi, 50 m ogni 30 s
        XCTAssertFalse(d.isResting(now: t0.addingTimeInterval(600 + 200)))
        XCTAssertTrue(d.isResting(now: t0.addingTimeInterval(600 + 300)), "fermo dopo l'ultimo spostamento")
    }

    func testResetForgetsAnchor() {
        var d = RestDetector()
        d.feed(point(0, 0))
        d.reset()
        XCTAssertNil(d.anchor)
        XCTAssertFalse(d.isResting(now: t0.addingTimeInterval(3600)))
    }
}
