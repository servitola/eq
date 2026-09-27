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
        // Filter history travels with the coefficients so a new filter count arrives with its
        // storage already allocated on the main queue; the render thread never resizes it for a
        // band-count change. Flattened [channel][band], sized for stereo.
        var states: [BiquadState] = []
        var preampLinear: Float = 1
        var outputGainLinear: Float = 1
        var limiterEnabled = true
        var limiterCeilingLinear: Float = pow(10, -1.0 / 20)  // -1 dBFS
        var bypassed = false
    }

    private var snapshot = Snapshot()
    private var pendingSnapshot: Snapshot?
    // Dropping the last reference to a Snapshot frees its arrays; parking it here moves that free
    // off the audio thread and onto the next update() call. It is also why `snapshot.states` is
    // uniquely referenced on the render thread: pendingSnapshot is cleared on swap and the retired
    // copy holds the previous snapshot's buffers, never the current one's.
    private var retiredSnapshot: Snapshot?
    private var lock = os_unfair_lock()

    private var limiterEnvelope: Float = 0
    private var limiterRelease = Float(exp(-1.0 / (0.080 * 48000)))
    private(set) var sampleRate: Double = 48000

    let meter = BandMeter(frequencies: Config.bandFrequencies)
    /// Written on the main queue, read once per callback on the audio thread.
    var meteringEnabled = false
    // Read and written only on the audio thread, inside `process`, so the reset on a
    // false→true transition never races the main queue's write to `meteringEnabled`.
    private var wasMetering = false
    private(set) var limiting = false
    // The tap engine's scratch buffers are at least this large; a longer callback goes unmetered
    // rather than allocating on the audio thread.
    static let meterCapacity = 4096
    private let meterInput = UnsafeMutablePointer<Float>.allocate(capacity: EQProcessor.meterCapacity)
    private let meterInputChannels: [UnsafeMutablePointer<Float>]

    init() {
        meterInput.initialize(repeating: 0, count: Self.meterCapacity)
        meterInputChannels = [meterInput]
    }

    deinit { meterInput.deallocate() }

    /// Call only while the IOProc is stopped.
    func configure(sampleRate: Double) {
        self.sampleRate = sampleRate
        limiterRelease = Float(exp(-1.0 / (0.080 * sampleRate)))
        meter.configure(sampleRate: sampleRate)
    }

    /// Audio thread only. Clear filter and limiter history before the engine
    /// enters its prolonged-silence fast path. Keeping the existing storage
    /// avoids allocating from the realtime callback.
    func resetRenderState() {
        for index in snapshot.states.indices { snapshot.states[index] = BiquadState() }
        limiterEnvelope = 0
        meter.reset()
    }

    /// Races the audio thread; call only while nothing is rendering.
    func renderStateForTesting() -> [Float] {
        snapshot.states.flatMap { [$0.z1, $0.z2] } + [limiterEnvelope]
    }

    /// Called from the daemon's main queue whenever parameters change.
    func update(bands: [EQBand], preampDB: Double, outputGainDB: Double = 0,
                limiterEnabled: Bool, limiterCeilingDB: Double, bypassed: Bool) {
        // Built inside a closure so no local keeps a second reference to the `states` buffer:
        // one would force the audio thread into a COW copy if it swaps this snapshot in mid-window.
        var incoming: Snapshot? = {
            var snap = Snapshot()
            snap.coefficients = bands.filter(\.isEnabled).map {
                BiquadCoefficients.make(type: $0.type, frequency: $0.frequency, gainDB: $0.gain, q: $0.q, sampleRate: sampleRate)
            }
            snap.states = Array(repeating: BiquadState(), count: 2 * snap.coefficients.count)
            snap.preampLinear = Float(pow(10, preampDB / 20))
            snap.outputGainLinear = Float(pow(10, outputGainDB / 20))
            snap.limiterEnabled = limiterEnabled
            snap.limiterCeilingLinear = Float(pow(10, limiterCeilingDB / 20))
            snap.bypassed = bypassed
            return snap
        }()
        os_unfair_lock_lock(&lock)
        swap(&pendingSnapshot, &incoming)
        let retired = retiredSnapshot
        retiredSnapshot = nil
        os_unfair_lock_unlock(&lock)
        _ = retired
        _ = incoming
    }

    /// Process non-interleaved Float32 channel buffers in place. Audio thread only.
    func process(channels: [UnsafeMutablePointer<Float>], frameCount: Int) {
        let metering = meteringEnabled && frameCount <= Self.meterCapacity && !channels.isEmpty
        if metering && !wasMetering { meter.reset() }
        wasMetering = metering
        if metering { captureMonoInput(channels, frameCount) }
        render(channels: channels, frameCount: frameCount)
        if metering { meter.feed(input: meterInputChannels, output: channels, frameCount: frameCount) }
    }

    private func captureMonoInput(_ channels: [UnsafeMutablePointer<Float>], _ frameCount: Int) {
        let left = channels[0]
        let right = channels.count > 1 ? channels[1] : left
        for frame in 0..<frameCount { meterInput[frame] = 0.5 * (left[frame] + right[frame]) }
    }

    private func render(channels: [UnsafeMutablePointer<Float>], frameCount: Int) {
        limiting = false
        if os_unfair_lock_trylock(&lock) {
            if let pending = pendingSnapshot {
                pendingSnapshot = nil
                retiredSnapshot = snapshot
                snapshot = pending
            }
            os_unfair_lock_unlock(&lock)
        }
        if snapshot.bypassed { return }

        // Copied out rather than read through `snapshot` inside the closure below: that closure
        // holds a modify access on `snapshot` for the states, and a second access would trap.
        let coefficients = snapshot.coefficients
        let preampLinear = snapshot.preampLinear
        let outputGainLinear = snapshot.outputGainLinear
        let limiterEnabled = snapshot.limiterEnabled
        let limiterCeilingLinear = snapshot.limiterCeilingLinear
        let channelCount = channels.count
        let bandCount = coefficients.count

        // update() sizes states for stereo; only a device with another channel count gets here,
        // and that allocates once, on the first cycle after the swap.
        if snapshot.states.count != channelCount * bandCount {
            snapshot.states = Array(repeating: BiquadState(), count: channelCount * bandCount)
            limiterEnvelope = 0
        }

        // Work through raw buffers so mutating filter state does not trigger an
        // Array copy-on-write uniqueness check for every sample and band.
        channels.withUnsafeBufferPointer { channelBuffers in
            snapshot.states.withUnsafeMutableBufferPointer { stateBuffer in
                coefficients.withUnsafeBufferPointer { coefficientBuffer in
                    let stateBase = stateBuffer.baseAddress
                    let coefficientBase = coefficientBuffer.baseAddress

                    for frame in 0..<frameCount {
                        // Stereo-linked limiter: find the loudest post-EQ sample across channels.
                        var maxMag: Float = 0
                        for ch in 0..<channelCount {
                            var sample = channelBuffers[ch][frame] * preampLinear
                            if bandCount > 0, let stateBase, let coefficientBase {
                                let channelStates = stateBase + ch * bandCount
                                for band in 0..<bandCount {
                                    sample = channelStates[band].process(sample, coefficientBase[band])
                                }
                            }
                            sample *= outputGainLinear
                            channelBuffers[ch][frame] = sample
                            maxMag = max(maxMag, abs(sample))
                        }
                        if limiterEnabled {
                            // Instant attack: a lagging envelope let onsets through above 0 dBFS and the DAC clipped them.
                            limiterEnvelope = maxMag > limiterEnvelope ? maxMag : limiterRelease * limiterEnvelope + (1 - limiterRelease) * maxMag
                            if limiterEnvelope > limiterCeilingLinear {
                                limiting = true
                                let gain = limiterCeilingLinear / limiterEnvelope
                                for ch in 0..<channelCount { channelBuffers[ch][frame] *= gain }
                            }
                        }
                    }
                }
                for index in stateBuffer.indices { stateBuffer[index].flushDenormals() }
            }
        }
        if limiterEnvelope < Float.leastNormalMagnitude { limiterEnvelope = 0 }
    }
}
