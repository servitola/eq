import Foundation

struct Filter: Codable, Equatable {
    var type: FilterType
    var frequency: Double
    var gain: Double
    var q: Double
}

struct Profile: Codable, Equatable {
    var name: String?
    var preamp: Double
    var bands: [Double]
    var filters: [Filter]
    var imported: String?
    var preset: String?

    init(name: String?, preamp: Double, bands: [Double], filters: [Filter] = [], imported: String? = nil, preset: String? = nil) {
        self.name = name; self.preamp = preamp; self.bands = bands; self.filters = filters; self.imported = imported
        self.preset = preset
    }

    private enum CodingKeys: String, CodingKey { case name, preamp, bands, filters, imported, preset }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        preamp = try c.decode(Double.self, forKey: .preamp)
        bands = try c.decode([Double].self, forKey: .bands)
        filters = try c.decodeIfPresent([Filter].self, forKey: .filters) ?? []
        imported = try c.decodeIfPresent(String.self, forKey: .imported)
        preset = try c.decodeIfPresent(String.self, forKey: .preset)
    }

    /// `==` stays exact so the daemon still sees a renamed device or a new preset label as a change;
    /// "modified" is about what you hear.
    func sameCurve(as other: Profile) -> Bool {
        bands == other.bands && preamp == other.preamp && filters == other.filters
    }

    static let flat = Profile(name: nil, preamp: 0, bands: Array(repeating: 0, count: Config.bandFrequencies.count))

    var engineBands: [EQBand] {
        zip(Config.bandFrequencies, bands).map { EQBand(type: .peak, frequency: $0, gain: $1, q: 1.41) }
            + filters.map { EQBand(type: $0.type, frequency: $0.frequency, gain: $0.gain, q: $0.q) }
    }
}

enum ProfileSource: String, Codable {
    case device
    case `default`
}

enum ConfigError: Error, Equatable, CustomStringConvertible {
    case unsupportedVersion(Int)
    case bandCount(String, Int)
    case gainOutOfRange(String, Double)
    case preampOutOfRange(String, Double)
    case invalidJSON(String)
    case filterOutOfRange(String, String)
    case badPresetName(String)

    var description: String {
        switch self {
        case .unsupportedVersion(let v): return "unsupported config version \(v) (expected 1)"
        case .bandCount(let key, let n): return "profile \"\(key)\" has \(n) bands, expected \(Config.bandFrequencies.count)"
        case .gainOutOfRange(let key, let g): return "profile \"\(key)\" has gain \(g) dB outside \(Config.gainRange.lowerBound)…\(Config.gainRange.upperBound)"
        case .preampOutOfRange(let key, let g): return "profile \"\(key)\" has preamp \(g) dB outside \(Config.preampRange.lowerBound)…\(Config.preampRange.upperBound)"
        case .invalidJSON(let why): return "config is not valid JSON: \(why)"
        case .filterOutOfRange(let key, let what): return "profile \"\(key)\" has a filter with \(what) outside the allowed range"
        case .badPresetName(let name): return "preset name \"\(name)\" is not 1–\(Config.presetNameLength.upperBound) letters, digits, spaces or - _ . (or repeats another name)"
        }
    }
}

struct Config: Codable, Equatable {
    static let bandFrequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let bandLabels = ["32Hz", "64Hz", "125Hz", "250Hz", "500Hz", "1kHz", "2kHz", "4kHz", "8kHz", "16kHz"]
    static let gainRange: ClosedRange<Double> = -12...12
    // An imported curve with a large boost carries a matching negative preamp, which can sink
    // below the band floor; the ceiling stays at the band ceiling.
    static let preampRange: ClosedRange<Double> = -30...12
    // Each filter costs a biquad per channel on the render thread, and AutoEq profiles stay
    // around ten filters; the cap bounds the cost of a hand-edited config.
    static let maxFilters = 32
    static let filterFrequencyRange: ClosedRange<Double> = 10...24000
    static let filterGainRange: ClosedRange<Double> = -30...30
    static let filterQRange: ClosedRange<Double> = 0.1...30
    static let screenshotCurve: [Double] = [4.8, 4.0, 4.2, 2.3, 0.0, -3.1, 0.0, 0.0, 3.1, 2.4]

    var version: Int
    var enabled: Bool
    var `default`: Profile
    var devices: [String: Profile]
    // nil, not empty, means "never seeded": a user who deleted every preset keeps none.
    var presets: [String: Profile]? = nil

    static let presetNameLength = 1...32
    private static let presetNameCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_. "))

    static func isValidPresetName(_ name: String) -> Bool {
        presetNameLength.contains(name.count) && name.unicodeScalars.allSatisfy(presetNameCharacters.contains)
    }

    static let seedPresets: [String: Profile] = [
        "favourite": Profile(name: nil, preamp: 0, bands: screenshotCurve),
        "flat": Profile.flat,
    ]

    mutating func seedPresetsIfNeeded() -> Bool {
        guard presets == nil else { return false }
        presets = Self.seedPresets
        return true
    }

    func preset(named query: String) -> (name: String, profile: Profile)? {
        let needle = query.lowercased()
        return presets?.first { $0.key.lowercased() == needle }.map { ($0.key, $0.value) }
    }

    static func initial(builtInUID: String?, builtInName: String?) -> Config {
        let curve = Profile(name: nil, preamp: 0, bands: screenshotCurve)
        var devices: [String: Profile] = [:]
        if let builtInUID {
            devices[builtInUID] = Profile(name: builtInName, preamp: 0, bands: screenshotCurve)
        }
        return Config(version: 1, enabled: true, default: curve, devices: devices, presets: seedPresets)
    }

    func validate() throws {
        guard version == 1 else { throw ConfigError.unsupportedVersion(version) }
        try Self.validate(profile: `default`, key: "default")
        for (uid, profile) in devices.sorted(by: { $0.key < $1.key }) {
            try Self.validate(profile: profile, key: uid)
        }
        var seen = Set<String>()
        for (name, profile) in (presets ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard Self.isValidPresetName(name), seen.insert(name.lowercased()).inserted else { throw ConfigError.badPresetName(name) }
            try Self.validate(profile: profile, key: "preset \(name)")
        }
    }

    private static func validate(profile: Profile, key: String) throws {
        guard profile.bands.count == bandFrequencies.count else {
            throw ConfigError.bandCount(key, profile.bands.count)
        }
        for gain in profile.bands where !gainRange.contains(gain) {
            throw ConfigError.gainOutOfRange(key, gain)
        }
        guard preampRange.contains(profile.preamp) else { throw ConfigError.preampOutOfRange(key, profile.preamp) }
        guard profile.filters.count <= maxFilters else {
            throw ConfigError.filterOutOfRange(key, "count \(profile.filters.count) (max \(maxFilters))")
        }
        for filter in profile.filters {
            if !filterFrequencyRange.contains(filter.frequency) { throw ConfigError.filterOutOfRange(key, "frequency \(filter.frequency) Hz") }
            if !filterGainRange.contains(filter.gain) { throw ConfigError.filterOutOfRange(key, "gain \(filter.gain) dB") }
            if !filterQRange.contains(filter.q) { throw ConfigError.filterOutOfRange(key, "q \(filter.q)") }
        }
    }

    func profile(forDeviceUID uid: String) -> (profile: Profile, source: ProfileSource) {
        if let profile = devices[uid] { return (profile, .device) }
        return (`default`, .default)
    }

    mutating func setProfile(_ profile: Profile, forDeviceUID uid: String) {
        devices[uid] = profile
    }
}
