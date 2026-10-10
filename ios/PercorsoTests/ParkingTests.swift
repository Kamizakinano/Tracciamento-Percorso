import XCTest
import CoreLocation
import AVFoundation
import UIKit
@testable import Percorso

final class ParkingTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore() -> ParkingStore { ParkingStore(directory: dir, systemServices: false) }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// Punto `meters` metri a est di (45, 9), dopo `seconds` secondi.
    private func point(_ meters: Double, _ seconds: Double, north: Double = 0) -> TrackPoint {
        TrackPoint(lat: 45.0 + north / 111_195, lon: 9.0 + meters / (111_195 * cos(45 * .pi / 180)),
                   time: t0.addingTimeInterval(seconds))
    }

    /// Guida verso est a 12 m/s per `meters` metri (un punto al secondo).
    private func drive(_ d: inout ParkingDetector, meters: Double, from start: Double = 0, at time: Double = 0) -> [ParkingEvent] {
        var events: [ParkingEvent] = []
        var x = start, t = time
        while x < start + meters {
            x += 12; t += 1
            if let e = d.feed(point(x, t), speed: 12) { events.append(e) }
        }
        return events
    }

    // MARK: - Rilevamento dalla velocità

    func testDriveThenWalkSavesParkingWhereTheCarStopped() {
        var d = ParkingDetector()
        let events = drive(&d, meters: 1200)
        XCTAssertEqual(events.count, 1, "dopo 500 m in auto: ripartenza")
        guard case .departed? = events.first else { return XCTFail("attesa la ripartenza") }
        // Scende e cammina verso nord a 1,3 m/s per 3 minuti.
        var parked: TrackPoint?
        for i in 1...180 {
            if case let .parked(p, left)? = d.feed(point(1200, 100 + Double(i), north: Double(i) * 1.3), speed: 1.3) {
                XCTAssertFalse(left)
                parked = p
            }
        }
        guard let spot = parked else { return XCTFail("atteso un parcheggio") }
        XCTAssertEqual(Geo.distance(spot, point(1200, 0)), 0, accuracy: 1, "il parcheggio è l'ultimo punto in auto")
    }

    func testRedLightIsNotParking() {
        var d = ParkingDetector()
        _ = drive(&d, meters: 1000)
        // Fermo al semaforo per 3 minuti (nessuno spostamento).
        for i in 1...180 {
            XCTAssertNil(d.feed(point(1000, 90 + Double(i)), speed: 0))
        }
        // Riparte.
        XCTAssertTrue(drive(&d, meters: 300, from: 1000, at: 300).isEmpty)
    }

    func testShortDriveIsNotParking() {
        var d = ParkingDetector()
        _ = drive(&d, meters: 300)
        for i in 1...200 {
            if case .parked? = d.feed(point(300, 30 + Double(i), north: Double(i) * 1.3), speed: 1.3) {
                XCTFail("300 m non bastano per un parcheggio")
            }
        }
        XCTAssertNil(d.tripEnded())
    }

    func testWalkingOrCyclingNeverParks() {
        var d = ParkingDetector()
        for i in 1...600 {
            XCTAssertNil(d.feed(point(Double(i) * 4.4, Double(i)), speed: 4.4), "bici")
        }
        XCTAssertNil(d.tripEnded())
    }

    func testTripEndAfterDrivingIsParking() {
        var d = ParkingDetector()
        _ = drive(&d, meters: 800)
        // Fermo (GPS sospeso da iOS).
        for i in 1...10 { _ = d.feed(point(800, 70 + Double(i)), speed: 0) }
        guard case let .parked(p, left)? = d.tripEnded() else { return XCTFail("atteso un parcheggio") }
        XCTAssertFalse(left)
        XCTAssertEqual(Geo.distance(p, point(800, 0)), 0, accuracy: 15)
        XCTAssertNil(d.tripEnded(), "dopo la fine del viaggio si riparte da zero")
    }

    func testTripEndWhileStillDrivingIsNotParking() {
        var d = ParkingDetector()
        _ = drive(&d, meters: 800)
        XCTAssertNil(d.tripEnded(), "Ferma premuto mentre guidi")
    }

    func testTripEndNoticedLaterFarAwayGoesToHistory() {
        var d = ParkingDetector()
        _ = drive(&d, meters: 800)
        for i in 1...10 { _ = d.feed(point(800, 70 + Double(i)), speed: 0) }
        // Ci si accorge della fine del viaggio solo quando sei già a 3 km.
        guard case let .parked(_, left)? = d.tripEnded(next: point(3800, 5000)) else { return XCTFail() }
        XCTAssertTrue(left)
    }

    // MARK: - Archivio

    func testParkRetrieveAndPersist() throws {
        let store = makeStore()
        XCTAssertNil(store.current)
        let spot = try XCTUnwrap(store.park(at: point(0, 0).coordinate, date: t0, source: .manual))
        XCTAssertEqual(store.current?.id, spot.id)

        store.setNote("Piano -2, colonna B7", for: spot.id)
        store.setExpiry(t0.addingTimeInterval(3600), reminderMinutes: 15, for: spot.id, now: t0)
        XCTAssertEqual(store.current?.reminderDate, t0.addingTimeInterval(2700))

        // Riaperto: i dati restano.
        let reopened = makeStore()
        XCTAssertEqual(reopened.current?.note, "Piano -2, colonna B7")
        XCTAssertEqual(reopened.current?.expiry, t0.addingTimeInterval(3600))

        reopened.retrieve(now: t0.addingTimeInterval(5400))
        XCTAssertNil(reopened.current)
        XCTAssertEqual(reopened.history.first?.duration(), 5400)
    }

    func testNewParkingMovesPreviousToHistory() {
        let store = makeStore()
        store.park(at: point(0, 0).coordinate, date: t0, source: .manual)
        store.park(at: point(5000, 0).coordinate, date: t0.addingTimeInterval(7200), source: .speed)
        XCTAssertEqual(store.spots.count, 2)
        XCTAssertEqual(store.spots.filter(\.isActive).count, 1, "una sola auto parcheggiata")
        XCTAssertEqual(store.current?.lon ?? 0, point(5000, 0).lon, accuracy: 1e-9)
        XCTAssertEqual(store.spots[0].retrieved, t0.addingTimeInterval(7200))
    }

    func testAutomaticDuplicateIsIgnored() {
        let store = makeStore()
        store.park(at: point(0, 0).coordinate, date: t0, source: .bluetooth)
        // Poco dopo la velocità rileva lo stesso parcheggio a 40 m.
        XCTAssertNil(store.park(at: point(40, 0).coordinate, date: t0.addingTimeInterval(150), source: .speed))
        XCTAssertEqual(store.spots.count, 1)
        XCTAssertEqual(store.current?.source, .bluetooth)
        // Il pulsante manuale salva sempre.
        XCTAssertNotNil(store.park(at: point(40, 0).coordinate, date: t0.addingTimeInterval(200), source: .manual))
    }

    func testAlreadyLeftGoesOnlyToHistory() {
        let store = makeStore()
        let car = store.park(at: point(0, 0).coordinate, date: t0, source: .manual)
        store.park(at: point(5000, 0).coordinate, date: t0.addingTimeInterval(3600), source: .speed, alreadyLeft: true)
        XCTAssertEqual(store.current?.id, car?.id, "l'auto parcheggiata ora non cambia")
        XCTAssertEqual(store.spots.count, 2)
    }

    func testDepartureNearCarRetrievesIt() {
        let store = makeStore()
        store.park(at: point(0, 0).coordinate, date: t0, source: .speed)
        store.departed(from: point(3000, 0).coordinate, now: t0.addingTimeInterval(600))
        XCTAssertNotNil(store.current, "partito da lontano (es. autobus): l'auto resta lì")
        store.departed(from: point(80, 0).coordinate, now: t0.addingTimeInterval(900))
        XCTAssertNil(store.current)
    }

    func testDeleteRemovesPhoto() throws {
        let store = makeStore()
        let spot = try XCTUnwrap(store.park(at: point(0, 0).coordinate, date: t0, source: .manual))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 1600), format: format).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2400, height: 1600))
        }
        store.setPhoto(image, for: spot.id)
        let saved = try XCTUnwrap(store.current.flatMap(store.image(for:)))
        XCTAssertLessThanOrEqual(max(saved.size.width, saved.size.height), 1600, "foto ridotta")
        let file = store.photosDir.appendingPathComponent(try XCTUnwrap(store.current?.photo))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        store.delete(ids: [spot.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(store.spots.isEmpty)
    }

    func testBackupRoundTripWithPhoto() throws {
        let store = makeStore()
        let spot = try XCTUnwrap(store.park(at: point(0, 0).coordinate, date: t0, source: .manual))
        store.setNote("Colonna B7", for: spot.id)
        store.setPhoto(UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { _ in }, for: spot.id)
        store.park(at: point(9000, 0).coordinate, date: t0.addingTimeInterval(86400), source: .speed)
        let data = try XCTUnwrap(store.backupData())

        // Ripristino su un iPhone "nuovo".
        let otherDir = dir.appendingPathComponent("altro", isDirectory: true)
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        let other = ParkingStore(directory: otherDir, systemServices: false)
        XCTAssertEqual(try other.restore(data), 2)
        XCTAssertEqual(other.spots.first?.note, "Colonna B7")
        XCTAssertNotNil(other.spots.first.flatMap(other.image(for:)), "foto ripristinata")
        XCTAssertEqual(other.spots.filter(\.isActive).count, 1)
        XCTAssertEqual(try other.restore(data), 0, "i parcheggi già presenti vengono saltati")
        // Un backup dei viaggi non è un backup dei parcheggi.
        XCTAssertThrowsError(try other.restore(Data("[]".utf8)))
    }

    // MARK: - Dove avevi trovato posto

    func testHintNearDestination() {
        let store = makeStore()
        let dest = point(0, 0).coordinate
        store.park(at: point(150, 0).coordinate, date: t0, source: .manual)
        store.park(at: point(300, 0, north: 100).coordinate, date: t0.addingTimeInterval(86400), source: .manual)
        store.park(at: point(4000, 0).coordinate, date: t0.addingTimeInterval(2 * 86400), source: .manual)
        store.park(at: point(20000, 0).coordinate, date: t0.addingTimeInterval(3 * 86400), source: .manual)
        let hint = ParkingStore.hint(for: dest, spots: store.spots)
        XCTAssertEqual(hint?.count, 2, "solo i parcheggi entro 400 m")
        XCTAssertEqual(hint?.nearest ?? 0, 150, accuracy: 2)
        XCTAssertEqual(hint?.text, "🅿️ Qui vicino hai già parcheggiato 2 volte · il posto più vicino è a 150 m")
        XCTAssertNil(ParkingStore.hint(for: point(60000, 0).coordinate, spots: store.spots))
    }

    func testCurrentCarIsNotAHint() {
        let store = makeStore()
        store.park(at: point(50, 0).coordinate, date: t0, source: .manual)
        XCTAssertNil(ParkingStore.hint(for: point(0, 0).coordinate, spots: store.spots),
                     "l'auto parcheggiata ora non conta")
        XCTAssertEqual(ParkingHint(count: 1, nearest: 80).text,
                       "🅿️ Qui vicino hai già parcheggiato 1 volta · il posto più vicino è a 80 m")
    }

    // MARK: - Ticket

    func testExpiryPastMidnightMeansTomorrow() {
        let cal = Calendar.current
        let now = cal.date(bySettingHour: 23, minute: 0, second: 0, of: t0)!
        let picked = cal.date(bySettingHour: 1, minute: 0, second: 0, of: t0)!
        let expiry = ParkingStore.normalizedExpiry(picked, now: now)
        XCTAssertEqual(expiry.timeIntervalSince(now), 2 * 3600, accuracy: 1)
        XCTAssertEqual(ParkingStore.normalizedExpiry(now.addingTimeInterval(1800), now: now), now.addingTimeInterval(1800))
    }

    // MARK: - Bluetooth e CarPlay

    func testCarAudioRecognition() {
        XCTAssertTrue(CarAudioMonitor.isCar(.carAudio, name: "CarPlay", carName: ""))
        XCTAssertTrue(CarAudioMonitor.isCar(.bluetoothA2DP, name: "Fiat Panda", carName: "Fiat Panda"))
        XCTAssertTrue(CarAudioMonitor.isCar(.bluetoothHFP, name: "Fiat Panda", carName: "Fiat Panda"))
        XCTAssertFalse(CarAudioMonitor.isCar(.bluetoothA2DP, name: "AirPods", carName: "Fiat Panda"))
        XCTAssertFalse(CarAudioMonitor.isCar(.bluetoothA2DP, name: "AirPods", carName: ""))
        XCTAssertFalse(CarAudioMonitor.isCar(.headphones, name: "Fiat Panda", carName: "Fiat Panda"))
    }
}
