import Foundation

/// eqMac's preset export: a JSON array of presets. The Advanced equaliser's ten gains sit on
/// `AdvancedEqualizer.frequencies`, which are our ten centres (eqMac 1.3.2, MIT/Apache-2.0,
/// `/presets/export`). The Expert equaliser keeps a band list with a bandwidth in octaves and an
/// `AUNBandEQ` filter type; that shape is only known from eqmac-backup's reader of eqMac's
/// preferences, so it is read as documented there.
enum EqMacFormat: EQFormat {
    static let name = "eqMac presets (JSON)"

    static func sniff(_ data: Data, filename: String?) -> Bool {
        guard let first = presets(ImportCheck.json(data))?.first else { return false }
        return isAdvanced(first) || isExpert(first)
    }

    static func parse(_ data: Data) throws -> ImportResult {
        guard let list = presets(ImportCheck.json(data)), let preset = list.first else { throw ImportError.unrecognized }
        var warnings: [String] = []
        if list.count > 1 {
            warnings.append("the file has \(list.count) presets; imported the first, \u{201C}\(preset["name"] as? String ?? "unnamed")\u{201D}")
        }
        if isAdvanced(preset) { return try advanced(preset, warnings: warnings) }
        if isExpert(preset) { return try expert(preset, warnings: warnings) }
        throw ImportError.unrecognized
    }

    private static func presets(_ json: Any?) -> [[String: Any]]? {
        if let object = json as? [String: Any] { return [object] }
        guard let list = json as? [[String: Any]], !list.isEmpty else { return nil }
        return list
    }

    private static func isAdvanced(_ preset: [String: Any]) -> Bool {
        (preset["gains"] as? [String: Any])?["bands"] is [Any]
    }

    private static func isExpert(_ preset: [String: Any]) -> Bool {
        guard preset["parametric"] == nil, let bands = preset["bands"] as? [Any] else { return false }
        return bands.contains { ($0 as? [String: Any])?["bandwidth"] != nil }
    }

    private static func preamp(_ value: Any?, warnings: inout [String]) throws -> Double {
        guard let value else { return 0 }
        guard let preamp = ImportCheck.number(value) else {
            warnings.append("the global gain is not a number; used 0 dB"); return 0
        }
        guard Config.preampRange.contains(preamp) else { throw ImportError.preampOutOfRange(preamp) }
        return preamp
    }

    private static func advanced(_ preset: [String: Any], warnings: [String]) throws -> ImportResult {
        var warnings = warnings
        let gains = preset["gains"] as? [String: Any] ?? [:]
        let raw = gains["bands"] as? [Any] ?? []
        guard raw.count == Config.bandFrequencies.count else {
            throw ImportError.nothingUsable(["gains.bands has \(raw.count) values; eqMac's Advanced equaliser has \(Config.bandFrequencies.count)"])
        }
        let values = raw.enumerated().map { index, value -> Double in
            if let gain = ImportCheck.number(value), Config.filterGainRange.contains(gain) { return gain }
            warnings.append("band \(index + 1) (\(Int(Config.bandFrequencies[index])) Hz) has no usable gain; set to 0 dB")
            return 0
        }
        let graphic = ImportCheck.graphic(zip(Config.bandFrequencies, values).map { (frequency: $0, gain: $1) }, warnings: &warnings)
        return ImportResult(filters: graphic.filters, bands: graphic.bands, preamp: try preamp(gains["global"], warnings: &warnings),
                            format: "eqMac Advanced preset", warnings: warnings)
    }

    /// `AUNBandEQ`'s filter types (AudioUnitParameters.h, `kAUNBandEQFilterType_*`).
    private static func expert(_ preset: [String: Any], warnings: [String]) throws -> ImportResult {
        var warnings = warnings
        var filters: [Filter] = []
        for (index, raw) in (preset["bands"] as? [Any] ?? []).enumerated() {
            let place = "band \(index + 1)"
            guard let band = raw as? [String: Any] else { warnings.append("\(place): skipped, not an object"); continue }
            if ImportCheck.flag(band["bypass"]) == true { continue }
            guard let frequency = ImportCheck.number(band["frequency"]) else { warnings.append("\(place): skipped, no frequency"); continue }
            let gain = ImportCheck.number(band["gain"]) ?? 0
            let bandwidth = ImportCheck.number(band["bandwidth"])
            func fromBandwidth() -> Double? {
                guard let bandwidth, bandwidth > 0 else { return nil }
                return 1 / (2 * sinh(log(2) / 2 * bandwidth))
            }
            let resolved: (FilterType, Double, Double?)
            switch band["type"] == nil ? 0 : ImportCheck.integer(ImportCheck.number(band["type"])) {
            case 0: resolved = (.peak, gain, fromBandwidth())
            case 1: resolved = (.lowPass, 0, 0.5.squareRoot())
            case 2: resolved = (.highPass, 0, 0.5.squareRoot())
            case 5: resolved = (.bandPass, 0, fromBandwidth())
            case 6: resolved = (.notch, 0, fromBandwidth())
            case 7: resolved = (.lowShelf, gain, 0.5.squareRoot())
            case 8: resolved = (.highShelf, gain, 0.5.squareRoot())
            case 9: resolved = (.lowShelf, gain, fromBandwidth())
            case 10: resolved = (.highShelf, gain, fromBandwidth())
            case 3, 4: warnings.append("\(place): skipped, a resonant low- or high-pass is not supported"); continue
            default: warnings.append("\(place): skipped, unknown filter type"); continue
            }
            guard let q = resolved.2 else { warnings.append("\(place): skipped, no positive bandwidth"); continue }
            switch ImportCheck.filter(resolved.0, frequency: frequency, gain: resolved.1, q: q) {
            case .filter(let filter): filters.append(filter)
            case .silent: break
            case .skipped(let why): warnings.append("\(place): skipped, \(why)")
            }
        }
        guard !filters.isEmpty else { throw ImportError.nothingUsable(warnings.isEmpty ? ["the preset has no bands"] : warnings) }
        let global = preset["global"] ?? (preset["gains"] as? [String: Any])?["global"]
        return ImportResult(filters: filters, bands: nil, preamp: try preamp(global, warnings: &warnings),
                            format: "eqMac Expert preset", warnings: warnings)
    }
}
