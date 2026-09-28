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

    /// Gentle's 50 ms window keeps a kick from pumping the gain much: 2.3 dB peak to peak on a
    /// 55 Hz kick alone against 2.9 dB at 2.5 ms. Night keeps 2.5 ms so its 5 ms attack still
    /// catches an explosion's onset: at 25 ms the explosions' peaks come out 3 dB higher.
    var settings: Settings {
        switch self {
        case .gentle: return Settings(ratio: 2, threshold: -18, knee: 6, attack: 0.030, release: 0.250, window: 0.050, reference: nil)
        case .night: return Settings(ratio: 4, threshold: -30, knee: 10, attack: 0.005, release: 0.400, window: 0.0025, reference: -24)
        }
    }
}

/// Everything the render thread needs for the compressor and the colour, worked out on the main
/// queue. Plain values only, so a snapshot carrying it costs the audio thread no reference counting.
struct DynamicsCoefficients {
    var compressor = false
    var detectorShelf = BiquadCoefficients()
    var detectorHighPass = BiquadCoefficients()
    var detectorSmoothing: Float = 0
    var attack: Float = 0
    var release: Float = 0
    var threshold: Float = 0
    var knee: Float = 0
    /// 1/ratio − 1: the static curve's slope above the knee, in dB of reduction per dB of level.
    var slope: Float = 0
    /// The fixed makeup, when `makeupFollow` is 0.
    var makeupDB: Float = 0
    var makeupGlide: Float = 0
    /// The pole of the average reduction a following makeup gives back; 0 for a fixed makeup.
    var makeupFollow: Float = 0
    var followGateDB: Float = 0
    /// A switch glides over this, the compressor's gain and the colour's drive both.
    var glide: Float = 0
    var colour: Dynamics.ColourKind?
    var drive: Float = 0
    var inverseDrive: Float = 0
    var bias: Float = 0
    var biasOffset: Float = 0
    var biasNormal: Float = 1
    var dcPole: Float = 0

    var isActive: Bool { compressor || colour != nil }

    /// The detector hears through ITU-R BS.1770's K-weighting, the filter loudness meters use:
    /// a +4 dB shelf above 1.7 kHz, then a high-pass at 38 Hz. A 100 Hz high-pass before it left
    /// a curve's bass boost out of the level, so a bass-heavy mix was compressed less than it
    /// sounds and the fixed makeup then made it up to 3 LU louder than with the compressor off.
    static let kShelf = (frequency: 1681.974450955533, gainDB: 3.999843853973347, q: 0.7071752369554196)
    static let kHighPass = (frequency: 38.13547087602444, q: 0.5003270373238773)
    /// A following makeup gives back the reduction averaged over this long: slow enough to leave
    /// a phrase's dynamics compressed, fast enough that a song's loud and quiet parts both end up
    /// as loud as they went in, which is what keeps the mix's balance.
    static let followTime = 3.0
    /// A pause is not averaged in, so the next song starts with the makeup the last one had. Far
    /// enough below the threshold that the knee never reaches it.
    static let followGateBelowThreshold: Float = 30
    /// Gentle takes 6 dB only at −6 dBFS RMS, 12 dB over its threshold, which only a crushed
    /// master reaches; past that a following makeup stops adding level.
    static let maxMakeupDB: Float = 6
    /// Drive at amount 1: tanh(2x)/2 takes a −12 dBFS sine down 0.7 dB with 2 % third harmonic.
    static let maxDrive = 2.0
    /// Tube's bias as a fraction of the input: where the curve sits, and so how much second
    /// harmonic it makes against third.
    static let tubeBias = 0.25
    static let dcCorner = 5.0
    static let glideTime = 0.010
    /// A drive this close to where it glides to is there: at 1e-4 the curve is x within 1e-9.
    static let driveSnap: Float = 1e-4
    /// The tube's DC blocker keeps running after its drive reaches 0 until its tail is this small.
    static let dcSnap: Float = 1e-5

    /// The glide, and the tube's DC blocker for the tail of a switch-off, are there even with both
    /// stages off, so a switch-off still has them.
    static func make(_ dynamics: Dynamics?, sampleRate: Double) -> DynamicsCoefficients {
        var c = DynamicsCoefficients()
        guard sampleRate > 0 else { return c }
        func pole(_ seconds: Double) -> Float { Float(exp(-1 / (seconds * sampleRate))) }
        c.glide = pole(glideTime)
        c.dcPole = pole(1 / (2 * Double.pi * dcCorner))
        guard let dynamics else { return c }
        if let mode = dynamics.comp {
            let s = mode.settings
            c.compressor = true
            c.detectorShelf = BiquadCoefficients.make(type: .highShelf, frequency: kShelf.frequency, gainDB: kShelf.gainDB, q: kShelf.q, sampleRate: sampleRate)
            c.detectorHighPass = BiquadCoefficients.make(type: .highPass, frequency: kHighPass.frequency, gainDB: 0, q: kHighPass.q, sampleRate: sampleRate)
            c.detectorSmoothing = pole(s.window)
            c.attack = pole(s.attack)
            c.release = pole(s.release)
            c.threshold = Float(s.threshold)
            c.knee = Float(s.knee)
            c.slope = Float(1 / s.ratio - 1)
            if let reference = s.reference {
                c.makeupDB = -reduction(level: Float(reference), threshold: c.threshold, knee: c.knee, slope: c.slope)
            } else {
                c.makeupFollow = pole(followTime)
                c.followGateDB = c.threshold - followGateBelowThreshold
            }
            // Never ahead of the reduction: switched on, or after the engine's reset in silence, the
            // reduction starts from 0, and makeup arriving faster than the attack would swell the level first.
            c.makeupGlide = pole(max(s.attack, glideTime))
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

/// The stages' memory between samples, owned by the render thread.
struct DynamicsState {
    var meanSquare: Float = 0
    var reductionDB: Float = 0
    /// What a following makeup gives back: the reduction, averaged while there is sound.
    var averageReductionDB: Float = 0
    /// The makeup applied, gliding to the mode's, or with the reduction to 0 once the compressor is off.
    var makeupDB: Float = 0
    /// The colour running and its drive, gliding to the setting's; a new kind waits for the old
    /// one to glide to 0 drive.
    var colour: Dynamics.ColourKind?
    var drive: Float = 0

    var isIdle: Bool { reductionDB == 0 && makeupDB == 0 && colour == nil }

    /// A release creeps towards 0 dB geometrically and would take the better part of a minute to
    /// get there; a thousandth of a dB is far below hearing, so it ends there. Makeup only ends
    /// on the way out: on the way in a 1-frame callback at 192 kHz moves it less than that.
    mutating func flushTails(compressing: Bool) {
        if meanSquare < Float.leastNormalMagnitude { meanSquare = 0 }
        if abs(reductionDB) < 1e-3 { reductionDB = 0 }
        if abs(averageReductionDB) < 1e-3 { averageReductionDB = 0 }
        if !compressing, abs(makeupDB) < 1e-3 { makeupDB = 0 }
    }
}

extension DynamicsCoefficients {
    /// One frame across every channel, in place: one gain for all, set by the loudest channel so
    /// the centre of 5.1 alone reads as loud as the same signal on both sides of stereo; then the colour.
    /// Returns the frame's largest magnitude for the limiter behind it. `detector` and `dc` hold
    /// `2 * channelCount` entries each.
    @inline(__always)
    func process(_ channels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>, frame: Int, channelCount: Int,
                 state: inout DynamicsState, detector: UnsafeMutablePointer<BiquadState>, dc: UnsafeMutablePointer<Float>) -> Float {
        var gain: Float = 1
        if compressor {
            var power: Float = 0
            for ch in 0..<channelCount {
                let filtered = detector[2 * ch + 1].process(detector[2 * ch].process(channels[ch][frame], detectorShelf), detectorHighPass)
                power = max(power, filtered * filtered)
            }
            state.meanSquare = detectorSmoothing * state.meanSquare + (1 - detectorSmoothing) * power
            let level = 10 * log10(state.meanSquare + 1e-12)
            let target = Self.reduction(level: level, threshold: threshold, knee: knee, slope: slope)
            let pole = target < state.reductionDB ? attack : release
            state.reductionDB = pole * state.reductionDB + (1 - pole) * target
            var makeupTarget = makeupDB
            if makeupFollow > 0 {
                if level > followGateDB {
                    state.averageReductionDB = makeupFollow * state.averageReductionDB + (1 - makeupFollow) * state.reductionDB
                }
                makeupTarget = min(-state.averageReductionDB, Self.maxMakeupDB)
            }
            state.makeupDB = makeupGlide * state.makeupDB + (1 - makeupGlide) * makeupTarget
            gain = exp2((state.reductionDB + state.makeupDB) * 0.166_096_4)
        } else if state.reductionDB != 0 || state.makeupDB != 0 {
            state.reductionDB *= glide
            state.makeupDB *= glide
            gain = exp2((state.reductionDB + state.makeupDB) * 0.166_096_4)
        }

        let targetDrive = state.colour == colour ? drive : 0
        if state.drive != targetDrive {
            state.drive = glide * state.drive + (1 - glide) * targetDrive
            if abs(state.drive - targetDrive) < Self.driveSnap { state.drive = targetDrive }
        }
        if state.drive == 0, state.colour != colour, state.colour != .tube || Self.settled(dc, count: 2 * channelCount) {
            state.colour = colour
            dc.update(repeating: 0, count: 2 * channelCount)
        }
        let d = state.drive
        var inverse = inverseDrive, b = bias, offset = biasOffset, normal = biasNormal
        if d > 0, d != drive || state.colour != colour {
            inverse = 1 / d
            b = d * Float(Self.tubeBias)
            offset = tanh(b)
            normal = inverse / (1 - offset * offset)
        }

        var peak: Float = 0
        for ch in 0..<channelCount {
            var sample = channels[ch][frame] * gain
            switch state.colour {
            case .tape?:
                if d > 0 { sample = tanh(d * sample) * inverse }
            case .tube?:
                // Blocking only what the curve adds keeps the dry signal whole, so at 0 drive the
                // stage is exactly a wire and a switch has nothing to jump over.
                let added = d > 0 ? (tanh(d * sample + b) - offset) * normal - sample : 0
                let blocked = added - dc[2 * ch] + dcPole * dc[2 * ch + 1]
                dc[2 * ch] = added
                dc[2 * ch + 1] = blocked
                sample += blocked
            case nil:
                break
            }
            channels[ch][frame] = sample
            peak = max(peak, abs(sample))
        }
        return peak
    }

    @inline(__always)
    private static func settled(_ dc: UnsafeMutablePointer<Float>, count: Int) -> Bool {
        for index in 0..<count where abs(dc[index]) >= dcSnap { return false }
        return true
    }
}
