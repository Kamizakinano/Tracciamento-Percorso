import XCTest
@testable import Percorso

/// Medaglie di esplorazione, natura e sfide speciali.
final class ExplorationMedalTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func sample(_ comune: String) -> PlaceSample {
        PlaceSample(comune: comune, provincia: "Brescia", regione: "Lombardia", stato: "Italia", countryCode: "IT")
    }

    /// Viaggio verso est da `fromKm` a `toKm` (lat 45), punti ogni 50 m.
    private func trip(_ fromKm: Double, _ toKm: Double, at start: Date, lat: Double = 45) -> Trip {
        let steps = Int((toKm - fromKm) * 20)
        let pts = (0...steps).map { i in
            TrackPoint(lat: lat, lon: 9 + (fromKm + Double(i) * 0.05) / 78.85, time: start.addingTimeInterval(Double(i) * 30))
        }
        return Trip(start: start, points: pts)
    }

    func testNewStreetRunsCountOnlyNeverTravelledStretches() {
        let d = date(2026, 10, 10)
        // Primo viaggio: 2 km tutti nuovi = 1 strada. Secondo: stessa strada + 1 km nuovo = 1 strada.
        // Terzo: 100 m nuovi (troppo corto) e poi strada già fatta.
        let runs = Passport.newStreetRuns([
            trip(0, 2, at: d),
            trip(0, 3, at: d.addingTimeInterval(3600)),
            trip(2.9, 3.0, at: d.addingTimeInterval(7200), lat: 45.01),
        ])
        XCTAssertEqual(runs.count, 2)
    }

    func testRevisitsAndMethodicalExplorer() {
        var p = Passport()
        p.record(sample("Brescia"), at: date(2026, 10, 1))
        p.record(sample("Brescia"), at: date(2026, 10, 1, 18)) // stesso giorno: non conta
        p.record(sample("Brescia"), at: date(2026, 10, 5))
        p.record(sample("Brescia"), at: date(2026, 10, 9))
        p.record(sample("Concesio"), at: date(2026, 10, 2))
        p.record(sample("Concesio"), at: date(2026, 10, 3))
        p.record(sample("Lumezzane"), at: date(2026, 10, 3))
        XCTAssertEqual(p.comuni(visitedOnDays: 2), 2, "Brescia e Concesio rivisitati")
        XCTAssertEqual(p.comuni(visitedOnDays: 3), 1, "solo Brescia in 3 giornate")
        let m = Dictionary(uniqueKeysWithValues: p.medals(trips: []).map { ($0.id, $0) })
        XCTAssertEqual(m["ritorno"]?.level, .bronze)
        XCTAssertEqual(m["metodico"]?.level, .bronze)
    }

    func testAutumnChallenge() {
        XCTAssertTrue(Passport.isAutumn(date(2026, 9, 23), calendar: cal))
        XCTAssertFalse(Passport.isAutumn(date(2026, 9, 22), calendar: cal))
        XCTAssertTrue(Passport.isAutumn(date(2026, 12, 20), calendar: cal))
        XCTAssertFalse(Passport.isAutumn(date(2026, 12, 21), calendar: cal))
        var p = Passport()
        p.record(sample("A"), at: date(2026, 10, 1))
        p.record(sample("B"), at: date(2026, 11, 1))
        p.record(sample("C"), at: date(2025, 10, 1)) // autunno di un altro anno
        p.record(sample("D"), at: date(2026, 7, 1))  // estate
        XCTAssertEqual(p.bestAutumn(calendar: cal), 2)
        p.record(sample("D"), at: date(2026, 10, 20)) // ci torni in autunno
        XCTAssertEqual(p.bestAutumn(calendar: cal), 3)
    }

    func testBestWeekend() {
        let sat = date(2026, 10, 17), sun = date(2026, 10, 18), mon = date(2026, 10, 19)
        let runs = [sat, sat, sun, mon, mon, mon, mon, date(2026, 10, 24)]
        XCTAssertEqual(Passport.bestWeekend(runs, calendar: cal), 3, "sabato + domenica dello stesso weekend")
    }

    func testNatureAndAttractionMedals() {
        let now = Date()
        var sights = (0..<20).map { _ in SightVisit(kind: .church, date: now) }
        sights += (0..<3).map { _ in SightVisit(kind: .park, date: now) }
        sights += [SightVisit(kind: .lake, date: now), SightVisit(kind: .viewpoint, date: now)]
        let m = Dictionary(uniqueKeysWithValues: Passport().medals(trips: [], extras: MedalExtras(sights: sights)).map { ($0.id, $0) })
        XCTAssertEqual(m["attrazioni"]?.value, 20, "parchi, laghi e panorami non contano come attrazioni")
        XCTAssertEqual(m["attrazioni"]?.level, .silver)
        XCTAssertEqual(m["parchi"]?.level, .bronze)
        XCTAssertEqual(m["laghi"]?.level, .bronze)
        XCTAssertEqual(m["panorami"]?.level, .bronze)
        XCTAssertEqual(m["strade"]?.level, .locked)
    }

    func testLakeTags() {
        XCTAssertEqual(SightKind.from(tags: ["natural": "water", "water": "lake"]), .lake)
        XCTAssertNil(SightKind.from(tags: ["natural": "water", "water": "pond"]))
        XCTAssertEqual(SightKind.lake.seenRadius, 250)
    }
}
