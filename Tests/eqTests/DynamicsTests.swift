import XCTest
@testable import eq

/// The compressor and the colour, driven through the real `EQProcessor.process`.
final class DynamicsTests: XCTestCase {
    private let rate = 48000.0

    private func processor(_ dynamics: Dynamics?, profile: Profile = .flat, enabled: Bool = true) -> EQProcessor {
        let processor = EQProcessor()
        processor.configure(sampleRate: rate)
        var profile = profile
        profile.dynamics = dynamics
        processor.apply(profile: profile, enabled: enabled)
        return processor
    }

    private func sine(_ frequency: Double, peakDB: Double, seconds: Double) -> [Float] {
        let amplitude = pow(10, peakDB / 20)
        return (0..<Int(seconds * rate)).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / rate)) }
    }

    /// Stereo, the same signal on both sides, in blocks of `block`; `each` sees the processor after every block.
    private func run(_ processor: EQProcessor, _ signal: [Float], block: Int = 512, each: (Int) -> Void = { _ in }) -> [Float] {
        let left = UnsafeMutablePointer<Float>.allocate(capacity: block)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: block)
        defer { left.deallocate(); right.deallocate() }
        var out: [Float] = []
        out.reserveCapacity(signal.count)
        var start = 0
        while start < signal.count {
            let n = min(block, signal.count - start)
            for i in 0..<n { left[i] = signal[start + i]; right[i] = signal[start + i] }
            processor.process(channels: [left, right], frameCount: n)
            out += UnsafeBufferPointer(start: left, count: n)
            start += n
            each(start)
        }
        return out
    }

    private func rmsDB(_ x: ArraySlice<Float>) -> Double {
        10 * log10(x.reduce(0) { $0 + Double($1) * Double($1) } / Double(x.count))
    }

    /// The amplitude of one frequency, exact when `x` holds whole periods of it.
    private func amplitude(_ x: ArraySlice<Float>, _ frequency: Double) -> Double {
        var re = 0.0, im = 0.0
        for (n, value) in x.enumerated() {
            let phase = 2 * Double.pi * frequency * Double(n) / rate
            re += Double(value) * cos(phase)
            im += Double(value) * sin(phase)
        }
        return 2 * (re * re + im * im).squareRoot() / Double(x.count)
    }

    // MARK: - Compressor

    func testStaticCurveHasRatioThresholdAndKnee() {
        for mode in Dynamics.Compressor.allCases {
            let s = mode.settings
            let c = DynamicsCoefficients.make(Dynamics(comp: mode), sampleRate: rate)
            func gr(_ level: Double) -> Double {
                Double(DynamicsCoefficients.reduction(level: Float(level), threshold: c.threshold, knee: c.knee, slope: c.slope))
            }
            XCTAssertEqual(gr(s.threshold - s.knee / 2 - 1), 0, "\(mode) below the knee")
            XCTAssertEqual(gr(s.threshold - s.knee / 2), 0, accuracy: 1e-6, "\(mode) knee starts")
            XCTAssertEqual(gr(s.threshold), (1 / s.ratio - 1) * s.knee / 8, accuracy: 1e-5, "\(mode) at the threshold")
            XCTAssertEqual(gr(s.threshold + s.knee / 2), (1 / s.ratio - 1) * s.knee / 2, accuracy: 1e-5, "\(mode) knee ends")
            let above = s.threshold + s.knee
            XCTAssertEqual(gr(above + 10) - gr(above), 10 * (1 / s.ratio - 1), accuracy: 1e-4, "\(mode) ratio")
            if let reference = s.reference { XCTAssertEqual(Double(c.makeupDB), -gr(reference), accuracy: 1e-5) }
        }
        let gentle = DynamicsCoefficients.make(Dynamics(comp: .gentle), sampleRate: rate)
        XCTAssertEqual(gentle.makeupDB, 0)
        XCTAssertGreaterThan(gentle.makeupFollow, 0)
        let night = DynamicsCoefficients.make(Dynamics(comp: .night), sampleRate: rate)
        XCTAssertEqual(night.makeupDB, 4.5)
        XCTAssertEqual(night.makeupFollow, 0)
    }

    /// What the detector's K-weighting adds at a frequency.
    private func weighting(_ mode: Dynamics.Compressor, _ frequency: Double) -> Double {
        let c = DynamicsCoefficients.make(Dynamics(comp: mode), sampleRate: rate)
        return c.detectorShelf.magnitudeDB(at: frequency, sampleRate: rate) + c.detectorHighPass.magnitudeDB(at: frequency, sampleRate: rate)
    }

    /// A steady 1 kHz tone settles to the static curve at its K-weighted RMS. Night adds its fixed
    /// makeup on top; gentle's makeup gives the reduction back within seconds, up to 6 dB.
    func testSteadyToneFollowsTheCurve() {
        for mode in Dynamics.Compressor.allCases {
            let c = DynamicsCoefficients.make(Dynamics(comp: mode), sampleRate: rate)
            for peak in [-50.0, -30.0, -20.0, -12.0, -6.0] {
                let input = sine(1000, peakDB: peak, seconds: mode == .gentle ? 15 : 3)
                let processor = processor(Dynamics(comp: mode))
                let output = run(processor, input)
                let tail = input.count - Int(rate / 2)
                let gain = rmsDB(output[tail...]) - rmsDB(input[tail...])
                let level = Float(peak - 10 * log10(2.0) + weighting(mode, 1000))
                let reduction = DynamicsCoefficients.reduction(level: level, threshold: c.threshold, knee: c.knee, slope: c.slope)
                XCTAssertEqual(processor.compressorReductionDB, reduction, accuracy: 0.3, "\(mode) at \(peak) dBFS")
                let makeup = mode == .gentle ? min(-reduction, DynamicsCoefficients.maxMakeupDB) : c.makeupDB
                XCTAssertEqual(gain, Double(reduction + makeup), accuracy: 0.3, "\(mode) at \(peak) dBFS")
            }
        }
    }

    /// A pause freezes gentle's makeup, and so does the engine's reset after a second of silence:
    /// the next song starts with the makeup the last one ended with, not from 0.
    func testGentleKeepsItsMakeupOverAPause() {
        let processor = processor(Dynamics(comp: .gentle))
        _ = run(processor, sine(1000, peakDB: -6, seconds: 12))
        _ = run(processor, [Float](repeating: 0, count: Int(3 * rate)))
        processor.resetRenderState()
        let output = run(processor, sine(1000, peakDB: -6, seconds: 1))
        let gain = rmsDB(output[Int(rate / 2)...]) - rmsDB(sine(1000, peakDB: -6, seconds: 1)[Int(rate / 2)...])
        print(String(format: "gentle after a pause: %+.2f dB", gain))
        XCTAssertEqual(gain, 0, accuracy: 0.5)
    }

    /// Linked by the loudest channel: dialogue on the centre of 5.1 alone is compressed as if it
    /// played on both sides of stereo, where averaging over six channels read it 7.8 dB low.
    func testTheLoudestChannelDrivesTheDetector() {
        let input = sine(1000, peakDB: -10, seconds: 1)
        for mode in Dynamics.Compressor.allCases {
            let stereo = processor(Dynamics(comp: mode))
            _ = run(stereo, input)
            let surround = processor(Dynamics(comp: mode))
            surround.configure(sampleRate: rate, channels: 6)
            let channels = (0..<6).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: 512) }
            defer { channels.forEach { $0.deallocate() } }
            var start = 0
            while start < input.count {
                let n = min(512, input.count - start)
                for (index, channel) in channels.enumerated() {
                    for i in 0..<n { channel[i] = index == 2 ? input[start + i] : 0 }
                }
                surround.process(channels: channels, frameCount: n)
                start += n
            }
            XCTAssertLessThan(stereo.compressorReductionDB, -2, "\(mode)")
            XCTAssertEqual(surround.compressorReductionDB, stereo.compressorReductionDB, accuracy: 0.01, "\(mode)")
        }
    }

    /// The time from a step to 63 % of the reduction's change. The detector's window and the
    /// attack or release are one-pole smoothers in series, so it measures about their sum.
    private func stepTimes(_ mode: Dynamics.Compressor) -> (attack: Double, release: Double) {
        let quiet = sine(1000, peakDB: -50, seconds: 1)
        let loud = sine(1000, peakDB: -6, seconds: 2)
        let signal = quiet + loud + sine(1000, peakDB: -50, seconds: 3)
        let processor = processor(Dynamics(comp: mode))
        var trace: [(t: Double, gr: Double)] = []
        _ = run(processor, signal, block: 16) { trace.append((Double($0) / self.rate, Double(processor.compressorReductionDB))) }
        let full = trace.last { $0.t <= 3 }!.gr
        let attack = trace.first { $0.t > 1 && $0.gr <= full * (1 - exp(-1)) }!.t - 1
        let release = trace.first { $0.t > 3 && $0.gr >= full * exp(-1) }!.t - 3
        return (attack, release)
    }

    func testAttackAndReleaseOnAStep() {
        for mode in Dynamics.Compressor.allCases {
            let s = mode.settings
            let measured = stepTimes(mode)
            let attack = s.attack + s.window, release = s.release + s.window
            print("\(mode): attack \(measured.attack * 1000) ms (\(attack * 1000) with the window), release \(measured.release * 1000) ms (\(release * 1000))")
            XCTAssertEqual(measured.attack, attack, accuracy: attack * 0.35, "\(mode) attack")
            XCTAssertEqual(measured.release, release, accuracy: release * 0.2, "\(mode) release")
        }
    }

    /// The detector hears deep bass at its loudness, so a bass-heavy mix or an explosion is
    /// compressed like anything else, but a steady 40 Hz tone at −10 dBFS holds the gain still
    /// instead of pumping it at the waveform's rate. Night reads it up to 1.5 dB louder than its
    /// RMS: the 5 ms attack catches each half-cycle's crest through the 2.5 ms window, and the
    /// 400 ms release barely lets go in between.
    func testDeepBassCompressesWithoutPumping() {
        for mode in Dynamics.Compressor.allCases {
            let c = DynamicsCoefficients.make(Dynamics(comp: mode), sampleRate: rate)
            let processor = processor(Dynamics(comp: mode))
            var trace: [Float] = []
            _ = run(processor, sine(40, peakDB: -10, seconds: 3), block: 16) { done in
                if done > Int(2 * self.rate) { trace.append(processor.compressorReductionDB) }
            }
            let level = Float(-10 - 10 * log10(2.0) + weighting(mode, 40))
            let expected = DynamicsCoefficients.reduction(level: level, threshold: c.threshold, knee: c.knee, slope: c.slope)
            let ripple = trace.max()! - trace.min()!
            print(String(format: "\(mode): 40 Hz at -10 dBFS reduces %.2f dB (curve %.2f), ripple %.3f dB", trace.last!, expected, ripple))
            XCTAssertLessThan(trace.last!, expected + 0.3, "\(mode)")
            XCTAssertGreaterThan(trace.last!, expected - (mode == .night ? 1.5 : 0.3), "\(mode)")
            XCTAssertLessThan(ripple, 0.15, "\(mode)")
        }
    }

    /// A gain that follows the waveform instead of its level is distortion; the detector's
    /// window and the attack keep it small down to where the high-pass lets bass in.
    func testCompressorBarelyDistortsBass() {
        for mode in Dynamics.Compressor.allCases {
            for frequency in [40.0, 100.0, 200.0] {
                let output = run(processor(Dynamics(comp: mode)), sine(frequency, peakDB: -6, seconds: 2))
                let distortion = thd(harmonics(output[Int(rate)...].prefix(Int(rate)), frequency))
                print(String(format: "\(mode) %.0f Hz at -6 dBFS: THD %.3f %%", frequency, distortion * 100))
                XCTAssertLessThan(distortion, 0.01, "\(mode) \(frequency) Hz")
            }
        }
    }

    // MARK: - Colour

    private func colour(_ kind: Dynamics.ColourKind, _ amount: Double, peakDB: Double = -12, frequency: Double = 1000)
        -> (input: ArraySlice<Float>, output: ArraySlice<Float>) {
        let input = sine(frequency, peakDB: peakDB, seconds: 1.5)
        let output = run(processor(Dynamics(color: .init(kind: kind, amount: amount))), input)
        // Half a second for the tube's DC blocker to settle; 48000 frames hold whole periods.
        let window = Int(rate / 2)..<(Int(rate / 2) + Int(rate))
        return (input[window], output[window])
    }

    private func harmonics(_ x: ArraySlice<Float>, _ fundamental: Double = 1000) -> [Double] {
        (1...7).map { amplitude(x, fundamental * Double($0)) }
    }

    private func thd(_ h: [Double]) -> Double {
        h.dropFirst().reduce(0) { $0 + $1 * $1 }.squareRoot() / h[0]
    }

    func testDistortionRisesWithAmount() {
        for kind in Dynamics.ColourKind.allCases {
            let distortion = [0.1, 0.3, 0.6, 1.0].map { thd(harmonics(colour(kind, $0).output)) }
            print("\(kind) THD at -12 dBFS for amount 0.1 0.3 0.6 1: \(distortion.map { String(format: "%.3f %%", $0 * 100) })")
            XCTAssertEqual(distortion, distortion.sorted(), "\(kind)")
            XCTAssertGreaterThan(distortion.last!, 10 * distortion.first!, "\(kind)")
        }
    }

    func testTubeHasEvenHarmonicsAndTapeDoesNot() {
        let tape = harmonics(colour(.tape, 1).output)
        let tube = harmonics(colour(.tube, 1).output)
        XCTAssertLessThan(tape[1] / tape[0], 1e-5, "tape 2nd")
        XCTAssertLessThan(tape[3] / tape[0], 1e-5, "tape 4th")
        XCTAssertGreaterThan(tape[2] / tape[0], 1e-3, "tape 3rd")
        XCTAssertGreaterThan(tube[1] / tube[0], 1e-2, "tube 2nd")
        XCTAssertGreaterThan(tube[1], tube[2], "tube's 2nd leads its 3rd")
    }

    func testColourKeepsTheLevel() {
        for kind in Dynamics.ColourKind.allCases {
            for amount in [0.1, 0.5, 1.0] {
                for peak in [-30.0, -12.0] {
                    let (input, output) = colour(kind, amount, peakDB: peak)
                    XCTAssertEqual(rmsDB(output), rmsDB(input), accuracy: 1, "\(kind) \(amount) at \(peak) dBFS")
                }
            }
        }
    }

    func testTubeLeavesNoDC() {
        let (_, output) = colour(.tube, 1, peakDB: -3)
        XCTAssertLessThan(abs(output.reduce(0) { $0 + Double($1) } / Double(output.count)), 1e-4)
    }

    /// No oversampling: a tone above 8 kHz folds its 3rd harmonic back under Nyquist. This pins how
    /// far down it lands for the README's note.
    func testAliasingAtFullAmount() {
        for kind in Dynamics.ColourKind.allCases {
            let (_, output) = colour(kind, 1, peakDB: -12, frequency: 10000)
            let fundamental = amplitude(output, 10000)
            let third = amplitude(output, 48000 - 30000)
            let fifth = amplitude(output, 50000 - 48000)
            let second = amplitude(output, 20000)
            print("\(kind) 10 kHz at -12 dBFS, amount 1: 2nd \(20 * log10(second / fundamental)) dB, folded 3rd (18 kHz) \(20 * log10(third / fundamental)) dB, folded 5th (2 kHz) \(20 * log10(fifth / fundamental)) dB")
            XCTAssertLessThan(20 * log10(third / fundamental), -30, "\(kind)")
            XCTAssertLessThan(20 * log10(fifth / fundamental), -55, "\(kind)")
        }
    }

    // MARK: - Switching

    private static let rates = [16000.0, 44100, 48000, 96000, 192000]

    /// A second of `from`, then `to`, applied between two 64-frame callbacks as the daemon would.
    private func switching(_ from: Dynamics?, _ to: Dynamics?, rate: Double, frequency: Double, peakDB: Double = -6)
        -> (input: [Float], output: [Float], at: Int) {
        let processor = EQProcessor()
        processor.configure(sampleRate: rate)
        var profile = Profile.flat
        profile.dynamics = from
        processor.apply(profile: profile, enabled: true)
        let amplitude = pow(10, peakDB / 20)
        let input = (0..<Int(2 * rate)).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / rate)) }
        var at = 0
        let output = run(processor, input, block: 64) { done in
            guard at == 0, done >= Int(rate) else { return }
            at = done
            profile.dynamics = to
            processor.apply(profile: profile, enabled: true)
        }
        return (input, output, at)
    }

    private func name(_ dynamics: Dynamics?) -> String {
        dynamics.map { Table.dynamics($0) }.flatMap { $0.isEmpty ? nil : $0 } ?? "off"
    }

    /// Switching the compressor on, off or to the other mode glides the gain there: no sample-to-sample
    /// step a listener hears as a click, and no swell above where it was or where it settles.
    func testSwitchingTheCompressorGlides() {
        let modes: [Dynamics?] = [nil, Dynamics(comp: .gentle), Dynamics(comp: .night)]
        for rate in Self.rates {
            for from in modes {
                for to in modes where to != from {
                    let (input, output, at) = switching(from, to, rate: rate, frequency: 1000)
                    let peak = input.map(abs).max()!
                    let gains = input.indices.map { n -> Double? in
                        abs(input[n]) > peak / 2 ? 20 * log10(Double(output[n] / input[n])) : nil
                    }
                    func mean(_ range: Range<Int>) -> Double {
                        let values = gains[range].compactMap { $0 }
                        return values.reduce(0, +) / Double(values.count)
                    }
                    let tenth = Int(rate / 10)
                    let before = mean((at - tenth)..<at), after = mean((input.count - tenth)..<input.count)
                    // Near a zero crossing out/in says nothing, so a step over such a gap counts per sample.
                    let measured = gains.indices.dropFirst(at - 1).compactMap { n in gains[n].map { (n, $0) } }
                    let transition = measured.map(\.1)
                    let step = zip(measured, measured.dropFirst()).map { abs($1.1 - $0.1) / Double($1.0 - $0.0) }.max()!
                    let label = "\(name(from)) → \(name(to)) at \(rate) Hz"
                    print(String(format: "\(label): largest step %.3f dB, peak %+.2f dB over the higher settled gain", step, transition.max()! - max(before, after)))
                    XCTAssertLessThan(step, 0.5, label)
                    XCTAssertLessThan(transition.max()!, max(before, after) + 1, label)
                }
            }
        }
    }

    /// The same for the colour: its drive glides, so neither the curve nor the tube's DC arrives as a step.
    func testSwitchingTheColourGlides() {
        let tube = Dynamics(color: .init(kind: .tube, amount: 1))
        let cases: [(Dynamics?, Dynamics?)] = [
            (nil, tube), (tube, nil), (Dynamics(color: .init(kind: .tube, amount: 0.2)), tube),
            (Dynamics(color: .init(kind: .tape, amount: 1)), tube), (tube, Dynamics(comp: .night, color: .init(kind: .tape, amount: 1))),
        ]
        for rate in Self.rates {
            for (from, to) in cases {
                let (_, output, at) = switching(from, to, rate: rate, frequency: 200)
                let steps = zip(output, output.dropFirst()).map { abs($1 - $0) }
                let tenth = Int(rate / 10)
                let steady = max(steps[(at - tenth)..<(at - 1)].max()!, steps[(steps.count - tenth)...].max()!)
                let label = "\(name(from)) → \(name(to)) at \(rate) Hz"
                print(String(format: "\(label): largest step %.2f × steady", steps[(at - 1)...].max()! / steady))
                XCTAssertLessThan(steps[(at - 1)...].max()!, 1.1 * steady, label)
            }
        }
    }

    /// Once a stage switched off has glided out it stops running: the output is the plain curve's, bit for bit.
    func testASwitchedOffStageStopsOnceItHasGlidedOut() {
        for from in [Dynamics(comp: .night), Dynamics(color: .init(kind: .tube, amount: 1)), Dynamics(comp: .gentle, color: .init(kind: .tape, amount: 1))] {
            let (input, output, at) = switching(from, nil, rate: rate, frequency: 1000)
            let plain = run(processor(nil), input)
            let settled = at + Int(rate / 2)
            XCTAssertEqual(Array(output[settled...]), Array(plain[settled...]), "\(from)")
        }
    }

    // MARK: - Safety

    func testOffIsBitIdenticalAndBypassDropsTheStage() {
        let input = sine(1000, peakDB: -6, seconds: 0.2)
        let full = Profile(name: nil, preamp: -3, bands: Config.screenshotCurve)
        let plain = run(processor(nil, profile: full), input)
        XCTAssertEqual(run(processor(Dynamics(), profile: full), input), plain)
        let bypassed = run(processor(Dynamics(comp: .night, color: .init(kind: .tube, amount: 1)), profile: full, enabled: false), input)
        XCTAssertEqual(bypassed, input)
    }

    func testNoNaNAndTheTailEndsInExactZeros() {
        let processor = processor(Dynamics(comp: .night, color: .init(kind: .tube, amount: 1)),
                                  profile: Profile(name: nil, preamp: 0, bands: Config.screenshotCurve))
        var noise = SystemRandomNumberGenerator()
        let loud = (0..<Int(rate)).map { _ in Float.random(in: -1...1, using: &noise) }
        let hot = run(processor, loud.map { $0 * 4 })
        XCTAssertTrue(hot.allSatisfy(\.isFinite))
        XCTAssertLessThanOrEqual(hot.map(abs).max()!, 1)
        var subnormal = 0
        var state: [Float] = []
        var blocks = 0
        var last: [Float] = []
        repeat {
            let out = run(processor, [Float](repeating: 0, count: 512))
            XCTAssertTrue(out.allSatisfy(\.isFinite))
            last = out
            state = processor.renderStateForTesting()
            if state.contains(where: { $0 != 0 && !$0.isNormal }) { subnormal += 1 }
            blocks += 1
        } while state.contains { $0 != 0 } && blocks < Int(8 * rate) / 512
        XCTAssertEqual(subnormal, 0)
        XCTAssertEqual(state.filter { $0 != 0 }, [], "still decaying after \(blocks * 512) frames")
        XCTAssertEqual(processor.compressorReductionDB, 0)
        XCTAssertEqual(last.filter { $0 != 0 }, [])
    }

    /// One second of stereo at 48 kHz through the full curve, with and without both stages. The
    /// numbers in the README come from `swift test -c release -Xswiftc -enable-testing --filter DynamicsTests/testCost`.
    func testCost() {
        let full = Profile(name: nil, preamp: -3, bands: Config.screenshotCurve)
        var noise = SystemRandomNumberGenerator()
        let signal = (0..<Int(rate)).map { _ in Float.random(in: -0.3...0.3, using: &noise) }
        func seconds(_ dynamics: Dynamics?) -> Double {
            let processor = processor(dynamics, profile: full)
            _ = run(processor, signal)
            var best = Double.infinity
            for _ in 0..<5 {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = run(processor, signal)
                best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
            }
            return best
        }
        let off = seconds(nil)
        let comp = seconds(Dynamics(comp: .night))
        let tape = seconds(Dynamics(color: .init(kind: .tape, amount: 1)))
        let both = seconds(Dynamics(comp: .night, color: .init(kind: .tube, amount: 1)))
        print(String(format: "cost per 1 s of stereo 48 kHz: curve %.2f ms, +comp %.2f ms, +tape %.2f ms, +comp+tube %.2f ms",
                     off * 1000, (comp - off) * 1000, (tape - off) * 1000, (both - off) * 1000))
        XCTAssertLessThan(both, 1, "slower than real time")
    }
}
