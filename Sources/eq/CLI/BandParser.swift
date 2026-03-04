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

    var description: String {
        switch self {
        case .usage(let what): return "usage: \(what)"
        case .unknownBand(let token): return "unknown band \"\(token)\" — use one of \(Config.bandLabels.joined(separator: " "))"
        case .badGain(let token): return "not a gain: \"\(token)\" (examples: +4, -3.1, 0)"
        case .gainOutOfRange(let g): return "gain \(g) dB outside \(Config.gainRange.lowerBound)…\(Config.gainRange.upperBound)"
        case .noSuchDevice(let q): return "no device or profile matches \"\(q)\" — see `eq devices`"
        case .ambiguousDevice(let q, let names): return "\"\(q)\" matches several devices: \(names.joined(separator: ", "))"
        case .noCurrentDevice: return "cannot determine the current output device"
        case .daemonNotRunning: return "eq daemon is not running — launchctl kickstart gui/$UID/com.servitola.eq"
        }
    }
}

enum BandParser {
    static func bandIndex(_ token: String) -> Int? {
        var t = token.lowercased()
        if t.hasSuffix("hz") { t.removeLast(2) }
        var multiplier = 1.0
        if t.hasSuffix("k") { t.removeLast(); multiplier = 1000 }
        guard let value = Double(t) else { return nil }
        return Config.bandFrequencies.firstIndex(of: value * multiplier)
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
