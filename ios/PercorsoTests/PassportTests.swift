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
        XCTAssertEqual(p.medals(trips: []).first { $0.id == "giornata" }?.level, .silver, "6 comuni nuovi in un giorno (3 e 5)")
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

    // MARK: - Chilometri e record

    /// Viaggio verso nord di `km` chilometri con il mezzo dato.
    private func trip(km: Double, mode: TravelMode, daysAgo: Double, base: Date) -> Trip {
        let start = base.addingTimeInterval(-daysAgo * 86400)
        let pts = (0...10).map { TrackPoint(lat: 45 + Double($0) * km / 10 / 111.195, lon: 9, time: start.addingTimeInterval(Double($0) * 60)) }
        return Trip(start: start, points: pts, mode: mode)
    }

    func testKilometreMedalsByMode() {
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        let trips = [trip(km: 300, mode: .car, daysAgo: 1, base: base),
                     trip(km: 260, mode: .car, daysAgo: 2, base: base),
                     trip(km: 12, mode: .foot, daysAgo: 3, base: base),
                     trip(km: 30, mode: .bike, daysAgo: 4, base: base)]
        let m = Dictionary(uniqueKeysWithValues: Passport().medals(trips: trips).map { ($0.id, $0) })
        XCTAssertEqual(m["km"]?.value ?? 0, 602, accuracy: 1)
        XCTAssertEqual(m["km"]?.level, .silver, "602 km: oltre 100 e 500")
        XCTAssertEqual(m["kmAuto"]?.level, .bronze, "560 km in auto")
        XCTAssertEqual(m["kmPiedi"]?.level, .bronze, "12 km a piedi")
        XCTAssertEqual(m["kmBici"]?.level, .bronze, "30 km in bici")
        XCTAssertEqual(m["viaggi"]?.level, .locked, "4 viaggi su 10")
        XCTAssertEqual(m["lungo"]?.level, .gold, "300 km in un viaggio")
    }

    func testDiamondLevel() {
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        let m = Passport().medals(trips: [trip(km: 1100, mode: .car, daysAgo: 0, base: base)]).first { $0.id == "lungo" }
        XCTAssertEqual(m?.level, .diamond)
        XCTAssertNil(m?.next, "livello massimo")
        XCTAssertEqual(m?.progress, 1)
    }

    func testPersonalRecords() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func day(_ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: 12))! }
        func t(_ km: Double, _ date: Date) -> Trip {
            Trip(start: date, points: [TrackPoint(lat: 45, lon: 9, time: date),
                                       TrackPoint(lat: 45 + km / 111.195, lon: 9, time: date.addingTimeInterval(3600))])
        }
        let trips = [t(50, day(9, 1)), t(30, day(9, 1)), t(120, day(10, 5)), t(10, day(10, 6)), t(5, day(8, 20))]
        let r = PersonalRecords.compute(trips, calendar: cal)
        XCTAssertEqual(r.longestTrips.map { Int($0.km.rounded()) }, [120, 50, 30])
        XCTAssertEqual(r.bestMonths.map { Int($0.km.rounded()) }, [130, 80, 5], "ottobre, settembre, agosto")
        XCTAssertEqual(r.bestDays.first.map { Int($0.km.rounded()) }, 120)
        XCTAssertEqual(r.bestDays[1].km, 80, accuracy: 0.5, "due viaggi lo stesso giorno si sommano")
        XCTAssertTrue(PersonalRecords.compute([]).longestTrips.isEmpty)
    }
}
