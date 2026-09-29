import Foundation

enum FilterOrigin: String, Codable {
    case `import`, hand
}

struct Filter: Codable, Equatable {
    var type: FilterType
    var frequency: Double
    var gain: Double
    var q: Double
    /// nil only in a config written before hand-edited filters existed; `Profile` resolves it on decode.
    var origin: FilterOrigin? = nil

    func sounds(like other: Filter) -> Bool {
        type == other.type && frequency == other.frequency && gain == other.gain && q == other.q
    }
}

/// AutoEq's preference layer on top of the curve: its bass and treble boosts, the same shelves at
/// the same corners (`DEFAULT_BASS_BOOST_FC` 105 Hz, `DEFAULT_TREBLE_BOOST_FC` 10 kHz, Q 0.7), and
/// its tilt in dB per octave around 632 Hz, the log-centre of 20 Hz–20 kHz (`log_tilt`).
struct Preference: Codable, Equatable {
    var bass: Double = 0
    var treble: Double = 0
    var tilt: Double = 0

    static let bassShelf = (frequency: 105.0, q: 0.7)
    static let trebleShelf = (frequency: 10000.0, q: 0.7)
    static let tiltCentre = 20 * (1000.0).squareRoot()
    // ±6 dB at 20 Hz and 20 kHz: the same 12 dB end to end the bass and treble ranges allow.
    static let tiltRange: ClosedRange<Double> = -1.2...1.2
    // A straight line in log-frequency is no biquad. Two shelves a side, 2.5 octaves apart at
    // Q 0.6, stay within 0.25 dB per dB/octave of it from 20 Hz to 20 kHz and flatten outside,
    // where AutoEq's line would keep climbing; more shelves buy little and cost a biquad each.
    static let tiltSpacing = 2.5
    static let tiltQ = 0.6

    init(bass: Double = 0, treble: Double = 0, tilt: Double = 0) {
        self.bass = bass; self.treble = treble; self.tilt = tilt
    }

    private enum CodingKeys: String, CodingKey { case bass, treble, tilt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bass = try c.decodeIfPresent(Double.self, forKey: .bass) ?? 0
        treble = try c.decodeIfPresent(Double.self, forKey: .treble) ?? 0
        tilt = try c.decodeIfPresent(Double.self, forKey: .tilt) ?? 0
    }

    var isFlat: Bool { bass == 0 && treble == 0 && tilt == 0 }

    /// Only what is set: a zero shelf would still cost a biquad per channel.
    var engineBands: [(label: String, band: EQBand)] {
        var bands: [(label: String, band: EQBand)] = []
        if bass != 0 {
            bands.append(("bass shelf", EQBand(type: .lowShelf, frequency: Self.bassShelf.frequency, gain: bass, q: Self.bassShelf.q)))
        }
        if treble != 0 {
            bands.append(("treble shelf", EQBand(type: .highShelf, frequency: Self.trebleShelf.frequency, gain: treble, q: Self.trebleShelf.q)))
        }
        if tilt != 0 {
            let step = tilt * Self.tiltSpacing
            for octaves in [0.5, 1.5].map({ $0 * Self.tiltSpacing }) {
                bands.append(("tilt", EQBand(type: .lowShelf, frequency: Self.tiltCentre / pow(2, octaves), gain: -step, q: Self.tiltQ)))
                bands.append(("tilt", EQBand(type: .highShelf, frequency: Self.tiltCentre * pow(2, octaves), gain: step, q: Self.tiltQ)))
            }
        }
        return bands
    }
}

struct Profile: Codable, Equatable {
    var name: String?
    var preamp: Double
    var bands: [Double]
    var filters: [Filter]
    var imported: String?
    var preset: String?
    /// nil when flat, so a config without the layer reads and writes as before.
    var preference: Preference?
    /// Instrument knobs by name, in dB; nil when none is set. A name `Instruments` does not know
    /// is kept in the file but runs nothing, since the file may be edited by hand.
    var instruments: [String: Double]?
    /// nil when both the compressor and the colour are off.
    var dynamics: Dynamics?

    init(name: String?, preamp: Double, bands: [Double], filters: [Filter] = [], imported: String? = nil, preset: String? = nil,
         preference: Preference? = nil, instruments: [String: Double]? = nil, dynamics: Dynamics? = nil) {
        self.name = name; self.preamp = preamp; self.bands = bands; self.filters = filters; self.imported = imported
        self.preset = preset; self.preference = preference; self.instruments = instruments; self.dynamics = dynamics
    }

    private enum CodingKeys: String, CodingKey { case name, preamp, bands, filters, imported, preset, preference, instruments, dynamics }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        preamp = try c.decode(Double.self, forKey: .preamp)
        bands = try c.decode([Double].self, forKey: .bands)
        imported = try c.decodeIfPresent(String.self, forKey: .imported)
        // Before hand-added filters, every filter came from an import; an unmarked filter in a
        // profile that names no import can only have been typed into the file by hand.
        let legacyOrigin: FilterOrigin = imported == nil ? .hand : .import
        filters = (try c.decodeIfPresent([Filter].self, forKey: .filters) ?? []).map {
            var filter = $0
            if filter.origin == nil { filter.origin = legacyOrigin }
            return filter
        }
        preset = try c.decodeIfPresent(String.self, forKey: .preset)
        preference = try c.decodeIfPresent(Preference.self, forKey: .preference).flatMap { $0.isFlat ? nil : $0 }
        instruments = try c.decodeIfPresent([String: Double].self, forKey: .instruments).flatMap { $0.isEmpty ? nil : $0 }
        dynamics = try c.decodeIfPresent(Dynamics.self, forKey: .dynamics).flatMap { $0.isOff ? nil : $0 }
    }

    /// Stores nil rather than an all-zero layer.
    mutating func setPreference(_ edit: (inout Preference) -> Void) {
        var layer = preference ?? Preference()
        edit(&layer)
        preference = layer.isFlat ? nil : layer
    }

    /// Stores nil rather than a layer with both parts off.
    mutating func setDynamics(_ edit: (inout Dynamics) -> Void) {
        var layer = dynamics ?? Dynamics()
        edit(&layer)
        dynamics = layer.isOff ? nil : layer
    }

    /// Stores nil rather than an empty table, and drops a knob turned to 0.
    mutating func setKnob(_ instrument: String, _ edit: (Double) -> Double) {
        var knobs = instruments ?? [:]
        let gain = edit(knobs[instrument] ?? 0)
        knobs[instrument] = gain == 0 ? nil : gain
        instruments = knobs.isEmpty ? nil : knobs
    }

    /// The knobs that run, in the instrument table's order.
    var knobs: [(instrument: Instrument, gain: Double)] {
        Instruments.all.compactMap { instrument in
            instruments?[instrument.name].flatMap { $0 == 0 ? nil : (instrument, $0) }
        }
    }

    var unknownInstruments: [String] {
        (instruments ?? [:]).keys.filter { name in !Instruments.all.contains { $0.name == name } }.sorted()
    }

    /// `==` stays exact so the daemon still sees a renamed device or a new preset label as a change;
    /// "modified" is about what you hear.
    func sameCurve(as other: Profile) -> Bool {
        bands == other.bands && preamp == other.preamp && (preference ?? Preference()) == (other.preference ?? Preference())
            && filters.count == other.filters.count && zip(filters, other.filters).allSatisfy { $0.sounds(like: $1) }
            && knobs.elementsEqual(other.knobs) { $0.instrument == $1.instrument && $0.gain == $1.gain }
            && (dynamics ?? Dynamics()) == (other.dynamics ?? Dynamics())
    }

    static let flat = Profile(name: nil, preamp: 0, bands: Array(repeating: 0, count: Config.bandFrequencies.count))

    /// What runs after the bands and filters: the preference shelves, then one peak per knob.
    var layerBands: [(label: String, band: EQBand)] {
        (preference?.engineBands ?? []) + knobs.map { ("\($0.instrument.name) boost", $0.instrument.knob(gain: $0.gain)) }
    }

    var engineBands: [EQBand] {
        zip(Config.bandFrequencies, bands).map { EQBand(type: .peak, frequency: $0, gain: $1, q: 1.41) }
            + filters.map { EQBand(type: $0.type, frequency: $0.frequency, gain: $0.gain, q: $0.q) }
            + layerBands.map(\.band)
    }

    /// Names an `engineBands` index the way the user numbers it: a graphic band or "filter N" as `eq filter` lists it.
    func engineBandLabel(_ index: Int) -> String {
        let graphic = min(Config.bandFrequencies.count, bands.count)
        if index < graphic { return "band \(index + 1)" }
        if index < graphic + filters.count { return "filter \(index - graphic + 1)" }
        let layer = layerBands
        return layer.indices.contains(index - graphic - filters.count) ? layer[index - graphic - filters.count].label : "band \(index + 1)"
    }
}

/// While an app with this bundle ID plays, the daemon plays `preset` instead of the device's curve.
struct AppRule: Codable, Equatable {
    var app: String
    var preset: String

    func matches(_ bundleID: String) -> Bool {
        app.caseInsensitiveCompare(bundleID) == .orderedSame
    }
}

/// While `app` has audio open, it plays on the first of `outputs` that is available, whatever the default output is.
struct RouteRule: Codable, Equatable {
    static let outputCount = 1...4

    var app: String
    var outputs: [String]

    func matches(_ bundleID: String) -> Bool {
        app.caseInsensitiveCompare(bundleID) == .orderedSame
    }
}

struct Experimental: Codable, Equatable {
    var apps: Bool
    var routes: Bool

    init(apps: Bool = false, routes: Bool = false) {
        self.apps = apps
        self.routes = routes
    }

    private enum CodingKeys: String, CodingKey { case apps, routes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apps = try c.decodeIfPresent(Bool.self, forKey: .apps) ?? false
        routes = try c.decodeIfPresent(Bool.self, forKey: .routes) ?? false
    }

    /// Only the flags that are on, so a config from before routes writes the block it always wrote.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if apps { try c.encode(true, forKey: .apps) }
        if routes { try c.encode(true, forKey: .routes) }
    }

    var isOff: Bool { !apps && !routes }
}

/// Which path carries the EQ: a process tap in the daemon, or the HAL plug-in in Driver/.
enum AudioMode: String, Codable, CaseIterable {
    case tap, driver
}

struct DriverOptions: Codable, Equatable {
    /// The decision-4 experiment: keep the EQ device hidden while it is the default output.
    var hideWhileDefault: Bool? = nil
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
    case filterUnstable(String, Int)
    case preferenceOutOfRange(String, String)
    case badRoute(String, String)

    var description: String {
        switch self {
        case .unsupportedVersion(let v): return "unsupported config version \(v) (expected 1)"
        case .bandCount(let key, let n): return "profile \"\(key)\" has \(n) bands, expected \(Config.bandFrequencies.count)"
        case .gainOutOfRange(let key, let g): return "profile \"\(key)\" has gain \(g) dB outside \(Config.gainRange.lowerBound)…\(Config.gainRange.upperBound)"
        case .preampOutOfRange(let key, let g): return "profile \"\(key)\" has preamp \(g) dB outside \(Config.preampRange.lowerBound)…\(Config.preampRange.upperBound)"
        case .invalidJSON(let why): return "config is not valid JSON: \(why)"
        case .filterOutOfRange(let key, let what): return "profile \"\(key)\" has a filter with \(what) outside the allowed range"
        case .filterUnstable(let key, let number):
            return "profile \"\(key)\": filter \(number) would be unstable at \(Int(Config.stabilityCheckRate / 1000)) kHz (its output would ring or grow without end); change its frequency or Q"
        case .preferenceOutOfRange(let key, let what): return "profile \"\(key)\" has \(what) outside the allowed range"
        case .badRoute(let app, let why): return "route for \"\(app)\" \(why)"
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
    // The rate most outputs run at. Higher rates push low filters closer to z = 1, where Float32
    // coefficients can round onto the unit circle, but a config must stay valid on any device.
    static let stabilityCheckRate = 48000.0
    static let screenshotCurve: [Double] = [4.8, 4.0, 4.2, 2.3, 0.0, -3.1, 0.0, 0.0, 3.1, 2.4]

    var version: Int
    var enabled: Bool
    var `default`: Profile
    var devices: [String: Profile]
    // nil, not empty, means "never seeded": a user who deleted every preset keeps none.
    var presets: [String: Profile]? = nil
    /// Shell commands the daemon runs on a change, by name: `device`, `preset`. Unknown names are logged and ignored.
    var hooks: [String: String]? = nil
    /// In order: the first rule whose app plays wins, unless several play at once.
    var apps: [AppRule]? = nil
    /// One rule per app; nothing plays by them unless `experimental.routes` is on.
    var routes: [RouteRule]? = nil
    var experimental: Experimental? = nil
    /// nil reads as tap, so a config from before driver mode means what it always meant.
    var mode: AudioMode? = nil
    var driver: DriverOptions? = nil

    var followsApps: Bool { experimental?.apps == true }
    var followsRoutes: Bool { experimental?.routes == true }
    var audioMode: AudioMode { mode ?? .tap }
    var hidesWhileDefault: Bool { driver?.hideWhileDefault == true }

    mutating func setFollowsApps(_ on: Bool) {
        setExperimental { $0.apps = on }
    }

    mutating func setFollowsRoutes(_ on: Bool) {
        setExperimental { $0.routes = on }
    }

    private mutating func setExperimental(_ edit: (inout Experimental) -> Void) {
        var flags = experimental ?? Experimental()
        edit(&flags)
        experimental = flags.isOff ? nil : flags
    }

    static let presetNameLength = 1...32
    private static let presetNameCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_. "))

    static func isValidPresetName(_ name: String) -> Bool {
        presetNameLength.contains(name.count) && name.unicodeScalars.allSatisfy(presetNameCharacters.contains)
    }

    /// Leading/trailing whitespace in a typed name is never intentional — trim it before it is
    /// validated or stored, so " fav " and "fav" are the same preset and "   " is not a name at all.
    static func normalizedPresetName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// What `initial` returns for whichever built-in device it was given, or for none.
    var isInitial: Bool {
        guard devices.count <= 1 else { return false }
        let device = devices.first
        return self == Self.initial(builtInUID: device?.key, builtInName: device?.value.name)
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
        try Self.validate(routes: routes ?? [])
    }

    private static func validate(routes: [RouteRule]) throws {
        var apps = Set<String>()
        for rule in routes {
            guard !rule.app.isEmpty else { throw ConfigError.badRoute(rule.app, "names no app") }
            guard apps.insert(rule.app.lowercased()).inserted else { throw ConfigError.badRoute(rule.app, "repeats: one rule per app") }
            let range = RouteRule.outputCount
            guard range.contains(rule.outputs.count) else {
                throw ConfigError.badRoute(rule.app, "has \(rule.outputs.count) outputs, expected \(range.lowerBound)–\(range.upperBound)")
            }
            guard !rule.outputs.contains(where: \.isEmpty) else { throw ConfigError.badRoute(rule.app, "has an empty output") }
            guard Set(rule.outputs).count == rule.outputs.count else { throw ConfigError.badRoute(rule.app, "lists an output twice") }
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
            if !filterFrequencyRange.contains(filter.frequency) {
                throw ConfigError.filterOutOfRange(key, "frequency \(filter.frequency) Hz (\(span(filterFrequencyRange)) Hz)")
            }
            if !filterGainRange.contains(filter.gain) { throw ConfigError.filterOutOfRange(key, "gain \(filter.gain) dB (\(span(filterGainRange)) dB)") }
            if !filterQRange.contains(filter.q) { throw ConfigError.filterOutOfRange(key, "q \(filter.q) (\(span(filterQRange)))") }
        }
        if let number = firstUnstableFilter(profile.filters, sampleRate: stabilityCheckRate) {
            throw ConfigError.filterUnstable(key, number)
        }
        if let layer = profile.preference {
            if !gainRange.contains(layer.bass) { throw ConfigError.preferenceOutOfRange(key, "bass \(layer.bass) dB (\(span(gainRange)) dB)") }
            if !gainRange.contains(layer.treble) { throw ConfigError.preferenceOutOfRange(key, "treble \(layer.treble) dB (\(span(gainRange)) dB)") }
            if !Preference.tiltRange.contains(layer.tilt) {
                throw ConfigError.preferenceOutOfRange(key, "tilt \(layer.tilt) dB/octave (\(span(Preference.tiltRange)) dB/octave)")
            }
        }
        for knob in profile.knobs where !gainRange.contains(knob.gain) {
            throw ConfigError.preferenceOutOfRange(key, "\(knob.instrument.name) boost \(knob.gain) dB (\(span(gainRange)) dB)")
        }
        if let color = profile.dynamics?.color, !Dynamics.amountRange.contains(color.amount) {
            throw ConfigError.preferenceOutOfRange(key, "color amount \(color.amount) (\(span(Dynamics.amountRange)))")
        }
    }

    private static func span(_ range: ClosedRange<Double>) -> String {
        String(format: "%g…%g", range.lowerBound, range.upperBound)
    }

    /// 1-based, matching the "Filter N" numbering of an imported AutoEq file.
    static func firstUnstableFilter(_ filters: [Filter], sampleRate: Double) -> Int? {
        filters.firstIndex {
            !BiquadCoefficients.make(type: $0.type, frequency: $0.frequency, gainDB: $0.gain, q: $0.q, sampleRate: sampleRate).isStable
        }.map { $0 + 1 }
    }

    func profile(forDeviceUID uid: String) -> (profile: Profile, source: ProfileSource) {
        if let profile = devices[uid] { return (profile, .device) }
        return (`default`, .default)
    }

    mutating func setProfile(_ profile: Profile, forDeviceUID uid: String) {
        devices[uid] = profile
    }
}
