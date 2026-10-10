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
    /// Itinerario con i mezzi pubblici da mostrare (al posto di `route`).
    var transit: TransitItinerary? = nil
    /// Risultati di una ricerca (es. tutti i Lidl della zona).
    var results: [Place] = []
    var resultsVersion = 0
    /// Inquadra i risultati (no quando si cerca nella zona già visibile).
    var fitResults = true
    /// Auto parcheggiata e parcheggi passati vicino alla destinazione.
    var parking: ParkingSpot? = nil
    var parkingHints: [ParkingSpot] = []
    let mapType: MKMapType
    let place: Place?
    /// Navigazione in corso: mappa inclinata che segue la direzione di marcia.
    var navigating = false
    @Binding var follow: Bool
    @Binding var focus: Trip?
    /// Regione da mostrare (per esempio quando si attivano le strade nuove).
    @Binding var zoomRequest: MKCoordinateRegion?
    var onRegionChange: (MKCoordinateRegion) -> Void = { _ in }
    var onUserLocation: (CLLocationCoordinate2D) -> Void = { _ in }
    /// Tocco sul pulsante "percorso" nel fumetto di un risultato.
    var onSelectResult: (Place) -> Void = { _ in }
    /// Tocco sul segnaposto dell'auto.
    var onSelectParking: () -> Void = {}

    /// Colori per numero di passaggi: 1 · 2-3 · 4 o più.
    static let levelColors: [UIColor] = [.systemYellow, .systemOrange, .systemRed]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = true
        map.showsScale = true
        map.showsTraffic = true
        map.showsBuildings = true
        // Lascia spazio ai pulsanti sopra e sotto la mappa.
        map.layoutMargins = UIEdgeInsets(top: 60, left: 8, bottom: 90, right: 70)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        c.parent = self

        // In navigazione la mappa standard diventa più tenue, così il percorso risalta.
        let type: MKMapType = navigating && mapType == .standard ? .mutedStandard : mapType
        if map.mapType != type { map.mapType = type }

        if c.wasNavigating != navigating {
            c.wasNavigating = navigating
            c.programmaticChange = true
            let camera = map.camera.copy() as! MKMapCamera
            camera.pitch = navigating ? 55 : 0
            if navigating, let user = map.userLocation.location {
                camera.centerCoordinate = user.coordinate
                camera.centerCoordinateDistance = 700
            }
            map.setCamera(camera, animated: false)
            map.setUserTrackingMode(navigating ? .followWithHeading : (follow ? .follow : .none), animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { c.programmaticChange = false }
        }

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

        let parkingKey = parking.map { "\($0.id)-\($0.lat)-\($0.lon)-\($0.address ?? "")" } ?? ""
        if c.parkingKey != parkingKey {
            if let old = c.parkingAnnotation { map.removeAnnotation(old) }
            c.parkingAnnotation = parking.map { ParkingAnnotation(spot: $0, isCar: true) }
            if let a = c.parkingAnnotation { map.addAnnotation(a) }
            c.parkingKey = parkingKey
        }
        let hintsKey = parkingHints.map(\.id.uuidString).joined()
        if c.hintsKey != hintsKey {
            map.removeAnnotations(c.hintAnnotations)
            c.hintAnnotations = parkingHints.map { ParkingAnnotation(spot: $0, isCar: false) }
            map.addAnnotations(c.hintAnnotations)
            c.hintsKey = hintsKey
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
                if !navigating {
                    map.setUserTrackingMode(.none, animated: false)
                    Self.fit(map, coords: route.coords)
                    DispatchQueue.main.async { follow = false }
                    return
                }
            }
        }

        if c.resultsVersion != resultsVersion {
            map.removeAnnotations(c.resultAnnotations)
            c.resultAnnotations = results.map { ResultAnnotation(place: $0) }
            map.addAnnotations(c.resultAnnotations)
            c.resultsVersion = resultsVersion
            if !results.isEmpty && fitResults {
                map.setUserTrackingMode(.none, animated: false)
                var coords = results.map(\.coordinate)
                if let user = map.userLocation.location?.coordinate { coords.append(user) }
                Self.fit(map, coords: coords)
                DispatchQueue.main.async { follow = false }
                return
            }
        }

        if c.transitID != transit?.id {
            map.removeOverlays(c.transitOverlays)
            c.transitOverlays = []
            c.transitID = transit?.id
            if let transit {
                for leg in transit.legs where leg.coords.count > 1 {
                    let line = ColoredPolyline(coordinates: leg.coords, count: leg.coords.count)
                    line.color = leg.uiColor
                    line.dashed = leg.isWalk
                    c.transitOverlays.append(line)
                }
                map.addOverlays(c.transitOverlays, level: .aboveLabels)
                map.setUserTrackingMode(.none, animated: false)
                Self.fit(map, coords: transit.legs.flatMap(\.coords))
                DispatchQueue.main.async { follow = false }
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
                c.placeAnnotation = pin
            }
            if let place, !navigating {
                map.selectAnnotation(c.placeAnnotation!, animated: true)
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
            let mode: MKUserTrackingMode = follow ? (navigating ? .followWithHeading : .follow) : .none
            if map.userTrackingMode != mode {
                c.programmaticChange = true
                map.setUserTrackingMode(mode, animated: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { c.programmaticChange = false }
            }
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
        var transitID: UUID?
        var resultsVersion = 0
        var resultAnnotations: [ResultAnnotation] = []
        var parkingKey = ""
        var parkingAnnotation: ParkingAnnotation?
        var hintsKey = ""
        var hintAnnotations: [ParkingAnnotation] = []
        var transitOverlays: [MKOverlay] = []
        var currentCount = -1
        var placeID: UUID?
        var placeAnnotation: MKPointAnnotation?
        var wasNavigating = false
        /// Cambi di inquadratura fatti dall'app (non dall'utente).
        var programmaticChange = false

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
            if let colored = overlay as? ColoredPolyline {
                let r = MKPolylineRenderer(polyline: colored)
                r.lineCap = .round
                r.lineJoin = .round
                r.strokeColor = colored.color
                r.lineWidth = colored.dashed ? 4 : 7
                if colored.dashed { r.lineDashPattern = [2, 8] }
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
            if mode == .none && parent.follow && !programmaticChange {
                DispatchQueue.main.async { self.parent.follow = false }
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let spot = annotation as? ParkingAnnotation {
                let id = spot.isCar ? "car" : "parkingHint"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: spot, reuseIdentifier: id)
                view.annotation = spot
                if spot.isCar {
                    view.markerTintColor = .systemBlue
                    view.glyphImage = UIImage(systemName: "car.fill")
                    view.displayPriority = .required
                    view.canShowCallout = false
                } else {
                    view.markerTintColor = .systemTeal
                    view.glyphText = "P"
                    view.glyphImage = nil
                    view.displayPriority = .required
                    view.canShowCallout = true
                }
                return view
            }
            if let pin = annotation as? MKPointAnnotation {
                // Destinazione: sempre visibile, anche vicino ai segnaposto dei parcheggi.
                let id = "place"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: pin, reuseIdentifier: id)
                view.annotation = pin
                view.displayPriority = .required
                view.canShowCallout = true
                return view
            }
            guard let result = annotation as? ResultAnnotation else { return nil }
            let id = "result"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: result, reuseIdentifier: id)
            view.annotation = result
            view.markerTintColor = .systemIndigo
            view.glyphImage = UIImage(systemName: "bag.fill")
            view.canShowCallout = true
            view.displayPriority = .required
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: "arrow.triangle.turn.up.right.circle.fill"), for: .normal)
            button.frame = CGRect(x: 0, y: 0, width: 36, height: 36)
            view.rightCalloutAccessoryView = button
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let spot = view.annotation as? ParkingAnnotation, spot.isCar else { return }
            mapView.deselectAnnotation(spot, animated: false)
            parent.onSelectParking()
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
            if let result = view.annotation as? ResultAnnotation { parent.onSelectResult(result.place) }
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            if let loc = userLocation.location { parent.onUserLocation(loc.coordinate) }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // La posizione può non cambiare mai (per esempio da fermi): passala comunque.
            if let loc = mapView.userLocation.location { parent.onUserLocation(loc.coordinate) }
            parent.onRegionChange(mapView.region)
        }
    }
}

/// Linea con colore e stile propri (tratti dell'itinerario con i mezzi).
final class ColoredPolyline: MKPolyline {
    var color: UIColor = .systemPurple
    var dashed = false
}

/// Segnaposto di un risultato della ricerca.
final class ResultAnnotation: NSObject, MKAnnotation {
    let place: Place
    var coordinate: CLLocationCoordinate2D { place.coordinate }
    var title: String? { place.name }
    var subtitle: String? { place.address }

    init(place: Place) { self.place = place }
}

/// Segnaposto dell'auto parcheggiata (o di un parcheggio passato).
final class ParkingAnnotation: NSObject, MKAnnotation {
    let spot: ParkingSpot
    let isCar: Bool
    var coordinate: CLLocationCoordinate2D { spot.coordinate }
    var title: String? { isCar ? "La tua auto" : spot.title }
    var subtitle: String? {
        isCar ? spot.address : "Parcheggiato il \(spot.date.formatted(date: .abbreviated, time: .omitted))"
    }

    init(spot: ParkingSpot, isCar: Bool) {
        self.spot = spot
        self.isCar = isCar
    }
}
