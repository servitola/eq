import Foundation

struct Profile: Codable, Equatable {
    var name: String?
    var preamp: Double
    var bands: [Double]

    static let flat = Profile(name: nil, preamp: 0, bands: Array(repeating: 0, count: Config.bandFrequencies.count))
}

enum ProfileSource: String, Codable {
    case device
    case `default`
}

enum ConfigError: Error, Equatable, CustomStringConvertible {
    case unsupportedVersion(Int)
    case bandCount(String, Int)
    case gainOutOfRange(String, Double)
    case invalidJSON(String)

    var description: String {
        switch self {
        case .unsupportedVersion(let v): return "unsupported config version \(v) (expected 1)"
        case .bandCount(let key, let n): return "profile \"\(key)\" has \(n) bands, expected \(Config.bandFrequencies.count)"
        case .gainOutOfRange(let key, let g): return "profile \"\(key)\" has gain \(g) dB outside \(Config.gainRange.lowerBound)…\(Config.gainRange.upperBound)"
        case .invalidJSON(let why): return "config is not valid JSON: \(why)"
        }
    }
}

struct Config: Codable, Equatable {
    static let bandFrequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let bandLabels = ["32Hz", "64Hz", "125Hz", "250Hz", "500Hz", "1kHz", "2kHz", "4kHz", "8kHz", "16kHz"]
    static let gainRange: ClosedRange<Double> = -12...12
    static let screenshotCurve: [Double] = [4.8, 4.0, 4.2, 2.3, 0.0, -3.1, 0.0, 0.0, 3.1, 2.4]

    var version: Int
    var enabled: Bool
    var `default`: Profile
    var devices: [String: Profile]

    static func initial(builtInUID: String?, builtInName: String?) -> Config {
        let curve = Profile(name: nil, preamp: 0, bands: screenshotCurve)
        var devices: [String: Profile] = [:]
        if let builtInUID {
            devices[builtInUID] = Profile(name: builtInName, preamp: 0, bands: screenshotCurve)
        }
        return Config(version: 1, enabled: true, default: curve, devices: devices)
    }

    func validate() throws {
        guard version == 1 else { throw ConfigError.unsupportedVersion(version) }
        try Self.validate(profile: `default`, key: "default")
        for (uid, profile) in devices.sorted(by: { $0.key < $1.key }) {
            try Self.validate(profile: profile, key: uid)
        }
    }

    private static func validate(profile: Profile, key: String) throws {
        guard profile.bands.count == bandFrequencies.count else {
            throw ConfigError.bandCount(key, profile.bands.count)
        }
        for gain in profile.bands + [profile.preamp] where !gainRange.contains(gain) {
            throw ConfigError.gainOutOfRange(key, gain)
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
