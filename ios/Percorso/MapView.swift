import SwiftUI
import MapKit

/// Mappa con le strade già percorse (colorate per frequenza), il viaggio in corso (blu),
/// le strade nuove della zona (verde) e il percorso consigliato (viola).
struct MapView: UIViewRepresentable {
    let history: HistoryLines
    let historyVersion: Int
    let showHistory: Bool
    let currentPoints: [TrackPoint]
    let exploreLines: [[CLLocationCoordinate2D]]
    let exploreVersion: Int
    let route: RouteOption?
    let mapType: MKMapType
    let place: Place?
    @Binding var follow: Bool
    @Binding var focus: Trip?
    /// Regione da mostrare (per esempio quando si attivano le strade nuove).
    @Binding var zoomRequest: MKCoordinateRegion?
    var onRegionChange: (MKCoordinateRegion) -> Void = { _ in }
    var onUserLocation: (CLLocationCoordinate2D) -> Void = { _ in }

    /// Colori per numero di passaggi: 1 · 2-3 · 4 o più.
    static let levelColors: [UIColor] = [.systemYellow, .systemOrange, .systemRed]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = true
        map.showsScale = true
        // Lascia spazio ai pulsanti sopra e sotto la mappa.
        map.layoutMargins = UIEdgeInsets(top: 60, left: 8, bottom: 90, right: 70)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        c.parent = self

        if map.mapType != mapType { map.mapType = mapType }

        let historyKey = "\(historyVersion)-\(showHistory)"
        if c.historyKey != historyKey {
            map.removeOverlays(c.historyOverlays)
            c.historyOverlays = []
            if showHistory {
                for (level, lines) in history.levels.enumerated() where !lines.isEmpty {
                    let multi = MKMultiPolyline(lines.map { MKPolyline(coordinates: $0, count: $0.count) })
                    multi.title = "h\(level)"
                    c.historyOverlays.append(multi)
                }
            }
            map.addOverlays(c.historyOverlays, level: .aboveRoads)
            // Prima apertura: inquadra tutti i viaggi (dopo che la mappa ha preso le sue dimensioni).
            if !c.didInitialFit && !follow && !history.levels.allSatisfy(\.isEmpty) {
                c.didInitialFit = true
                let all = history.levels.flatMap { $0 }.flatMap { $0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { Self.fit(map, coords: all) }
            }
            c.historyKey = historyKey
        }

        if c.exploreVersion != exploreVersion {
            if let old = c.exploreOverlay { map.removeOverlay(old) }
            c.exploreOverlay = nil
            if !exploreLines.isEmpty {
                let multi = MKMultiPolyline(exploreLines.map { MKPolyline(coordinates: $0, count: $0.count) })
                multi.title = Coordinator.explore
                map.addOverlay(multi, level: .aboveRoads)
                c.exploreOverlay = multi
            }
            c.exploreVersion = exploreVersion
        }

        if c.routeID != route?.id {
            if let old = c.routeOverlay { map.removeOverlay(old) }
            c.routeOverlay = nil
            c.routeID = route?.id
            if let route, route.coords.count > 1 {
                let line = MKPolyline(coordinates: route.coords, count: route.coords.count)
                line.title = Coordinator.route
                map.addOverlay(line, level: .aboveLabels)
                c.routeOverlay = line
                map.setUserTrackingMode(.none, animated: false)
                Self.fit(map, coords: route.coords)
                DispatchQueue.main.async { follow = false }
                return
            }
        }

        if c.currentCount != currentPoints.count {
            if let old = c.currentOverlay { map.removeOverlay(old) }
            c.currentOverlay = nil
            if currentPoints.count > 1 {
                let coords = currentPoints.map(\.coordinate)
                let line = MKPolyline(coordinates: coords, count: coords.count)
                line.title = Coordinator.current
                map.addOverlay(line, level: .aboveRoads)
                c.currentOverlay = line
            }
            c.currentCount = currentPoints.count
        }

        if c.placeID != place?.id {
            if let old = c.placeAnnotation { map.removeAnnotation(old) }
            c.placeAnnotation = nil
            c.placeID = place?.id
            if let place {
                let pin = MKPointAnnotation()
                pin.coordinate = place.coordinate
                pin.title = place.name
                map.addAnnotation(pin)
                map.selectAnnotation(pin, animated: true)
                c.placeAnnotation = pin
                map.setUserTrackingMode(.none, animated: false)
                map.setRegion(MKCoordinateRegion(center: place.coordinate, latitudinalMeters: 1500, longitudinalMeters: 1500),
                              animated: true)
                DispatchQueue.main.async { follow = false }
                return
            }
        }

        if let region = zoomRequest {
            map.setUserTrackingMode(.none, animated: false)
            map.setRegion(region, animated: true)
            DispatchQueue.main.async {
                follow = false
                zoomRequest = nil
            }
            return
        }

        if let trip = focus {
            map.setUserTrackingMode(.none, animated: false)
            Self.fit(map, coords: trip.points.map(\.coordinate))
            DispatchQueue.main.async {
                follow = false
                focus = nil
            }
        } else {
            let mode: MKUserTrackingMode = follow ? .follow : .none
            if map.userTrackingMode != mode { map.setUserTrackingMode(mode, animated: true) }
        }
    }

    private static func fit(_ map: MKMapView, coords: [CLLocationCoordinate2D]) {
        guard !coords.isEmpty else { return }
        var rect = MKMapRect.null
        for c in coords {
            let mp = MKMapPoint(c)
            rect = rect.union(MKMapRect(x: mp.x, y: mp.y, width: 1, height: 1))
        }
        map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 120, left: 40, bottom: 200, right: 70), animated: true)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        static let current = "current"
        static let explore = "explore"
        static let route = "route"

        var parent: MapView
        var historyKey: String?
        var historyOverlays: [MKOverlay] = []
        var didInitialFit = false
        var exploreVersion = -1
        var exploreOverlay: MKOverlay?
        var routeID: UUID?
        var routeOverlay: MKOverlay?
        var currentOverlay: MKPolyline?
        var currentCount = -1
        var placeID: UUID?
        var placeAnnotation: MKPointAnnotation?

        init(_ parent: MapView) { self.parent = parent }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let multi = overlay as? MKMultiPolyline {
                let r = MKMultiPolylineRenderer(multiPolyline: multi)
                r.lineCap = .round
                r.lineJoin = .round
                if multi.title == Self.explore {
                    r.strokeColor = UIColor.systemGreen.withAlphaComponent(0.9)
                    r.lineWidth = 3.5
                    r.lineDashPattern = [6, 5]
                } else {
                    let level = Int(multi.title?.dropFirst() ?? "0") ?? 0
                    r.strokeColor = MapView.levelColors[min(level, 2)].withAlphaComponent(0.7)
                    r.lineWidth = 9
                }
                return r
            }
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: line)
            r.lineCap = .round
            r.lineJoin = .round
            if line.title == Self.route {
                r.strokeColor = UIColor.systemPurple.withAlphaComponent(0.9)
                r.lineWidth = 7
            } else {
                r.strokeColor = .systemBlue
                r.lineWidth = 5
            }
            return r
        }

        func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            // L'utente ha spostato la mappa a mano: smetti di seguirlo.
            if mode == .none && parent.follow {
                DispatchQueue.main.async { self.parent.follow = false }
            }
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            if let loc = userLocation.location { parent.onUserLocation(loc.coordinate) }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            parent.onRegionChange(mapView.region)
        }
    }
}
