import Foundation

/// Peace's `.peace` configuration: an INI file of slider settings per speaker group, which Peace
/// turns into Equalizer APO lines when it is applied. Read by writing the same lines Peace writes
/// (`Peace.au3`, `ReadFile` and the filter loop of the configuration writer, GPL-2.0) and handing
/// them to the APO parser, so channels, shelves and pass filters mean what they mean in APO.
enum PeaceFormat: EQFormat {
    static let name = "Peace configuration (.peace)"

    /// Peace's `$FilterTypes`, indexed by the `FilterN=` value: the APO type, whether it takes a
    /// gain, whether it takes the Quality value.
    private static let filterTypes: [(token: String, gain: Bool, quality: Bool)] = [
        ("PK", true, true), ("LPQ", false, true), ("HPQ", false, true), ("BP", false, true), ("LS", true, false),
        ("HS", true, false), ("NO", false, true), ("AP", false, true), ("LSC", true, true), ("HSC", true, true),
        ("BWLP", false, true), ("BWHP", false, true), ("LRLP", false, true), ("LRHP", false, true),
        ("LSCQ", true, true), ("HSCQ", true, true), ("LSQ", true, true), ("HSQ", true, true),
    ]
    /// Peace's `$SpeakerTypes`: the groups it assumes when a file lists none.
    private static let defaultTargets = ["all", "L", "R", "C", "SUB", "RL", "RR", "SL", "SR"]
    private static let slidersMax = 31
    private static let maxSliderFrequency = 22500.0
    // Peace takes any order; a pass filter steeper than this is more biquads than eq has room for.
    private static let maxPassOrder = 16
    private static let sections = ["frequencies", "gains", "qualities", "filters", "disabled", "speakers", "commands"]

    /// Peace's effects that are not equalisation, with the value that means "off".
    private static let effects: [(key: String, off: String)] = [
        ("Routing", ""), ("Muting", ""), ("Reverse", "0"), ("Upmix", "0"), ("Downmix 5.1", "0"), ("Downmix 7.1", "0"),
        ("Stereo Widening", "0"), ("Echo Count", "0"), ("Fake Stereo", "0"), ("Crossfeed Simulation", "0"),
        ("Bass Gain", "0"), ("Treble Gain", "0"), ("Stereo Balance", "0"), ("Channels Delay", "0"), ("Stereo Expanding", "0"),
    ]

    static func sniff(_ data: Data, filename: String?) -> Bool {
        guard let text = ImportText.decode(data) else { return false }
        return APOFormat.lines(text).contains { raw in
            let line = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard line.hasPrefix("["), line.hasSuffix("]") else { return false }
            let name = line.dropFirst().dropLast().trimmingCharacters(in: CharacterSet.decimalDigits)
            return sections.contains(name)
        }
    }

    static func parse(_ data: Data) throws -> ImportResult {
        guard let text = ImportText.decode(data) else { throw ImportError.unrecognized }
        let ini = INI(text)
        var warnings: [String] = []
        var lines: [String] = []
        var places: [String] = []
        func emit(_ line: String, _ place: String) { lines.append(line); places.append(place) }

        let ignored = effects.filter { effect in
            ini.value("general", effect.key).map { $0.trimmingCharacters(in: .whitespaces) != effect.off && APOFormat.number($0) != 0 } ?? false
        }
        if !ignored.isEmpty { warnings.append("Peace effects ignored: " + ignored.map(\.key).joined(separator: ", ")) }

        for (index, command) in commands(ini, "0") + commands(ini, "2") { emit(command, "[Commands] line \(index)") }

        for speaker in speakers(ini) {
            let suffix = speaker.index == 0 ? "" : String(speaker.index)
            let label = speaker.index == 0 ? "" : "speaker \u{201C}\(speaker.name)\u{201D} "
            if let off = ini.value("general", "Off" + suffix).flatMap(APOFormat.number), off == 1 { continue }
            let targets = speaker.targets.trimmingCharacters(in: .whitespaces)
            let isCopy = targets.lowercased() != "all" && targets.contains("=")
            if isCopy {
                emit("Copy: \(targets)", "\(label)targets")
                emit("Channel: \(targets.prefix { $0 != "=" })", "\(label)targets")
            } else {
                emit("Channel: \(targets)", "\(label)targets")
            }
            var preamp = 0.0
            if let raw = ini.value("general", "PreAmp" + suffix) {
                if let value = APOFormat.number(raw.trimmingCharacters(in: .whitespaces)) { preamp = value } else {
                    warnings.append("\(label)PreAmp\(suffix) \u{201C}\(raw)\u{201D} is not a number; used 0 dB")
                }
            }
            // Peace writes a zero preamp only for the group every channel shares; eq writes it there
            // too, or a GraphicEQ-only file would get AutoEq's derived preamp instead of none.
            if speaker.index == 0 || preamp != 0 { emit(String(format: "Preamp: %.6f dB", preamp), "\(label)PreAmp") }

            let graphic = ini.value("general", "GraphicEQ" + suffix).flatMap(APOFormat.number).map { $0 != 0 } ?? false
            var points: [String] = []
            for slider in 1...slidersMax {
                let place = "\(label)slider \(slider)"
                guard let rawFrequency = ini.value("frequencies" + suffix, "Frequency\(slider)") else { continue }
                guard let frequency = APOFormat.number(rawFrequency.trimmingCharacters(in: .whitespaces)) else {
                    warnings.append("\(place): skipped, frequency \u{201C}\(rawFrequency)\u{201D} is not a number"); continue
                }
                guard frequency > 0 else { continue }
                let f = min(frequency, maxSliderFrequency)
                func number(_ section: String, _ key: String, _ fallback: Double) -> Double? {
                    guard let raw = ini.value(section + suffix, "\(key)\(slider)") else { return fallback }
                    return APOFormat.number(raw.trimmingCharacters(in: .whitespaces))
                }
                guard let gain = number("gains", "Gain", 0), let quality = number("qualities", "Quality", 1.41),
                      let filterNumber = number("filters", "Filter", 0), let disabled = number("disabled", "Disabled", 0) else {
                    warnings.append("\(place): skipped, a setting is not a number"); continue
                }
                if graphic {
                    points.append(String(format: "%.6f %.6f", f, gain))
                    continue
                }
                guard disabled == 0 else { continue }
                guard let typeIndex = ImportCheck.integer(filterNumber), filterTypes.indices.contains(typeIndex) else {
                    warnings.append(String(format: "%@: skipped, unknown filter type %g", place, filterNumber)); continue
                }
                let type = filterTypes[typeIndex]
                if type.gain && gain == 0 { continue }
                for line in apoLines(typeIndex, frequency: f, gain: gain, quality: quality, place: place, warnings: &warnings) {
                    emit(line, place)
                }
            }
            if graphic, !points.isEmpty { emit("GraphicEQ: " + points.joined(separator: "; "), "\(label)GraphicEQ") }
        }

        for (index, command) in commands(ini, "1") { emit(command, "[Commands] line \(index)") }

        var result: ImportResult
        do {
            result = try APOFormat.parse(text: lines.joined(separator: "\n"), places: places)
        } catch ImportError.nothingUsable(let reasons) {
            throw ImportError.nothingUsable(warnings + reasons)
        } catch ImportError.unrecognized {
            throw ImportError.nothingUsable(warnings.isEmpty ? ["the configuration sets no filter"] : warnings)
        }
        result.warnings = warnings + result.warnings
        result.format = result.bands != nil && result.filters.isEmpty ? "Peace (10 bands)" : "Peace"
        return result
    }

    /// The Equalizer APO lines Peace writes for one slider.
    private static func apoLines(_ typeIndex: Int, frequency: Double, gain: Double, quality: Double, place: String, warnings: inout [String]) -> [String] {
        let fc = String(format: "Fc %.6f Hz", frequency)
        switch typeIndex {
        case 10...13:
            // Peace's Butterworth and Linkwitz-Riley cascades: Quality is the order.
            guard quality >= 0, quality <= Double(maxPassOrder) else {
                warnings.append(String(format: "%@: skipped, order %g is steeper than %d", place, quality, maxPassOrder)); return []
            }
            let lowPass = typeIndex == 10 || typeIndex == 12
            let token = lowPass ? "LPQ" : "HPQ"
            var order = quality
            var factors = Int((quality / 2).rounded(.down))
            var firstOrder = false
            var cascade = 1
            if typeIndex >= 12 {
                cascade = 2
                firstOrder = factors % 2 == 1
                factors /= 2
                order /= 2
            }
            var lines: [String] = []
            if firstOrder { lines.append("Filter: ON \(token) \(fc) Q 0.5") }
            for k in stride(from: factors, through: 1, by: -1) {
                let q = 1 / (-2 * cos(Double.pi * (2 * Double(k) + order - 1) / (2 * order)))
                guard q.isFinite, q > 0 else {
                    warnings.append(String(format: "%@: skipped, order %g has no Butterworth Q", place, quality)); return []
                }
                lines += Array(repeating: String(format: "Filter: ON %@ %@ Q %.6f", token, fc, q), count: cascade)
            }
            return lines
        default:
            let type = filterTypes[typeIndex]
            var token = type.token
            if typeIndex == 14 || typeIndex == 15 { token = String(token.prefix(3)) }
            if typeIndex == 16 || typeIndex == 17 { token = String(token.prefix(2)) }
            var line = "Filter: ON \(token)"
            let isSlope = typeIndex == 8 || typeIndex == 9
            if isSlope { line += String(format: " %.6f dB", quality) }
            line += " \(fc)"
            if type.gain { line += String(format: " Gain %.6f dB", gain) }
            if type.quality && !isSlope { line += String(format: " Q %.6f", quality) }
            return [line]
        }
    }

    private static func speakers(_ ini: INI) -> [(index: Int, targets: String, name: String)] {
        var found: [(Int, String, String)] = []
        while found.count < 64, ini.value("speakers", "SpeakerId\(found.count)") != nil {
            let i = found.count
            found.append((i, ini.value("speakers", "SpeakerTargets\(i)") ?? "all", ini.value("speakers", "SpeakerName\(i)") ?? "speaker \(i)"))
        }
        if found.isEmpty { return defaultTargets.enumerated().map { ($0, $1, $1) } }
        return found
    }

    /// Peace stores its command window one command per tab.
    private static func commands(_ ini: INI, _ key: String) -> [(Int, String)] {
        guard let raw = ini.value("commands", key) else { return [] }
        return raw.split(separator: "\t").enumerated().map { ($0 + 1, String($1)) }
    }

    /// Case-insensitive like Windows' `GetPrivateProfileString`, which Peace reads through; the
    /// first of a repeated key wins, as there.
    private struct INI {
        var values: [String: [String: String]] = [:]

        init(_ text: String) {
            var section = ""
            for raw in APOFormat.lines(text) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("["), line.hasSuffix("]") {
                    section = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).lowercased()
                } else if let equals = line.firstIndex(of: "="), !line.hasPrefix(";") {
                    let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                    if values[section]?[key] == nil { values[section, default: [:]][key] = String(line[line.index(after: equals)...]) }
                }
            }
        }

        func value(_ section: String, _ key: String) -> String? { values[section.lowercased()]?[key.lowercased()] }
    }
}
