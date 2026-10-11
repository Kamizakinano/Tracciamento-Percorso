import XCTest
@testable import Percorso

/// Mezzo di un viaggio ricavato dalle velocità.
final class TravelModeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// Tratti a velocità costante: (metri al secondo, secondi).
    private func trip(_ parts: [(Double, Double)]) -> [TrackPoint] {
        var pts = [TrackPoint(lat: 45, lon: 9, time: t0)]
        var x = 0.0, t = 0.0
        for (speed, seconds) in parts {
            for _ in 0..<Int(seconds / 2) {
                x += speed * 2; t += 2
                pts.append(TrackPoint(lat: 45 + x / 111_195, lon: 9, time: t0.addingTimeInterval(t)))
            }
        }
        return pts
    }

    func testCityDriveWithStopsAndWalkIsCar() {
        // Il caso del viaggio da 1,95 km: guida lenta, semafori e poi a piedi dal parcheggio.
        let points = trip([(11, 60), (0, 40), (5, 60), (13, 45), (0, 60), (1.3, 240)])
        let avg = Geo.length(of: points) / points.last!.time.timeIntervalSince(points.first!.time)
        XCTAssertEqual(TravelMode.infer(speed: avg), .bike, "con la vecchia regola risultava bici")
        XCTAssertEqual(TravelMode.infer(points: points), .car)
    }

    func testBikeAndWalk() {
        XCTAssertEqual(TravelMode.infer(points: trip([(4.5, 600), (0, 60), (5, 300)])), .bike)
        XCTAssertEqual(TravelMode.infer(points: trip([(1.4, 900)])), .foot)
        // Breve discesa veloce in bici: resta bici.
        XCTAssertEqual(TravelMode.infer(points: trip([(4.5, 900), (9, 40)])), .bike)
    }

    func testTooShortIsUnknown() {
        XCTAssertNil(TravelMode.infer(points: trip([(1, 20)])))
        XCTAssertNil(TravelMode.infer(points: []))
    }

    func testSavedAutomaticTripsAreReinferredOnce() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let points = trip([(11, 60), (0, 40), (5, 60), (13, 45), (0, 60), (1.3, 240)])
        var trips = [Trip(start: t0, points: points, mode: .bike, automatic: true),
                     Trip(start: t0, points: points, mode: .bike, automatic: false)]
        TripStore.reinferModes(&trips, defaults: defaults)
        XCTAssertEqual(trips[0].mode, .car)
        XCTAssertEqual(trips[1].mode, .bike, "i viaggi manuali restano come sono")
        trips[0].mode = .bike // correzione a mano: non viene più toccata
        TripStore.reinferModes(&trips, defaults: defaults)
        XCTAssertEqual(trips[0].mode, .bike)
    }
}
