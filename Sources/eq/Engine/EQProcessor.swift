import EQCore
import Foundation

/// The EQ chain, run by EQCore: preamp → biquad cascade → output gain → compressor → colour → soft limiter.
///
/// The daemon's main queue turns parameters into an `eqc_settings` and hands it to EQCore, which
/// computes the coefficients there and publishes them through a triple buffer; the render thread
/// picks up the latest whole at the start of its next callback, never waiting.
final class EQProcessor {
    private let storage: CoreStorage
    /// The engine, for render threads to call EQCore directly: a plain pointer costs them no
    /// reference counting. Lives as long as this processor.
    let core: OpaquePointer
    let meter: BandMeter

    /// Main queue. What the render thread was last handed, solo included.
    private(set) var settings: eqc_settings?
    /// Main queue only. The requested range; `effectiveSolo` is what it becomes at the current rate.
    /// Assigning it takes effect on the next `update`; `setSolo`/`clearSolo` rebuild at once.
    var solo: SoloRange?
    var effectiveSolo: SoloRange? { solo.flatMap { Self.clampSolo(low: $0.low, high: $0.high, sampleRate: sampleRate) } }

    private(set) var sampleRate: Double = 48000
    private(set) var channelCount = 2
    // The tap engine's scratch buffers are at least this large; a longer callback goes unmetered
    // rather than allocating on the audio thread.
    static let meterCapacity = Int(EQC_METER_CAPACITY)

    /// Written on the main queue, read once per callback on the audio thread.
    var meteringEnabled = false {
        didSet {
            eqc_set_metering(core, meteringEnabled)
            eqc_set_spectrum(core, meteringEnabled)
        }
    }
    var limiting: Bool { eqc_limiting(core) }
    /// The compressor's current gain change in dB, 0 or below, before makeup. Written by the
    /// render thread once per callback.
    var compressorReductionDB: Float { eqc_compressor_reduction_db(core) }

    init() {
        storage = CoreStorage(size: eqc_engine_size())
        core = OpaquePointer(storage.pointer)
        eqc_engine_init(core, Config.bandFrequencies, Int32(Config.bandFrequencies.count))
        meter = BandMeter(eqc_engine_meter(core), in: storage)
    }

    /// Call only while the IOProc is stopped. A profile already applied is rebuilt for the new
    /// rate and channel count, so the first render never resizes filter state.
    func configure(sampleRate: Double, channels: Int = 2) {
        self.sampleRate = sampleRate
        channelCount = min(max(channels, 1), Int(EQC_MAX_CHANNELS))
        eqc_configure(core, sampleRate, Int32(channelCount))
    }

    /// Audio thread only. Clear filter and limiter history before the engine enters its
    /// prolonged-silence fast path.
    func resetRenderState() { eqc_reset_render_state(core) }

    static func clampSolo(low: Double, high: Double, sampleRate: Double) -> SoloRange? {
        var clampedLow = 0.0, clampedHigh = 0.0
        guard eqc_clamp_solo(low, high, sampleRate, &clampedLow, &clampedHigh) else { return nil }
        return SoloRange(low: clampedLow, high: clampedHigh)
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
        guard var settings else { return }
        publish(&settings)
    }

    /// Main queue. Adds the solo range and hands `settings` to the render thread.
    @discardableResult
    func publish(_ settings: inout eqc_settings) -> [Int] {
        settings.solo = solo != nil
        settings.soloLow = solo?.low ?? 0
        settings.soloHigh = solo?.high ?? 0
        self.settings = settings
        var unstable = [Int32](repeating: 0, count: Int(EQC_MAX_BANDS))
        let count = Int(eqc_update(core, &settings, &unstable))
        return unstable.prefix(count).map(Int.init)
    }

    /// Races the audio thread; call only while nothing is rendering.
    func renderStateForTesting() -> [Float] {
        var state = [Float](repeating: 0, count: 2 * Int(EQC_MAX_CHANNELS) * (Int(EQC_MAX_BANDS) + 4) + 3 + 6 * Int(EQC_MAX_CHANNELS))
        state.removeLast(state.count - Int(eqc_engine_render_state(core, &state, Int32(state.count))))
        return state
    }

    /// Called from the daemon's main queue whenever parameters change. Returns the indices into
    /// `bands` whose coefficients are unstable at the current rate; those run as pass-through.
    @discardableResult
    func update(bands: [EQBand], preampDB: Double, outputGainDB: Double = 0,
                limiterEnabled: Bool, limiterCeilingDB: Double, bypassed: Bool, dynamics: Dynamics? = nil) -> [Int] {
        var s = Self.settings(bands: bands, preampDB: preampDB, outputGainDB: outputGainDB, limiterEnabled: limiterEnabled,
                              limiterCeilingDB: limiterCeilingDB, bypassed: bypassed, dynamics: dynamics)
        return publish(&s)
    }

    /// The parameters as EQCore takes them, without solo, which `publish` adds.
    static func settings(bands: [EQBand], preampDB: Double, outputGainDB: Double = 0,
                         limiterEnabled: Bool, limiterCeilingDB: Double, bypassed: Bool, dynamics: Dynamics? = nil) -> eqc_settings {
        var s = eqc_settings()
        s.bandCount = Int32(min(bands.count, Int(EQC_MAX_BANDS)))
        withUnsafeMutableBytes(of: &s.bands) { raw in
            let slots = raw.bindMemory(to: eqc_band.self)
            for (index, band) in bands.prefix(slots.count).enumerated() {
                slots[index] = eqc_band(type: band.type.core, frequency: band.frequency, gainDB: band.gain, q: band.q, enabled: band.isEnabled)
            }
        }
        s.preampDB = preampDB
        s.outputGainDB = outputGainDB
        s.limiterEnabled = limiterEnabled
        s.limiterCeilingDB = limiterCeilingDB
        s.bypassed = bypassed
        s.compressor = dynamics?.comp?.core ?? EQC_COMPRESSOR_OFF
        s.colour = dynamics?.color?.kind.core ?? EQC_COLOUR_OFF
        s.colourAmount = dynamics?.color?.amount ?? 0
        return s
    }

    /// Process non-interleaved Float32 channel buffers in place. Audio thread only.
    func process(channels: [UnsafeMutablePointer<Float>], frameCount: Int) {
        eqc_process(core, channels, Int32(channels.count), Int32(frameCount))
    }
}
