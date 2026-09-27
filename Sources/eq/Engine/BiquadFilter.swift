// Vendored from zollans/OnlyEQ @ 6569655 (Unlicense), trimmed for eq.
import Foundation

/// RBJ Audio-EQ-Cookbook biquad coefficients, normalized (a0 == 1).
struct BiquadCoefficients: Equatable {
    // The render path is Float32. Store its coefficients in the same format so
    // every sample does five fused operations instead of five Double→Float
    // conversions per enabled band.
    var b0: Float = 1, b1: Float = 0, b2: Float = 0
    var a1: Float = 0, a2: Float = 0

    static func make(type: FilterType, frequency: Double, gainDB: Double, q rawQ: Double, sampleRate: Double) -> BiquadCoefficients {
        let fc = min(max(frequency, 1), sampleRate * 0.499)
        let q = max(rawQ, 0.025)
        let a = pow(10.0, gainDB / 40.0)
        let w0 = 2.0 * Double.pi * fc / sampleRate
        let cosw = cos(w0), sinw = sin(w0)
        let alpha = sinw / (2.0 * q)

        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        switch type {
        case .peak:
            b0 = 1 + alpha * a
            b1 = -2 * cosw
            b2 = 1 - alpha * a
            a0 = 1 + alpha / a
            a1 = -2 * cosw
            a2 = 1 - alpha / a
        case .lowShelf:
            let s = 2 * sqrt(a) * alpha
            b0 = a * ((a + 1) - (a - 1) * cosw + s)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosw)
            b2 = a * ((a + 1) - (a - 1) * cosw - s)
            a0 = (a + 1) + (a - 1) * cosw + s
            a1 = -2 * ((a - 1) + (a + 1) * cosw)
            a2 = (a + 1) + (a - 1) * cosw - s
        case .highShelf:
            let s = 2 * sqrt(a) * alpha
            b0 = a * ((a + 1) + (a - 1) * cosw + s)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosw)
            b2 = a * ((a + 1) + (a - 1) * cosw - s)
            a0 = (a + 1) - (a - 1) * cosw + s
            a1 = 2 * ((a - 1) - (a + 1) * cosw)
            a2 = (a + 1) - (a - 1) * cosw - s
        case .lowPass:
            b0 = (1 - cosw) / 2
            b1 = 1 - cosw
            b2 = (1 - cosw) / 2
            a0 = 1 + alpha
            a1 = -2 * cosw
            a2 = 1 - alpha
        case .highPass:
            b0 = (1 + cosw) / 2
            b1 = -(1 + cosw)
            b2 = (1 + cosw) / 2
            a0 = 1 + alpha
            a1 = -2 * cosw
            a2 = 1 - alpha
        case .notch:
            b0 = 1
            b1 = -2 * cosw
            b2 = 1
            a0 = 1 + alpha
            a1 = -2 * cosw
            a2 = 1 - alpha
        case .bandPass:
            b0 = alpha
            b1 = 0
            b2 = -alpha
            a0 = 1 + alpha
            a1 = -2 * cosw
            a2 = 1 - alpha
        }
        return BiquadCoefficients(b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b2 / a0),
                                  a1: Float(a1 / a0), a2: Float(a2 / a0))
    }

    /// Jury's triangle for a normalised second-order denominator: both poles strictly inside the unit circle.
    var isStable: Bool { abs(a2) < 1 && abs(a1) < 1 + a2 }

    /// Magnitude response in dB at `frequency` for a given sample rate.
    func magnitudeDB(at frequency: Double, sampleRate: Double) -> Double {
        let b0 = Double(b0), b1 = Double(b1), b2 = Double(b2)
        let a1 = Double(a1), a2 = Double(a2)
        let w = 2.0 * Double.pi * frequency / sampleRate
        // |H(e^jw)|^2 = (b0^2 + b1^2 + b2^2 + 2(b0b1 + b1b2)cos w + 2 b0b2 cos 2w) /
        //               (1 + a1^2 + a2^2 + 2(a1 + a1a2)cos w + 2 a2 cos 2w)
        let cw = cos(w), c2w = cos(2 * w)
        let num = b0 * b0 + b1 * b1 + b2 * b2 + 2 * (b0 * b1 + b1 * b2) * cw + 2 * b0 * b2 * c2w
        let den = 1 + a1 * a1 + a2 * a2 + 2 * (a1 + a1 * a2) * cw + 2 * a2 * c2w
        guard den > 0, num > 0 else { return -120 }
        return 10 * log10(num / den)
    }
}

/// Per-channel biquad state, transposed direct form II.
struct BiquadState {
    var z1: Float = 0, z2: Float = 0

    @inline(__always)
    mutating func process(_ x: Float, _ c: BiquadCoefficients) -> Float {
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        return y
    }

    // A decaying tail parks the state in subnormals: flush-to-zero is off on these threads (the
    // tail test sees them), and subnormal arithmetic can cost far more than normal arithmetic.
    @inline(__always)
    mutating func flushDenormals() {
        if abs(z1) < Float.leastNormalMagnitude { z1 = 0 }
        if abs(z2) < Float.leastNormalMagnitude { z2 = 0 }
    }
}
