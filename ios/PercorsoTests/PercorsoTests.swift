import XCTest
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
}
