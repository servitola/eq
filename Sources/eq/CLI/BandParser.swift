import Foundation

enum CLIError: Error, Equatable, CustomStringConvertible {
    case usage(String)
    case unknownBand(String)
    case badGain(String)
    case gainOutOfRange(Double)
    case noSuchDevice(String)
    case ambiguousDevice(String, [String])
    case noCurrentDevice
    case daemonNotRunning
    case noMeter
    case daemonClosedMeter
    case noEvents
    case daemonClosedEvents
    case importUnrecognized(String)
    case importNotFound(String)
    case importAmbiguous([String])
    case importSuggest(String, [String])
    case importVariant(String, [String], asked: String?)
    case importRefused(String)
    case network(String)
    case noSuchPreset(String)
    case noSuchApp(String)
    case noSuchAppRule(String)
    case badPresetName(String)
    case presetExists(String)
    case noBackup
    case noRedo
    case unreadableBackup(Int)
    case noSuchFilter(String, Int)
    case exportRefused(String)
    case exportFailed(String)
    case notConnected(String)
    case switchFailed(String)
    case agent(String)
    case driver(String)
    case legacyAgent(String)

    var description: String {
        switch self {
        case .usage(let what): return "usage: \(what)"
        case .unknownBand(let token): return "unknown band \"\(token)\" — use one of \(Config.bandLabels.joined(separator: " "))"
        case .badGain(let token): return "not a gain: \"\(token)\" (examples: +4, -3.1, 0)"
        case .gainOutOfRange(let g): return "gain \(g) dB outside \(Config.gainRange.lowerBound)…\(Config.gainRange.upperBound)"
        case .noSuchDevice(let q): return "no device or profile matches \"\(q)\" — see `eq device list`"
        case .ambiguousDevice(let q, let names): return "\"\(q)\" matches several devices: \(names.joined(separator: ", "))"
        case .noCurrentDevice: return "cannot determine the current output device"
        case .daemonNotRunning: return "eq daemon is not running — see eq doctor"
        case .noMeter: return "the eq daemon is not running — eq doctor tells why"
        case .daemonClosedMeter: return "daemon closed the meter"
        case .noEvents: return "eq daemon is not serving events — is it running and at least \(Build.version)? " + LaunchAgent.restartHint
        case .daemonClosedEvents: return "daemon closed the event stream"
        case .importUnrecognized(let what): return "could not read an EQ profile from \(what)"
        case .importNotFound(let what): return "AutoEq has no ParametricEQ.txt for \(what)"
        case .importAmbiguous(let names): return "several models match — narrow the name:\n  \(names.joined(separator: "\n  "))"
        case .importSuggest(let query, let names):
            return "no headphone matches \"\(query)\" — did you mean:\n  \(names.joined(separator: "\n  "))"
        case .importVariant(let model, let variants, let asked):
            if variants.isEmpty { return "\(model) has no variants — drop --variant" }
            let lead = asked.map { "\(model) has no variant \"\($0)\"" } ?? "\(model) comes in several variants"
            return "\(lead) — pick one with --variant:\n  \(variants.joined(separator: "\n  "))"
        case .importRefused(let why): return "not imported: \(why)"
        case .network(let why): return "network: \(why)"
        case .noSuchPreset(let name): return "no preset \"\(name)\" — see `eq preset`"
        case .noSuchApp(let name): return "no app \"\(name)\" is playing or installed — give its bundle ID, like com.spotify.client"
        case .noSuchAppRule(let name): return "no app rule for \"\(name)\" — see `eq app`"
        case .badPresetName(let name): return "bad preset name \"\(name)\": 1–\(Config.presetNameLength.upperBound) letters, digits, spaces or - _ ."
        case .presetExists(let name): return "preset \"\(name)\" already exists"
        case .noBackup: return "nothing to undo — no backup of the config yet"
        case .noRedo: return "nothing to redo"
        case .unreadableBackup(let index):
            return index == 0
                ? "the config eq redo would restore is unreadable — see eq history"
                : "backup eq.json.\(index) is unreadable — see eq history"
        case .noSuchFilter(let token, let count):
            return count == 0 ? "no filter \"\(token)\" — this curve has no filters" : "no filter \"\(token)\" — pick 1…\(count), see `eq filter`"
        case .exportRefused(let why): return "not exported: \(why)"
        case .exportFailed(let why): return "export failed: \(why)"
        case .notConnected(let name): return "\(name) is not connected — see `eq device list`"
        case .switchFailed(let why): return "could not switch the output: \(why)"
        case .agent(let why): return "launch agent: \(why)"
        case .driver(let why): return "driver: \(why)"
        case .legacyAgent(let path):
            return "\(LaunchAgent.abbreviate(path)) already starts eq at login; to switch to the bundled login item: eq agent install --replace-legacy"
        }
    }
}

enum BandParser {
    static func bandIndex(_ token: String) -> Int? {
        frequency(token).flatMap { Config.bandFrequencies.firstIndex(of: $0) }
    }

    /// `1k`, `1khz`, `1000hz`, `1000`, `2.5k`; a comma works as the decimal point.
    static func frequency(_ token: String) -> Double? {
        var t = token.lowercased().replacingOccurrences(of: ",", with: ".")
        if t.hasSuffix("hz") { t.removeLast(2) }
        var multiplier = 1.0
        if t.hasSuffix("k") { t.removeLast(); multiplier = 1000 }
        guard let value = Double(t), value.isFinite else { return nil }
        return value * multiplier
    }

    static func gain(_ token: String) throws -> Double {
        guard let value = Double(token.replacingOccurrences(of: ",", with: ".")) else {
            throw CLIError.badGain(token)
        }
        guard Config.gainRange.contains(value) else { throw CLIError.gainOutOfRange(value) }
        return value
    }

    static func assignments(_ tokens: [String]) throws -> [(index: Int, gain: Double)] {
        guard !tokens.isEmpty, tokens.count % 2 == 0 else { throw CLIError.usage("expected pairs of <band> <gain>") }
        var result: [(index: Int, gain: Double)] = []
        for pair in stride(from: 0, to: tokens.count, by: 2) {
            guard let index = bandIndex(tokens[pair]) else { throw CLIError.unknownBand(tokens[pair]) }
            result.append((index, try gain(tokens[pair + 1])))
        }
        return result
    }
}
