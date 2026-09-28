import Foundation

/// The checks every structured format shares before a number from a file becomes part of a curve.
enum ImportCheck {
    /// JSON text, or nil; a plain-text format must not pay for a JSON parse, so the first character decides.
    static func json(_ data: Data) -> Any? {
        guard let text = ImportText.decode(data) else { return nil }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.hasPrefix("{") || body.hasPrefix("[") else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(body.utf8))
    }

    /// A JSON number that is finite. JSONSerialization hands `true` back as a number too, and a flag
    /// is never a frequency.
    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    static func flag(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    /// `Int(exactly:)`, not `Int(_:)`: the latter traps on a value like 1e300.
    static func integer(_ value: Double?) -> Int? {
        guard let value, abs(value) < 1e9 else { return nil }
        return Int(exactly: value)
    }

    static func filter(_ type: FilterType, frequency: Double, gain: Double, q: Double) -> APOFormat.FilterLine {
        guard frequency.isFinite, Config.filterFrequencyRange.contains(frequency) else {
            return .skipped(outside("frequency", frequency, "Hz", Config.filterFrequencyRange))
        }
        guard gain.isFinite, Config.filterGainRange.contains(gain) else {
            return .skipped(outside("gain", gain, "dB", Config.filterGainRange))
        }
        guard q.isFinite, Config.filterQRange.contains(q) else { return .skipped(outside("Q", q, "", Config.filterQRange)) }
        let result = Filter(type: type, frequency: frequency, gain: gain, q: q)
        guard Config.firstUnstableFilter([result], sampleRate: Config.stabilityCheckRate) == nil else {
            return .skipped("it would be unstable at \(Int(Config.stabilityCheckRate / 1000)) kHz")
        }
        return .filter(result)
    }

    static func outside(_ what: String, _ value: Double, _ unit: String, _ range: ClosedRange<Double>) -> String {
        let suffix = unit.isEmpty ? "" : " \(unit)"
        return String(format: "%@ %g%@ is outside %g–%g%@", what, value, suffix, range.lowerBound, range.upperBound, suffix)
    }

    /// RBJ's shelf slope S from a slope in dB per octave, as APO's `LSC x dB` and CamillaDSP's
    /// `slope` both read it: S = slope / 12.
    static func shelfQ(slope: Double, gain: Double) -> Double? {
        let s = slope / 12, a = pow(10, gain / 40)
        let radicand = (a + 1 / a) * (1 / s - 1) + 2
        guard s > 0, radicand > 0 else { return nil }
        return 1 / radicand.squareRoot()
    }

    /// Gains on a graphic equaliser's own centres. Ten on ours are the ten bands; any other set is
    /// reduced to ten the way a GraphicEQ line is. Gains beyond the bands' range stay ten peaks
    /// instead, so the curve still sounds as the file meant.
    static func graphic(_ points: [(frequency: Double, gain: Double)], warnings: inout [String]) -> (bands: [Double]?, filters: [Filter]) {
        let asPeaks = points.map { Filter(type: .peak, frequency: $0.frequency, gain: $0.gain, q: APOFormat.fixedBandQ) }
        if let bands = APOFormat.fixedBands(asPeaks) { return (bands, []) }
        if onOurCentres(points.map(\.frequency)) {
            warnings.append(String(format: "gains beyond ±%g dB do not fit the ten bands; imported as ten peak filters", Config.gainRange.upperBound))
            var filters: [Filter] = []
            for peak in asPeaks.sorted(by: { $0.frequency < $1.frequency }) where peak.gain != 0 {
                switch filter(peak.type, frequency: peak.frequency, gain: peak.gain, q: peak.q) {
                case .filter(let f): filters.append(f)
                case .silent: break
                case .skipped(let why): warnings.append("skipped a band: \(why)")
                }
            }
            return (nil, filters)
        }
        let line = points.map { String(format: "%.17g %.17g", $0.frequency, $0.gain) }.joined(separator: "; ")
        guard let reduced = APOFormat.graphic(line) else { return (nil, []) }
        warnings.append("\(points.count) graphic bands reduced to 10")
        let limited = reduced.bands.map { min(max(($0 * 10).rounded() / 10, Config.gainRange.lowerBound), Config.gainRange.upperBound) }
        if limited != reduced.bands.map({ ($0 * 10).rounded() / 10 }) {
            warnings.append(String(format: "graphic gains beyond ±%g dB were limited to it", Config.gainRange.upperBound))
        }
        return (limited, [])
    }

    private static func onOurCentres(_ frequencies: [Double]) -> Bool {
        guard frequencies.count == Config.bandFrequencies.count else { return false }
        return zip(frequencies.sorted(), Config.bandFrequencies).allSatisfy { f, centre in
            f / centre <= APOFormat.fixedBandTolerance && f / centre >= 1 / APOFormat.fixedBandTolerance
        }
    }
}
