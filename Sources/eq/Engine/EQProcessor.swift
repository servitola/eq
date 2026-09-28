// Vendored from zollans/OnlyEQ @ 6569655 (Unlicense), trimmed for eq.
import Foundation
import os.lock

/// Realtime-safe EQ chain: preamp → biquad cascade → output gain → compressor → colour → soft limiter.
///
/// The daemon's main queue rebuilds a `Snapshot` and swaps it in under a lock; the render
/// thread try-locks — if the lock is contended it keeps using the old snapshot
/// for that cycle rather than blocking the audio thread.
final class EQProcessor {
    struct Snapshot {
        var coefficients: [BiquadCoefficients] = []
        // Filter history travels with the coefficients so a new filter count arrives with its
        // storage already allocated on the main queue; the render thread never resizes it for a
        // band-count change. Flattened [channel][band], sized for `channelCount`.
        var states: [BiquadState] = []
        var preampLinear: Float = 1
        var outputGainLinear: Float = 1
        var limiterEnabled = true
        var limiterCeilingLinear: Float = pow(10, -1.0 / 20)  // -1 dBFS
        var bypassed = false
        var dynamics = DynamicsCoefficients()
    }

    private var snapshot = Snapshot()
    private var pendingSnapshot: Snapshot?
    // Dropping the last reference to a Snapshot frees its arrays; parking it here moves that free
    // off the audio thread and onto the next update() call. It is also why `snapshot.states` is
    // uniquely referenced on the render thread: pendingSnapshot is cleared on swap and the retired
    // copy holds the previous snapshot's buffers, never the current one's.
    private var retiredSnapshot: Snapshot?
    private var lock = os_unfair_lock()

    private struct Parameters {
        var bands: [EQBand], preampDB: Double, outputGainDB: Double
        var limiterEnabled: Bool, limiterCeilingDB: Double, bypassed: Bool, dynamics: Dynamics?
    }
    // Kept so a solo change can rebuild the snapshot without the caller resending the profile.
    private var parameters: Parameters?
    /// Main queue only. The requested range; `effectiveSolo` is what it becomes at the current rate.
    /// Assigning it takes effect on the next `update`; `setSolo`/`clearSolo` rebuild at once.
    var solo: SoloRange?
    var effectiveSolo: SoloRange? { solo.flatMap { Self.clampSolo(low: $0.low, high: $0.high, sampleRate: sampleRate) } }

    private var limiterEnvelope: Float = 0
    private var dynamicsState = DynamicsState()
    // Raw storage sized for the most channels a tap delivers, so neither a channel-count change
    // nor switching the compressor or tube on ever allocates on the render thread.
    private let detectorStates = UnsafeMutablePointer<BiquadState>.allocate(capacity: 2 * TapFormat.maxChannels)
    private let dcStates = UnsafeMutablePointer<Float>.allocate(capacity: 2 * TapFormat.maxChannels)
    /// The compressor's current gain change in dB, 0 or below, before makeup. Written by the
    /// render thread once per callback; a racy read on the main queue is harmless.
    private(set) var compressorReductionDB: Float = 0
    private var limiterRelease = Float(exp(-1.0 / (0.080 * 48000)))
    private(set) var sampleRate: Double = 48000
    private(set) var channelCount = 2

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
        detectorStates.initialize(repeating: BiquadState(), count: 2 * TapFormat.maxChannels)
        dcStates.initialize(repeating: 0, count: 2 * TapFormat.maxChannels)
    }

    deinit {
        meterInput.deallocate()
        detectorStates.deallocate()
        dcStates.deallocate()
    }

    /// Call only while the IOProc is stopped. A profile already applied is rebuilt for the new
    /// rate and channel count, so the first render never resizes filter state.
    func configure(sampleRate: Double, channels: Int = 2) {
        self.sampleRate = sampleRate
        channelCount = max(channels, 1)
        limiterRelease = Float(exp(-1.0 / (0.080 * sampleRate)))
        meter.configure(sampleRate: sampleRate)
        rebuild()
    }

    /// Audio thread only. Clear filter and limiter history before the engine
    /// enters its prolonged-silence fast path. Keeping the existing storage
    /// avoids allocating from the realtime callback.
    func resetRenderState() {
        for index in snapshot.states.indices { snapshot.states[index] = BiquadState() }
        limiterEnvelope = 0
        resetDynamics()
        meter.reset()
    }

    private func resetDynamics() {
        resetCompressor()
        resetColour()
    }

    private func resetCompressor() {
        dynamicsState = DynamicsState()
        compressorReductionDB = 0
        detectorStates.update(repeating: BiquadState(), count: 2 * TapFormat.maxChannels)
    }

    private func resetColour() {
        dcStates.update(repeating: 0, count: 2 * TapFormat.maxChannels)
    }

    static func clampSolo(low: Double, high: Double, sampleRate: Double) -> SoloRange? {
        guard low.isFinite, high.isFinite, sampleRate > 0 else { return nil }
        let clamped = SoloRange(low: max(low, 20), high: min(high, 0.45 * sampleRate))
        return clamped.low < clamped.high ? clamped : nil
    }

    /// Main queue. Returns false, changing nothing, when the range is empty after clamping.
    @discardableResult
    func setSolo(low: Double, high: Double) -> Bool {
        guard Self.clampSolo(low: low, high: high, sampleRate: sampleRate) != nil else { return false }
        solo = SoloRange(low: low, high: high)
        rebuild()
        return true
    }

    func clearSolo() {
        guard solo != nil else { return }
        solo = nil
        rebuild()
    }

    private func rebuild() {
        guard let p = parameters else { return }
        update(bands: p.bands, preampDB: p.preampDB, outputGainDB: p.outputGainDB,
               limiterEnabled: p.limiterEnabled, limiterCeilingDB: p.limiterCeilingDB, bypassed: p.bypassed, dynamics: p.dynamics)
    }

    /// Races the audio thread; call only while nothing is rendering.
    func renderStateForTesting() -> [Float] {
        snapshot.states.flatMap { [$0.z1, $0.z2] } + [limiterEnvelope, dynamicsState.meanSquare, dynamicsState.reductionDB]
            + (0..<(2 * TapFormat.maxChannels)).flatMap { [detectorStates[$0].z1, detectorStates[$0].z2, dcStates[$0]] }
    }

    /// Called from the daemon's main queue whenever parameters change. Returns the indices into
    /// `bands` whose coefficients are unstable at the current rate; those run as pass-through.
    @discardableResult
    func update(bands: [EQBand], preampDB: Double, outputGainDB: Double = 0,
                limiterEnabled: Bool, limiterCeilingDB: Double, bypassed: Bool, dynamics: Dynamics? = nil) -> [Int] {
        parameters = Parameters(bands: bands, preampDB: preampDB, outputGainDB: outputGainDB,
                                limiterEnabled: limiterEnabled, limiterCeilingDB: limiterCeilingDB, bypassed: bypassed, dynamics: dynamics)
        var unstable: [Int] = []
        let solo = effectiveSolo
        // Built inside a closure so no local keeps a second reference to the `states` buffer:
        // one would force the audio thread into a COW copy if it swaps this snapshot in mid-window.
        var incoming: Snapshot? = {
            var snap = Snapshot()
            // Config.validate checks stability at 48 kHz only; at 96/192 kHz Float32 rounding pushes
            // some in-range filters below ~28 Hz onto the unit circle, and one would ring forever.
            snap.coefficients = bands.indices.filter { bands[$0].isEnabled }.map { index in
                let band = bands[index]
                let c = BiquadCoefficients.make(type: band.type, frequency: band.frequency, gainDB: band.gain, q: band.q, sampleRate: sampleRate)
                guard c.isStable else {
                    unstable.append(index)
                    return BiquadCoefficients()
                }
                return c
            }
            if let solo {
                // Listening to a range with the EQ switched off still has to isolate it, so the
                // user's curve is dropped but the solo pair runs.
                if bypassed { snap.coefficients = [] }
                snap.coefficients += Self.soloCoefficients(solo, sampleRate: sampleRate)
            }
            snap.states = Array(repeating: BiquadState(), count: channelCount * snap.coefficients.count)
            snap.preampLinear = bypassed ? 1 : Float(pow(10, preampDB / 20))
            snap.outputGainLinear = bypassed ? 1 : Float(pow(10, outputGainDB / 20))
            snap.limiterEnabled = limiterEnabled
            snap.limiterCeilingLinear = Float(pow(10, limiterCeilingDB / 20))
            snap.bypassed = bypassed && solo == nil
            snap.dynamics = bypassed ? DynamicsCoefficients() : DynamicsCoefficients.make(dynamics, sampleRate: sampleRate)
            return snap
        }()
        os_unfair_lock_lock(&lock)
        swap(&pendingSnapshot, &incoming)
        let retired = retiredSnapshot
        retiredSnapshot = nil
        os_unfair_lock_unlock(&lock)
        _ = retired
        _ = incoming
        return unstable
    }

    // Two 2nd-order Butterworth sections per edge: a 4th-order slope, -6 dB at the edge itself.
    private static func soloCoefficients(_ solo: SoloRange, sampleRate: Double) -> [BiquadCoefficients] {
        let q = 0.5.squareRoot()
        let hp = BiquadCoefficients.make(type: .highPass, frequency: solo.low, gainDB: 0, q: q, sampleRate: sampleRate)
        let lp = BiquadCoefficients.make(type: .lowPass, frequency: solo.high, gainDB: 0, q: q, sampleRate: sampleRate)
        return [hp, hp, lp, lp].map { $0.isStable ? $0 : BiquadCoefficients() }
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
        var swapped = false
        if os_unfair_lock_trylock(&lock) {
            // Swaps only: an assignment would copy a snapshot, retaining its arrays, or destroy
            // one. update() leaves retiredSnapshot nil whenever it sets pendingSnapshot, so the
            // second swap puts nil back into pendingSnapshot.
            if pendingSnapshot != nil {
                swap(&snapshot, &pendingSnapshot!)
                swap(&retiredSnapshot, &pendingSnapshot)
                swapped = true
            }
            os_unfair_lock_unlock(&lock)
        }
        // A stage switched off leaves its memory behind; clear it so switching back on starts fresh.
        if swapped, !snapshot.dynamics.compressor { resetCompressor() }
        if swapped, snapshot.dynamics.colour != .tube { resetColour() }
        if snapshot.bypassed { return }

        // Copied out rather than read through `snapshot` inside the closure below: that closure
        // holds a modify access on `snapshot` for the states, and a second access would trap.
        let coefficients = snapshot.coefficients
        let preampLinear = snapshot.preampLinear
        let outputGainLinear = snapshot.outputGainLinear
        let limiterEnabled = snapshot.limiterEnabled
        let limiterCeilingLinear = snapshot.limiterCeilingLinear
        let dynamics = snapshot.dynamics
        let shaping = dynamics.isActive
        var dynamicsState = self.dynamicsState
        let detectorStates = self.detectorStates
        let dcStates = self.dcStates
        let channelCount = channels.count
        let shapedChannels = min(channelCount, TapFormat.maxChannels)
        let bandCount = coefficients.count

        // update() sizes states for the configured channel count; only a caller passing another
        // count gets here, and that allocates once, on the first cycle after the swap.
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
                        if shaping {
                            maxMag = dynamics.process(channelBuffers, frame: frame, channelCount: shapedChannels,
                                                      state: &dynamicsState, detector: detectorStates, dc: dcStates)
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
        if shaping {
            for index in 0..<(2 * shapedChannels) { detectorStates[index].flushDenormals() }
            for index in 0..<(2 * shapedChannels) where abs(dcStates[index]) < Float.leastNormalMagnitude { dcStates[index] = 0 }
            dynamicsState.flushTails()
            self.dynamicsState = dynamicsState
            compressorReductionDB = dynamicsState.reductionDB
        }
    }
}
