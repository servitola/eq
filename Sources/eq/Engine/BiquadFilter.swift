import EQCore
import Foundation

/// RBJ Audio-EQ-Cookbook biquad coefficients, normalized (a0 == 1), as EQCore designs and runs them.
typealias BiquadCoefficients = eqc_biquad
/// Per-channel biquad state, transposed direct form II.
typealias BiquadState = eqc_biquad_state

extension FilterType {
    var core: eqc_filter_type {
        switch self {
        case .peak: return EQC_PEAK
        case .lowShelf: return EQC_LOW_SHELF
        case .highShelf: return EQC_HIGH_SHELF
        case .lowPass: return EQC_LOW_PASS
        case .highPass: return EQC_HIGH_PASS
        case .notch: return EQC_NOTCH
        case .bandPass: return EQC_BAND_PASS
        }
    }
}

extension eqc_biquad {
    static func make(type: FilterType, frequency: Double, gainDB: Double, q: Double, sampleRate: Double) -> BiquadCoefficients {
        eqc_design(type.core, frequency, gainDB, q, sampleRate)
    }

    var isStable: Bool { eqc_biquad_is_stable(self) }

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

extension eqc_biquad_state {
    mutating func flushDenormals() { eqc_biquad_flush(&self) }
}
