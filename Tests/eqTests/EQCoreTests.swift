import EQCore
import XCTest

/// EQCore through its C API alone, the way the HAL plug-in will drive it.
final class EQCoreTests: XCTestCase {
    private static let rates = [16000.0, 44100, 48000, 96000, 192_000]

    private final class Engine {
        let memory = UnsafeMutableRawPointer.allocate(byteCount: eqc_engine_size(), alignment: 16)
        var core: OpaquePointer { OpaquePointer(memory) }

        init(rate: Double, channels: Int) {
            let meter = [100.0, 1000, 10000]
            eqc_engine_init(core, meter, Int32(meter.count))
            eqc_configure(core, rate, Int32(channels))
        }

        deinit { memory.deallocate() }

        @discardableResult
        func update(_ settings: eqc_settings) -> [Int32] {
            var settings = settings
            var unstable = [Int32](repeating: -1, count: Int(EQC_MAX_BANDS))
            let count = eqc_update(core, &settings, &unstable)
            return Array(unstable.prefix(Int(count)))
        }

        /// Runs `input` through channel by channel in blocks of `block`, returning every channel.
        func run(_ input: [[Float]], block: Int = 512) -> [[Float]] {
            let frames = input[0].count
            let buffers = input.map { _ in UnsafeMutablePointer<Float>.allocate(capacity: block) }
            defer { buffers.forEach { $0.deallocate() } }
            var output = input.map { _ in [Float]() }
            var start = 0
            while start < frames {
                let n = min(block, frames - start)
                for (c, buffer) in buffers.enumerated() { for i in 0..<n { buffer[i] = input[c][start + i] } }
                eqc_process(core, buffers, Int32(buffers.count), Int32(n))
                for (c, buffer) in buffers.enumerated() { output[c] += UnsafeBufferPointer(start: buffer, count: n) }
                start += n
            }
            return output
        }
    }

    private func settings(_ bands: [eqc_band] = [], preampDB: Double = 0, bypassed: Bool = false,
                          compressor: eqc_compressor = EQC_COMPRESSOR_OFF, colour: eqc_colour = EQC_COLOUR_OFF,
                          amount: Double = 0, solo: (Double, Double)? = nil) -> eqc_settings {
        var s = eqc_settings()
        s.bandCount = Int32(bands.count)
        withUnsafeMutableBytes(of: &s.bands) { raw in
            let slots = raw.bindMemory(to: eqc_band.self)
            for (index, band) in bands.enumerated() { slots[index] = band }
        }
        s.preampDB = preampDB
        s.limiterEnabled = true
        s.limiterCeilingDB = -1
        s.bypassed = bypassed
        s.compressor = compressor
        s.colour = colour
        s.colourAmount = amount
        if let solo { s.solo = true; s.soloLow = solo.0; s.soloHigh = solo.1 }
        return s
    }

    private func peak(_ frequency: Double, _ gain: Double, q: Double = 1.41) -> eqc_band {
        eqc_band(type: EQC_PEAK, frequency: frequency, gainDB: gain, q: q, enabled: true)
    }

    private func impulse(_ count: Int) -> [Float] {
        var x = [Float](repeating: 0, count: count)
        x[0] = 1.0 / 1024
        return x
    }

    private func sine(_ frequency: Double, amplitude: Double, rate: Double, count: Int) -> [Float] {
        (0..<count).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / rate)) }
    }

    /// The gain in dB at `frequency` of an impulse response to a 2^-10 impulse.
    private func gainDB(_ response: [Float], at frequency: Double, rate: Double) -> Double {
        var re = 0.0, im = 0.0
        for (n, x) in response.enumerated() {
            let w = 2 * Double.pi * frequency * Double(n) / rate
            re += Double(x) * cos(w)
            im -= Double(x) * sin(w)
        }
        return 20 * log10((re * re + im * im).squareRoot() * 1024)
    }

    // MARK: - Prepare and process

    func testCurveAndSoloAtEveryRate() {
        for rate in Self.rates {
            let engine = Engine(rate: rate, channels: 2)
            XCTAssertEqual(engine.update(settings([peak(100, 6, q: 2), peak(5000, -6, q: 2)])), [])
            let response = engine.run([impulse(16384), impulse(16384)])
            XCTAssertEqual(response[0], response[1])
            XCTAssertEqual(gainDB(response[0], at: 100, rate: rate), 6, accuracy: 0.1, "\(rate) Hz")
            XCTAssertEqual(gainDB(response[0], at: 5000, rate: rate), -6, accuracy: 0.1, "\(rate) Hz")
            XCTAssertEqual(gainDB(response[0], at: 1000, rate: rate), 0, accuracy: 0.3, "\(rate) Hz")

            engine.update(settings([peak(1000, 6)], solo: (300, 2800)))
            let soloed = engine.run([impulse(16384), impulse(16384)])[0]
            XCTAssertEqual(gainDB(soloed, at: 1000, rate: rate), 6, accuracy: 1, "\(rate) Hz")
            XCTAssertLessThanOrEqual(gainDB(soloed, at: 100, rate: rate), -20, "\(rate) Hz")
            XCTAssertLessThanOrEqual(gainDB(soloed, at: 7000, rate: rate), -20, "\(rate) Hz")
        }
    }

    func testSoloClampsToTheRate() {
        var low = 0.0, high = 0.0
        XCTAssertTrue(eqc_clamp_solo(5, 30000, 16000, &low, &high))
        XCTAssertEqual(low, 20)
        XCTAssertEqual(high, 7200)
        XCTAssertFalse(eqc_clamp_solo(8000, 9000, 16000, &low, &high))
        XCTAssertFalse(eqc_clamp_solo(.nan, 1000, 48000, &low, &high))
        XCTAssertFalse(eqc_clamp_solo(100, 1000, 0, &low, &high))
    }

    func testPreampAndBypass() {
        let engine = Engine(rate: 48000, channels: 1)
        let x = sine(1000, amplitude: 0.25, rate: 48000, count: 4800)
        engine.update(settings(preampDB: -6.0206))
        XCTAssertEqual(engine.run([x])[0][100], x[100] / 2, accuracy: 1e-5)
        engine.update(settings([peak(1000, 12)], preampDB: -20, bypassed: true, compressor: EQC_COMPRESSOR_NIGHT))
        XCTAssertEqual(engine.run([x])[0], x)
        XCTAssertFalse(eqc_limiting(engine.core))
    }

    func testTheLimiterHoldsTheCeiling() {
        for rate in Self.rates {
            let engine = Engine(rate: rate, channels: 2)
            engine.update(settings([peak(1000, 12)]))
            let x = sine(1000, amplitude: 0.9, rate: rate, count: Int(rate / 10))
            let out = engine.run([x, x])
            XCTAssertTrue(eqc_limiting(engine.core))
            XCTAssertLessThanOrEqual(out[0].map(abs).max()!, Float(pow(10, -1.0 / 20)) * 1.0001, "\(rate) Hz")
        }
    }

    func testUnstableBandsRunAsAWireAndAreNamed() {
        let shelf = eqc_band(type: EQC_LOW_SHELF, frequency: 10, gainDB: 30, q: 0.1, enabled: true)
        var off = peak(500, 3)
        off.enabled = false
        let engine = Engine(rate: 192_000, channels: 2)
        XCTAssertEqual(engine.update(settings([peak(1000, 0, q: 1), off, shelf])), [2])
        XCTAssertEqual(engine.run([impulse(64), impulse(64)])[0], impulse(64))
        XCTAssertEqual(Engine(rate: 48000, channels: 2).update(settings([shelf])), [])
    }

    /// A settings struct with NaN or absurd values runs nothing it cannot run safely.
    func testNonFiniteSettingsPassSoundThrough() {
        for rate in Self.rates {
            let engine = Engine(rate: rate, channels: 2)
            let bands = [peak(.nan, 6), peak(1000, .nan), peak(1000, 6, q: .nan), peak(.infinity, 6), peak(1000, 6, q: 0)]
            XCTAssertEqual(engine.update(settings(bands, colour: EQC_COLOUR_TUBE, amount: .nan, solo: (.nan, 1000))).count, 3)
            let out = engine.run([impulse(4096), impulse(4096)])[0]
            XCTAssertTrue(out.allSatisfy(\.isFinite), "\(rate) Hz")
        }
    }

    // MARK: - Safety

    /// A decaying tail ends in exact zeros, never parked in subnormals, on every channel count and
    /// with every stage running.
    func testTailsEndInZerosOnEveryChannelCount() {
        for channels in [1, 2, 6, 16] {
            for rate in [16000.0, 192_000] {
                let engine = Engine(rate: rate, channels: channels)
                engine.update(settings([peak(40, 4, q: 8), eqc_band(type: EQC_LOW_SHELF, frequency: 20, gainDB: 6, q: 0.7, enabled: true)],
                                       compressor: EQC_COMPRESSOR_GENTLE, colour: EQC_COLOUR_TUBE, amount: 0.5))
                eqc_set_metering(engine.core, true)
                let tone = sine(40, amplitude: 1e-36, rate: rate, count: 512)
                engine.run(Array(repeating: tone, count: channels))
                let silence = Array(repeating: [Float](repeating: 0, count: 512), count: channels)
                var state = [Float](repeating: .nan, count: 8192)
                var n = 0, out: [[Float]] = []
                for _ in 0..<Int(4 * rate / 512) {
                    out = engine.run(silence)
                    n = state.withUnsafeMutableBufferPointer { buffer -> Int in
                        let n = Int(eqc_engine_render_state(engine.core, buffer.baseAddress!, Int32(buffer.count)))
                        return n + Int(eqc_meter_render_state(eqc_engine_meter(engine.core), buffer.baseAddress! + n, Int32(buffer.count - n)))
                    }
                    XCTAssertTrue(state[0..<n].allSatisfy { $0 == 0 || $0.isNormal }, "\(channels) ch at \(rate) Hz")
                }
                XCTAssertEqual(out.joined().filter { $0 != 0 }, [])
                XCTAssertGreaterThan(n, 100)
                XCTAssertEqual(state[0..<n].filter { $0 != 0 }, [], "\(channels) ch at \(rate) Hz")
            }
        }
    }

    func testFlushZeroesOnlySubnormals() {
        var state = eqc_biquad_state(z1: Float.leastNormalMagnitude / 2, z2: -Float.leastNonzeroMagnitude)
        eqc_biquad_flush(&state)
        XCTAssertEqual([state.z1, state.z2], [0, 0])
        state = eqc_biquad_state(z1: Float.leastNormalMagnitude, z2: -0.25)
        eqc_biquad_flush(&state)
        XCTAssertEqual([state.z1, state.z2], [Float.leastNormalMagnitude, -0.25])
    }

    func testTheMeterRecoversFromNaN() {
        let engine = Engine(rate: 48000, channels: 2)
        engine.update(settings())
        eqc_set_metering(engine.core, true)
        var x = [Float](repeating: 0, count: 512)
        x[0] = .nan
        engine.run([x, x])
        var input = [Double](repeating: 0, count: 3), output = input, peak = 0.0
        eqc_meter_read(eqc_engine_meter(engine.core), &input, &output, &peak)
        XCTAssertTrue((input + output + [peak]).allSatisfy(\.isFinite))
        engine.update(settings())
        let tone = sine(1000, amplitude: 0.5, rate: 48000, count: 9600)
        engine.run([tone, tone])
        eqc_meter_read(eqc_engine_meter(engine.core), &input, &output, &peak)
        XCTAssertEqual(output[1], -6, accuracy: 1.5)
        XCTAssertEqual(peak, -6, accuracy: 1.5)
    }

    /// A NaN or infinite sample plays exactly as a 0 would have, with every stage running.
    func testANonFiniteSampleIsASilentOne() {
        let chain = settings([peak(1000, 6), peak(60, 4, q: 4)], compressor: EQC_COMPRESSOR_GENTLE, colour: EQC_COLOUR_TUBE, amount: 0.5)
        let tone = sine(440, amplitude: 0.5, rate: 48000, count: 4800)
        for bad in [Float.nan, .infinity, -.infinity] {
            var poisoned = tone, clean = tone
            for i in [0, 700, 2049] { poisoned[i] = bad; clean[i] = 0 }
            let a = Engine(rate: 48000, channels: 2), b = Engine(rate: 48000, channels: 2)
            a.update(chain)
            b.update(chain)
            XCTAssertEqual(a.run([poisoned, tone]), b.run([clean, tone]), "\(bad)")
        }
    }

    /// Finite input through an absurd preamp overflows the history; the call it happens in plays
    /// silence and the next one, with sane settings, plays as a fresh engine would.
    func testOverflowedHistoryIsClearedWithinTheCall() {
        let tone = sine(440, amplitude: 0.5, rate: 48000, count: 512)
        let sane = settings([peak(1000, 6)], compressor: EQC_COMPRESSOR_NIGHT, colour: EQC_COLOUR_TAPE, amount: 0.5)
        let engine = Engine(rate: 48000, channels: 2)
        engine.update(settings([peak(1000, 6)], preampDB: 1000, compressor: EQC_COMPRESSOR_NIGHT))
        XCTAssertEqual(engine.run([tone, tone]).joined().filter { $0 != 0 }, [])
        var state = [Float](repeating: .nan, count: 8192)
        let n = Int(eqc_engine_render_state(engine.core, &state, Int32(state.count)))
        XCTAssertTrue(state[0..<n].allSatisfy { $0 == 0 })
        XCTAssertFalse(eqc_limiting(engine.core))
        XCTAssertEqual(eqc_compressor_reduction_db(engine.core), 0)

        engine.update(sane)
        let fresh = Engine(rate: 48000, channels: 2)
        fresh.update(sane)
        let played = engine.run([tone, tone])
        XCTAssertTrue(played.joined().allSatisfy(\.isFinite))
        XCTAssertEqual(played, fresh.run([tone, tone]))
    }

    // MARK: - Channels

    /// Every channel of a 1–16 channel engine runs the same chain, sample for sample.
    func testEveryChannelCountRunsTheSameChain() {
        let x = sine(700, amplitude: 0.2, rate: 48000, count: 4096)
        let reference = Engine(rate: 48000, channels: 1)
        reference.update(settings([peak(1000, 6), peak(80, -3)], compressor: EQC_COMPRESSOR_NIGHT, colour: EQC_COLOUR_TAPE, amount: 0.3))
        let want = reference.run([x])[0]
        for channels in 1...Int(EQC_MAX_CHANNELS) {
            let engine = Engine(rate: 48000, channels: channels)
            engine.update(settings([peak(1000, 6), peak(80, -3)], compressor: EQC_COMPRESSOR_NIGHT, colour: EQC_COLOUR_TAPE, amount: 0.3))
            let out = engine.run(Array(repeating: x, count: channels))
            for channel in 0..<channels { XCTAssertEqual(out[channel], want, "channel \(channel) of \(channels)") }
        }
    }

    func testChannelsPastTheMaximumAreLeftAlone() {
        let engine = Engine(rate: 48000, channels: 16)
        engine.update(settings(preampDB: -6))
        let x = sine(700, amplitude: 0.2, rate: 48000, count: 256)
        let out = engine.run(Array(repeating: x, count: 17))
        XCTAssertNotEqual(out[15], x)
        XCTAssertEqual(out[16], x)
    }

    // MARK: - Hand-over and glides

    /// Updates published between two callbacks: the render thread plays the latest whole.
    func testTheLatestUpdateWins() {
        let engine = Engine(rate: 48000, channels: 1)
        for gain in stride(from: -12.0, through: 12, by: 1) { engine.update(settings([peak(1000, gain)])) }
        engine.update(settings([peak(1000, 6)]))
        XCTAssertEqual(gainDB(engine.run([impulse(16384)])[0], at: 1000, rate: 48000), 6, accuracy: 0.1)
    }

    func testConfigurePreparesTheLastSettingsForTheNewRate() {
        let engine = Engine(rate: 48000, channels: 2)
        engine.update(settings([peak(1000, 6)]))
        eqc_configure(engine.core, 96000, 2)
        XCTAssertEqual(gainDB(engine.run([impulse(32768), impulse(32768)])[0], at: 1000, rate: 96000), 6, accuracy: 0.1)
    }

    /// Switched on, the colour's drive glides in over about 10 ms rather than jumping.
    func testColourGlidesIn() {
        let rate = 48000.0
        let engine = Engine(rate: rate, channels: 1)
        engine.update(settings())
        let x = [Float](repeating: 0.5, count: Int(rate / 5))
        engine.run([Array(x[0..<512])])
        engine.update(settings(colour: EQC_COLOUR_TAPE, amount: 1))
        let out = engine.run([x], block: 64)[0]
        let full = tanh(2 * 0.5) / 2
        XCTAssertLessThan(abs(Double(out[0]) - 0.5), 0.01 * (0.5 - full))
        let steps = zip(out, out.dropFirst()).map { abs($0 - $1) }
        XCTAssertLessThan(steps.max()!, 0.002)
        XCTAssertEqual(Double(out.last!), full, accuracy: 1e-6)
    }

    /// Switched off, the compressor glides its gain back to unity instead of stepping.
    func testCompressorGlidesOut() {
        let rate = 48000.0
        let engine = Engine(rate: rate, channels: 2)
        engine.update(settings(compressor: EQC_COMPRESSOR_NIGHT))
        let x = sine(1000, amplitude: 0.5, rate: rate, count: Int(rate))
        engine.run([x, x])
        XCTAssertLessThan(eqc_compressor_reduction_db(engine.core), -5)
        engine.update(settings())
        let tail = sine(1000, amplitude: 0.5, rate: rate, count: Int(rate / 2))
        let out = engine.run([tail, tail])[0]
        let gains = zip(out, tail).filter { abs($1) > 0.1 }.map { 20 * log10(Double($0 / $1)) }
        XCTAssertLessThan(zip(gains, gains.dropFirst()).map { abs($0 - $1) }.max()!, 0.5)
        XCTAssertEqual(gains.last!, 0, accuracy: 1e-3)
        XCTAssertEqual(eqc_compressor_reduction_db(engine.core), 0)
    }

    /// A new colour waits for the old one to glide out: tape to tube never plays both at once.
    func testColourKindChangeGlidesThroughZero() {
        let c = eqc_dynamics_design(EQC_COMPRESSOR_OFF, EQC_COLOUR_TUBE, 1, 48000)
        var state = eqc_dynamics_state(meanSquare: 0, reductionDB: 0, averageReductionDB: 0, makeupDB: 0, colour: EQC_COLOUR_TAPE, drive: 2)
        var detector = [eqc_biquad_state](repeating: eqc_biquad_state(), count: 2)
        var dc = [Float](repeating: 0, count: 2)
        let sample = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        defer { sample.deallocate() }
        var tapeDrives: [Float] = []
        for _ in 0..<48000 {
            sample.pointee = 0.25
            _ = eqc_dynamics_frame([c], [sample], 0, 1, &state, &detector, &dc)
            if state.colour == EQC_COLOUR_TAPE { tapeDrives.append(state.drive) }
        }
        XCTAssertEqual(state.colour, EQC_COLOUR_TUBE)
        XCTAssertEqual(tapeDrives, tapeDrives.sorted(by: >))
        XCTAssertLessThan(tapeDrives.last!, 1e-3)
        XCTAssertEqual(state.drive, 2)
    }
}
