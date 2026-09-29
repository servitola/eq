import XCTest
import EQCore

/// A resampler the tests own, with the reference every output frame is judged against: frame i is
/// the input signal at `positions[i]`, the fractional input position the resampler reports for it.
private final class Harness {
    let inputRate: Double
    let channels: Int
    let resampler: OpaquePointer
    private let storage: UnsafeMutableRawPointer
    private var inputPosition = 0
    private(set) var consumed = 0

    init?(input: Double, output: Double, channels: Int = 2, maxOutput: Int = 4096) {
        let size = eqc_resampler_size(input, output, Int32(channels), Int32(maxOutput))
        guard size > 0 else { return nil }
        inputRate = input
        self.channels = channels
        storage = .allocate(byteCount: size, alignment: 16)
        resampler = OpaquePointer(storage)
        eqc_resampler_init(resampler, input, output, Int32(channels), Int32(maxOutput))
    }

    deinit { storage.deallocate() }

    /// `frames` output frames, fed `signal(input frame)` on every channel; channel 0 comes back.
    func run(frames: Int, block: (Int) -> Int = { _ in 128 }, correction: (Int) -> Double = { _ in 0 },
             signal: (Int) -> Double) -> (samples: [Float], positions: [Double]) {
        var samples: [Float] = []
        var positions: [Double] = []
        samples.reserveCapacity(frames)
        positions.reserveCapacity(frames)
        let outputs = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: 4096) }
        defer { outputs.forEach { $0.deallocate() } }
        var index = 0
        while samples.count < frames {
            let count = min(block(index), frames - samples.count)
            eqc_resampler_set_correction(resampler, correction(index))
            let needed = Int(eqc_resampler_needed(resampler, Int32(count)))
            for channel in 0..<channels {
                let input = eqc_resampler_input(resampler, Int32(channel))
                for frame in 0..<needed { input[frame] = Float(signal(inputPosition + frame)) }
            }
            inputPosition += needed
            consumed += needed
            let position = eqc_resampler_position(resampler)
            let step = eqc_resampler_step(resampler)
            eqc_resampler_produce(resampler, Int32(needed), outputs, Int32(count))
            for frame in 0..<count {
                samples.append(outputs[0][frame])
                positions.append(position + Double(frame) * step)
            }
            index += 1
        }
        return (samples, positions)
    }
}

/// Least squares of a·sin + b·cos at each frame's own input position: the gain in dB of a tone of
/// amplitude 0.5, and the residual (everything that is not the tone) in dB below it.
private func fit(_ run: (samples: [Float], positions: [Double]), frequency: Double, inputRate: Double,
                 skip: Int) -> (gainDB: Double, residualDB: Double, phase: Double) {
    var ss = 0.0, sc = 0.0, cc = 0.0, ys = 0.0, yc = 0.0
    for index in skip..<run.samples.count {
        let phase = 2 * Double.pi * frequency * run.positions[index] / inputRate
        let s = sin(phase), c = cos(phase), y = Double(run.samples[index])
        ss += s * s; sc += s * c; cc += c * c; ys += y * s; yc += y * c
    }
    let det = ss * cc - sc * sc
    let a = (ys * cc - yc * sc) / det, b = (yc * ss - ys * sc) / det
    var error = 0.0, signal = 0.0
    for index in skip..<run.samples.count {
        let phase = 2 * Double.pi * frequency * run.positions[index] / inputRate
        let model = a * sin(phase) + b * cos(phase)
        error += (Double(run.samples[index]) - model) * (Double(run.samples[index]) - model)
        signal += model * model
    }
    return (20 * log10((a * a + b * b).squareRoot() / 0.5), 10 * log10(error / signal), atan2(b, a))
}

private func tone(_ frequency: Double, rate: Double, amplitude: Double = 0.5) -> (Int) -> Double {
    { amplitude * sin(2 * Double.pi * frequency * Double($0) / rate) }
}

final class ResamplerTests: XCTestCase {
    private func harness(_ input: Double, _ output: Double, channels: Int = 2) throws -> Harness {
        try XCTUnwrap(Harness(input: input, output: output, channels: channels))
    }

    func testTheFirstOutputIsInputFrameZeroAfterHalfAKernel() throws {
        let h = try harness(44100, 44100)
        let latency = Int(eqc_resampler_latency(h.resampler))
        XCTAssertEqual(latency, 32)
        XCTAssertEqual(eqc_resampler_taps(h.resampler), 64)
        XCTAssertEqual(Int(eqc_resampler_needed(h.resampler, 1)), latency + 1, "frame 0 and the half kernel after it")
        let impulseAt = 300
        let run = h.run(frames: 1000) { $0 == impulseAt ? 1 : 0 }
        let peak = run.samples.indices.max { abs(run.samples[$0]) < abs(run.samples[$1]) }!
        XCTAssertEqual(run.positions[peak], Double(impulseAt), accuracy: 1e-9)
        XCTAssertEqual(run.samples[peak], 1, accuracy: 1e-6, "at 1:1 the kernel lands on its own zeros")
    }

    func testDecimatingStretchesTheKernel() throws {
        XCTAssertEqual(eqc_resampler_taps(try harness(48000, 44100).resampler), 72)
        XCTAssertEqual(eqc_resampler_taps(try harness(96000, 48000).resampler), 128)
        XCTAssertEqual(eqc_resampler_taps(try harness(44100, 48000).resampler), 64)
    }

    func testThePassbandIsFlatTo20kHzBothWays() throws {
        for (input, output) in [(48000.0, 44100.0), (44100.0, 48000.0)] {
            for frequency in [20.0, 100, 1000, 5000, 10000, 15000, 19000, 20000] {
                let h = try harness(input, output)
                let result = fit(h.run(frames: 8192, signal: tone(frequency, rate: input)), frequency: frequency, inputRate: input, skip: 512)
                XCTAssertEqual(result.gainDB, 0, accuracy: 0.01, "\(Int(input))→\(Int(output)) at \(Int(frequency)) Hz")
                XCTAssertEqual(result.phase, 0, accuracy: 1e-6, "linear phase, centred on the reported position")
            }
        }
    }

    func testTheStopbandIsAtLeast80dBDown() throws {
        // 30 kHz is past 96→48 kHz's stopband (26.2 kHz); what gets through folds to 18 kHz.
        let h = try harness(96000, 48000)
        let run = h.run(frames: 16384, signal: tone(30000, rate: 96000, amplitude: 1))
        let rms = (run.samples.dropFirst(512).reduce(0) { $0 + Double($1) * Double($1) } / Double(run.samples.count - 512)).squareRoot()
        XCTAssertLessThan(20 * log10(rms / 0.5.squareRoot()), -80)
        // Upsampling a 10 kHz tone leaves an image at 34.1 kHz that folds to 13.9 kHz at 48 kHz.
        let up = try harness(44100, 48000)
        XCTAssertLessThan(fit(up.run(frames: 16384, signal: tone(10000, rate: 44100)), frequency: 10000, inputRate: 44100, skip: 512).residualDB, -80)
    }

    func testDistortionAt1kHzIsBelow100dB() throws {
        for (input, output) in [(48000.0, 44100.0), (44100.0, 48000.0), (96000.0, 44100.0)] {
            let h = try harness(input, output)
            let result = fit(h.run(frames: 32768, signal: tone(1000, rate: input)), frequency: 1000, inputRate: input, skip: 1024)
            XCTAssertLessThan(result.residualDB, -100, "\(Int(input))→\(Int(output)): THD+N \(result.residualDB) dB")
        }
    }

    func testDriftOf500ppmEitherWayStaysClean() throws {
        for correction in [500e-6, -500e-6] {
            let h = try harness(44100, 44100)
            let frames = 44100
            let run = h.run(frames: frames, correction: { _ in correction }, signal: tone(1000, rate: 44100))
            XCTAssertLessThan(fit(run, frequency: 1000, inputRate: 44100, skip: 1024).residualDB, -100)
            XCTAssertEqual(eqc_resampler_step(h.resampler), 1 + correction, accuracy: 1e-9)
            XCTAssertEqual(Double(h.consumed), Double(frames) * (1 + correction) + 32, accuracy: 2,
                           "input taken at the corrected rate, plus the look-ahead")
        }
    }

    func testCorrectionIsClampedToAThousandPpm() throws {
        let h = try harness(44100, 44100)
        eqc_resampler_set_correction(h.resampler, 0.5)
        XCTAssertEqual(eqc_resampler_step(h.resampler), 1 + EQC_RESAMPLER_MAX_CORRECTION, accuracy: 1e-9)
        eqc_resampler_set_correction(h.resampler, .nan)
        XCTAssertEqual(eqc_resampler_step(h.resampler), 1 - EQC_RESAMPLER_MAX_CORRECTION, accuracy: 1e-9)
    }

    /// A servo moves the ratio every buffer; every output frame must still be the input at its own
    /// position, so a step shows up as no click at all.
    func testRatioStepsBetweenBuffersDoNotClick() throws {
        for (input, output) in [(44100.0, 44100.0), (48000.0, 44100.0)] {
            let h = try harness(input, output)
            let run = h.run(frames: 60000, block: { 64 + ($0 * 37) % 400 }, correction: { ($0 / 20) % 2 == 0 ? 500e-6 : -500e-6 },
                            signal: tone(1000, rate: input))
            var worst = 0.0
            for index in 1024..<run.samples.count {
                let reference = 0.5 * sin(2 * Double.pi * 1000 * run.positions[index] / input)
                worst = max(worst, abs(Double(run.samples[index]) - reference))
            }
            XCTAssertLessThan(20 * log10(worst / 0.5), -90, "\(Int(input))→\(Int(output))")
        }
    }

    func testBlockSizeDoesNotChangeASingleSample() throws {
        let a = try harness(48000, 44100)
        let b = try harness(48000, 44100)
        let signal = tone(3000, rate: 48000)
        let whole = a.run(frames: 20000, block: { _ in 4096 }, signal: signal)
        let pieces = b.run(frames: 20000, block: { [1, 7, 128, 333, 4096, 64][$0 % 6] }, signal: signal)
        XCTAssertEqual(whole.samples, pieces.samples)
    }

    func testChannelsStayApart() throws {
        let h = try harness(48000, 44100, channels: 3)
        let outputs = (0..<3).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: 256) }
        defer { outputs.forEach { $0.deallocate() } }
        for _ in 0..<10 {
            let needed = Int(eqc_resampler_needed(h.resampler, 256))
            for channel in 0..<3 {
                let input = eqc_resampler_input(h.resampler, Int32(channel))
                for frame in 0..<needed { input[frame] = Float(channel) - 1 }
            }
            eqc_resampler_produce(h.resampler, Int32(needed), outputs, 256)
        }
        for channel in 0..<3 { XCTAssertEqual(outputs[channel][255], Float(channel) - 1, accuracy: 1e-5) }
    }

    func testMissingInputPlaysAsSilence() throws {
        let h = try harness(44100, 44100)
        _ = h.run(frames: 2048) { _ in 0.5 }
        let outputs = [UnsafeMutablePointer<Float>.allocate(capacity: 512), UnsafeMutablePointer<Float>.allocate(capacity: 512)]
        defer { outputs.forEach { $0.deallocate() } }
        eqc_resampler_produce(h.resampler, 0, outputs, 512)
        XCTAssertEqual(outputs[0][511], 0, accuracy: 1e-6)
        XCTAssertEqual(outputs[0][0], 0.5, accuracy: 0.01, "the look-ahead already taken still plays, then fades out")
    }

    func testResetStartsOverFromFrameZero() throws {
        let h = try harness(48000, 44100)
        _ = h.run(frames: 5000) { _ in 0.3 }
        eqc_resampler_reset(h.resampler)
        XCTAssertEqual(eqc_resampler_position(h.resampler), 0)
        XCTAssertEqual(Int(eqc_resampler_needed(h.resampler, 1)), Int(eqc_resampler_latency(h.resampler)) + 1)
    }

    func testOutOfRangeShapesAreRefused() {
        XCTAssertEqual(eqc_resampler_size(48000, 44100, 0, 128), 0)
        XCTAssertEqual(eqc_resampler_size(48000, 44100, 17, 128), 0)
        XCTAssertEqual(eqc_resampler_size(48000, 0, 2, 128), 0)
        XCTAssertEqual(eqc_resampler_size(.nan, 48000, 2, 128), 0)
        XCTAssertEqual(eqc_resampler_size(384000, 44100, 2, 128), 0)
        XCTAssertEqual(eqc_resampler_size(48000, 44100, 2, 0), 0)
        XCTAssertGreaterThan(eqc_resampler_size(48000, 44100, 16, 4096), 0)
    }
}
