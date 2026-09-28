import Foundation

/// One named span of an instrument's sound, in Hz — a fundamental, a formant, a harmonic.
struct HzRange: Encodable, Equatable {
    var name: String
    var low: Double
    var high: Double
}

/// An instrument as one or more real Hz ranges: what the watch draws, focuses on and solos,
/// and what `eq zones` lists. `character` names the range its knob turns.
struct Instrument: Equatable {
    var name: String
    var short: String
    var ranges: [HzRange]
    var character: String

    var characterRange: HzRange { ranges.first { $0.name == character } ?? outerSpan }

    /// One peak at the range's geometric centre, as wide as the range: Q = f0 / (high − low).
    func knob(gain: Double) -> EQBand {
        let range = characterRange
        let centre = (range.low * range.high).squareRoot()
        return EQBand(type: .peak, frequency: centre, gain: gain, q: centre / (range.high - range.low))
    }

    /// The bounds a solo uses for a multi-range instrument: outside edges, not a union of gaps.
    var outerSpan: HzRange {
        HzRange(name: name, low: ranges.map(\.low).min() ?? 0, high: ranges.map(\.high).max() ?? 0)
    }

    var bands: [Int] { Array(Set(ranges.flatMap(Instruments.bands(touchedBy:)))).sorted() }
}

extension Instrument: Encodable {
    private enum CodingKeys: String, CodingKey { case name, ranges, bands, character }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(ranges, forKey: .ranges)
        try container.encode(bands.map { Config.bandFrequencies[$0] }, forKey: .bands)
        try container.encode(character, forKey: .character)
    }
}

/// The instrument table from the mixing charts in the spec (coarse on purpose, guidance not gospel).
/// Each character range is the one a mixing engineer reaches for to bring that instrument forward.
enum Instruments {
    static let all: [Instrument] = [
        // Thump is the weight you feel; the click shares 2–5 kHz with snare crack and guitar bite.
        Instrument(name: "kick", short: "kck", ranges: [
            HzRange(name: "thump", low: 50, high: 100),
            HzRange(name: "beater click", low: 2000, high: 5000),
        ], character: "thump"),
        // Growl makes a bass line heard on small speakers without the kick's thump; the low end is `eq bass`.
        Instrument(name: "bass", short: "bas", ranges: [
            HzRange(name: "fundamental", low: 40, high: 250),
            HzRange(name: "growl/attack", low: 700, high: 1200),
        ], character: "growl/attack"),
        // Crack cuts through a mix; the body sits on the bass fundamental.
        Instrument(name: "snare", short: "snr", ranges: [
            HzRange(name: "body", low: 150, high: 250),
            HzRange(name: "crack", low: 4000, high: 6000),
        ], character: "crack"),
        // Pick attack brings a guitar forward; its body spans four octaves. Shared with voice presence.
        Instrument(name: "guitar", short: "gtr", ranges: [
            HzRange(name: "body", low: 80, high: 1200),
            HzRange(name: "bite", low: 2000, high: 5000),
        ], character: "bite"),
        // Hammer attack and clarity; the fundamental is most of the keyboard, 27 Hz–4.2 kHz.
        Instrument(name: "piano", short: "pno", ranges: [
            HzRange(name: "fundamental", low: 27, high: 4200),
            HzRange(name: "brightness", low: 4000, high: 8000),
        ], character: "brightness"),
        // Presence is intelligibility, where the ear is most sensitive; F1/F2 change with every vowel.
        Instrument(name: "voice", short: "vox", ranges: [
            HzRange(name: "fundamental", low: 85, high: 255),
            HzRange(name: "F1", low: 300, high: 1000),
            HzRange(name: "F2", low: 900, high: 2800),
            HzRange(name: "presence", low: 2000, high: 5000),
            HzRange(name: "sibilance", low: 5000, high: 9000),
        ], character: "presence"),
        Instrument(name: "cymbals", short: "cym", ranges: [
            HzRange(name: "shimmer", low: 6000, high: 16000),
        ], character: "shimmer"),
        Instrument(name: "air", short: "air", ranges: [
            HzRange(name: "sparkle", low: 10000, high: 20000),
        ], character: "sparkle"),
    ]

    /// By full name or the watch's three-letter one, in any case.
    static func named(_ query: String) -> Instrument? {
        let needle = query.lowercased()
        return all.first { $0.name == needle || $0.short == needle }
    }

    /// A band touches a range when the range overlaps the octave around the band's centre
    /// frequency, `[f/√2, f·√2]` — the slice of spectrum that band's column stands in for.
    static func bands(touchedBy range: HzRange) -> [Int] {
        Config.bandFrequencies.indices.filter { i in
            let f = Config.bandFrequencies[i]
            let low = f / 2.0.squareRoot()
            let high = f * 2.0.squareRoot()
            return range.low < high && range.high > low
        }
    }
}

/// Renders `eq zones`: one line per range, the instrument name only on its first line so a
/// multi-range instrument reads as a small tree instead of repeating itself.
enum InstrumentTable {
    static func hz(_ value: Double, gap: String = "") -> String {
        guard value >= 1000 else { return "\(Int(value.rounded()))\(gap)Hz" }
        let k = value / 1000
        let text = k.rounded() == k ? String(Int(k)) : String(format: "%.1f", k)
        return "\(text)\(gap)kHz"
    }

    static func rangeText(_ range: HzRange) -> String { "\(range.name) \(hz(range.low))–\(hz(range.high))" }

    static func bandsText(_ range: HzRange) -> String {
        Instruments.bands(touchedBy: range).map { Config.bandLabels[$0] }.joined(separator: " ")
    }

    static func render(_ instruments: [Instrument]) -> [String] {
        let nameWidth = (instruments.map(\.name.count).max() ?? 0) + 1
        let rangeWidth = (instruments.flatMap { $0.ranges.map { rangeText($0).count } }.max() ?? 0) + 1
        return instruments.flatMap { instrument -> [String] in
            instrument.ranges.enumerated().map { index, range in
                let pad = String(repeating: " ", count: nameWidth - instrument.name.count)
                let nameCell = index == 0 ? Paint.ink(.bold, instrument.name) + pad : String(repeating: " ", count: nameWidth)
                let rangeCell = rangeText(range).padding(toLength: rangeWidth, withPad: " ", startingAt: 0)
                return nameCell + rangeCell + Paint.ink(.dim, bandsText(range))
            }
        }
    }
}
