import Foundation
struct ExtractedLabMarker: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var value: String
    var unit: String
    var referenceRange: String?
    var isNormal: Bool
}


enum LabsMarkerCatalog {
    private static let knownMarkers: [String: (aliases: [String], unit: String, low: Double?, high: Double?)] = [
        "Hemoglobin": (["hemoglobin", "hgb"], "g/dL", 12.0, 17.5),
        "WBC": (["wbc", "white blood cells", "leukocytes"], "10^3/uL", 4.0, 11.0),
        "RBC": (["rbc", "red blood cells"], "10^6/uL", 4.0, 6.0),
        "Platelets": (["platelets", "plt"], "10^3/uL", 150.0, 450.0),
        "Glucose": (["glucose"], "mg/dL", 70.0, 100.0),
        "Creatinine": (["creatinine"], "mg/dL", 0.6, 1.3),
        "ALT": (["alt"], "U/L", 0.0, 55.0),
        "AST": (["ast"], "U/L", 0.0, 40.0),
        "Ferritin": (["ferritin"], "ng/mL", 30.0, 400.0),
        "TSH": (["tsh"], "uIU/mL", 0.4, 4.0),
        "Vitamin D": (["vitamin d", "25-oh vitamin d"], "ng/mL", 30.0, 100.0),
        "Vitamin B12": (["vitamin b12", "b12"], "pg/mL", 200.0, 900.0),
        "HbA1c": (["hba1c", "hb a1c"], "%", 4.0, 5.6),
        "CRP": (["crp", "c-reactive protein"], "mg/L", 0.0, 5.0),
    ]

    private static let lineRegex: NSRegularExpression? = {
        do {
            return try NSRegularExpression(
                pattern: #"(?i)^([a-z][a-z0-9 %()/+\-._]{1,50}?)[:\s]+([<>]?\d+(?:[.,]\d+)?)\s*([a-zµμ%/^0-9]+(?:/[a-zµμ^0-9]+)?)?(?:\s*\(?(\d+(?:[.,]\d+)?\s*[-–]\s*\d+(?:[.,]\d+)?)\)?)?$"#,
                options: []
            )
        } catch {
            assertionFailure("Invalid lab marker regex: \(error)")
            return nil
        }
    }()

    static func extractMarkers(from text: String) -> [ExtractedLabMarker] {
        let separators = CharacterSet.newlines.union(CharacterSet(charactersIn: ";"))
        let lines = text
            .components(separatedBy: separators)
            .flatMap { $0.components(separatedBy: ",") }
            .map { $0.replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 3 }

        var markers: [ExtractedLabMarker] = []
        var seen = Set<String>()

        for line in lines {
            guard let marker = parseMarker(from: line) else { continue }
            let key = "\(marker.name)|\(marker.value)|\(marker.unit)"
            guard seen.insert(key).inserted else { continue }
            markers.append(marker)
        }

        return markers
    }

    static func markerIdentifier(for name: String) -> String {
        name
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
    }

    static func bounds(for marker: ExtractedLabMarker) -> (low: Double?, high: Double?) {
        if let referenceRange = marker.referenceRange {
            let parts = referenceRange
                .replacingOccurrences(of: "–", with: "-")
                .components(separatedBy: "-")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if parts.count == 2,
               let low = Double(parts[0].replacingOccurrences(of: ",", with: ".")),
               let high = Double(parts[1].replacingOccurrences(of: ",", with: ".")) {
                return (low, high)
            }
        }

        if let catalogEntry = matchedCatalogEntry(for: marker.name) {
            return (catalogEntry.low, catalogEntry.high)
        }
        return (nil, nil)
    }

    private static func parseMarker(from line: String) -> ExtractedLabMarker? {
        guard let lineRegex else { return nil }
        let nsLine = line as NSString
        let matchRange = NSRange(location: 0, length: nsLine.length)
        if let match = lineRegex.firstMatch(in: line, options: [], range: matchRange) {
            let rawName = nsLine.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = nsLine.substring(with: match.range(at: 2)).replacingOccurrences(of: ",", with: ".")
            let catalogEntry = matchedCatalogEntry(for: rawName)
            let rawUnit = match.range(at: 3).location == NSNotFound
                ? (catalogEntry?.unit ?? "")
                : nsLine.substring(with: match.range(at: 3))
            let reference = match.range(at: 4).location == NSNotFound
                ? catalogEntry.flatMap { entry in
                    if let low = entry.low, let high = entry.high {
                        return "\(low)-\(high)"
                    }
                    return nil
                }
                : nsLine.substring(with: match.range(at: 4))

            guard Double(rawValue) != nil else { return nil }

            let markerName = canonicalName(for: rawName)
            let marker = ExtractedLabMarker(
                id: UUID(),
                name: markerName,
                value: rawValue,
                unit: rawUnit,
                referenceRange: reference,
                isNormal: isNormal(value: rawValue, markerName: markerName, referenceRange: reference)
            )
            return marker
        }

        return nil
    }

    private static func canonicalName(for rawName: String) -> String {
        matchedCatalogEntry(for: rawName).map(\.name) ?? rawName.capitalized
    }

    private static func isNormal(value: String, markerName: String, referenceRange: String?) -> Bool {
        guard let numericValue = Double(value.replacingOccurrences(of: ",", with: ".")) else { return true }
        let parsedRange: (Double, Double)? = {
            guard let referenceRange else { return nil }
            let parts = referenceRange
                .replacingOccurrences(of: "–", with: "-")
                .components(separatedBy: "-")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2,
                  let low = Double(parts[0].replacingOccurrences(of: ",", with: ".")),
                  let high = Double(parts[1].replacingOccurrences(of: ",", with: ".")) else {
                return nil
            }
            return (low, high)
        }()

        if let parsedRange {
            return numericValue >= parsedRange.0 && numericValue <= parsedRange.1
        }

        if let catalogEntry = matchedCatalogEntry(for: markerName),
           let low = catalogEntry.low,
           let high = catalogEntry.high {
            return numericValue >= low && numericValue <= high
        }

        return true
    }

    private static func matchedCatalogEntry(for name: String) -> (name: String, unit: String, low: Double?, high: Double?)? {
        let normalized = name.lowercased()
        for (canonicalName, entry) in knownMarkers {
            if normalized.contains(canonicalName.lowercased()) || entry.aliases.contains(where: normalized.contains) {
                return (canonicalName, entry.unit, entry.low, entry.high)
            }
        }
        return nil
    }
}

for input in ["Glucose 5,6 mmol/L", "Glucose 5.6 mmol/L", "Глюкоза 5,6 ммоль/л", "Ferritin 85,5 ng/mL"] { print(input, "=>", LabsMarkerCatalog.extractMarkers(from: input).map { "\($0.name)=\($0.value) \($0.unit) ref=\($0.referenceRange ?? "nil") normal=\($0.isNormal)" }) }
