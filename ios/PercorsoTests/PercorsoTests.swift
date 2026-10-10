import XCTest
import CoreLocation
@testable import Percorso

final class PercorsoTests: XCTestCase {
    private func point(_ lat: Double, _ lon: Double) -> TrackPoint {
        TrackPoint(lat: lat, lon: lon, time: Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// Strada rettilinea verso est, lunga ~1,1 km, con punti ogni ~110 m.
    private var road: [TrackPoint] {
        (0...10).map { point(45.0, 9.0 + Double($0) * 0.0014) }
    }

    func testDistance() {
        // 0,001° di latitudine ≈ 111 m
        XCTAssertEqual(Geo.distance(point(45.0, 9.0), point(45.001, 9.0)), 111.2, accuracy: 0.5)
        XCTAssertEqual(Geo.length(of: road), 1101, accuracy: 10)
        XCTAssertEqual(Geo.length(of: [point(45, 9)]), 0)
    }

    func testIndexRecognisesTravelledRoad() {
        var index = SpatialIndex()
        index.add(road)

        // Sulla strada, anche a metà tra due punti registrati (grazie all'interpolazione).
        XCTAssertTrue(index.isNear(point(45.0, 9.0007), within: 15))
        // 10 m a lato della strada.
        XCTAssertTrue(index.isNear(point(45.00009, 9.005), within: 15))
        // 100 m a lato: strada diversa.
        XCTAssertFalse(index.isNear(point(45.0009, 9.005), within: 25))
        // Molto lontano.
        XCTAssertFalse(index.isNear(point(46.0, 10.0), within: 40))
    }

    func testEmptyIndex() {
        XCTAssertFalse(SpatialIndex().isNear(point(45, 9), within: 40))
    }

    func testGPXRoundTrip() throws {
        let trip = Trip(name: "Giro & lago <test>", start: road[0].time, end: road[10].time, points: road)
        let xml = GPX.export([trip])
        let parsed = GPX.parse(try XCTUnwrap(xml.data(using: .utf8)))

        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].name, "Giro & lago <test>")
        XCTAssertEqual(parsed[0].points.count, road.count)
        XCTAssertEqual(parsed[0].points[5].lat, road[5].lat, accuracy: 1e-9)
        XCTAssertEqual(parsed[0].points[5].lon, road[5].lon, accuracy: 1e-9)
        XCTAssertEqual(parsed[0].points[5].time, road[5].time)
    }

    func testGPXImportFromOtherApps() throws {
        let xml = """
        <?xml version="1.0"?>
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>Esportazione</name></metadata>
          <trk><name>Uscita in bici</name><trkseg>
            <trkpt lat="45.0" lon="9.0"><ele>120</ele><time>2026-05-01T08:00:00.500Z</time></trkpt>
            <trkpt lat="45.001" lon="9.001"><time>2026-05-01T08:01:00Z</time></trkpt>
          </trkseg></trk>
          <rte><rtept lat="44.0" lon="8.0"/><rtept lat="44.01" lon="8.01"/></rte>
          <trk><trkseg><trkpt lat="1" lon="1"/></trkseg></trk>
        </gpx>
        """
        let parsed = GPX.parse(try XCTUnwrap(xml.data(using: .utf8)))

        XCTAssertEqual(parsed.count, 2, "la traccia con un solo punto va scartata")
        XCTAssertEqual(parsed[0].name, "Uscita in bici")
        XCTAssertEqual(parsed[0].points.count, 2)
        XCTAssertEqual(parsed[1].points.count, 2)
    }

    func testInvalidGPX() {
        XCTAssertTrue(GPX.parse(Data("non è un gpx".utf8)).isEmpty)
    }

    // MARK: - Frequenza di passaggio

    func testVisitsCountDistinctTrips() {
        var index = SpatialIndex()
        index.add(road)
        index.add(road)
        index.add(road.map { point($0.lat + 0.002, $0.lon) }) // strada parallela a ~220 m
        XCTAssertEqual(index.visits(near: CLLocationCoordinate2D(latitude: 45.0, longitude: 9.007), within: 15), 2)
        XCTAssertEqual(index.visits(near: CLLocationCoordinate2D(latitude: 45.002, longitude: 9.007), within: 15), 1)
        XCTAssertEqual(index.visits(near: CLLocationCoordinate2D(latitude: 45.001, longitude: 9.007), within: 15), 0)
    }

    func testHistoryLinesLevels() {
        let once = Trip(start: Date(), points: road.map { point($0.lat + 0.002, $0.lon) })
        let repeated = (0..<4).map { _ in Trip(start: Date(), points: road) }
        let trips = [once] + repeated
        let index = TripStore.makeIndex(trips)
        let lines = HistoryLines.build(trips: trips, index: index)
        XCTAssertEqual(lines.levels[0].count, 1, "strada fatta una volta: gialla")
        XCTAssertEqual(lines.levels[1].count, 0)
        XCTAssertEqual(lines.levels[2].count, 4, "strada fatta 4 volte: rossa")
        XCTAssertEqual(HistoryLines.level(forVisits: 1), 0)
        XCTAssertEqual(HistoryLines.level(forVisits: 3), 1)
        XCTAssertEqual(HistoryLines.level(forVisits: 9), 2)
    }

    // MARK: - Filtri e mezzi

    func testTravelModeInference() {
        XCTAssertEqual(TravelMode.infer(speed: 1.2), .foot)
        XCTAssertEqual(TravelMode.infer(speed: 5), .bike)
        XCTAssertEqual(TravelMode.infer(speed: 14), .car)
        // ~1,1 km in 2 minuti = auto
        let fast = road.enumerated().map { TrackPoint(lat: $1.lat, lon: $1.lon, time: Date(timeIntervalSince1970: Double($0) * 12)) }
        XCTAssertEqual(Trip(start: Date(), points: fast).effectiveMode, .car)
    }

    func testTripFilter() {
        let now = Date()
        var old = Trip(start: now.addingTimeInterval(-40 * 86400), points: road)
        old.end = old.start
        old.mode = .bike
        let recent = Trip(start: now.addingTimeInterval(-3600), end: now, points: road, mode: .car)
        XCTAssertTrue(TripFilter().includes(old, now: now))
        XCTAssertFalse(TripFilter(days: 30).includes(old, now: now))
        XCTAssertTrue(TripFilter(days: 30).includes(recent, now: now))
        XCTAssertFalse(TripFilter(mode: .bike).includes(recent, now: now))
        XCTAssertTrue(TripFilter(mode: .bike).includes(old, now: now))
    }

    // MARK: - Registrazione automatica

    func testAutoSplit() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000) // 14 nov 2023, 22:13 UTC
        let a = TrackPoint(lat: 45, lon: 9, time: t0)
        XCTAssertFalse(LocationTracker.shouldSplit(last: a, next: TrackPoint(lat: 45.0005, lon: 9, time: t0 + 30)))
        XCTAssertTrue(LocationTracker.shouldSplit(last: a, next: TrackPoint(lat: 45.0005, lon: 9, time: t0 + 600)), "pausa lunga")
        XCTAssertTrue(LocationTracker.shouldSplit(last: a, next: TrackPoint(lat: 45.05, lon: 9, time: t0 + 30)), "salto di 5 km")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // 23:58 e 00:01 del giorno dopo (UTC): pochi minuti e pochi metri, ma giorno diverso.
        let beforeMidnight = TrackPoint(lat: 45, lon: 9, time: t0 + 6280)
        let afterMidnight = TrackPoint(lat: 45.0001, lon: 9, time: t0 + 6460)
        XCTAssertTrue(LocationTracker.shouldSplit(last: beforeMidnight, next: afterMidnight, calendar: cal))
    }

    // MARK: - Strade nuove e percorsi

    func testNewStreetsFromOverpass() throws {
        var index = SpatialIndex()
        index.add(road)
        let json = """
        {"elements":[
          {"type":"way","geometry":[{"lat":45.0,"lon":9.001},{"lat":45.0,"lon":9.009}]},
          {"type":"way","geometry":[{"lat":45.003,"lon":9.001},{"lat":45.003,"lon":9.009}]},
          {"type":"node"}
        ]}
        """
        let lines = try ExploreService.newStreets(from: Data(json.utf8), index: index, within: 20)
        XCTAssertEqual(lines.count, 1, "solo la strada mai percorsa")
        XCTAssertEqual(try XCTUnwrap(lines.first?.first).latitude, 45.003, accuracy: 1e-9)
        XCTAssertTrue(ExploreService.query(region: .init(center: .init(latitude: 45, longitude: 9),
                                                         span: .init(latitudeDelta: 0.01, longitudeDelta: 0.01)),
                                           mode: .foot).contains("footway"))
    }

    func testRouteRankingPrefersNewStreets() {
        var index = SpatialIndex()
        index.add(road)
        let known = road.map(\.coordinate)
        let fresh = road.map { CLLocationCoordinate2D(latitude: $0.lat + 0.003, longitude: $0.lon) }
        let options = [
            RouteOption(coords: known, distance: 1100, time: 120),
            RouteOption(coords: fresh, distance: 1250, time: 140),
            RouteOption(coords: fresh, distance: 5000, time: 600), // nuova ma troppo lunga
        ]
        let ranked = RoutePlanner.rank(options, index: index, within: 20)
        XCTAssertEqual(ranked.first?.distance, 1250)
        XCTAssertEqual(ranked.first?.newFraction ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(ranked.last?.distance, 5000)
    }

    func testWaypointIsBesideTheLine() {
        let a = CLLocationCoordinate2D(latitude: 45, longitude: 9)
        let b = CLLocationCoordinate2D(latitude: 45, longitude: 9.02)
        let w = RoutePlanner.waypoint(a, b, offset: 500)
        XCTAssertEqual(w.longitude, 9.01, accuracy: 1e-6)
        XCTAssertEqual(Geo.distance(w, CLLocationCoordinate2D(latitude: 45, longitude: 9.01)), 500, accuracy: 5)
    }

    // MARK: - Statistiche

    func testStatsNewDistance() {
        let first = Trip(start: Date(timeIntervalSince1970: 1000), points: road, mode: .car)
        let again = Trip(start: Date(timeIntervalSince1970: 2000), points: road, mode: .bike)
        let s = TripStats.compute([again, first], since: nil)
        XCTAssertEqual(s.trips, 2)
        XCTAssertEqual(s.distance, 2 * 1101, accuracy: 20)
        XCTAssertEqual(s.newDistance, 1101, accuracy: 20, "la seconda volta la strada non è più nuova")
        XCTAssertEqual(s.byMode.map(\.mode), [.car, .bike])
        XCTAssertEqual(TripStats.compute([again, first], since: Date(timeIntervalSince1970: 1500)).trips, 1)
    }
}
