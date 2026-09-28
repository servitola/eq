import AVFoundation
import XCTest
@testable import eq

/// Offline measurement of what the compressor does to a whole mix: program material through the
/// favourite curve, the compressor on against off, compared per octave band and in BS.1770 loudness.
final class CompressorBalanceTests: XCTestCase {
    private static let rate = 48000.0
    private var rate: Double { Self.rate }
    static let bands: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    // MARK: - Measurement filters, in Double

    struct Biquad {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var z1 = 0.0, z2 = 0.0
        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
        static func rbj(_ type: FilterType, _ f: Double, gain: Double = 0, q: Double, rate: Double) -> Biquad {
            let a = pow(10, gain / 40), w = 2 * Double.pi * f / rate, cw = cos(w), alpha = sin(w) / (2 * q)
            var b = (1.0, 0.0, 0.0), d = (1.0, 0.0, 0.0)
            switch type {
            case .highPass: b = ((1 + cw) / 2, -(1 + cw), (1 + cw) / 2); d = (1 + alpha, -2 * cw, 1 - alpha)
            case .lowPass: b = ((1 - cw) / 2, 1 - cw, (1 - cw) / 2); d = (1 + alpha, -2 * cw, 1 - alpha)
            case .bandPass: b = (alpha, 0, -alpha); d = (1 + alpha, -2 * cw, 1 - alpha)
            case .highShelf:
                let s = 2 * sqrt(a) * alpha
                b = (a * ((a + 1) + (a - 1) * cw + s), -2 * a * ((a - 1) + (a + 1) * cw), a * ((a + 1) + (a - 1) * cw - s))
                d = ((a + 1) - (a - 1) * cw + s, 2 * ((a - 1) - (a + 1) * cw), (a + 1) - (a - 1) * cw - s)
            default: fatalError()
            }
            return Biquad(b0: b.0 / d.0, b1: b.1 / d.0, b2: b.2 / d.0, a1: d.1 / d.0, a2: d.2 / d.0)
        }
    }

    /// BS.1770-4 integrated loudness, in LUFS, of `x` played on both sides of stereo.
    static func loudness(_ x: [Float], rate: Double) -> Double {
        let k = (shelf: DynamicsCoefficients.kShelf, highPass: DynamicsCoefficients.kHighPass)
        var shelf = Biquad.rbj(.highShelf, k.shelf.frequency, gain: k.shelf.gainDB, q: k.shelf.q, rate: rate)
        var highPass = Biquad.rbj(.highPass, k.highPass.frequency, q: k.highPass.q, rate: rate)
        var energy = [Double](repeating: 0, count: x.count + 1)
        for i in x.indices {
            let y = highPass.process(shelf.process(Double(x[i])))
            energy[i + 1] = energy[i] + y * y
        }
        let block = Int(0.4 * rate), hop = Int(0.1 * rate)
        let blocks = stride(from: 0, through: x.count - block, by: hop).map { 2 * (energy[$0 + block] - energy[$0]) / Double(block) }
        func lufs(_ z: Double) -> Double { -0.691 + 10 * log10(z) }
        let absolute = blocks.filter { lufs($0) > -70 }
        let relative = lufs(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { lufs($0) > relative }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }

    /// Long-term energy in each octave band, in dB: two band-passes an octave wide, in series.
    static func bandLevels(_ x: [Float], rate: Double) -> [Double] {
        bands.map { f in
            var a = Biquad.rbj(.bandPass, f, q: 2.0.squareRoot(), rate: rate), b = a
            var sum = 0.0
            for s in x { let y = b.process(a.process(Double(s))); sum += y * y }
            return 10 * log10(sum / Double(x.count) + 1e-30)
        }
    }

    // MARK: - Program material

    struct Program {
        var signal: [Float]
        /// Samples where the pad plays loud, quiet, and not at all, from an eighth into each section.
        var loud: [Range<Int>] = []
        var quiet: [Range<Int>] = []
        var bassOnly: [Range<Int>] = []
    }

    static func pink(count: Int, seed: UInt64) -> [Double] {
        var g = SplitMix(seed)
        var b = [Double](repeating: 0, count: 7)
        return (0..<count).map { _ in
            let w = g.uniform() * 2 - 1
            b[0] = 0.99886 * b[0] + w * 0.0555179; b[1] = 0.99332 * b[1] + w * 0.0750759
            b[2] = 0.96900 * b[2] + w * 0.1538520; b[3] = 0.86650 * b[3] + w * 0.3104856
            b[4] = 0.55000 * b[4] + w * 0.5329522; b[5] = -0.7616 * b[5] - w * 0.0168980
            let out = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + w * 0.5362
            b[6] = w * 0.115926
            return out * 0.11
        }
    }

    struct SplitMix {
        var state: UInt64
        init(_ seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }

    /// A kick at 55 Hz every 500 ms, a bass line between 41 and 110 Hz, a pad of 300 Hz–3 kHz whose
    /// level moves by 10 dB between sections and drops out for one, and hats at 8–12 kHz every 125 ms.
    static func music(sectionSeconds: Double = 8, rate: Double) -> Program {
        let sectionLevels = [0.0, -10, 0, -10, -5, 0, -.infinity, 0]
        let section = Int(sectionSeconds * rate)
        let count = sectionLevels.count * section
        let beat = Int(0.5 * rate)
        var out = kick(count: count, rate: rate)
        let notes = [41.2, 55, 61.7, 82.4, 110, 73.4, 49, 98]
        for n in 0..<count {
            let index = n / beat
            let t = Double(n % beat) / rate
            let f = notes[index % notes.count]
            let phase = 2 * Double.pi * f * Double(n) / rate
            let env = min(t / 0.01, 1) * (0.6 + 0.4 * exp(-t / 0.08))
            out[n] += 0.16 * env * (sin(phase) + 0.5 * sin(2 * phase) + 0.25 * sin(3 * phase))
        }
        let pad = [330.0, 415, 494, 660, 740, 990, 1320, 1480, 1980, 2640]
        var g = SplitMix(7)
        let phases = pad.map { _ in g.uniform() * 2 * Double.pi }
        var level = pow(10, sectionLevels[0] / 20)
        let glide = exp(-1 / (0.3 * rate))
        var program = Program(signal: [])
        for (i, l) in sectionLevels.enumerated() {
            let range = (i * section + section / 8)..<((i + 1) * section)
            if l == 0 { program.loud.append(range) }
            if l == -10 { program.quiet.append(range) }
            if l == -.infinity { program.bassOnly.append(range) }
        }
        for n in 0..<count {
            let target = pow(10, sectionLevels[min(n / section, sectionLevels.count - 1)] / 20)
            level = glide * level + (1 - glide) * target
            let swell = 1 + 0.2 * sin(2 * Double.pi * Double(n) / (2 * rate))
            var sum = 0.0
            for (k, f) in pad.enumerated() { sum += sin(2 * Double.pi * f * Double(n) / rate + phases[k]) / sqrt(Double(k + 1)) }
            out[n] += 0.07 * level * swell * sum
        }
        var hp = Biquad.rbj(.highPass, 8000, q: 0.7071, rate: rate), lp = Biquad.rbj(.lowPass, 12000, q: 0.7071, rate: rate)
        let hat = Int(0.125 * rate)
        for n in 0..<count {
            let t = Double(n % hat) / rate
            let noise = lp.process(hp.process(g.uniform() * 2 - 1))
            out[n] += 0.25 * exp(-t / 0.03) * noise
        }
        program.signal = out.map(Float.init)
        return program
    }

    /// 55 Hz with a pitch drop from 145 Hz, every 500 ms.
    static func kick(count: Int, rate: Double) -> [Double] {
        let beat = Int(0.5 * rate)
        var phase = 0.0
        return (0..<count).map { n in
            let t = Double(n % beat) / rate
            if n % beat == 0 { phase = 0 }
            phase += 2 * Double.pi * (55 + 90 * exp(-t / 0.015)) / rate
            return 0.35 * exp(-t / 0.18) * sin(phase)
        }
    }

    /// Pink noise whose level swings 12 dB over a 10-second cycle.
    static func swingingPink(seconds: Double = 40, rate: Double) -> Program {
        let noise = pink(count: Int(seconds * rate), seed: 3)
        let signal = noise.enumerated().map { n, x in Float(x * pow(10, (-6 + 6 * sin(2 * Double.pi * Double(n) / (10 * rate))) / 20)) }
        return Program(signal: signal)
    }

    /// The program through the favourite curve, once for each loudness it is to have before the
    /// curve. The curve is linear, so one pass scaled serves every level.
    static func throughCurve(_ p: Program, loudness targets: [Double], rate: Double) -> [Program] {
        let loudness = Self.loudness(p.signal, rate: rate)
        let equalised = equalise(p.signal, rate: rate)
        return targets.map { target in
            let gain = Float(pow(10, (target - loudness) / 20))
            var scaled = p
            scaled.signal = equalised.map { $0 * gain }
            return scaled
        }
    }

    static func equalise(_ input: [Float], rate: Double) -> [Float] {
        let processor = EQProcessor()
        processor.configure(sampleRate: rate)
        let profile = Profile(name: nil, preamp: 0, bands: Config.screenshotCurve)
        processor.update(bands: profile.engineBands, preampDB: 0, limiterEnabled: false, limiterCeilingDB: 0, bypassed: false)
        var output = input
        output.withUnsafeMutableBufferPointer { buffer in
            let right = UnsafeMutablePointer<Float>.allocate(capacity: 512)
            defer { right.deallocate() }
            var start = 0
            while start < buffer.count {
                let n = min(512, buffer.count - start)
                right.update(from: buffer.baseAddress! + start, count: n)
                processor.process(channels: [buffer.baseAddress! + start, right], frameCount: n)
                start += n
            }
        }
        return output
    }

    /// Dialogue at 150 Hz–4 kHz in phrases with pauses, 12 s at one level then 12 s 10 dB under it,
    /// and four explosions of 30–200 Hz noise. Ranges: dialogue alone at each level, and each
    /// explosion's first second.
    static func film(rate: Double) -> (signal: [Float], dialogue: [Range<Int>], quietDialogue: [Range<Int>], explosions: [Range<Int>]) {
        let seconds = 48.0
        let count = Int(seconds * rate)
        var out = [Double](repeating: 0, count: count)
        var g = SplitMix(11)
        var formant1 = Biquad.rbj(.bandPass, 700, q: 2, rate: rate), formant2 = Biquad.rbj(.bandPass, 1800, q: 3, rate: rate)
        var hiss = Biquad.rbj(.highPass, 2500, q: 0.7, rate: rate)
        var phase = 0.0
        for n in 0..<count {
            let t = Double(n) / rate
            let f0 = 140 + 30 * sin(2 * Double.pi * 0.7 * t) + 15 * sin(2 * Double.pi * 3.1 * t)
            phase += 2 * Double.pi * f0 / rate
            // A plain sawtooth: its aliases sit far under what the formants pass.
            let voiced = phase.truncatingRemainder(dividingBy: 2 * Double.pi) / Double.pi - 1
            let speech = formant1.process(voiced) * 1.6 + formant2.process(voiced) * 1.2 + 0.05 * hiss.process(g.uniform() * 2 - 1)
            let syllables = max(0, sin(2 * Double.pi * 4 * t)) * (0.5 + 0.5 * pow(sin(2 * Double.pi * 0.23 * t), 2))
            let phrase = Int(t / 2.5) % 3 == 2 ? 0.0 : 1.0
            let level = Int(t / 12) % 2 == 1 ? 0.3 : 1.0
            out[n] = 0.25 * speech * syllables * phrase * level
        }
        var low = Biquad.rbj(.lowPass, 200, q: 0.7, rate: rate), low2 = low, high = Biquad.rbj(.highPass, 30, q: 0.7, rate: rate)
        var explosions: [Range<Int>] = []
        for startSecond in [5.0, 20.0, 29.0, 41.0] {
            let start = Int(startSecond * rate)
            explosions.append(start..<(start + Int(rate)))
            for n in start..<min(count, start + Int(3 * rate)) {
                let t = Double(n - start) / rate
                let rumble = high.process(low2.process(low.process(g.uniform() * 2 - 1)))
                out[n] += 2.2 * min(t / 0.01, 1) * exp(-t / 0.8) * rumble
            }
        }
        var dialogue: [Range<Int>] = [], quietDialogue: [Range<Int>] = []
        for block in 0..<Int(seconds / 12) {
            let clear = ((block * 12 * Int(rate))..<((block + 1) * 12 * Int(rate))).split { n in
                explosions.contains { $0.lowerBound - Int(rate) <= n && n < $0.lowerBound + Int(4 * rate) }
            }
            for part in clear where part.count > Int(rate) {
                let range = (part.startIndex + Int(rate / 2))..<part.endIndex
                if block % 2 == 1 { quietDialogue.append(range) } else { dialogue.append(range) }
            }
        }
        return (out.map(Float.init), dialogue, quietDialogue, explosions)
    }

    // MARK: - The chain

    struct Result {
        var output: [Float]
        var gainDB: [Float]
        var reductionDB: [Float]
    }

    /// What comes after the curve: the compressor built from `coefficients` (nil for off), run by
    /// the render thread's own code, then a copy of the processor's limiter at −1 dBFS.
    static func chain(_ input: [Float], _ coefficients: DynamicsCoefficients?, rate: Double) -> Result {
        let count = input.count
        let left = UnsafeMutablePointer<Float>.allocate(capacity: count), right = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { left.deallocate(); right.deallocate() }
        left.initialize(from: input, count: count)
        right.initialize(from: input, count: count)
        var gains = [Float](repeating: 0, count: count), reductions = gains
        if let coefficients {
            var state = DynamicsState()
            let detector = UnsafeMutablePointer<BiquadState>.allocate(capacity: 4)
            let dc = UnsafeMutablePointer<Float>.allocate(capacity: 4)
            detector.initialize(repeating: BiquadState(), count: 4)
            dc.initialize(repeating: 0, count: 4)
            defer { detector.deallocate(); dc.deallocate() }
            let pointers = [left, right]
            pointers.withUnsafeBufferPointer { channels in
                for frame in 0..<count {
                    _ = coefficients.process(channels, frame: frame, channelCount: 2, state: &state, detector: detector, dc: dc)
                    gains[frame] = state.reductionDB + state.makeupDB
                    reductions[frame] = state.reductionDB
                }
            }
        }
        let ceiling = Float(pow(10, -1.0 / 20)), release = Float(exp(-1.0 / (0.080 * rate)))
        var envelope: Float = 0
        for i in 0..<count {
            let peak = max(abs(left[i]), abs(right[i]))
            envelope = peak > envelope ? peak : release * envelope + (1 - release) * peak
            if envelope > ceiling { left[i] *= ceiling / envelope }
        }
        return Result(output: Array(UnsafeBufferPointer(start: left, count: count)), gainDB: gains, reductionDB: reductions)
    }

    struct Report {
        var loudnessDelta: Double
        var bandDeltas: [Double]
        var loudReduction: Double
        /// The gain, makeup included, where the pad is out against where it plays loud: how much
        /// louder the compressor leaves a passage of bass alone than the full mix.
        var bassSkew: Double
        var meanReduction: Double
        /// Net gain on the quiet sections over the loud ones: how far the compressor levels them.
        var levelling: Double
        /// The reduction's swing within each beat on the loud sections, peak to peak, averaged.
        var pumping: Double
        /// Bass (32–125 Hz) against mids (500 Hz–2 kHz), each averaged in dB.
        var tilt: Double { (bandDeltas[0...2].reduce(0, +) - bandDeltas[4...6].reduce(0, +)) / 3 }
        var spread: Double { bandDeltas.max()! - bandDeltas.min()! }
    }

    static func measure(_ program: Program, _ coefficients: DynamicsCoefficients, rate: Double) -> Report {
        let settle = Int(2 * rate)
        let off = chain(program.signal, nil, rate: rate)
        let on = chain(program.signal, coefficients, rate: rate)
        let offTail = Array(off.output[settle...]), onTail = Array(on.output[settle...])
        let deltas = zip(bandLevels(onTail, rate: rate), bandLevels(offTail, rate: rate)).map { $0 - $1 }
        let loudness = Self.loudness(onTail, rate: rate) - Self.loudness(offTail, rate: rate)
        func mean(_ ranges: [Range<Int>], _ x: [Float]) -> Double {
            let values = ranges.flatMap { x[$0] }
            return values.isEmpty ? .nan : values.reduce(0) { $0 + Double($1) } / Double(values.count)
        }
        let beat = Int(0.5 * rate)
        let swings = program.loud.flatMap { range in
            stride(from: range.lowerBound, to: range.upperBound - beat, by: beat).map { start -> Double in
                let slice = on.reductionDB[start..<(start + beat)]
                return Double(slice.max()! - slice.min()!)
            }
        }
        return Report(loudnessDelta: loudness, bandDeltas: deltas, loudReduction: mean(program.loud, on.reductionDB),
                      bassSkew: mean(program.bassOnly, on.gainDB) - mean(program.loud, on.gainDB),
                      meanReduction: mean([settle..<program.signal.count], on.reductionDB),
                      levelling: mean(program.quiet, on.gainDB) - mean(program.loud, on.gainDB),
                      pumping: swings.isEmpty ? .nan : swings.reduce(0, +) / Double(swings.count))
    }

    /// Gain modulation in dB, peak to peak, over the last second of a steady input.
    static func modulation(_ input: [Float], _ coefficients: DynamicsCoefficients, rate: Double) -> (mean: Double, depth: Double) {
        let result = chain(input, coefficients, rate: rate)
        let tail = result.reductionDB[(input.count - Int(rate))...]
        return (tail.reduce(0) { $0 + Double($1) } / Double(tail.count), Double(tail.max()! - tail.min()!))
    }

    // MARK: - Acceptance

    /// Gentle on the favourite curve moves no octave band against the others by 1 dB, the
    /// loudness by 1 LU, and bass alone by 1 dB against the full mix, at a streaming level and 6 dB
    /// under it, while it still takes 2 dB off the loud sections at the streaming level.
    func testGentleKeepsTheBalanceOfABassHeavyMix() {
        let c = DynamicsCoefficients.make(Dynamics(comp: .gentle), sampleRate: rate)
        let music = Self.music(sectionSeconds: 6, rate: rate)
        let levels = Self.throughCurve(music, loudness: [-14, -20], rate: rate)
        let programs = [("music at -14 LUFS", levels[0]), ("music at -20 LUFS", levels[1]),
                        ("pink noise at -16 LUFS", Self.throughCurve(Self.swingingPink(seconds: 15, rate: rate), loudness: [-16], rate: rate)[0])]
        for (name, program) in programs {
            let r = Self.measure(program, c, rate: rate)
            print(Self.line(name, r))
            XCTAssertLessThan(abs(r.loudnessDelta), 1, name)
            XCTAssertLessThan(r.spread, 1, name)
            if !program.loud.isEmpty {
                XCTAssertLessThan(r.bassSkew, 1, name)
                XCTAssertLessThan(r.pumping, 2.5, name)
            }
            if name.contains("-14") { XCTAssertLessThan(r.loudReduction, -2, name) }
        }
    }

    /// Night on film: explosions of 30–200 Hz come down against the dialogue, and quiet dialogue
    /// comes up against loud; the detector hears the explosions' bass.
    func testNightTurnsExplosionsDownAgainstDialogue() {
        let n = Self.night(.make(Dynamics(comp: .night), sampleRate: rate), rate: rate)
        print(n.line)
        XCTAssertLessThan(n.explosionOverDialogue.on, n.explosionOverDialogue.off - 1)
        XCTAssertLessThan(n.explosionPeak.on, n.explosionPeak.off - 1)
        XCTAssertGreaterThan(n.quietUnderLoud.on, n.quietUnderLoud.off + 5)
    }

    static func line(_ name: String, _ r: Report) -> String {
        String(format: "%@: ΔLU %+.2f, bass-mid tilt %+.2f dB, band spread %.2f dB | reduction: mean %.2f dB, loud sections %.2f dB | bass alone %+.2f dB, quiet sections %+.2f dB, pumping %.2f dB per beat | bands %@",
               name, r.loudnessDelta, r.tilt, r.spread, r.meanReduction, r.loudReduction, r.bassSkew, r.levelling, r.pumping,
               r.bandDeltas.map { String(format: "%+.2f", $0) }.joined(separator: " "))
    }

    /// Film-like material at −24 LUFS: dialogue at 150 Hz–4 kHz in phrases, 12 s loud then 12 s
    /// 10 dB quieter, and explosions of 30–200 Hz noise.
    static func night(_ c: DynamicsCoefficients, rate: Double) -> (explosionOverDialogue: (off: Double, on: Double),
                                                                  explosionPeak: (off: Double, on: Double),
                                                                  quietUnderLoud: (off: Double, on: Double), line: String) {
        let film = Self.film(rate: rate)
        let input = Self.throughCurve(Program(signal: film.signal), loudness: [-24], rate: rate)[0].signal
        let off = Self.chain(input, nil, rate: rate), on = Self.chain(input, c, rate: rate)
        func level(_ x: [Float], _ ranges: [Range<Int>]) -> Double {
            let values = ranges.flatMap { x[$0] }
            return 10 * log10(values.reduce(0) { $0 + Double($1) * Double($1) } / Double(values.count))
        }
        func peak(_ x: [Float]) -> Double { 20 * log10(Double(film.explosions.flatMap { x[$0] }.map(abs).max()!)) }
        let over = (level(off.output, film.explosions) - level(off.output, film.dialogue), level(on.output, film.explosions) - level(on.output, film.dialogue))
        let peaks = (peak(off.output), peak(on.output))
        let quiet = (level(off.output, film.quietDialogue) - level(off.output, film.dialogue), level(on.output, film.quietDialogue) - level(on.output, film.dialogue))
        let lu = Self.loudness(on.output, rate: rate) - Self.loudness(off.output, rate: rate)
        let line = String(format: "explosions over dialogue %.1f → %.1f dB, explosion peak %.1f → %.1f dBFS, quiet under loud dialogue %.1f → %.1f dB, ΔLU %+.2f",
                          over.0, over.1, peaks.0, peaks.1, quiet.0, quiet.1, lu)
        return (over, peaks, quiet, line)
    }

    // MARK: - Exploring the design

    struct Variant {
        enum Detector { case highPass100, kWeighting }
        var name: String
        var detector: Detector
        var window: Double
        /// Seconds a following makeup averages over; nil for the mode's fixed makeup (gentle's
        /// was +3 dB, restoring −12 dBFS).
        var follow: Double?
    }

    static func coefficients(_ mode: Dynamics.Compressor, _ v: Variant, rate: Double) -> DynamicsCoefficients {
        var c = DynamicsCoefficients.make(Dynamics(comp: mode), sampleRate: rate)
        if v.detector == .highPass100 {
            // The design before: two Butterworth high-pass sections at 100 Hz.
            c.detectorShelf = .make(type: .highPass, frequency: 100, gainDB: 0, q: 0.5.squareRoot(), sampleRate: rate)
            c.detectorHighPass = c.detectorShelf
        }
        c.detectorSmoothing = Float(exp(-1 / (v.window * rate)))
        if let follow = v.follow {
            c.makeupFollow = Float(exp(-1 / (follow * rate)))
            c.followGateDB = c.threshold - DynamicsCoefficients.followGateBelowThreshold
        } else {
            c.makeupFollow = 0
            c.makeupDB = mode == .gentle ? 3 : 4.5
        }
        return c
    }

    /// The table in the spec. `EQ_EXPLORE=1 swift test -c release -Xswiftc -enable-testing --filter
    /// CompressorBalanceTests/testExploreDesigns`; `EQ_EXPLORE_FILES=a.caf:b.caf` adds recordings,
    /// each normalised to −14 LUFS.
    func testExploreDesigns() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EQ_EXPLORE"] != nil)
        let gentle = [
            Variant(name: "before: HPF100, 2.5 ms, fixed +3 dB", detector: .highPass100, window: 0.0025, follow: nil),
            Variant(name: "(a) K, 2.5 ms, fixed", detector: .kWeighting, window: 0.0025, follow: nil),
            Variant(name: "(b) HPF100, 25 ms, fixed", detector: .highPass100, window: 0.025, follow: nil),
            Variant(name: "(b) HPF100, 50 ms, fixed", detector: .highPass100, window: 0.050, follow: nil),
            Variant(name: "(c) HPF100, 2.5 ms, follow 3 s", detector: .highPass100, window: 0.0025, follow: 3),
            Variant(name: "(ab) K, 50 ms, fixed", detector: .kWeighting, window: 0.050, follow: nil),
            Variant(name: "(bc) HPF100, 50 ms, follow 3 s", detector: .highPass100, window: 0.050, follow: 3),
            Variant(name: "(ac) K, 2.5 ms, follow 3 s", detector: .kWeighting, window: 0.0025, follow: 3),
            Variant(name: "(abc) K, 25 ms, follow 3 s", detector: .kWeighting, window: 0.025, follow: 3),
            Variant(name: "(abc) K, 50 ms, follow 1.5 s", detector: .kWeighting, window: 0.050, follow: 1.5),
            Variant(name: "(abc) K, 50 ms, follow 3 s", detector: .kWeighting, window: 0.050, follow: 3),
        ]
        let music = Self.music(rate: rate)
        let levels = Self.throughCurve(music, loudness: [-14, -20], rate: rate)
        var programs = [("music -14", levels[0]), ("music -20", levels[1]),
                        ("pink -16", Self.throughCurve(Self.swingingPink(rate: rate), loudness: [-16], rate: rate)[0])]
        for path in (ProcessInfo.processInfo.environment["EQ_EXPLORE_FILES"] ?? "").split(separator: ":") {
            let url = URL(fileURLWithPath: String(path))
            let file = try AVAudioFile(forReading: url)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let track = Program(signal: Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))))
            programs.append(("\(url.lastPathComponent) -14", Self.throughCurve(track, loudness: [-14], rate: rate)[0]))
        }
        // The kick alone, at the level it has in the mix at −14 LUFS.
        let kickGain = pow(10, (-14 - Self.loudness(music.signal, rate: rate)) / 20)
        let kick = Self.equalise(Self.kick(count: Int(6 * rate), rate: rate).map { Float($0 * kickGain) }, rate: rate)
        let sine40 = Self.equalise((0..<Int(3 * rate)).map { Float(pow(10, -10.0 / 20) * sin(2 * Double.pi * 40 * Double($0) / rate)) }, rate: rate)
        var lines: [String] = []
        for v in gentle {
            let c = Self.coefficients(.gentle, v, rate: rate)
            lines.append("== gentle \(v.name)")
            for (name, p) in programs { lines.append("  " + Self.line(name, Self.measure(p, c, rate: rate))) }
            let s = Self.modulation(sine40, c, rate: rate), k = Self.modulation(kick, c, rate: rate)
            lines.append(String(format: "  40 Hz at -10 dBFS: reduction %.2f dB, ripple %.2f dB; kick alone: reduction %.2f dB, swing %.2f dB", s.mean, s.depth, k.mean, k.depth))
        }
        let night = [
            Variant(name: "before: HPF100, 2.5 ms", detector: .highPass100, window: 0.0025, follow: nil),
            Variant(name: "K, 2.5 ms", detector: .kWeighting, window: 0.0025, follow: nil),
            Variant(name: "K, 10 ms", detector: .kWeighting, window: 0.010, follow: nil),
            Variant(name: "K, 25 ms", detector: .kWeighting, window: 0.025, follow: nil),
        ]
        for v in night {
            let c = Self.coefficients(.night, v, rate: rate)
            let s = Self.modulation(sine40, c, rate: rate)
            lines.append(String(format: "== night %@: %@; 40 Hz at -10 dBFS: reduction %.1f dB, ripple %.2f dB", v.name, Self.night(c, rate: rate).line, s.mean, s.depth))
        }
        print(lines.joined(separator: "\n"))
    }
}
