import Foundation

struct Zone: Encodable, Equatable {
    var name: String
    var short: String
    var bands: [Int]
    var why: String

    private enum CodingKeys: String, CodingKey { case name, bands, why }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(bands.map { Config.bandFrequencies[$0] }, forKey: .bands)
        try container.encode(why, forKey: .why)
    }
}

enum ZoneMode {
    case off, compact, all

    var next: ZoneMode {
        switch self {
        case .off: return .compact
        case .compact: return .all
        case .all: return .off
        }
    }

    var zones: [Zone] {
        switch self {
        case .off: return []
        case .compact: return Zones.compact
        case .all: return Zones.all
        }
    }
}

enum Zones {
    static let all: [Zone] = [
        Zone(name: "sub", short: "sub", bands: [0, 1], why: "felt more than heard; rumble"),
        Zone(name: "kick", short: "kck", bands: [1, 2], why: "thump and punch of the bass drum"),
        Zone(name: "bass", short: "bas", bands: [1, 2, 3], why: "bass guitar body and definition"),
        Zone(name: "mud", short: "mud", bands: [3, 4], why: "warmth and fullness; too much turns muddy"),
        Zone(name: "guitar", short: "gtr", bands: [3, 4, 5, 6], why: "body to bite of guitars and keys"),
        Zone(name: "voice", short: "vox", bands: [4, 5, 6, 7], why: "vowels at 500–1k, intelligibility and presence at 2–4k"),
        Zone(name: "snare", short: "snr", bands: [3, 7], why: "body and crack"),
        Zone(name: "cymbals", short: "cym", bands: [7, 8, 9], why: "attack and shimmer of hats and cymbals"),
        Zone(name: "sibilance", short: "sib", bands: [7, 8], why: "the \"s\" of a voice; a cut here tames harshness"),
        Zone(name: "air", short: "air", bands: [9], why: "sparkle and space"),
    ]

    static let compact = all.filter { ["sub", "kick", "bass", "guitar", "voice", "cymbals", "air"].contains($0.name) }

    /// "sibilance" is the longest name; the short names are three letters plus a gap.
    static let fullNameWidth = 9
    static let shortNameWidth = 4

    struct Placement: Equatable {
        var start: Int
        var nameWidth: Int
        var full: Bool
    }

    /// Where the band table starts when zone rows sit under it: full names in the centring pad
    /// when it is wide enough, otherwise short names and the whole frame shifted right to make
    /// room — never past the right edge, since the bars matter more than the names.
    static func placement(_ layout: WatchLayout) -> Placement {
        let room = max(layout.width - layout.tableWidth, 0)
        if room / 2 >= fullNameWidth { return Placement(start: room / 2, nameWidth: fullNameWidth, full: true) }
        let start = min(max(room - shortNameWidth, 0) / 2 + shortNameWidth, room)
        return Placement(start: start, nameWidth: shortNameWidth, full: false)
    }

    /// One row per zone in screen columns. A zone's contiguous bands draw one `━` segment from
    /// the first band's bar centre to the last's; a lone band covers its bar. The loudest band
    /// in the zone lends its cells the bar's ink; everything else is dim. `why` adds the reason
    /// after the table's right edge.
    static func render(_ zones: [Zone], layout: WatchLayout, levels: [Double], gains: [Double],
                       why: Bool = false) -> [String] {
        let columns = layout.visibleColumns
        let place = placement(layout)
        let end = place.start + layout.tableWidth
        let levels = Watch.padded(levels, to: columns, with: Watch.floorDB)
        let gains = Watch.padded(gains, to: columns, with: 0)
        return zones.map { zone in
            let label = place.full ? zone.name : zone.short
            let nameColumn = max(place.start - place.nameWidth, 0)
            let firstFree = nameColumn + label.count + 1
            let visible = zone.bands.filter { $0 >= 0 && $0 < columns }
            let loudest = visible.max { levels[$0] < levels[$1] }.flatMap { levels[$0] > Watch.floorDB + 0.5 ? $0 : nil }

            var owner = [Int?](repeating: nil, count: end)
            for run in runs(visible) {
                guard let first = run.first, let last = run.last else { continue }
                let lo = first == last ? layout.barStart(first) : layout.centre(first)
                let hi = first == last ? layout.barStart(first) + layout.barWidth - 1 : layout.centre(last)
                for c in max(place.start + lo, firstFree)...max(place.start + hi, firstFree) where c < end {
                    owner[c] = run.min { abs(layout.centre($0) - (c - place.start)) < abs(layout.centre($1) - (c - place.start)) }
                }
            }

            var line = String(repeating: " ", count: nameColumn) + Paint.ink(.dim, label)
            var column = nameColumn + label.count
            let lastOwned = owner.lastIndex { $0 != nil } ?? -1
            var c = column
            while c <= lastOwned {
                guard let band = owner[c] else { line += " "; c += 1; continue }
                let ink: Paint.Ink? = band == loudest ? Watch.barInk(gain: gains[band], level: levels[band]) : .dim
                var n = 0
                while c + n <= lastOwned, let next = owner[c + n],
                      (next == loudest) == (band == loudest) { n += 1 }
                let text = String(repeating: "━", count: n)
                line += ink.map { Paint.ink($0, text) } ?? text
                c += n
            }
            column = max(c, column)
            if why { line += String(repeating: " ", count: max(end - column, 0) + 2) + Paint.ink(.dim, zone.why) }
            return line
        }
    }

    private static func runs(_ bands: [Int]) -> [[Int]] {
        var result: [[Int]] = []
        for band in bands.sorted() {
            if let last = result.last?.last, last + 1 == band { result[result.count - 1].append(band) } else { result.append([band]) }
        }
        return result
    }
}

/// One named span of an instrument's sound, in Hz — a fundamental, a formant, a harmonic.
struct HzRange: Encodable, Equatable {
    var name: String
    var low: Double
    var high: Double
}

/// An instrument as one or more real Hz ranges, replacing the old band-index `Zone` for
/// everything that needs actual frequencies: focus, solo, and the `eq zones` table.
/// `Zone`/`Zones` above stay as the live-overlay renderer for `eq watch` until it moves onto this model.
struct Instrument: Equatable {
    var name: String
    var short: String
    var ranges: [HzRange]

    /// The bounds a solo uses for a multi-range instrument: outside edges, not a union of gaps.
    var outerSpan: HzRange {
        HzRange(name: name, low: ranges.map(\.low).min() ?? 0, high: ranges.map(\.high).max() ?? 0)
    }

    var bands: [Int] { Array(Set(ranges.flatMap(Instruments.bands(touchedBy:)))).sorted() }
}

extension Instrument: Encodable {
    private enum CodingKeys: String, CodingKey { case name, ranges, bands }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(ranges, forKey: .ranges)
        try container.encode(bands.map { Config.bandFrequencies[$0] }, forKey: .bands)
    }
}

/// The instrument table from the mixing charts in the spec (coarse on purpose, guidance not gospel).
enum Instruments {
    static let all: [Instrument] = [
        Instrument(name: "kick", short: "kck", ranges: [
            HzRange(name: "thump", low: 50, high: 100),
            HzRange(name: "beater click", low: 2000, high: 5000),
        ]),
        Instrument(name: "bass", short: "bas", ranges: [
            HzRange(name: "fundamental", low: 40, high: 250),
            HzRange(name: "growl/attack", low: 700, high: 1200),
        ]),
        Instrument(name: "snare", short: "snr", ranges: [
            HzRange(name: "body", low: 150, high: 250),
            HzRange(name: "crack", low: 4000, high: 6000),
        ]),
        Instrument(name: "guitar", short: "gtr", ranges: [
            HzRange(name: "body", low: 80, high: 1200),
            HzRange(name: "bite", low: 2000, high: 5000),
        ]),
        Instrument(name: "piano", short: "pno", ranges: [
            HzRange(name: "fundamental", low: 27, high: 4200),
            HzRange(name: "brightness", low: 4000, high: 8000),
        ]),
        Instrument(name: "voice", short: "vox", ranges: [
            HzRange(name: "fundamental", low: 85, high: 255),
            HzRange(name: "F1", low: 300, high: 1000),
            HzRange(name: "F2", low: 900, high: 2800),
            HzRange(name: "presence", low: 2000, high: 5000),
            HzRange(name: "sibilance", low: 5000, high: 9000),
        ]),
        Instrument(name: "cymbals", short: "cym", ranges: [
            HzRange(name: "shimmer", low: 6000, high: 16000),
        ]),
        Instrument(name: "air", short: "air", ranges: [
            HzRange(name: "sparkle", low: 10000, high: 20000),
        ]),
    ]

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
    static func hz(_ value: Double) -> String {
        guard value >= 1000 else { return "\(Int(value.rounded()))Hz" }
        let k = value / 1000
        let text = k.rounded() == k ? String(Int(k)) : String(format: "%.1f", k)
        return "\(text)kHz"
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
