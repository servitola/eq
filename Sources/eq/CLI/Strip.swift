import Foundation

/// Instruments on the meter's log-frequency axis, so a range lands between band columns in
/// proportion to its octaves instead of snapping to whole bands.
enum Strip {
    /// Column of `f`: a band's bar centre is its own frequency, log2 f is interpolated between
    /// neighbouring centres, and past either end the edge octave's slope carries on. Unclamped, so
    /// a caller can tell a range that is off the table altogether.
    static func x(_ f: Double, centres: [Int]) -> Double {
        let logs = Config.bandFrequencies.map(log2)
        guard centres.count >= 2 else { return Double(centres.first ?? 0) }
        let l = log2(max(f, 1))
        let k = min(logs.indices.dropLast().first { l <= logs[$0 + 1] } ?? logs.count - 2, centres.count - 2)
        let a = Double(centres[k]), b = Double(centres[k + 1])
        return a + (b - a) * (l - logs[k]) / (logs[k + 1] - logs[k])
    }

    /// The frequency at column `x`, the inverse of `x(_:centres:)`.
    static func frequency(at x: Double, centres: [Int]) -> Double {
        let logs = Config.bandFrequencies.map(log2)
        guard centres.count >= 2 else { return Config.bandFrequencies[0] }
        let k = centres.indices.dropLast().first { x <= Double(centres[$0 + 1]) } ?? centres.count - 2
        let a = Double(centres[k]), b = Double(centres[k + 1])
        return pow(2, logs[k] + (logs[k + 1] - logs[k]) * (x - a) / (b - a))
    }

    struct Segment: Equatable {
        var name: String
        var lo: Int
        var hi: Int
        var count: Int { hi - lo + 1 }
    }

    /// Column spans of an instrument's ranges, clamped to `columns`, one blank column between
    /// neighbours. Voice's F1 and F2 share 900–1000 Hz; a shared column would read as one range,
    /// so an overlap is split down the middle instead of going to whichever range came first.
    static func segments(_ instrument: Instrument, centres: [Int], columns: ClosedRange<Int>) -> [Segment] {
        var result: [Segment] = []
        for range in instrument.ranges.sorted(by: { $0.low < $1.low }) {
            let a = x(range.low, centres: centres), b = x(range.high, centres: centres)
            guard b >= Double(columns.lowerBound), a <= Double(columns.upperBound) else { continue }
            var segment = Segment(name: range.name, lo: max(Int(a.rounded()), columns.lowerBound),
                                  hi: min(Int(b.rounded()), columns.upperBound))
            if var previous = result.last, segment.lo <= previous.hi + 1 {
                let cut = (previous.hi + segment.lo) / 2
                previous.hi = min(previous.hi, cut - 1)
                segment.lo = max(segment.lo, cut + 1)
                result.removeLast()
                if previous.lo <= previous.hi { result.append(previous) }
            }
            segment.lo = max(segment.lo, (result.last?.hi ?? Int.min / 2) + 2)
            if segment.lo <= segment.hi { result.append(segment) }
        }
        return result
    }

    enum Part { case stroke, name, gap }

    /// The span's name sits in its middle when a stroke and a space still fit on either side.
    static func labelled(_ segment: Segment, stroke: Character, ends: (Character, Character)? = nil) -> [(glyph: Character, part: Part)] {
        let n = segment.count
        var cells = [(glyph: Character, part: Part)](repeating: (stroke, .stroke), count: n)
        if let ends {
            if n == 1 { cells[0].glyph = "│" } else { cells[0].glyph = ends.0; cells[n - 1].glyph = ends.1 }
        }
        let name = Array(segment.name)
        guard name.count + 4 <= n else { return cells }
        let at = (n - name.count) / 2
        cells[at - 1] = (" ", .gap)
        cells[at + name.count] = (" ", .gap)
        for (i, c) in name.enumerated() { cells[at + i] = (c, .name) }
        return cells
    }
}
