import Foundation

/// An EasyEffects preset's equaliser plugin (`output.equalizer`, or `equalizer#0` since
/// EasyEffects 7; `input` for a microphone preset). Its bands are LSP's: a named type, a real Q,
/// and a `slope` multiplier; `input-gain` and `output-gain` together are the preamp.
enum EasyEffectsFormat: EQFormat {
    static let name = "EasyEffects preset (JSON)"

    private static let types: [String: FilterType] = [
        "Bell": .peak, "Lo-shelf": .lowShelf, "Hi-shelf": .highShelf, "Lo-pass": .lowPass, "Hi-pass": .highPass,
        "Notch": .notch, "Bandpass": .bandPass,
    ]

    static func sniff(_ data: Data, filename: String?) -> Bool {
        equalizers(ImportCheck.json(data)).first != nil
    }

    static func parse(_ data: Data) throws -> ImportResult {
        let found = equalizers(ImportCheck.json(data))
        guard let plugin = found.first else { throw ImportError.unrecognized }
        var warnings: [String] = []
        if found.count > 1 { warnings.append("the preset has \(found.count) equalisers; imported the first") }

        let split = ImportCheck.flag(plugin["split-channels"]) ?? false
        guard let left = plugin["left"] as? [String: Any] else { throw ImportError.nothingUsable(["the equaliser has no left channel"]) }
        if split, let right = plugin["right"] as? [String: Any], !NSDictionary(dictionary: left).isEqual(to: right) {
            warnings.append("left and right channels differ; imported the left channel")
        }

        let declared = ImportCheck.integer(ImportCheck.number(plugin["num-bands"]))
        let count = declared.map { min(max($0, 0), 64) } ?? left.keys.filter { $0.hasPrefix("band") }.count
        var filters: [Filter] = []
        for index in 0..<count {
            let place = "band\(index)"
            guard let band = left[place] as? [String: Any] else { warnings.append("\(place): missing"); continue }
            if ImportCheck.flag(band["mute"]) == true { continue }
            let typeName = band["type"] as? String ?? ""
            if typeName == "Off" { continue }
            guard let type = types[typeName] else {
                warnings.append("\(place): skipped, filter type \u{201C}\(typeName)\u{201D} is not supported"); continue
            }
            guard let frequency = ImportCheck.number(band["frequency"]) else { warnings.append("\(place): skipped, no frequency"); continue }
            guard let q = ImportCheck.number(band["q"]) else { warnings.append("\(place): skipped, no Q"); continue }
            let takesGain = type == .peak || type == .lowShelf || type == .highShelf
            guard let gain = takesGain ? ImportCheck.number(band["gain"]) : 0 else { warnings.append("\(place): skipped, no gain"); continue }
            if let slope = band["slope"] as? String, slope != "x1" {
                warnings.append("\(place): slope \(slope) imported as a single filter")
            }
            switch ImportCheck.filter(type, frequency: frequency, gain: gain, q: q) {
            case .filter(let filter): filters.append(filter)
            case .silent: break
            case .skipped(let why): warnings.append("\(place): skipped, \(why)")
            }
        }

        var preamp = 0.0
        for key in ["input-gain", "output-gain"] where plugin[key] != nil {
            if let value = ImportCheck.number(plugin[key]) { preamp += value } else { warnings.append("\(key) is not a number; used 0 dB") }
        }
        guard Config.preampRange.contains(preamp) else { throw ImportError.preampOutOfRange(preamp) }
        var bands: [Double]?
        if let fixed = APOFormat.fixedBands(filters) {
            bands = fixed
            filters = []
        }
        guard !filters.isEmpty || bands != nil else {
            throw ImportError.nothingUsable(warnings.isEmpty ? ["the equaliser has no bands"] : warnings)
        }
        return ImportResult(filters: filters, bands: bands, preamp: preamp, format: "EasyEffects equalizer", warnings: warnings)
    }

    /// In `plugins_order` when it names them, so the first one listed is the first one applied.
    private static func equalizers(_ json: Any?) -> [[String: Any]] {
        guard let root = json as? [String: Any] else { return [] }
        for side in ["output", "input"] {
            guard let section = root[side] as? [String: Any] else { continue }
            let order = (section["plugins_order"] as? [Any])?.compactMap { $0 as? String } ?? []
            let names = order + section.keys.sorted().filter { !order.contains($0) }
            let found = names.filter { $0 == "equalizer" || $0.hasPrefix("equalizer#") }.compactMap { section[$0] as? [String: Any] }
            if !found.isEmpty { return found }
        }
        return []
    }
}
