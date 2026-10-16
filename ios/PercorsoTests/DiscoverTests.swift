import XCTest
import CoreLocation
@testable import Percorso

final class DiscoverTests: XCTestCase {
    private func sight(_ id: String, _ dLat: Double, _ dLon: Double, score: Int = 0) -> Sight {
        Sight(id: id, name: "Luogo \(id)", kind: .monument, lat: 45 + dLat, lon: 9 + dLon, score: score)
    }
    private let here = CLLocationCoordinate2D(latitude: 45, longitude: 9)

    func testParseOverpass() throws {
        let json = """
        {"elements":[
          {"type":"node","id":1,"lat":45.1,"lon":9.1,"tags":{"historic":"monument","name":"Monumento ai Caduti"}},
          {"type":"way","id":2,"center":{"lat":45.2,"lon":9.2},"tags":{"amenity":"place_of_worship","name":"Cattedrale","name:it":"Cattedrale di San Giovanni","wikidata":"Q1","tourism":"attraction"}},
          {"type":"node","id":3,"lat":45.3,"lon":9.3,"tags":{"tourism":"viewpoint","name":"Belvedere"}},
          {"type":"node","id":4,"lat":45.4,"lon":9.4,"tags":{"shop":"bakery","name":"Forno"}},
          {"type":"node","id":5,"lat":45.5,"lon":9.5,"tags":{"historic":"monument"}},
          {"type":"node","id":6,"lat":45.1,"lon":9.1,"tags":{"historic":"memorial","name":"Monumento ai Caduti"}}
        ]}
        """
        let sights = try DiscoverService.parse(Data(json.utf8), language: "it")
        XCTAssertEqual(sights.count, 3, "niente negozi, niente luoghi senza nome, niente doppioni")
        XCTAssertEqual(sights.first?.name, "Cattedrale di San Giovanni", "nome in italiano e più importante prima")
        XCTAssertEqual(sights.first?.kind, .church)
        XCTAssertEqual(sights.first?.lat, 45.2, "le vie/edifici usano il centro")
        XCTAssertEqual(sights.first { $0.id == "node/3" }?.kind, .viewpoint)
    }

    func testKindsFromTags() {
        XCTAssertEqual(SightKind.from(tags: ["historic": "castle"]), .castle)
        XCTAssertEqual(SightKind.from(tags: ["tourism": "museum"]), .museum)
        XCTAssertEqual(SightKind.from(tags: ["amenity": "fountain"]), .fountain)
        XCTAssertEqual(SightKind.from(tags: ["place": "square"]), .square)
        XCTAssertNil(SightKind.from(tags: ["amenity": "restaurant"]))
    }

    func testSuggestionPrefersAheadAndImportant() {
        // A 200 m davanti (nord) e B 180 m dietro (sud): camminando verso nord vince A.
        let a = sight("A", 0.0018, 0), b = sight("B", -0.0016, 0)
        XCTAssertEqual(DiscoverService.bestSuggestion([a, b], from: here, heading: 0)?.sight.id, "A")
        // Senza direzione vince il più vicino.
        XCTAssertEqual(DiscoverService.bestSuggestion([a, b], from: here, heading: nil)?.sight.id, "B")
        // Un luogo importante vale una piccola deviazione in più.
        let famous = sight("F", 0.0030, 0, score: 5)
        XCTAssertEqual(DiscoverService.bestSuggestion([a, famous], from: here, heading: 0)?.sight.id, "F")
    }

    func testSuggestionLimits() {
        XCTAssertNil(DiscoverService.bestSuggestion([sight("lontano", 0.01, 0)], from: here, heading: nil), "oltre 600 m")
        XCTAssertNil(DiscoverService.bestSuggestion([sight("qui", 0.0002, 0)], from: here, heading: nil), "ci sei già")
        let s = DiscoverService.bestSuggestion([sight("A", 0.0036, 0)], from: here, heading: nil)
        XCTAssertEqual(s?.walkMinutes, 5, "400 m a piedi ≈ 5 minuti")
    }

    func testHeadingAndBearing() {
        XCTAssertEqual(DiscoverService.bearing(from: here, to: CLLocationCoordinate2D(latitude: 45.01, longitude: 9)), 0, accuracy: 0.5)
        XCTAssertEqual(DiscoverService.bearing(from: here, to: CLLocationCoordinate2D(latitude: 45, longitude: 9.01)), 90, accuracy: 0.5)
        XCTAssertEqual(abs(DiscoverService.angleDifference(350, 10)), 20, accuracy: 0.001)
        let t0 = Date()
        let pts = (0...5).map { TrackPoint(lat: 45 + Double($0) * 0.0001, lon: 9, time: t0.addingTimeInterval(Double($0))) }
        XCTAssertEqual(DiscoverService.heading(of: pts) ?? -1, 0, accuracy: 1, "camminando verso nord")
        XCTAssertNil(DiscoverService.heading(of: [pts[0]]), "fermo")
    }

    func testVisitedAreRemembered() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = DiscoverService(directory: dir)
        d.loadDemo()
        let scala = try XCTUnwrap(d.sights.first { $0.name == "Teatro alla Scala" })
        d.update(location: scala.coordinate)
        XCTAssertTrue(d.isVisited(scala))
        XCTAssertTrue(DiscoverService(directory: dir).visited.contains(scala.id), "ricordato anche dopo")
    }
}
