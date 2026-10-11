import XCTest
import SwiftUI
import MapKit
@testable import Percorso

final class MapOptionsTests: XCTestCase {
    func testTrafficIsOffByDefault() {
        // Il traffico di Apple usa giallo/arancione/rosso come le strade già fatte: spento di serie.
        let map = MapView(history: HistoryLines(), historyVersion: 0, showHistory: true, currentPoints: [],
                          exploreLines: [], exploreVersion: 0, route: nil, mapType: .standard, place: nil,
                          follow: .constant(true), focus: .constant(nil), zoomRequest: .constant(nil))
        XCTAssertFalse(map.showsTraffic)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        XCTAssertFalse(defaults.bool(forKey: Settings.showTraffic))
    }
}

final class BackupCopyTests: XCTestCase {
    func testCopyNameHasTheDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 12))!
        XCTAssertEqual(BackupManager.copyName(date: date), "Percorso-backup-copia-2026-10-12.json")
        XCTAssertNotEqual(BackupManager.copyName(date: date), BackupManager.fileName,
                          "la copia non deve sovrascrivere il backup")
    }
}
