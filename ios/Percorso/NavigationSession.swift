import Foundation
import CoreLocation

/// Navigazione svolta per svolta dentro l'app: segue la posizione lungo il
/// percorso, annuncia le svolte a voce e ricalcola se esci dal percorso.
final class NavigationSession: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var route: RouteOption?
    @Published private(set) var destination: Place?
    /// Indice del passo con la prossima svolta.
    @Published private(set) var stepIndex = 0
    @Published private(set) var distanceToManeuver = 0.0
    @Published private(set) var remainingDistance = 0.0
    @Published private(set) var remainingTime: TimeInterval = 0
    @Published private(set) var arrived = false
    @Published private(set) var rerouting = false
    private(set) var mode: TravelMode = .car

    /// La registrazione è stata avviata dalla navigazione (va fermata alla fine).
    var startedRecording = false
    var voiceEnabled = true
    /// Sostituisce il ricalcolo del percorso (usato nei test).
    var rerouteHandler: ((CLLocationCoordinate2D) -> Void)?

    private let store: TripStore?
    private var offRouteCount = 0
    private var lastReroute = Date.distantPast
    private var spokenFar = Set<Int>()
    private var spokenNear = Set<Int>()
    private var task: Task<Void, Never>?

    init(store: TripStore?) {
        self.store = store
    }

    var steps: [RouteStep] { route?.steps ?? [] }
    var currentStep: RouteStep? { steps.indices.contains(stepIndex) ? steps[stepIndex] : nil }

    var instruction: String {
        if arrived { return "Sei arrivato a destinazione" }
        if let text = currentStep?.instruction, !text.isEmpty { return text }
        return "Prosegui sul percorso"
    }

    var maneuverIcon: String { arrived ? "flag.checkered" : Self.icon(for: currentStep?.instruction ?? "") }

    // MARK: - Distanze in base al mezzo

    private var arriveRadius: Double { mode == .car ? 40 : 20 }
    private var passRadius: Double { mode == .car ? 35 : (mode == .bike ? 20 : 15) }
    private var offRouteRadius: Double { mode == .car ? 60 : 35 }
    private var farAnnounce: Double { mode == .car ? 400 : (mode == .bike ? 150 : 80) }
    private var nearAnnounce: Double { mode == .car ? 60 : (mode == .bike ? 30 : 20) }

    // MARK: - Comandi

    func start(route: RouteOption, destination: Place, mode: TravelMode) {
        self.mode = mode
        self.destination = destination
        isActive = true
        arrived = false
        rerouting = false
        replaceRoute(route)
        speak("Percorso avviato. \(instruction)")
    }

    func stop() {
        task?.cancel()
        isActive = false
        route = nil
        destination = nil
        arrived = false
        rerouting = false
    }

    func replaceRoute(_ newRoute: RouteOption) {
        route = newRoute
        stepIndex = Self.firstManeuver(in: newRoute.steps)
        spokenFar = []
        spokenNear = []
        offRouteCount = 0
        remainingDistance = newRoute.distance
        remainingTime = newRoute.time
        distanceToManeuver = 0
    }

    /// Il primo passo di Apple è spesso vuoto (il punto di partenza).
    static func firstManeuver(in steps: [RouteStep]) -> Int {
        steps.firstIndex { !$0.instruction.isEmpty } ?? 0
    }

    // MARK: - Aggiornamento con la posizione

    func update(_ location: CLLocation) {
        guard isActive, !arrived, let route else { return }
        let p = location.coordinate

        if let destination, Geo.distance(p, destination.coordinate) < arriveRadius {
            arrived = true
            distanceToManeuver = 0
            remainingDistance = 0
            remainingTime = 0
            speak("Sei arrivato a destinazione")
            return
        }

        // Svolta superata: passa alla successiva.
        while stepIndex < steps.count - 1,
              let point = steps[stepIndex].coords.first,
              Geo.distance(p, point) < passRadius {
            stepIndex += 1
        }

        let maneuverPoint = currentStep?.coords.first ?? destination?.coordinate
        distanceToManeuver = maneuverPoint.map { Geo.distance(p, $0) } ?? 0
        let after = steps.indices.contains(stepIndex) ? steps[stepIndex...].reduce(0) { $0 + $1.distance } : 0
        remainingDistance = distanceToManeuver + after
        remainingTime = route.distance > 0 ? route.time * remainingDistance / route.distance : 0

        // Fuori percorso per 3 letture di fila: ricalcola (al massimo ogni 15 secondi).
        let off = Geo.distance(from: p, toPolyline: route.coords)
        if location.horizontalAccuracy <= 40 && off > offRouteRadius {
            offRouteCount += 1
        } else {
            offRouteCount = 0
        }
        if offRouteCount >= 3 && Date().timeIntervalSince(lastReroute) > 15 {
            reroute(from: p)
        }

        announce()
    }

    private func announce() {
        guard currentStep != nil else { return }
        let i = stepIndex
        let d = distanceToManeuver
        if d <= nearAnnounce, !spokenNear.contains(i) {
            spokenNear.insert(i)
            spokenFar.insert(i)
            speak(instruction)
        } else if d <= farAnnounce, d > nearAnnounce * 1.5, !spokenFar.contains(i) {
            spokenFar.insert(i)
            speak("Tra \(Geo.formatShort(d)), \(instruction)")
        }
    }

    private func speak(_ text: String) {
        guard voiceEnabled, Settings.navigationVoiceOn else { return }
        VoiceAlert.shared.speak(text)
    }

    private func reroute(from p: CLLocationCoordinate2D) {
        offRouteCount = 0
        lastReroute = Date()
        if let rerouteHandler {
            rerouteHandler(p)
            return
        }
        guard let destination else { return }
        rerouting = true
        speak("Ricalcolo del percorso")
        let mode = self.mode
        let index = store?.index ?? SpatialIndex()
        task?.cancel()
        task = Task {
            let routes = await RoutePlanner.candidates(from: p, to: destination.coordinate, mode: mode)
            let ranked = RoutePlanner.rank(routes, index: index, within: Settings.threshold(for: mode))
            await MainActor.run {
                self.rerouting = false
                if self.isActive, let best = ranked.first { self.replaceRoute(best) }
            }
        }
    }

    // MARK: - Icona della svolta

    static func icon(for instruction: String) -> String {
        let t = instruction.lowercased()
        func has(_ words: String...) -> Bool { words.contains { t.contains($0) } }
        if has("inversione", "u-turn", "make a u") { return "arrow.uturn.down" }
        if has("rotonda", "roundabout", "rotatoria") { return "arrow.triangle.turn.up.right.circle" }
        if has("destinazione", "arriv", "destination") { return "flag.checkered" }
        if has("leggermente a sinistra", "slight left", "tieni la sinistra", "keep left") { return "arrow.up.left" }
        if has("leggermente a destra", "slight right", "tieni la destra", "keep right") { return "arrow.up.right" }
        if has("sinistra", "left") { return "arrow.turn.up.left" }
        if has("destra", "right") { return "arrow.turn.up.right" }
        if has("uscita", "exit") { return "arrow.up.right" }
        return "arrow.up"
    }
}
