import XCTest
@testable import Percorso

/// Registrazione programmata "dal giorno A al giorno B".
final class RecordingPeriodTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Rome")!
        return c
    }()

    private func date(_ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testWholeDaysIncluded() {
        // Dal 12 al 15 ottobre: dalla mezzanotte del 12 alla fine del 15.
        let p = RecordingPeriod(start: date(12, 18), end: date(15, 9))
        XCTAssertFalse(p.contains(date(11, 23, 59), calendar: cal))
        XCTAssertTrue(p.contains(date(12, 0, 0), calendar: cal))
        XCTAssertTrue(p.contains(date(13), calendar: cal))
        XCTAssertTrue(p.contains(date(15, 23, 59), calendar: cal), "l'ultimo giorno è compreso")
        XCTAssertFalse(p.contains(date(16, 0, 0), calendar: cal))
    }

    func testUpcomingAndOver() {
        let p = RecordingPeriod(start: date(12), end: date(15))
        XCTAssertTrue(p.isUpcoming(date(11), calendar: cal))
        XCTAssertFalse(p.isUpcoming(date(12), calendar: cal))
        XCTAssertFalse(p.isOver(date(15, 22), calendar: cal))
        XCTAssertTrue(p.isOver(date(16, 8), calendar: cal))
    }

    func testSingleDayAndReversedDates() {
        let one = RecordingPeriod(start: date(20, 8), end: date(20, 8))
        XCTAssertTrue(one.contains(date(20, 21), calendar: cal))
        XCTAssertFalse(one.contains(date(21, 1), calendar: cal))
        // Fine prima dell'inizio: vale solo il giorno di inizio.
        let reversed = RecordingPeriod(start: date(20), end: date(18))
        XCTAssertFalse(reversed.contains(date(19), calendar: cal))
        XCTAssertTrue(reversed.contains(date(20, 10), calendar: cal))
    }

    func testDaylightSavingDay() {
        // 25 ottobre 2026: in Italia torna l'ora solare (giorno di 25 ore).
        let p = RecordingPeriod(start: date(25), end: date(25))
        let b = p.bounds(calendar: cal)
        XCTAssertEqual(b.to.timeIntervalSince(b.from), 25 * 3600)
        XCTAssertTrue(p.contains(date(25, 23, 30), calendar: cal))
    }
}
