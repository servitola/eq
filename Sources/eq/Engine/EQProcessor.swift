// Vendored from zollans/OnlyEQ @ 6569655 (Unlicense), trimmed for eq.
import Foundation
import os.lock

/// Realtime-safe EQ chain: preamp → biquad cascade → soft limiter → output gain.
///
/// The daemon's main queue rebuilds a `Snapshot` and swaps it in under a lock; the render
/// thread try-locks — if the lock is contended it keeps using the old snapshot
/// for that cycle rather than blocking the audio thread.
final class EQProcessor {
    struct Snapshot {
        var coefficients: [BiquadCoefficients] = []
        var preampLinear: Float = 1
        var outputGainLinear: Float = 1
        var limiterEnabled = true
        var limiterCeilingLinear: Float = pow(10, -1.0 / 20)  // -1 dBFS
        var bypassed = false
    }

    private var snapshot = Snapshot()
    private var pendingSnapshot: Snapshot?
    // Dropping the last reference to a Snapshot frees its coefficient array; parking it here moves
    // that free off the audio thread and onto the next update() call.
    private var retiredSnapshot: Snapshot?
    private var lock = os_unfair_lock()

    // Render-thread state (only touched on the audio thread).
    // Pre-sized for stereo × the fixed band count so the first real profile does not allocate on
    // the audio thread; process() still resizes for any other topology.
    private var states = Array(repeating: BiquadState(), count: 2 * Config.bandFrequencies.count)  // flattened [channel][band]
    private var stateChannelCount = 2
    private var stateBandCount = Config.bandFrequencies.count
    private var limiterEnvelope: Float = 0
    private var limiterRelease = Float(exp(-1.0 / (0.080 * 48000)))
    private(set) var sampleRate: Double = 48000

    func configure(sampleRate: Double) {
        self.sampleRate = sampleRate
        limiterRelease = Float(exp(-1.0 / (0.080 * sampleRate)))
    }

    /// Audio thread only. Clear filter and limiter history before the engine
    /// enters its prolonged-silence fast path. Keeping the existing storage
    /// avoids allocating from the realtime callback.
    func resetRenderState() {
        for index in states.indices { states[index] = BiquadState() }
        limiterEnvelope = 0
    }

    /// Called from the daemon's main queue whenever parameters change.
    func update(bands: [EQBand], preampDB: Double, outputGainDB: Double = 0,
                limiterEnabled: Bool, limiterCeilingDB: Double, bypassed: Bool) {
        var snap = Snapshot()
        snap.coefficients = bands.filter(\.isEnabled).map {
            BiquadCoefficients.make(type: $0.type, frequency: $0.frequency, gainDB: $0.gain, q: $0.q, sampleRate: sampleRate)
        }
        snap.preampLinear = Float(pow(10, preampDB / 20))
        snap.outputGainLinear = Float(pow(10, outputGainDB / 20))
        snap.limiterEnabled = limiterEnabled
        snap.limiterCeilingLinear = Float(pow(10, limiterCeilingDB / 20))
        snap.bypassed = bypassed
        os_unfair_lock_lock(&lock)
        pendingSnapshot = snap
        retiredSnapshot = nil
        os_unfair_lock_unlock(&lock)
    }

    /// Process non-interleaved Float32 channel buffers in place. Audio thread only.
    func process(channels: [UnsafeMutablePointer<Float>], frameCount: Int) {
        if os_unfair_lock_trylock(&lock) {
            if let pending = pendingSnapshot {
                retiredSnapshot = snapshot
                snapshot = pending
                pendingSnapshot = nil
            }
            os_unfair_lock_unlock(&lock)
        }
        let snap = snapshot
        if snap.bypassed { return }

        // (Re)size filter state to match topology. The initial empty snapshot, which the IOProc
        // runs with until the daemon's first apply lands, never touches `states`, so it must not
        // shrink the pre-sized storage either.
        let channelCount = channels.count
        let bandCount = snap.coefficients.count
        if bandCount > 0, stateChannelCount != channelCount || stateBandCount != bandCount {
            states = Array(repeating: BiquadState(), count: channelCount * bandCount)
            stateChannelCount = channelCount
            stateBandCount = bandCount
            limiterEnvelope = 0
        }

        // Work through raw buffers so mutating filter state does not trigger an
        // Array copy-on-write uniqueness check for every sample and band.
        channels.withUnsafeBufferPointer { channelBuffers in
            states.withUnsafeMutableBufferPointer { stateBuffer in
                snap.coefficients.withUnsafeBufferPointer { coefficientBuffer in
                    let stateBase = stateBuffer.baseAddress
                    let coefficientBase = coefficientBuffer.baseAddress

                    for frame in 0..<frameCount {
                        // Stereo-linked limiter: find the loudest post-EQ sample across channels.
                        var maxMag: Float = 0
                        for ch in 0..<channelCount {
                            var sample = channelBuffers[ch][frame] * snap.preampLinear
                            if bandCount > 0, let stateBase, let coefficientBase {
                                let channelStates = stateBase + ch * bandCount
                                for band in 0..<bandCount {
                                    sample = channelStates[band].process(sample, coefficientBase[band])
                                }
                            }
                            sample *= snap.outputGainLinear
                            channelBuffers[ch][frame] = sample
                            maxMag = max(maxMag, abs(sample))
                        }
                        if snap.limiterEnabled {
                            // Instant attack: a lagging envelope let onsets through above 0 dBFS and the DAC clipped them.
                            limiterEnvelope = maxMag > limiterEnvelope ? maxMag : limiterRelease * limiterEnvelope + (1 - limiterRelease) * maxMag
                            if limiterEnvelope > snap.limiterCeilingLinear {
                                let gain = snap.limiterCeilingLinear / limiterEnvelope
                                for ch in 0..<channelCount { channelBuffers[ch][frame] *= gain }
                            }
                        }
                    }
                }
            }
        }
    }
}
