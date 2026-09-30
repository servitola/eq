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

    /// Braille cells keyed by (column offset, row): each sample's dot joined to the one before
    /// by a Bresenham line on the 2×4 dot grid, so a steep slope is split between both dot
    /// columns and leaves no gap. `thick` doubles each dot downwards, to `bottom` at most, so the
    /// dots touch and read as a solid line.
    static func cells(_ ys: [Int], thick: Bool = false, bottom: Int = .max) -> [Int: [Int: Character]] {
        var masks: [Int: [Int: UInt32]] = [:]
        func plot(_ x: Int, _ y: Int) {
            for y in y...max(thick ? min(y + 1, bottom) : y, y) {
                masks[x / 2, default: [:]][y / 4, default: 0] |= bits[x % 2][y % 4]
            }
        }
        for (x, y) in ys.enumerated() {
            guard x > 0 else {
                plot(x, y)
                continue
            }
            let from = ys[x - 1], rise = abs(y - from), step = y > from ? 1 : -1
            if rise == 0 { plot(x, y) }
            for i in stride(from: 1, through: rise, by: 1) { plot(2 * i > rise ? x : x - 1, from + i * step) }
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
        var thick: Bool
    }

    private var key: Key?
    private(set) var ys: [Int] = []
    private(set) var glyphs: [Int: [Int: Character]] = [:]

    func update(_ gains: [Double], rate: Double, centres: [Int], x0: Int, width: Int, rows: Int, thick: Bool = false) {
        let next = Key(gains: gains, rate: rate, centres: centres, x0: x0, width: width, rows: rows, thick: thick)
        guard next != key else { return }
        key = next
        ys = Curve.dots(gains, rate: rate, centres: centres, x0: x0, width: width, rows: rows)
        glyphs = Curve.cells(ys, thick: thick, bottom: rows * 4 - 1)
    }
}

/// The curve's way to new gains: 300 ms, easing out, a step each meter frame, so a preset switch
/// or an edit is seen moving rather than jumping. It starts from wherever the curve is drawn.
struct CurveMotion: Equatable {
    static let frames = 9

    private(set) var from: [Double] = []
    private(set) var to: [Double] = []
    private(set) var step = CurveMotion.frames

    var moving: Bool { step < Self.frames }

    var gains: [Double] {
        guard moving else { return to }
        let e = Self.ease(Double(step) / Double(Self.frames))
        return zip(from, to).map { $0 + ($1 - $0) * e }
    }

    /// Cubic ease-out: most of the way in the first frames, settling gently.
    static func ease(_ t: Double) -> Double { 1 - pow(1 - min(max(t, 0), 1), 3) }

    /// One frame toward `target`. The first gains, or a different number of them, are taken as they
    /// are; new ones start a move from the curve on screen.
    mutating func advance(toward target: [Double]) {
        guard !to.isEmpty, target.count == to.count else {
            (from, to, step) = (target, target, Self.frames)
            return
        }
        if target != to {
            from = gains
            to = target
            step = 0
        }
        if moving { step += 1 }
    }
}
