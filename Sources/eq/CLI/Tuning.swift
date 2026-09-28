import Foundation

extension CLI {
    static let filterUsage = "eq filter [add <type> <freq> <gain> [q] | set <n> <key>=<value> … | rm <n>|all] [--device DEVICE]"

    static let filterTypeNames: [String: FilterType] = [
        "peak": .peak, "lowshelf": .lowShelf, "highshelf": .highShelf, "lowpass": .lowPass,
        "highpass": .highPass, "notch": .notch, "bandpass": .bandPass,
    ]

    /// A shelf or pass at 0.707 is the Butterworth shape, no bump at the corner; a bell at 1.41 is
    /// about an octave wide, the same Q the graphic bands use.
    static func defaultQ(for type: FilterType) -> Double {
        switch type {
        case .peak, .notch, .bandPass: return 1.41
        case .lowShelf, .highShelf, .lowPass, .highPass: return 0.707
        }
    }

    static func filter(_ args: [String], _ ctx: CLIContext) throws -> Output {
        let (explicit, rest) = try splitDeviceOption(args, flag: "--device", ctx)
        let operands = Array(rest.dropFirst())
        switch rest.first ?? "list" {
        case "list":
            guard operands.isEmpty else { throw CLIError.usage(filterUsage) }
            return try filterList(explicit, ctx)
        case "add":
            guard (3...4).contains(operands.count) else { throw CLIError.usage("eq filter add <type> <freq> <gain> [q] [--device DEVICE]") }
            let type = try filterType(operands[0])
            let added = Filter(type: type, frequency: try filterFrequency(operands[1]), gain: try filterGain(operands[2]),
                               q: operands.count == 4 ? try filterQ(operands[3]) : defaultQ(for: type), origin: .hand)
            return try editProfile(explicit, ctx) { profile in
                profile.filters.append(added)
                return "added filter \(profile.filters.count)"
            }
        case "set":
            guard operands.count >= 2 else { throw CLIError.usage("eq filter set <n> <key>=<value> … [--device DEVICE]") }
            return try editProfile(explicit, ctx) { profile in
                let index = try filterIndex(operands[0], count: profile.filters.count)
                for assignment in operands.dropFirst() {
                    let parts = assignment.split(separator: "=", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { throw CLIError.usage("expected <key>=<value>, got \"\(assignment)\" (keys: freq gain q type)") }
                    switch parts[0].lowercased() {
                    case "freq": profile.filters[index].frequency = try filterFrequency(parts[1])
                    case "gain": profile.filters[index].gain = try filterGain(parts[1])
                    case "q": profile.filters[index].q = try filterQ(parts[1])
                    case "type": profile.filters[index].type = try filterType(parts[1])
                    default: throw CLIError.usage("unknown key \"\(parts[0])\" (keys: freq gain q type)")
                    }
                }
                return "changed filter \(index + 1)"
            }
        case "rm":
            guard operands.count == 1 else { throw CLIError.usage("eq filter rm <n>|all [--device DEVICE]") }
            return try editProfile(explicit, ctx) { profile in
                let hadImported = profile.filters.contains { $0.origin == .import }
                // A GraphicEQ import has no filters, so the label goes only with the last imported filter.
                defer { if hadImported, !profile.filters.contains(where: { $0.origin == .import }) { profile.imported = nil } }
                if operands[0].lowercased() == "all" {
                    let count = profile.filters.count
                    profile.filters = []
                    return "removed \(count) filter" + (count == 1 ? "" : "s")
                }
                let index = try filterIndex(operands[0], count: profile.filters.count)
                profile.filters.remove(at: index)
                return "removed filter \(index + 1)"
            }
        default:
            throw CLIError.usage(filterUsage)
        }
    }

    private static func filterList(_ explicit: Target?, _ ctx: CLIContext) throws -> Output {
        let config = try loadConfig(ctx)
        let target: Target
        if let explicit { target = explicit } else { target = try currentDevice(ctx) }
        let resolved = config.profile(forDeviceUID: target.uid)
        let sourceLabel = resolved.source == .device ? "own profile" : "default profile"
        let header = Table.paintedHeader("\(target.name) (\(sourceLabel))")
        let filters = resolved.profile.filters
        let body = filters.isEmpty
            ? Paint.ink(.dim, "  no filters — add one with eq filter add peak 3k -2")
            : Table.filters(filters, imported: resolved.profile.imported)
        let rows = filters.enumerated().map { index, filter in
            FilterRow(number: index + 1, type: filter.type, frequency: filter.frequency, gain: filter.gain, q: filter.q,
                      origin: filter.origin ?? .hand)
        }
        let report = FiltersReport(device: DeviceRef(uid: target.uid, name: target.name),
                                   source: resolved.source == .device ? "device" : "default",
                                   imported: resolved.profile.imported, filters: rows)
        return Output(header + "\n" + body, report)
    }

    /// Loads, edits the target's own profile, saves (validating) and shows the curve under a green
    /// line saying what happened.
    static func editProfile(_ explicit: Target?, _ ctx: CLIContext, _ edit: (inout Profile) throws -> String) throws -> Output {
        var config = try loadConfig(ctx)
        let target: Target
        if let explicit { target = explicit } else { target = try currentDevice(ctx) }
        var profile = editableProfile(config, target)
        let done = try edit(&profile)
        config.setProfile(profile, forDeviceUID: target.uid)
        try ctx.store.save(config)
        let text = Paint.ink(.green, done) + "\n" + Table.profile(profile, header: target.name, preset: presetMark(profile, config))
        return Output(text, ProfileReport(device: DeviceRef(uid: target.uid, name: target.name), source: "device",
                                          profile: profile, preset: presetMark(profile, config)?.name))
    }

    private static func filterType(_ token: String) throws -> FilterType {
        guard let type = filterTypeNames[token.lowercased()] else {
            throw CLIError.usage("unknown filter type \"\(token)\" — use one of peak lowshelf highshelf lowpass highpass notch bandpass")
        }
        return type
    }

    private static func filterFrequency(_ token: String) throws -> Double {
        guard let value = BandParser.frequency(token) else { throw CLIError.usage("not a frequency: \"\(token)\" (examples: 3k, 250hz, 1000)") }
        return value
    }

    private static func filterGain(_ token: String) throws -> Double {
        guard let value = Double(token.replacingOccurrences(of: ",", with: ".")), value.isFinite else { throw CLIError.badGain(token) }
        return value
    }

    private static func filterQ(_ token: String) throws -> Double {
        guard let value = Double(token.replacingOccurrences(of: ",", with: ".")), value.isFinite else {
            throw CLIError.usage("not a Q: \"\(token)\" (examples: 0.707, 1.41, 4)")
        }
        return value
    }

    private static func filterIndex(_ token: String, count: Int) throws -> Int {
        guard let number = Int(token), number >= 1, number <= count else {
            throw CLIError.noSuchFilter(token, count)
        }
        return number - 1
    }

    /// `eq bass|treble|tilt <value>`: sets that part of the preference layer, 0 removes it.
    static func preference(_ part: String, _ args: [String], _ ctx: CLIContext) throws -> Output {
        let (explicit, rest) = try splitDeviceOption(args, flag: "--device", ctx)
        let unit = part == "tilt" ? "dB/octave" : "dB"
        guard rest.count == 1 else { throw CLIError.usage("eq \(part) [--device DEVICE] <\(part == "tilt" ? "slope" : "gain")>") }
        let value: Double
        if part == "tilt" {
            guard let slope = Double(rest[0].replacingOccurrences(of: ",", with: ".")), slope.isFinite else { throw CLIError.badGain(rest[0]) }
            guard Preference.tiltRange.contains(slope) else {
                throw CLIError.usage("tilt \(slope) dB/octave outside \(Preference.tiltRange.lowerBound)…\(Preference.tiltRange.upperBound)")
            }
            value = slope
        } else {
            value = try BandParser.gain(rest[0])
        }
        return try editProfile(explicit, ctx) { profile in
            profile.setPreference { layer in
                switch part {
                case "bass": layer.bass = value
                case "treble": layer.treble = value
                default: layer.tilt = value
                }
            }
            return "\(part) " + String(format: "%+.1f", value) + " \(unit)"
        }
    }

    static let boostUsage = "eq boost [<instrument> <gain>] [--device DEVICE]"

    /// `eq boost <instrument> <gain>` turns that instrument's knob, 0 removes it; alone it lists the knobs.
    static func boost(_ args: [String], _ ctx: CLIContext) throws -> Output {
        let (explicit, rest) = try splitDeviceOption(args, flag: "--device", ctx)
        if rest.isEmpty { return try boostList(explicit, ctx) }
        guard rest.count == 2 else { throw CLIError.usage(boostUsage) }
        guard let instrument = Instruments.named(rest[0]) else {
            throw CLIError.usage("unknown instrument \"\(rest[0])\" — use one of \(Instruments.all.map(\.name).joined(separator: " "))")
        }
        let gain = try BandParser.gain(rest[1])
        return try editProfile(explicit, ctx) { profile in
            profile.setKnob(instrument.name) { _ in gain }
            return "boost \(instrument.name) " + String(format: "%+.1f", gain) + " dB"
        }
    }

    private static func boostList(_ explicit: Target?, _ ctx: CLIContext) throws -> Output {
        let config = try loadConfig(ctx)
        let target: Target
        if let explicit { target = explicit } else { target = try currentDevice(ctx) }
        let resolved = config.profile(forDeviceUID: target.uid)
        let sourceLabel = resolved.source == .device ? "own profile" : "default profile"
        let set = Dictionary(uniqueKeysWithValues: resolved.profile.knobs.map { ($0.instrument.name, $0.gain) })
        let nameWidth = (Instruments.all.map(\.name.count).max() ?? 0) + 2
        let rangeWidth = (Instruments.all.map { InstrumentTable.rangeText($0.characterRange).count }.max() ?? 0) + 2
        let lines = Instruments.all.map { instrument -> String in
            let gain = set[instrument.name] ?? 0
            let range = InstrumentTable.rangeText(instrument.characterRange)
            return "  " + Paint.ink(.bold, instrument.name) + String(repeating: " ", count: nameWidth - instrument.name.count)
                + Paint.ink(.dim, range) + String(repeating: " ", count: rangeWidth - range.count)
                + Paint.ink(gain == 0 ? .dim : Paint.gain(gain), Table.gain(gain)) + " dB"
        }
        let report = BoostReport(device: DeviceRef(uid: target.uid, name: target.name),
                                 source: resolved.source == .device ? "device" : "default",
                                 knobs: Instruments.all.map { BoostRow(instrument: $0.name, range: $0.characterRange, gain: set[$0.name] ?? 0) })
        return Output(([Table.paintedHeader("\(target.name) (\(sourceLabel))")] + lines).joined(separator: "\n"), report)
    }
}
