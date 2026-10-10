import SwiftUI
import MapKit

/// Mappa con le strade già percorse (arancione) e il viaggio in corso (blu).
struct MapView: UIViewRepresentable {
    let trips: [Trip]
    let historyVersion: Int
    let showHistory: Bool
    let currentPoints: [TrackPoint]
    @Binding var follow: Bool
    @Binding var focus: Trip?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = true
        map.showsScale = true
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        c.parent = self

        let historyKey = "\(historyVersion)-\(showHistory)"
        if c.historyKey != historyKey {
            map.removeOverlays(c.historyOverlays)
            c.historyOverlays = showHistory ? trips.compactMap { Self.polyline($0.points, kind: Coordinator.history) } : []
            map.addOverlays(c.historyOverlays, level: .aboveRoads)
            if c.historyKey == nil && !follow { Self.fit(map, points: trips.flatMap(\.points)) }
            c.historyKey = historyKey
        }

        if c.currentCount != currentPoints.count {
            if let old = c.currentOverlay { map.removeOverlay(old) }
            c.currentOverlay = Self.polyline(currentPoints, kind: Coordinator.current)
            if let new = c.currentOverlay { map.addOverlay(new, level: .aboveRoads) }
            c.currentCount = currentPoints.count
        }

        if let trip = focus {
            map.setUserTrackingMode(.none, animated: false)
            Self.fit(map, points: trip.points)
            DispatchQueue.main.async {
                follow = false
                focus = nil
            }
        } else {
            let mode: MKUserTrackingMode = follow ? .follow : .none
            if map.userTrackingMode != mode { map.setUserTrackingMode(mode, animated: true) }
        }
    }

    private static func polyline(_ points: [TrackPoint], kind: String) -> MKPolyline? {
        guard points.count > 1 else { return nil }
        let coords = points.map(\.coordinate)
        let line = MKPolyline(coordinates: coords, count: coords.count)
        line.title = kind
        return line
    }

    private static func fit(_ map: MKMapView, points: [TrackPoint]) {
        guard !points.isEmpty else { return }
        var rect = MKMapRect.null
        for p in points {
            let mp = MKMapPoint(p.coordinate)
            rect = rect.union(MKMapRect(x: mp.x, y: mp.y, width: 1, height: 1))
        }
        map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 80, left: 40, bottom: 120, right: 40), animated: true)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        static let history = "history"
        static let current = "current"

        var parent: MapView
        var historyKey: String?
        var historyOverlays: [MKOverlay] = []
        var currentOverlay: MKPolyline?
        var currentCount = -1

        init(_ parent: MapView) { self.parent = parent }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: line)
            r.lineCap = .round
            r.lineJoin = .round
            if line.title == Self.current {
                r.strokeColor = .systemBlue
                r.lineWidth = 5
            } else {
                r.strokeColor = UIColor.systemOrange.withAlphaComponent(0.55)
                r.lineWidth = 9
            }
            return r
        }

        func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            // L'utente ha spostato la mappa a mano: smetti di seguirlo.
            if mode == .none && parent.follow {
                DispatchQueue.main.async { self.parent.follow = false }
            }
        }
    }
}
