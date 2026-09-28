import Foundation

extension Dynamics.Compressor {
    struct Settings {
        var ratio: Double, threshold: Double, knee: Double, attack: Double, release: Double
        /// The RMS level the automatic makeup restores exactly: typical music for gentle, film
        /// dialogue for night, so each mode changes dynamics and leaves its material as loud.
        var reference: Double
    }

    var settings: Settings {
        switch self {
        case .gentle: return Settings(ratio: 2, threshold: -18, knee: 6, attack: 0.030, release: 0.250, reference: -12)
        case .night: return Settings(ratio: 4, threshold: -30, knee: 10, attack: 0.005, release: 0.400, reference: -24)
        }
    }
}

/// Everything the render thread needs for the compressor and the colour, worked out on the main
/// queue. Plain values only, so a snapshot carrying it costs the audio thread no reference counting.
struct DynamicsCoefficients {
    var compressor = false
    var detector = BiquadCoefficients()
    var detectorSmoothing: Float = 0
    var attack: Float = 0
    var release: Float = 0
    var threshold: Float = 0
    var knee: Float = 0
    /// 1/ratio − 1: the static curve's slope above the knee, in dB of reduction per dB of level.
    var slope: Float = 0
    var makeupDB: Float = 0
    var colour: Dynamics.ColourKind?
    var drive: Float = 0
    var inverseDrive: Float = 0
    var bias: Float = 0
    var biasOffset: Float = 0
    var biasNormal: Float = 1
    var dcPole: Float = 0

    var isActive: Bool { compressor || colour != nil }

    /// Two Butterworth sections, −6 dB at 100 Hz and 24 dB an octave below: one alone let a 40 Hz
    /// tone at −10 dBFS take 2 dB off night mode, since the detector sees its peaks.
    static let detectorCorner = 100.0
    /// Mean-square averaging. Short enough that night's 5 ms attack is still the attack, long
    /// enough that a 100 Hz tone, where the detector's high-pass starts to let bass in, ripples
    /// the reduction by a fraction of a dB once the attack smooths it.
    static let detectorWindow = 0.0025
    /// Drive at amount 1: tanh(2x)/2 takes a −12 dBFS sine down 0.7 dB with 2 % third harmonic.
    static let maxDrive = 2.0
    /// Tube's bias as a fraction of the input: where the curve sits, and so how much second
    /// harmonic it makes against third.
    static let tubeBias = 0.25
    static let dcCorner = 5.0

    static func make(_ dynamics: Dynamics?, sampleRate: Double) -> DynamicsCoefficients {
        var c = DynamicsCoefficients()
        guard let dynamics, sampleRate > 0 else { return c }
        func pole(_ seconds: Double) -> Float { Float(exp(-1 / (seconds * sampleRate))) }
        if let mode = dynamics.comp {
            let s = mode.settings
            c.compressor = true
            c.detector = BiquadCoefficients.make(type: .highPass, frequency: detectorCorner, gainDB: 0, q: 0.5.squareRoot(), sampleRate: sampleRate)
            c.detectorSmoothing = pole(detectorWindow)
            c.attack = pole(s.attack)
            c.release = pole(s.release)
            c.threshold = Float(s.threshold)
            c.knee = Float(s.knee)
            c.slope = Float(1 / s.ratio - 1)
            c.makeupDB = -reduction(level: Float(s.reference), threshold: c.threshold, knee: c.knee, slope: c.slope)
        }
        if let colour = dynamics.color, colour.amount > 0 {
            let drive = min(max(colour.amount, 0), 1) * maxDrive
            c.colour = colour.kind
            c.drive = Float(drive)
            c.inverseDrive = Float(1 / drive)
            if colour.kind == .tube {
                let t = tanh(drive * tubeBias)
                c.bias = Float(drive * tubeBias)
                // The render thread's own Float tanh, so silence in is exactly silence out.
                c.biasOffset = tanh(c.bias)
                // The slope at rest, so a quiet signal comes out as loud as it went in.
                c.biasNormal = Float(1 / (drive * (1 - t * t)))
                c.dcPole = pole(1 / (2 * Double.pi * dcCorner))
            }
        }
        return c
    }

    /// The static curve with a soft knee (Giannoulis, Massberg and Reiss, JAES 2012): the gain
    /// change in dB, 0 or below, for a detector level in dB.
    @inline(__always)
    static func reduction(level: Float, threshold: Float, knee: Float, slope: Float) -> Float {
        let over = level - threshold
        if 2 * over <= -knee { return 0 }
        if 2 * over < knee {
            let x = over + knee / 2
            return slope * x * x / (2 * knee)
        }
        return slope * over
    }
}

/// The compressor's memory between samples, owned by the render thread.
struct DynamicsState {
    var meanSquare: Float = 0
    var reductionDB: Float = 0

    /// A release creeps towards 0 dB geometrically and would take the better part of a minute to
    /// get there; a thousandth of a dB is far below hearing, so it ends there.
    mutating func flushTails() {
        if meanSquare < Float.leastNormalMagnitude { meanSquare = 0 }
        if abs(reductionDB) < 1e-3 { reductionDB = 0 }
    }
}

extension DynamicsCoefficients {
    /// One frame across every channel, in place: the stereo-linked gain, then the colour.
    /// Returns the frame's largest magnitude for the limiter behind it. `detector` and `dc` hold
    /// `2 * channelCount` entries each.
    @inline(__always)
    func process(_ channels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>, frame: Int, channelCount: Int,
                 state: inout DynamicsState, detector: UnsafeMutablePointer<BiquadState>, dc: UnsafeMutablePointer<Float>) -> Float {
        var gain: Float = 1
        if compressor {
            var power: Float = 0
            for ch in 0..<channelCount {
                let filtered = detector[2 * ch + 1].process(detector[2 * ch].process(channels[ch][frame], self.detector), self.detector)
                power += filtered * filtered
            }
            power /= Float(channelCount)
            state.meanSquare = detectorSmoothing * state.meanSquare + (1 - detectorSmoothing) * power
            let level = 10 * log10(state.meanSquare + 1e-12)
            let target = Self.reduction(level: level, threshold: threshold, knee: knee, slope: slope)
            let pole = target < state.reductionDB ? attack : release
            state.reductionDB = pole * state.reductionDB + (1 - pole) * target
            gain = exp2((state.reductionDB + makeupDB) * 0.166_096_4)
        }
        var peak: Float = 0
        for ch in 0..<channelCount {
            var sample = channels[ch][frame] * gain
            switch colour {
            case .tape?:
                sample = tanh(drive * sample) * inverseDrive
            case .tube?:
                let shaped = (tanh(drive * sample + bias) - biasOffset) * biasNormal
                let blocked = shaped - dc[2 * ch] + dcPole * dc[2 * ch + 1]
                dc[2 * ch] = shaped
                dc[2 * ch + 1] = blocked
                sample = blocked
            case nil:
                break
            }
            channels[ch][frame] = sample
            peak = max(peak, abs(sample))
        }
        return peak
    }
}
