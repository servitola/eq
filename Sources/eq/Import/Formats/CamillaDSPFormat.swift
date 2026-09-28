import Foundation

/// A CamillaDSP config (YAML): `filters:` names the filters, `pipeline:` says which channel runs
/// which, in order. Biquad parameters mean what CamillaDSP's `src/filters/biquad.rs` makes of
/// them: the shelf frequency is the middle of the slope, `slope` is dB per octave read as RBJ's
/// S = slope / 12, and `bandwidth` is in octaves with the digital warp at the config's sample rate.
enum CamillaDSPFormat: EQFormat {
    static let name = "CamillaDSP config (YAML)"

    private static let biquads: [String: FilterType] = [
        "Peaking": .peak, "Lowshelf": .lowShelf, "Highshelf": .highShelf, "Lowpass": .lowPass, "Highpass": .highPass,
        "Notch": .notch, "Bandpass": .bandPass,
    ]

    static func sniff(_ data: Data, filename: String?) -> Bool {
        guard let text = ImportText.decode(data) else { return false }
        var filters = false, camilla = false
        for raw in APOFormat.lines(text) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("filters:") {
                let rest = line.dropFirst("filters:".count).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty || rest.hasPrefix("#") { filters = true }
            }
            if raw.hasPrefix("pipeline:") || line.hasPrefix("type: Biquad") || line.contains("type: Biquad,") || line.contains("type: Biquad}") {
                camilla = true
            }
            if filters && camilla { return true }
        }
        return false
    }

    static func parse(_ data: Data) throws -> ImportResult {
        guard let text = ImportText.decode(data) else { throw ImportError.unrecognized }
        let root: YAML
        do { root = try YAML.parse(text) } catch { throw ImportError.nothingUsable(["not YAML eq can read: \(error)"]) }
        guard let definitions = root["filters"]?.entries else { throw ImportError.nothingUsable(["the config has no filters: section"]) }

        var warnings: [String] = []
        var sampleRate = Config.stabilityCheckRate
        if let rate = root["devices"]?["samplerate"]?.number, (8000...768_000).contains(rate) { sampleRate = rate }

        var resolved: [String: Step] = [:]
        func step(_ name: String) -> Step {
            if let known = resolved[name] { return known }
            let found: Step
            if let definition = definitions.first(where: { $0.key == name })?.value {
                found = resolve(definition, sampleRate: sampleRate)
            } else {
                found = .skipped("is not defined under filters:")
            }
            if case .skipped(let why) = found { warnings.append("filter \u{201C}\(name)\u{201D}: skipped, \(why)") }
            resolved[name] = found
            return found
        }

        var left: [String] = [], right: [String] = []
        if let pipeline = root["pipeline"]?.list {
            var ignored: Set<String> = []
            for entry in pipeline {
                let kind = entry["type"]?.string ?? ""
                guard kind == "Filter" else {
                    if ignored.insert(kind).inserted { warnings.append("pipeline \(kind.isEmpty ? "steps without a type" : kind) steps ignored") }
                    continue
                }
                if entry["bypassed"]?.string?.lowercased() == "true" { continue }
                // `channel: n` up to CamillaDSP 2.x, a `channels:` list since 3.0; neither (or null) means every channel.
                let channels: [Int]?
                if let one = entry["channel"]?.number {
                    channels = [ImportCheck.integer(one) ?? -1]
                } else if let many = entry["channels"]?.list {
                    channels = many.map { $0.number.flatMap(ImportCheck.integer) ?? -1 }
                } else {
                    channels = nil
                }
                let names = entry["names"]?.list?.compactMap(\.string) ?? []
                if channels?.contains(0) ?? true { left += names }
                if channels?.contains(1) ?? true { right += names }
            }
        } else {
            warnings.append("no pipeline: imported every filter under filters:, in order")
            left = definitions.map(\.key)
            right = left
        }

        func chain(_ names: [String]) -> (filters: [Filter], gain: Double) {
            names.reduce(into: ([], 0)) { chain, name in
                switch step(name) {
                case .filter(let filter): chain.0.append(filter)
                case .gain(let gain): chain.1 += gain
                case .skipped: break
                }
            }
        }
        let l = chain(left), r = chain(right)
        if l.filters != r.filters || l.gain != r.gain { warnings.append("left and right channels differ; imported the left channel (channel 0)") }

        var filters = l.filters
        var bands: [Double]?
        if let fixed = APOFormat.fixedBands(filters) {
            bands = fixed
            filters = []
        }
        guard !filters.isEmpty || bands != nil else {
            throw ImportError.nothingUsable(warnings.isEmpty ? ["the pipeline runs no filter on channel 0"] : warnings)
        }
        guard Config.preampRange.contains(l.gain) else { throw ImportError.preampOutOfRange(l.gain) }
        return ImportResult(filters: filters, bands: bands, preamp: l.gain, format: "CamillaDSP config", warnings: warnings)
    }

    private enum Step {
        case filter(Filter)
        /// A `Gain` filter, in dB: eq's preamp.
        case gain(Double)
        case skipped(String)
    }

    private static func resolve(_ definition: YAML, sampleRate: Double) -> Step {
        let kind = definition["type"]?.string ?? ""
        let parameters = definition["parameters"]
        switch kind {
        case "Biquad": break
        case "Gain":
            guard let gain = parameters?["gain"]?.number else { return .skipped("a Gain filter without a number gain") }
            if parameters?["mute"]?.string?.lowercased() == "true" { return .skipped("a muted Gain filter") }
            if parameters?["scale"]?.string == "linear" {
                guard gain > 0 else { return .skipped("a linear gain that is not positive") }
                return .gain(20 * log10(gain))
            }
            return .gain(gain)
        case "": return .skipped("no type")
        default: return .skipped("\(kind) filters have no equal in eq")
        }
        let biquad = parameters?["type"]?.string ?? ""
        guard let type = biquads[biquad] else { return .skipped(biquad.isEmpty ? "a Biquad without a type" : "\(biquad) biquads are not supported") }
        guard let frequency = parameters?["freq"]?.number else { return .skipped("no freq") }
        let takesGain = type == .peak || type == .lowShelf || type == .highShelf
        guard let gain = takesGain ? parameters?["gain"]?.number : 0 else { return .skipped("no gain") }
        let q: Double
        if let given = parameters?["q"]?.number {
            q = given
        } else if takesGain && type != .peak, let slope = parameters?["slope"]?.number {
            guard let fromSlope = ImportCheck.shelfQ(slope: slope, gain: gain) else {
                return .skipped(String(format: "a %g dB/oct slope does not fit %g dB of gain", slope, gain))
            }
            q = fromSlope
        } else if [.peak, .notch, .bandPass].contains(type), let bandwidth = parameters?["bandwidth"]?.number {
            guard bandwidth > 0, frequency > 0, frequency < sampleRate / 2 else { return .skipped("bandwidth or freq out of range") }
            q = APOFormat.qFromBandwidth(bandwidth, frequency: frequency, sampleRate: sampleRate)
        } else {
            return .skipped("no q\(takesGain && type != .peak ? " or slope" : type == .lowPass || type == .highPass ? "" : " or bandwidth")")
        }
        switch ImportCheck.filter(type, frequency: frequency, gain: gain, q: q) {
        case .filter(let filter): return .filter(filter)
        case .silent: return .skipped("empty")
        case .skipped(let why): return .skipped(why)
        }
    }
}
