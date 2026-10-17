import XCTest
import CoreLocation
@testable import Percorso

final class TrackCleanerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// Punti in linea retta verso est, `step` metri ogni `dt` secondi.
    private func line(_ n: Int, step: Double = 5, dt: Double = 4) -> [TrackPoint] {
        (0..<n).map { i in
            TrackPoint(lat: 45.0, lon: 9.0 + Double(i) * step / 78_700, time: t0.addingTimeInterval(Double(i) * dt))
        }
    }

    func testSpikeIsRemoved() {
        var pts = line(10)
        // Riflesso del GPS: un punto 80 m a nord e subito ritorno.
        pts[5].lat += 80 / 111_000
        let out = TrackCleaner.removeSpikes(pts, maxSpeed: 4)
        XCTAssertEqual(out.count, 9)
        XCTAssertFalse(out.contains(pts[5]))
    }

    func testNormalWalkKeepsAllPoints() {
        let pts = line(10)
        XCTAssertEqual(TrackCleaner.removeSpikes(pts, maxSpeed: 4).count, 10)
    }

    func testSmoothReducesZigZag() {
        var pts = line(20)
        for i in pts.indices { pts[i].lat += (i % 2 == 0 ? 1 : -1) * 6 / 111_000 } // ±6 m
        let smooth = TrackCleaner.smooth(pts)
        XCTAssertEqual(smooth.count, pts.count)
        XCTAssertEqual(smooth.first, pts.first)
        XCTAssertEqual(smooth.last, pts.last)
        XCTAssertLessThan(Geo.length(of: smooth), Geo.length(of: pts) * 0.8)
    }

    func testSimplifyStraightLine() {
        let out = TrackCleaner.simplify(line(30))
        XCTAssertEqual(out.count, 2)
    }

    func testSimplifyKeepsCorner() {
        let east = line(10)
        let corner = east.last!
        let north = (1..<10).map { i in
            TrackPoint(lat: corner.lat + Double(i) * 5 / 111_000, lon: corner.lon,
                       time: corner.time.addingTimeInterval(Double(i) * 4))
        }
        let out = TrackCleaner.simplify(east + north)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[1], corner)
    }

    func testChunksShareEndpoints() {
        let pts = line(101) // 500 m
        let parts = TrackCleaner.chunks(pts, length: 250)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].last, parts[1].first)
        XCTAssertEqual(parts[0].first, pts.first)
        XCTAssertEqual(parts[1].last, pts.last)
    }

    func testRouteMatches() {
        let chunk = line(51) // 250 m
        let near = chunk.map { CLLocationCoordinate2D(latitude: $0.lat + 8 / 111_000, longitude: $0.lon) }
        XCTAssertTrue(TrackCleaner.routeMatches(near, chunk: chunk, tolerance: 25))
        let far = chunk.map { CLLocationCoordinate2D(latitude: $0.lat + 60 / 111_000, longitude: $0.lon) }
        XCTAssertFalse(TrackCleaner.routeMatches(far, chunk: chunk, tolerance: 25))
        // Percorso con un giro lungo: troppo più lungo del tratto registrato.
        let a = chunk.first!.coordinate, b = chunk.last!.coordinate
        let detour = [a, CLLocationCoordinate2D(latitude: a.latitude + 0.002, longitude: a.longitude),
                      CLLocationCoordinate2D(latitude: b.latitude + 0.002, longitude: b.longitude), b]
        XCTAssertFalse(TrackCleaner.routeMatches(detour, chunk: chunk, tolerance: 400))
    }

    func testProcessSnapsToRoad() async {
        var pts = line(51)
        for i in 1..<50 { pts[i].lat += (i % 2 == 0 ? 1 : -1) * 4 / 111_000 }
        // Strada finta: dritta, 2 m a nord.
        let out = await TrackCleaner.process(pts, mode: .foot, road: { a, b, _ in
            .route([CLLocationCoordinate2D(latitude: a.latitude + 2 / 111_000, longitude: a.longitude),
                    CLLocationCoordinate2D(latitude: b.latitude + 2 / 111_000, longitude: b.longitude)])
        }, pause: 0)
        XCTAssertNotNil(out)
        XCTAssertEqual(out?.first, pts.first)
        XCTAssertEqual(out?.last, pts.last)
        XCTAssertLessThan(Geo.length(of: out!), 262)
    }

    func testProcessWithoutNetworkReturnsNil() async {
        let out = await TrackCleaner.process(line(51), mode: .foot, road: { _, _, _ in .failed }, pause: 0)
        XCTAssertNil(out)
    }

    func testProcessKeepsChunkWhenNoRoute() async {
        let pts = line(51)
        let out = await TrackCleaner.process(pts, mode: .foot, road: { _, _, _ in .noRoute }, pause: 0)
        XCTAssertEqual(out, TrackCleaner.clean(pts, mode: .foot))
    }

    func testNeedsCleaning() {
        var trip = Trip(start: t0, points: line(5))
        XCTAssertTrue(TripStore.needsCleaning(trip))
        trip.cleanVersion = TrackCleaner.version
        XCTAssertFalse(TripStore.needsCleaning(trip))
    }

    func testOldTripsDecodeWithoutNewFields() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","start":0,"points":[]}"#
        let trip = try JSONDecoder().decode(Trip.self, from: Data(json.utf8))
        XCTAssertNil(trip.rawPoints)
        XCTAssertNil(trip.cleanVersion)
    }
}
