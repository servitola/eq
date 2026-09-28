import Foundation

/// Poweramp's equaliser preset export: an array holding one preset of `preamp`, `parametric` and
/// `bands`. A band's `type` is 0 low shelf, 1 high shelf, 2 peak; in graphic mode (`parametric:
/// false`) the peaks carry `q: 0` and are the sliders.
enum PowerampFormat: EQFormat {
    static let name = "Poweramp preset (JSON)"

    static func sniff(_ data: Data, filename: String?) -> Bool {
        guard let preset = preset(ImportCheck.json(data)).preset, let bands = preset["bands"] as? [Any] else { return false }
        return preset["parametric"] != nil || bands.contains { ($0 as? [String: Any])?["channels"] != nil }
    }

    static func parse(_ data: Data) throws -> ImportResult {
        let found = preset(ImportCheck.json(data))
        guard let preset = found.preset, let rawBands = preset["bands"] as? [Any] else { throw ImportError.unrecognized }
        var warnings: [String] = []
        if found.count > 1 {
            warnings.append("the file has \(found.count) presets; imported the first, \u{201C}\(preset["name"] as? String ?? "unnamed")\u{201D}")
        }
        let parametric = ImportCheck.flag(preset["parametric"]) ?? false
        var filters: [Filter] = []
        var sliders: [(frequency: Double, gain: Double)] = []

        for (index, raw) in rawBands.enumerated() {
            let place = "band \(index + 1)"
            guard let band = raw as? [String: Any] else { warnings.append("\(place): skipped, not an object"); continue }
            if let channels = band["channels"], ImportCheck.number(channels) != 0 {
                warnings.append("\(place): skipped, it applies to one channel only"); continue
            }
            guard let frequency = ImportCheck.number(band["frequency"]) else { warnings.append("\(place): skipped, no frequency"); continue }
            guard let gain = ImportCheck.number(band["gain"]) else { warnings.append("\(place): skipped, no gain"); continue }
            let q = ImportCheck.number(band["q"]) ?? 0
            let type: FilterType
            switch ImportCheck.integer(ImportCheck.number(band["type"])) {
            case 0: type = .lowShelf
            case 1: type = .highShelf
            case 2: type = .peak
            default: warnings.append("\(place): skipped, unknown band type"); continue
            }
            if type == .peak && !parametric {
                guard Config.filterFrequencyRange.contains(frequency), Config.filterGainRange.contains(gain) else {
                    warnings.append(String(format: "%@: skipped, %g Hz at %g dB is out of range", place, frequency, gain)); continue
                }
                sliders.append((frequency, gain))
                continue
            }
            // Graphic mode's tone shelves are there at 0 dB whether used or not.
            if type != .peak && gain == 0 { continue }
            let resolvedQ: Double
            if q > 0 {
                resolvedQ = q
            } else if type == .peak {
                warnings.append("\(place): skipped, a parametric peak without a Q"); continue
            } else {
                resolvedQ = 0.5.squareRoot()
            }
            switch ImportCheck.filter(type, frequency: frequency, gain: gain, q: resolvedQ) {
            case .filter(let filter): filters.append(filter)
            case .silent: break
            case .skipped(let why): warnings.append("\(place): skipped, \(why)")
            }
        }

        var bands: [Double]?
        if sliders.count == 1 {
            warnings.append("a single graphic band is not a curve; skipped it")
        } else if !sliders.isEmpty {
            let graphic = ImportCheck.graphic(sliders, warnings: &warnings)
            bands = graphic.bands
            filters = graphic.filters + filters
        }
        guard !filters.isEmpty || bands != nil else {
            throw ImportError.nothingUsable(warnings.isEmpty ? ["the preset has no bands"] : warnings)
        }
        var preamp = 0.0
        if let value = preset["preamp"] {
            if let number = ImportCheck.number(value) { preamp = number } else { warnings.append("the preamp is not a number; used 0 dB") }
        }
        guard Config.preampRange.contains(preamp) else { throw ImportError.preampOutOfRange(preamp) }
        return ImportResult(filters: filters, bands: bands, preamp: preamp,
                            format: parametric ? "Poweramp parametric preset" : "Poweramp graphic preset", warnings: warnings)
    }

    private static func preset(_ json: Any?) -> (preset: [String: Any]?, count: Int) {
        if let object = json as? [String: Any] { return (object, 1) }
        guard let list = json as? [[String: Any]] else { return (nil, 0) }
        return (list.first, list.count)
    }
}
