import Foundation

/// eq's own profile, the shape `eq export --format json` and `eq.json` both write: ten `bands`,
/// a `preamp`, `filters` with their type, frequency, gain and Q, the bass/treble/tilt
/// `preference` layer, the `instruments` knobs and the `dynamics`. Unlike every borrowed format, this one is read
/// back to exactly the numbers eq wrote, not fitted or reduced. A layer the file carries, even
/// flat or `{}`, replaces the device's; one it leaves out (a file from before that layer, or
/// `eq.json`, which omits empty ones) keeps it.
enum EQJSONFormat: EQFormat {
    static let name = "eq's own profile (JSON)"

    static func sniff(_ data: Data, filename: String?) -> Bool {
        guard let root = ImportCheck.json(data) as? [String: Any], let bands = root["bands"] as? [Any],
              bands.count == Config.bandFrequencies.count, bands.allSatisfy({ ImportCheck.number($0) != nil }) else { return false }
        return ImportCheck.number(root["preamp"]) != nil
    }

    static func parse(_ data: Data) throws -> ImportResult {
        guard let root = ImportCheck.json(data) as? [String: Any] else { throw ImportError.unrecognized }
        guard let rawBands = root["bands"] as? [Any], rawBands.count == Config.bandFrequencies.count else {
            throw ImportError.nothingUsable(["bands has \((root["bands"] as? [Any])?.count ?? 0) values; eq has \(Config.bandFrequencies.count)"])
        }
        var warnings: [String] = []
        let bands = rawBands.enumerated().map { index, value -> Double in
            if let gain = ImportCheck.number(value), Config.gainRange.contains(gain) { return gain }
            warnings.append("band \(index + 1) (\(Int(Config.bandFrequencies[index])) Hz) has no usable gain; set to 0 dB")
            return 0
        }

        guard let preamp = ImportCheck.number(root["preamp"]) else { throw ImportError.nothingUsable(["preamp is not a number"]) }
        guard Config.preampRange.contains(preamp) else { throw ImportError.preampOutOfRange(preamp) }

        var filters: [Filter] = []
        for (index, raw) in (root["filters"] as? [Any] ?? []).enumerated() {
            let place = "filter \(index + 1)"
            guard let entry = raw as? [String: Any] else { warnings.append("\(place): skipped, not an object"); continue }
            guard let typeName = entry["type"] as? String, let type = FilterType(rawValue: typeName) else {
                warnings.append("\(place): skipped, unknown filter type"); continue
            }
            guard let frequency = ImportCheck.number(entry["frequency"]) else { warnings.append("\(place): skipped, no frequency"); continue }
            guard let gain = ImportCheck.number(entry["gain"]) else { warnings.append("\(place): skipped, no gain"); continue }
            guard let q = ImportCheck.number(entry["q"]) else { warnings.append("\(place): skipped, no Q"); continue }
            switch ImportCheck.filter(type, frequency: frequency, gain: gain, q: q) {
            case .filter(let filter): filters.append(filter)
            case .silent: break
            case .skipped(let why): warnings.append("\(place): skipped, \(why)")
            }
        }

        var preference: Preference?
        if let layer = root["preference"] as? [String: Any] {
            let bass = ImportCheck.number(layer["bass"]) ?? 0
            let treble = ImportCheck.number(layer["treble"]) ?? 0
            let tilt = ImportCheck.number(layer["tilt"]) ?? 0
            if Config.gainRange.contains(bass), Config.gainRange.contains(treble), Preference.tiltRange.contains(tilt) {
                preference = Preference(bass: bass, treble: treble, tilt: tilt)
            } else {
                warnings.append("preference is out of range; dropped")
            }
        }

        var instruments: [String: Double]?
        if let knobs = root["instruments"] as? [String: Any] {
            instruments = [:]
            for (name, raw) in knobs.sorted(by: { $0.key < $1.key }) {
                guard Instruments.all.contains(where: { $0.name == name }) else { warnings.append("instrument \(name): skipped, eq has no such instrument"); continue }
                guard let gain = ImportCheck.number(raw), Config.gainRange.contains(gain) else {
                    warnings.append("instrument \(name): skipped, boost out of range"); continue
                }
                if gain != 0 { instruments?[name] = gain }
            }
        }

        var dynamics: Dynamics?
        if let layer = root["dynamics"] as? [String: Any] {
            dynamics = Dynamics()
            if let raw = layer["comp"] {
                if let mode = (raw as? String).flatMap(Dynamics.Compressor.init(rawValue:)) { dynamics?.comp = mode }
                else { warnings.append("dynamics comp: skipped, eq has no such mode") }
            }
            if let raw = layer["color"] {
                let entry = raw as? [String: Any]
                if let kind = (entry?["kind"] as? String).flatMap(Dynamics.ColourKind.init(rawValue:)),
                   let amount = ImportCheck.number(entry?["amount"]), Dynamics.amountRange.contains(amount) {
                    if amount > 0 { dynamics?.color = .init(kind: kind, amount: amount) }
                } else {
                    warnings.append("dynamics color: skipped, needs a kind of tape or tube and an amount of 0…1")
                }
            }
        }

        return ImportResult(filters: filters, bands: bands, preamp: preamp, format: "eq's own profile", warnings: warnings,
                            preference: preference, instruments: instruments, dynamics: dynamics)
    }
}
