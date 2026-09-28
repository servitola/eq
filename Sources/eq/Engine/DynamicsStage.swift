import EQCore
import Foundation

extension Dynamics.Compressor {
    struct Settings {
        var ratio: Double, threshold: Double, knee: Double, attack: Double, release: Double
        /// The detector's mean-square averaging time.
        var window: Double
        /// The level a fixed makeup restores exactly, film dialogue for night, so quiet dialogue
        /// comes up. nil makes the makeup follow the reduction instead, so music stays as loud.
        var reference: Double?
    }

    var core: eqc_compressor {
        switch self {
        case .gentle: return EQC_COMPRESSOR_GENTLE
        case .night: return EQC_COMPRESSOR_NIGHT
        }
    }

    var settings: Settings {
        let s = eqc_compressor_params(core)
        return Settings(ratio: s.ratio, threshold: s.threshold, knee: s.knee, attack: s.attack, release: s.release,
                        window: s.window, reference: s.reference.isNaN ? nil : s.reference)
    }
}

extension Dynamics.ColourKind {
    var core: eqc_colour {
        switch self {
        case .tape: return EQC_COLOUR_TAPE
        case .tube: return EQC_COLOUR_TUBE
        }
    }
}

/// The compressor and colour's coefficients, worked out off the render thread.
typealias DynamicsCoefficients = eqc_dynamics
/// The stages' memory between samples, owned by the render thread.
typealias DynamicsState = eqc_dynamics_state

extension eqc_dynamics {
    static let kShelf = (frequency: EQC_K_SHELF_FREQUENCY, gainDB: EQC_K_SHELF_GAIN_DB, q: EQC_K_SHELF_Q)
    static let kHighPass = (frequency: EQC_K_HIGH_PASS_FREQUENCY, q: EQC_K_HIGH_PASS_Q)
    static let followGateBelowThreshold = EQC_FOLLOW_GATE_BELOW_THRESHOLD
    static let maxMakeupDB = EQC_MAX_MAKEUP_DB

    var isActive: Bool { compressor || colour != EQC_COLOUR_OFF }

    static func make(_ dynamics: Dynamics?, sampleRate: Double) -> DynamicsCoefficients {
        eqc_dynamics_design(dynamics?.comp?.core ?? EQC_COMPRESSOR_OFF, dynamics?.color?.kind.core ?? EQC_COLOUR_OFF,
                            dynamics?.color?.amount ?? 0, sampleRate)
    }

    static func reduction(level: Float, threshold: Float, knee: Float, slope: Float) -> Float {
        eqc_reduction(level, threshold, knee, slope)
    }

    /// One frame across every channel, in place; returns the frame's largest magnitude. `detector`
    /// and `dc` hold `2 * channelCount` entries each.
    func process(_ channels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>, frame: Int, channelCount: Int,
                 state: inout DynamicsState, detector: UnsafeMutablePointer<BiquadState>, dc: UnsafeMutablePointer<Float>) -> Float {
        withUnsafePointer(to: self) { eqc_dynamics_frame($0, channels.baseAddress!, Int32(frame), Int32(channelCount), &state, detector, dc) }
    }
}
