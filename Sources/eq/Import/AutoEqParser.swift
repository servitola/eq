// Vendored from zollans/OnlyEQ @ 6569655 (Unlicense), trimmed for eq.
import Foundation

enum AutoEqParser {
    struct Result: Equatable {
        var filters: [Filter]
        var bands: [Double]?
        var preamp: Double
        var format: String
        var warnings: [String]
    }

    enum ParseError: Error, Equatable, CustomStringConvertible {
        case unrecognized
        case empty

        var description: String {
            switch self {
            case .unrecognized: "Unrecognized EQ format. Supported: AutoEq/Equalizer APO parametric, GraphicEQ."
            case .empty: "No EQ filters found in the input."
            }
        }
    }

    static func parse(_ text: String) throws -> Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.empty }
        if trimmed.contains("GraphicEQ:") { return try parseGraphic(trimmed) }
        return try parseParametric(trimmed)
    }

    // MARK: - Parametric text (AutoEq / Equalizer APO)

    private static let filterLineRegex = try! NSRegularExpression(
        pattern: #"Filter\s*\d+[:\s]\s*(ON|OFF)?\s*([A-Z]+(?:\s+(?:6|12)\s*dB)?)\s+Fc\s+([\d.,]+)\s*k?Hz\s+Gain\s+(-?[\d.,]+)\s*dB(?:\s+(Q|BW\s+Oct)\s+([\d.,]+))?"#,
        options: [.caseInsensitive]
    )
    private static let preampRegex = try! NSRegularExpression(
        pattern: #"Preamp[:\s]\s*(-?[\d.,]+)\s*dB"#, options: [.caseInsensitive]
    )

    static func parseParametric(_ text: String) throws -> Result {
        var filters: [Filter] = []
        var warnings: [String] = []
        var preamp: Double = 0

        for line in text.components(separatedBy: .newlines) {
            let ns = line as NSString
            if let m = preampRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                preamp = parseNumber(ns.substring(with: m.range(at: 1))) ?? 0
                continue
            }
            guard let m = filterLineRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }

            let onOff = m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)).uppercased() : "ON"
            let typeToken = ns.substring(with: m.range(at: 2)).uppercased()
                .replacingOccurrences(of: " ", with: "")
            var fc = parseNumber(ns.substring(with: m.range(at: 3))) ?? 0
            if line.lowercased().contains("khz") { fc *= 1000 }
            let gain = parseNumber(ns.substring(with: m.range(at: 4))) ?? 0

            var q = 0.707
            if m.range(at: 5).location != NSNotFound, m.range(at: 6).location != NSNotFound {
                let qKind = ns.substring(with: m.range(at: 5)).uppercased()
                let value = parseNumber(ns.substring(with: m.range(at: 6))) ?? 0.707
                if qKind.hasPrefix("BW") {
                    let bw = pow(2.0, value)
                    q = sqrt(bw) / (bw - 1)
                } else {
                    q = value
                }
            }

            guard onOff != "OFF" else { continue }
            guard let type = filterType(fromToken: typeToken) else {
                if typeToken == "AP" { warnings.append("Skipped unsupported all-pass filter.") }
                else { warnings.append("Skipped unknown filter type \u{201C}\(typeToken)\u{201D}.") }
                continue
            }
            guard fc > 0 else { continue }
            filters.append(Filter(type: type, frequency: fc, gain: gain, q: q))
        }

        guard !filters.isEmpty else { throw ParseError.unrecognized }
        return Result(filters: filters, bands: nil, preamp: preamp, format: "AutoEq / Equalizer APO parametric", warnings: warnings)
    }

    private static func filterType(fromToken token: String) -> FilterType? {
        switch token {
        case "PK", "PEQ", "MODAL": .peak
        case "LS", "LSC", "LSQ", "LS6DB", "LS12DB": .lowShelf
        case "HS", "HSC", "HSQ", "HS6DB", "HS12DB": .highShelf
        case "LP", "LPQ": .lowPass
        case "HP", "HPQ": .highPass
        case "BP": .bandPass
        case "NO", "NOTCH": .notch
        default: nil
        }
    }

    // MARK: - GraphicEQ

    static func parseGraphic(_ text: String) throws -> Result {
        guard let line = text.components(separatedBy: .newlines).first(where: { $0.contains("GraphicEQ:") }) else {
            throw ParseError.unrecognized
        }
        let payload = line.replacingOccurrences(of: "GraphicEQ:", with: "")
        var points: [(f: Double, g: Double)] = []
        for pair in payload.components(separatedBy: ";") {
            let parts = pair.split(separator: " ").compactMap { parseNumber(String($0)) }
            if parts.count == 2 { points.append((parts[0], parts[1])) }
        }
        guard points.count >= 2 else { throw ParseError.empty }
        points.sort { $0.f < $1.f }

        func interpolate(_ f: Double) -> Double {
            if f <= points[0].f { return points[0].g }
            if f >= points[points.count - 1].f { return points[points.count - 1].g }
            for i in 1..<points.count where points[i].f >= f {
                let (f0, g0) = points[i - 1], (f1, g1) = points[i]
                let t = (log(f) - log(f0)) / (log(f1) - log(f0))
                return g0 + t * (g1 - g0)
            }
            return 0
        }

        let bands = Config.bandFrequencies.map { freq -> Double in
            let value = (interpolate(freq) * 10).rounded() / 10
            return min(max(value, Config.gainRange.lowerBound), Config.gainRange.upperBound)
        }
        let preamp = -(max(0, bands.max() ?? 0) * 10).rounded() / 10
        return Result(
            filters: [],
            bands: bands,
            preamp: preamp,
            format: "GraphicEQ (reduced to 10 bands)",
            warnings: ["GraphicEQ has \(points.count) points; reduced to 10 bands \u{2014} the model's ParametricEQ.txt is exact"]
        )
    }

    private static func parseNumber(_ s: String) -> Double? {
        Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }
}
