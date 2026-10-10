import XCTest
import CoreLocation
import MapKit
import UIKit
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

    func testExploreNeedsZoom() {
        let center = CLLocationCoordinate2D(latitude: 45.46, longitude: 9.19)
        XCTAssertFalse(ExploreService.isTooWide(MKCoordinateRegion(center: center, latitudinalMeters: 1500, longitudinalMeters: 1500)))
        XCTAssertTrue(ExploreService.isTooWide(MKCoordinateRegion(center: center, latitudinalMeters: 15000, longitudinalMeters: 15000)))
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

    // MARK: - Navigazione

    /// Percorso a L: 1 km verso est, poi svolta a sinistra e 500 m verso nord.
    private func lRoute() -> (RouteOption, Place) {
        let a = CLLocationCoordinate2D(latitude: 45.0, longitude: 9.0)
        let corner = CLLocationCoordinate2D(latitude: 45.0, longitude: 9.0127)
        let end = CLLocationCoordinate2D(latitude: 45.0045, longitude: 9.0127)
        let steps = [
            RouteStep(instruction: "", distance: 0, coords: [a]),
            RouteStep(instruction: "Prosegui su Via Roma", distance: 1000, coords: [a, corner]),
            RouteStep(instruction: "Svolta a sinistra in Via Verdi", distance: 500, coords: [corner, end]),
            RouteStep(instruction: "La destinazione è sulla destra", distance: 0, coords: [end]),
        ]
        return (RouteOption(coords: [a, corner, end], distance: 1500, time: 180, steps: steps),
                Place(name: "Arrivo", coordinate: end))
    }

    private func location(_ lat: Double, _ lon: Double) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), altitude: 0,
                   horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date())
    }

    func testNavigationFollowsSteps() {
        let (route, dest) = lRoute()
        let nav = NavigationSession(store: nil)
        nav.voiceEnabled = false
        nav.start(route: route, destination: dest, mode: .car)
        XCTAssertEqual(nav.stepIndex, 1, "il primo passo vuoto viene saltato")

        nav.update(location(45.0, 9.0001)) // alla partenza
        XCTAssertEqual(nav.instruction, "Svolta a sinistra in Via Verdi")
        XCTAssertEqual(nav.maneuverIcon, "arrow.turn.up.left")
        XCTAssertEqual(nav.distanceToManeuver, 990, accuracy: 15)
        XCTAssertEqual(nav.remainingDistance, 1490, accuracy: 20)

        nav.update(location(45.0, 9.0126)) // all'incrocio
        XCTAssertEqual(nav.instruction, "La destinazione è sulla destra")

        nav.update(location(45.0044, 9.0127)) // a 10 m dall'arrivo
        XCTAssertTrue(nav.arrived)
        XCTAssertEqual(nav.remainingDistance, 0)
    }

    func testNavigationReroutesWhenOffRoute() {
        let (route, dest) = lRoute()
        let nav = NavigationSession(store: nil)
        nav.voiceEnabled = false
        var reroutes = 0
        nav.rerouteHandler = { _ in reroutes += 1 }
        nav.start(route: route, destination: dest, mode: .car)
        nav.update(location(45.0002, 9.005)) // 22 m dal percorso: ancora sopra
        XCTAssertEqual(reroutes, 0)
        for _ in 0..<3 { nav.update(location(45.002, 9.005)) } // 220 m fuori
        XCTAssertEqual(reroutes, 1)
    }

    func testDistanceToPolylineAndFormatting() {
        let line = [CLLocationCoordinate2D(latitude: 45, longitude: 9), CLLocationCoordinate2D(latitude: 45, longitude: 9.01)]
        XCTAssertEqual(Geo.distance(from: CLLocationCoordinate2D(latitude: 45.001, longitude: 9.005), toPolyline: line), 111, accuracy: 2)
        XCTAssertEqual(Geo.distance(from: CLLocationCoordinate2D(latitude: 45, longitude: 8.99), toPolyline: line), 786, accuracy: 10)
        XCTAssertEqual(Geo.formatShort(43), "40 m")
        XCTAssertEqual(Geo.formatShort(237), "250 m")
        XCTAssertTrue(Geo.formatShort(1240).hasPrefix("1"))
        XCTAssertEqual(NavigationSession.icon(for: "Alla rotonda prendi la seconda uscita"), "arrow.triangle.turn.up.right.circle")
        XCTAssertEqual(NavigationSession.icon(for: "Turn right onto Main St"), "arrow.turn.up.right")
        XCTAssertEqual(NavigationSession.icon(for: "Prosegui dritto"), "arrow.up")
    }

    // MARK: - Mezzi pubblici

    func testDecodePolyline() {
        // Esempio della documentazione Google (precisione 5).
        let c = TransitPlanner.decodePolyline("_p~iF~ps|U_ulLnnqC_mqNvxq`@", precision: 5)
        XCTAssertEqual(c.count, 3)
        XCTAssertEqual(c[0].latitude, 38.5, accuracy: 1e-6)
        XCTAssertEqual(c[0].longitude, -120.2, accuracy: 1e-6)
        XCTAssertEqual(c[2].latitude, 43.252, accuracy: 1e-6)
        XCTAssertEqual(c[2].longitude, -126.453, accuracy: 1e-6)
    }

    func testParseTransitous() throws {
        let json = """
        {"itineraries":[
          {"duration":900,"startTime":"2026-10-12T08:00:00Z","endTime":"2026-10-12T08:15:00Z","transfers":0,"legs":[
            {"mode":"WALK","from":{"name":"START","departure":"2026-10-12T08:00:00Z"},"to":{"name":"DUOMO M3","arrival":"2026-10-12T08:04:00Z"},
             "duration":240,"startTime":"2026-10-12T08:00:00Z","endTime":"2026-10-12T08:04:00Z","distance":231,
             "legGeometry":{"points":"_p~iF~ps|U_ulLnnqC","precision":5}},
            {"mode":"SUBWAY","from":{"name":"DUOMO M3"},"to":{"name":"CENTRALE FS"},"duration":420,
             "startTime":"2026-10-12T08:05:00Z","endTime":"2026-10-12T08:12:00Z","routeShortName":"3","headsign":"COMASINA",
             "routeColor":"FCC200","intermediateStops":[{"name":"MONTENAPOLEONE"},{"name":"TURATI"},{"name":"REPUBBLICA"}]}
          ]},
          {"duration":1500,"startTime":"2026-10-12T08:00:00Z","endTime":"2026-10-12T08:25:00Z","transfers":0,"legs":[
            {"mode":"WALK","from":{"name":"START"},"to":{"name":"END"},"duration":1500}
          ]}
        ],"from":{},"to":{}}
        """
        let its = try TransitPlanner.parse(Data(json.utf8))
        XCTAssertEqual(its.count, 1, "l'itinerario solo a piedi viene scartato")
        let it = try XCTUnwrap(its.first)
        XCTAssertEqual(it.duration, 900)
        XCTAssertEqual(it.legs.count, 2)
        XCTAssertEqual(it.legs[0].from, "Partenza")
        XCTAssertTrue(it.legs[0].isWalk)
        XCTAssertEqual(it.legs[0].coords.count, 2)
        let metro = it.legs[1]
        XCTAssertEqual(metro.line, "3")
        XCTAssertEqual(metro.modeName, "Metro")
        XCTAssertEqual(metro.stops, 4)
        XCTAssertEqual(metro.headsign, "COMASINA")
        XCTAssertNotNil(UIColor(hex: "FCC200"))
        XCTAssertNil(UIColor(hex: "zzz"))
        XCTAssertTrue(TransitPlanner.url(from: .init(latitude: 45.46, longitude: 9.19), to: .init(latitude: 45.48, longitude: 9.2), at: Date())
            .absoluteString.contains("fromPlace=45.46,9.19"))
    }

    func testRouteModes() {
        XCTAssertEqual(RouteMode(.bike), .bike)
        XCTAssertNil(RouteMode.transit.travelMode)
        XCTAssertEqual(RouteMode.allCases.count, 4)
        XCTAssertEqual(4400 / bikeSpeed, 1000, accuracy: 1, "4,4 km in bici ~ 17 minuti")
    }

    // MARK: - Ricerca di tutti i negozi

    func testResultsSortedByDistance() {
        let me = CLLocationCoordinate2D(latitude: 45.4642, longitude: 9.19)
        let far = Place(name: "Lidl lontano", coordinate: .init(latitude: 45.50, longitude: 9.19), address: "Via A")
        let near = Place(name: "Lidl vicino", coordinate: .init(latitude: 45.466, longitude: 9.19))
        let mid = Place(name: "Lidl medio", coordinate: .init(latitude: 45.48, longitude: 9.19))
        XCTAssertEqual(PlaceSearch.sorted([far, near, mid], from: me).map(\.name), ["Lidl vicino", "Lidl medio", "Lidl lontano"])
        XCTAssertEqual(PlaceSearch.sorted([far, near], from: nil).map(\.name), ["Lidl lontano", "Lidl vicino"])
        XCTAssertFalse(PlaceSearch.categories.isEmpty)
    }
}
