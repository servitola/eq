import Foundation

/// The EQ's response drawn over the meter in braille, two dots across and four down a cell.
enum Curve {
    static let span = 12.0

    /// The ten bands as the daemon runs them: RBJ peaking, Q 1.41, at the device's rate.
    static func response(_ gains: [Double], at f: Double, rate: Double) -> Double {
        let fs = rate > 0 ? rate : Config.stabilityCheckRate
        var total = 0.0
        for (f0, gain) in zip(Config.bandFrequencies, gains) where gain != 0 && gain.isFinite && f0 < fs / 2 {
            total += BiquadCoefficients.make(type: .peak, frequency: f0, gainDB: gain, q: 1.41, sampleRate: fs)
                .magnitudeDB(at: f, sampleRate: fs)
        }
        return total
    }

    /// The dot row (0 at the top of `rows` cells) of each of the two samples per column across
    /// `width` columns from `x0`, ±12 dB top to bottom.
    static func dots(_ gains: [Double], rate: Double, centres: [Int], x0: Int, width: Int, rows: Int) -> [Int] {
        let total = Double(rows * 4 - 1)
        return (0..<(width * 2)).map { dx in
            let x = Double(x0) + (Double(dx) + 0.5) / 2
            let g = min(max(response(gains, at: Strip.frequency(at: x, centres: centres), rate: rate), -span), span)
            return Int(((span - g) / (2 * span) * total).rounded())
        }
    }

    private static let bits: [[UInt32]] = [[0x01, 0x02, 0x04, 0x40], [0x08, 0x10, 0x20, 0x80]]

    /// Braille cells keyed by (column offset, row): each sample's dot, joined to the one before
    /// by the dots between them so a steep slope stays one line.
    static func cells(_ ys: [Int]) -> [Int: [Int: Character]] {
        var masks: [Int: [Int: UInt32]] = [:]
        var previous: Int?
        for (dx, dy) in ys.enumerated() {
            var lo = dy, hi = dy
            if let previous, abs(dy - previous) > 1 {
                (lo, hi) = dy > previous ? (previous + 1, dy) : (dy, previous - 1)
            }
            for y in lo...hi {
                masks[dx / 2, default: [:]][y / 4, default: 0] |= bits[dx % 2][y % 4]
            }
            previous = dy
        }
        return masks.mapValues { $0.mapValues { Character(UnicodeScalar(0x2800 + $0)!) } }
    }
}

/// The curve changes only with the gains, the rate or the geometry: recomputed then, not per frame.
final class CurveCache {
    private struct Key: Equatable {
        var gains: [Double]
        var rate: Double
        var centres: [Int]
        var x0, width, rows: Int
    }

    private var key: Key?
    private(set) var ys: [Int] = []
    private(set) var glyphs: [Int: [Int: Character]] = [:]

    func update(_ gains: [Double], rate: Double, centres: [Int], x0: Int, width: Int, rows: Int) {
        let next = Key(gains: gains, rate: rate, centres: centres, x0: x0, width: width, rows: rows)
        guard next != key else { return }
        key = next
        ys = Curve.dots(gains, rate: rate, centres: centres, x0: x0, width: width, rows: rows)
        glyphs = Curve.cells(ys)
    }
}
