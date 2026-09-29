import Foundation

/// One thing the Tune view edits: a band, the preamp, a tone shelf, the tilt, the compressor's
/// mode, the colour's kind or its amount.
enum TuneControl: Hashable {
    case band(Int)
    case preamp, bass, treble, tilt
    case comp, colour, amount

    static let all: [TuneControl] = (0..<Config.bandFrequencies.count).map(TuneControl.band) + [.preamp, .bass, .treble, .tilt, .comp, .colour, .amount]
    /// Tab walks these; each keeps the control it had selected.
    static let groups = ["bands", "chain", "dynamics"]

    var group: Int {
        switch self {
        case .band: return 0
        case .preamp, .bass, .treble, .tilt: return 1
        case .comp, .colour, .amount: return 2
        }
    }

    var index: Int { Self.all.firstIndex(of: self) ?? 0 }

    var name: String {
        switch self {
        case .band(let i): return Config.bandLabels[i].replacingOccurrences(of: "Hz", with: " Hz").replacingOccurrences(of: "k ", with: " k")
        case .preamp: return "preamp"
        case .bass: return "bass"
        case .treble: return "treble"
        case .tilt: return "tilt"
        case .comp: return "comp"
        case .colour: return "colour"
        case .amount: return "amount"
        }
    }

    /// A mode, not a number: ↑ and ↓ take the next one.
    var isChoice: Bool { self == .comp || self == .colour }

    var unit: String {
        switch self {
        case .tilt: return "dB/octave"
        case .amount, .comp, .colour: return ""
        default: return "dB"
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .band, .bass, .treble: return Config.gainRange
        case .preamp: return Config.preampRange
        case .tilt: return Preference.tiltRange
        case .amount: return Dynamics.amountRange
        case .comp: return 0...Double(Dynamics.Compressor.allCases.count)
        case .colour: return 0...Double(Dynamics.ColourKind.allCases.count)
        }
    }

    /// A key's nudge (±0.1, ±0.5 or ±3, as a band takes it) in this control's own units.
    func delta(_ nudge: Double) -> Double {
        let size = abs(nudge) < 0.3 ? 0 : (abs(nudge) < 1 ? 1 : 2)
        let steps: [Double]
        switch self {
        case .band, .preamp, .bass, .treble: steps = [0.1, 0.5, 3]
        case .tilt: steps = [0.05, 0.1, 0.5]
        case .amount: steps = [0.05, 0.1, 0.3]
        case .comp, .colour: steps = [1, 1, 1]
        }
        return nudge < 0 ? -steps[size] : steps[size]
    }

    func value(in profile: Profile) -> Double {
        switch self {
        case .band(let i): return profile.bands.indices.contains(i) ? profile.bands[i] : 0
        case .preamp: return profile.preamp
        case .bass: return profile.preference?.bass ?? 0
        case .treble: return profile.preference?.treble ?? 0
        case .tilt: return profile.preference?.tilt ?? 0
        case .comp: return profile.dynamics?.comp.flatMap { Dynamics.Compressor.allCases.firstIndex(of: $0) }.map { Double($0 + 1) } ?? 0
        case .colour: return profile.dynamics?.color.flatMap { Dynamics.ColourKind.allCases.firstIndex(of: $0.kind) }.map { Double($0 + 1) } ?? 0
        case .amount: return profile.dynamics?.color?.amount ?? 0
        }
    }

    /// `-3.0`, `0.30` for the tilt, `night`, `off`.
    func text(in profile: Profile) -> String {
        let v = value(in: profile)
        switch self {
        case .comp: return profile.dynamics?.comp?.rawValue ?? "off"
        case .colour: return profile.dynamics?.color?.kind.rawValue ?? "off"
        case .amount: return profile.dynamics?.color == nil ? "off" : String(format: "%.2f", v)
        case .tilt: return MeterScene.gainText(v, digits: 2)
        default: return MeterScene.gainText(v)
        }
    }

    /// Hundredths, so a stepped 3.7 saves as 4.2, not 4.2000000000000002.
    private static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    /// Moved by `delta`, held inside its range; a mode steps to the next one and stops at the ends.
    func adjust(_ profile: inout Profile, by delta: Double) throws {
        if self == .amount, profile.dynamics?.color == nil { throw CLI.WatchSession.Note(description: "colour is off — pick tape or tube first") }
        let current = value(in: profile)
        let lower = self == .amount ? abs(self.delta(0.1)) : range.lowerBound
        try set(&profile, Self.rounded(min(max(current + delta, lower), range.upperBound)))
    }

    /// Set outright; out of range is refused with the range in the message.
    func assign(_ profile: inout Profile, _ value: Double) throws {
        guard value.isFinite, range.contains(value) else {
            throw CLI.WatchSession.Note(description: "\(name) \(MeterScene.gainText(value)) is outside \(Table.gain(range.lowerBound))…\(Table.gain(range.upperBound)) \(unit)")
        }
        try set(&profile, Self.rounded(value))
    }

    private func set(_ profile: inout Profile, _ value: Double) throws {
        switch self {
        case .band(let i):
            guard profile.bands.indices.contains(i) else { return }
            profile.bands[i] = value
        case .preamp: profile.preamp = value
        case .bass: profile.setPreference { $0.bass = value }
        case .treble: profile.setPreference { $0.treble = value }
        case .tilt: profile.setPreference { $0.tilt = value }
        case .comp:
            let modes = Dynamics.Compressor.allCases
            profile.setDynamics { $0.comp = value >= 1 ? modes[min(Int(value) - 1, modes.count - 1)] : nil }
        case .colour:
            let kinds = Dynamics.ColourKind.allCases
            profile.setDynamics { layer in
                layer.color = value >= 1 ? .init(kind: kinds[min(Int(value) - 1, kinds.count - 1)],
                                                 amount: layer.color?.amount ?? CLI.WatchSession.colourStart) : nil
            }
        case .amount:
            profile.setDynamics { layer in
                if value <= 0 { layer.color = nil } else { layer.color?.amount = value }
            }
        }
    }

    /// What Enter's line means: a number, or a mode's name.
    func parse(_ text: String) -> Double? {
        let word = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch self {
        case .comp:
            if ["off", "none"].contains(word) { return 0 }
            return Dynamics.Compressor.allCases.firstIndex { $0.rawValue == word }.map { Double($0 + 1) } ?? Double(word)
        case .colour:
            if ["off", "none"].contains(word) { return 0 }
            return Dynamics.ColourKind.allCases.firstIndex { $0.rawValue == word }.map { Double($0 + 1) } ?? Double(word)
        default:
            return Double(word.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "db", with: "")
                .trimmingCharacters(in: .whitespaces))
        }
    }

    var prompt: String {
        switch self {
        case .comp: return "comp (off gentle night): "
        case .colour: return "colour (off tape tube): "
        case .amount: return "colour amount (0–1): "
        default: return "\(name) \(unit): "
        }
    }
}

/// What the Tune view has selected, and what each group had when Tab left it.
struct TuneState: Equatable {
    var selected = TuneControl.band(0)
    var memory: [TuneControl] = [.band(0), .preamp, .comp]

    mutating func select(_ control: TuneControl) {
        selected = control
        memory[control.group] = control
    }

    mutating func move(_ delta: Int) {
        let all = TuneControl.all
        select(all[min(max(selected.index + delta, 0), all.count - 1)])
    }

    mutating func jump(_ delta: Int) {
        let count = TuneControl.groups.count
        select(memory[((selected.group + delta) % count + count) % count])
    }
}
