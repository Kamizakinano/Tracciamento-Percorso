import Foundation

/// Esportazione e importazione dei viaggi in formato GPX.
enum GPX {
    static func export(_ trips: [Trip]) -> String {
        let iso = ISO8601DateFormatter()
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Percorso" xmlns="http://www.topografix.com/GPX/1/1">

        """
        for t in trips {
            out += "<trk><name>\(escape(t.name ?? iso.string(from: t.start)))</name><trkseg>"
            for p in t.points {
                out += "<trkpt lat=\"\(p.lat)\" lon=\"\(p.lon)\"><time>\(iso.string(from: p.time))</time></trkpt>"
            }
            out += "</trkseg></trk>\n"
        }
        out += "</gpx>\n"
        return out
    }

    static func parse(_ data: Data) -> [Trip] {
        let delegate = Parser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.trips
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private final class Parser: NSObject, XMLParserDelegate {
        var trips: [Trip] = []
        private var points: [TrackPoint] = []
        private var name: String?
        private var pending: (lat: Double, lon: Double)?
        private var pendingTime: Date?
        private var text = ""
        private var depthInPoint = false

        private let iso = ISO8601DateFormatter()
        private let isoFrac: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch element {
            case "trk", "rte":
                points = []
                name = nil
            case "trkpt", "rtept":
                if let lat = attributes["lat"].flatMap(Double.init), let lon = attributes["lon"].flatMap(Double.init) {
                    pending = (lat, lon)
                }
                pendingTime = nil
                depthInPoint = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch element {
            case "time" where depthInPoint:
                pendingTime = isoFrac.date(from: value) ?? iso.date(from: value)
            case "name" where !depthInPoint:
                if name == nil && !value.isEmpty { name = value }
            case "trkpt", "rtept":
                if let p = pending {
                    points.append(TrackPoint(lat: p.lat, lon: p.lon, time: pendingTime ?? Date()))
                }
                pending = nil
                depthInPoint = false
            case "trk", "rte":
                if points.count > 1 {
                    trips.append(Trip(name: name, start: points[0].time, end: points[points.count - 1].time, points: points))
                }
                points = []
            default:
                break
            }
            text = ""
        }
    }
}
