import XCTest
import CoreLocation
@testable import Percorso

final class PassportTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func sample(_ comune: String, _ prov: String = "Brescia", _ reg: String = "Lombardia",
                        _ stato: String = "Italia", _ code: String = "IT") -> PlaceSample {
        PlaceSample(comune: comune, provincia: prov, regione: reg, stato: stato, countryCode: code)
    }

    func testRecordCountsEachPlaceOnceWithFirstVisit() {
        var p = Passport()
        let added = p.record(sample("Brescia"), at: t0.addingTimeInterval(3600))
        XCTAssertEqual(Set(added.map(\.kind)), Set(PlaceKind.allCases), "primo punto: comune, provincia, regione e stato nuovi")
        XCTAssertTrue(p.record(sample("Brescia"), at: t0.addingTimeInterval(7200)).isEmpty)
        // Un viaggio più vecchio analizzato dopo: la prima visita si sposta indietro.
        p.record(sample("Brescia"), at: t0)
        XCTAssertEqual(p.list(.comune).first?.firstVisit, t0)
        p.record(sample("Concesio"), at: t0)
        p.record(sample("Verona", "Verona", "Veneto"), at: t0)
        p.record(sample("Lugano", "Lugano", "Ticino", "Svizzera", "CH"), at: t0)
        XCTAssertEqual(p.count(.comune), 4)
        XCTAssertEqual(p.count(.provincia), 3)
        XCTAssertEqual(p.count(.regione), 3)
        XCTAssertEqual(p.count(.stato), 2)
        XCTAssertEqual(p.list(.comune).first { $0.name == "Concesio" }?.parent, "Brescia")
    }

    func testMissingNamesAreSkipped() {
        var p = Passport()
        p.record(PlaceSample(comune: nil, provincia: " ", regione: nil, stato: "Italia", countryCode: "IT"), at: t0)
        XCTAssertEqual(p.count(.comune), 0)
        XCTAssertEqual(p.count(.provincia), 0)
        XCTAssertEqual(p.count(.stato), 1)
    }

    func testMedalLevelsAndProgress() {
        var p = Passport()
        for i in 0..<27 { p.record(sample("Comune \(i)"), at: t0.addingTimeInterval(Double(i) * 86400)) }
        let comuni = try? XCTUnwrap(p.medals(trips: []).first { $0.id == "comune" })
        XCTAssertEqual(comuni?.level, .silver, "27 comuni: argento (25)")
        XCTAssertEqual(comuni?.next, 100)
        XCTAssertEqual(comuni?.progress ?? 0, 2.0 / 75.0, accuracy: 1e-9)
        let stati = p.medals(trips: []).first { $0.id == "stato" }
        XCTAssertEqual(stati?.level, .locked, "un solo stato")
        XCTAssertEqual(stati?.progress ?? 1, 0.5, accuracy: 1e-9)
    }

    func testTripMedals() {
        // Viaggio di ~110 km, metà su strade nuove.
        let pts = (0...100).map { TrackPoint(lat: 45 + Double($0) * 0.00989, lon: 9, time: t0.addingTimeInterval(Double($0) * 60)) }
        var trip = Trip(start: t0, points: pts)
        trip.newFraction = 0.5
        let medals = Passport().medals(trips: [trip])
        XCTAssertEqual(medals.first { $0.id == "lungo" }?.level, .silver, "110 km in un viaggio")
        XCTAssertEqual(medals.first { $0.id == "nuove" }?.level, .bronze, "55 km su strade nuove")
    }

    func testBestDay() {
        var p = Passport()
        let noon = Date(timeIntervalSince1970: 1_700_049_600) // 15/11/2023 12:00 UTC: stesso giorno in ogni fuso
        for i in 0..<6 { p.record(sample("Giro \(i)"), at: noon.addingTimeInterval(Double(i) * 600)) }
        p.record(sample("Altro giorno"), at: noon.addingTimeInterval(5 * 86400))
        XCTAssertEqual(p.bestDay(), 6)
        XCTAssertEqual(p.medals(trips: []).first { $0.id == "giornata" }?.level, .bronze)
    }

    func testMedalsUnlockOnlyOnce() {
        var p = Passport()
        for i in 0..<5 { p.record(sample("C\(i)"), at: t0) }
        let first = p.unlockNew(p.medals(trips: []), now: t0)
        XCTAssertTrue(first.contains { $0.id == "comune" && $0.level == .bronze })
        XCTAssertTrue(p.unlockNew(p.medals(trips: []), now: t0).isEmpty, "già sbloccate")
        for i in 5..<25 { p.record(sample("C\(i)"), at: t0) }
        let second = p.unlockNew(p.medals(trips: []), now: t0)
        XCTAssertEqual(second.first { $0.id == "comune" }?.level, .silver)
    }

    func testSamplesAlongTrip() {
        // 10 km verso nord, un punto ogni ~111 m.
        let pts = (0...90).map { TrackPoint(lat: 45 + Double($0) * 0.001, lon: 9, time: t0.addingTimeInterval(Double($0))) }
        let s = Passport.samples(of: pts, every: 1500)
        XCTAssertEqual(s.first, pts.first)
        XCTAssertEqual(s.last, pts.last)
        XCTAssertEqual(s.count, 8, "inizio + 6 campioni ogni 1,5 km + fine")
        XCTAssertEqual(Passport.samples(of: [pts[0]]).count, 1)
        XCTAssertTrue(Passport.samples(of: []).isEmpty)
    }

    func testCacheCellAndSaving() throws {
        let a = CLLocationCoordinate2D(latitude: 45.5401, longitude: 10.2201)
        let b = CLLocationCoordinate2D(latitude: 45.5410, longitude: 10.2210) // ~120 m
        XCTAssertEqual(Passport.cell(a), Passport.cell(b))
        XCTAssertNotEqual(Passport.cell(a), Passport.cell(CLLocationCoordinate2D(latitude: 45.56, longitude: 10.22)))

        var p = Passport()
        p.record(sample("Brescia"), at: t0)
        p.cache[Passport.cell(a)] = sample("Brescia")
        p.processedTrips.insert(UUID())
        let decoded = try JSONDecoder().decode(Passport.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(decoded.count(.comune), 1)
        XCTAssertEqual(decoded.cache[Passport.cell(a)], sample("Brescia"))
        XCTAssertEqual(decoded.processedTrips.count, 1)
    }

    // MARK: - Solo a piedi

    /// Tratti a velocità costante: (metri al secondo, secondi), un punto ogni 5 s.
    private func track(_ parts: [(Double, Double)]) -> [TrackPoint] {
        var pts = [TrackPoint(lat: 45, lon: 9, time: t0)]
        var x = 0.0, t = 0.0
        for (speed, seconds) in parts {
            for _ in 0..<Int(seconds / 5) {
                x += speed * 5; t += 5
                pts.append(TrackPoint(lat: 45 + x / 111_195, lon: 9, time: t0.addingTimeInterval(t)))
            }
        }
        return pts
    }

    func testCarTripCountsOnlyTheWalkAfterParking() {
        // Auto, coda lenta di 300 m in mezzo, ancora auto, poi 400 m a piedi dal parcheggio.
        let pts = track([(14, 300), (1.5, 200), (14, 300), (1.3, 310)])
        let stretches = Passport.walkingStretches(of: pts, mode: .car)
        XCTAssertEqual(stretches.count, 1, "la coda in mezzo non conta")
        XCTAssertEqual(stretches.first?.last, pts.last)
        XCTAssertGreaterThanOrEqual(Geo.length(of: stretches[0]), 390)
    }

    func testDrivingThroughIsNotAVisit() {
        let pts = track([(14, 600)])
        XCTAssertTrue(Passport.walkingStretches(of: pts, mode: .car).isEmpty)
        XCTAssertTrue(Passport.walkingSamples(of: Trip(start: t0, points: pts, mode: .car)).isEmpty)
    }

    func testShortWalkIsNotEnough() {
        // 150 m a piedi dopo il parcheggio: meno di 200 m.
        let pts = track([(14, 300), (1.3, 115)])
        XCTAssertTrue(Passport.walkingStretches(of: pts, mode: .car).isEmpty)
    }

    func testWalkingTripCountsEverywhere() {
        // Passeggiata di 2,3 km con una pausa: campioni a ogni km.
        let pts = track([(1.4, 900), (0, 120), (1.4, 750)])
        let stretches = Passport.walkingStretches(of: pts, mode: .foot)
        XCTAssertEqual(stretches.count, 1)
        let samples = Passport.walkingSamples(of: Trip(start: t0, points: pts, mode: .foot))
        XCTAssertEqual(samples.first, pts.first)
        XCTAssertEqual(samples.last, pts.last)
        XCTAssertEqual(samples.count, 4, "inizio, 1 km, 2 km, fine")
    }

    func testOldPassportIsRecalculated() {
        var p = Passport()
        p.record(sample("Passato in auto"), at: t0)
        p.processedTrips.insert(UUID())
        p.cache["1:1"] = sample("Brescia")
        XCTAssertTrue(p.migrateIfNeeded())
        XCTAssertEqual(p.count(.comune), 0)
        XCTAssertTrue(p.processedTrips.isEmpty, "i viaggi vengono rianalizzati")
        XCTAssertNotNil(p.cache["1:1"], "i nomi già scaricati restano")
        XCTAssertFalse(p.migrateIfNeeded())
    }
}
