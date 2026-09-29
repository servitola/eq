import XCTest
import CoreAudio
@testable import eq

/// Drives a route engine's two render functions on two simulated clocks, without Core Audio: the tap
/// on the clock of the device the app plays on, the output on the target's. Events run in host-time
/// order, as the two IO threads would.
private final class RouteSim {
    let engine = RouteEngine(targetUID: "test-target")
    let tapRate: Double
    let outputRate: Double
    /// How much faster the tap's clock really runs than its nominal rate.
    let drift: Double
    let tapFrames: Int
    let outputFrames: Int
    /// A deterministic ± this many seconds on every time stamp.
    let jitter: Double
    /// When the output buffer plays, after its callback.
    let lead = 0.005
    private let ticksPerSecond = Double(AudioConvertNanosToHostTime(1_000_000_000))
    private let tapBuffer: UnsafeMutablePointer<Float>
    private let outputBuffer: UnsafeMutablePointer<Float>
    private var tapIndex = 0
    private var outputIndex = 0
    private var tapPosition = 0
    private var noise: UInt64 = 0x2545F4914F6CDD1D
    var stalled = false
    private(set) var output: [Float] = []

    init(tapRate: Double, outputRate: Double, drift: Double = 0, tapFrames: Int = 128, outputFrames: Int = 128,
         jitter: Double = 0, outputChannels: Int = 2) {
        self.tapRate = tapRate
        self.outputRate = outputRate
        self.drift = drift
        self.tapFrames = tapFrames
        self.outputFrames = outputFrames
        self.jitter = jitter
        self.outputChannels = outputChannels
        tapBuffer = .allocate(capacity: 2 * 4096)
        outputBuffer = .allocate(capacity: 2 * 4096)
        engine.processor.configure(sampleRate: outputRate, channels: 2)
        engine.processor.apply(profile: .flat, enabled: false)
        engine.prepare(channels: 2, tapRate: tapRate, outputRate: outputRate, tapFrames: tapFrames, outputFrames: outputFrames)
    }

    let outputChannels: Int

    deinit {
        tapBuffer.deallocate()
        outputBuffer.deallocate()
    }

    private func wobble() -> Double {
        guard jitter > 0 else { return 0 }
        noise ^= noise << 13
        noise ^= noise >> 7
        noise ^= noise << 17
        return (Double(noise % 2001) / 1000 - 1) * jitter
    }

    private func stamp(_ seconds: Double) -> AudioTimeStamp {
        var t = AudioTimeStamp()
        t.mHostTime = UInt64((10 + seconds + wobble()) * ticksPerSecond)
        t.mFlags = [.hostTimeValid]
        return t
    }

    /// Runs `seconds` of both clocks; the tap plays `signal(tap frame)` on the left, its negation on the right.
    func run(seconds: Double, signal: (Int) -> Float) {
        let end = seconds + Double(outputIndex * outputFrames) / outputRate
        while true {
            let tapTime = Double((tapIndex + 1) * tapFrames) / (tapRate * (1 + drift))
            let outputTime = Double(outputIndex * outputFrames) / outputRate
            if min(tapTime, outputTime) >= end { return }
            if tapTime <= outputTime {
                if !stalled { tap(at: tapTime, signal) }
                tapIndex += 1
            } else {
                pull(at: outputTime)
                outputIndex += 1
            }
        }
    }

    private func tap(at time: Double, _ signal: (Int) -> Float) {
        for frame in 0..<tapFrames {
            let value = signal(tapPosition + frame)
            tapBuffer[2 * frame] = value
            tapBuffer[2 * frame + 1] = -value
        }
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 2, mDataByteSize: UInt32(2 * tapFrames * MemoryLayout<Float>.size), mData: tapBuffer))
        engine.renderTap(input: &list, inputTime: stamp(time - Double(tapFrames) / (tapRate * (1 + drift))))
        tapPosition += tapFrames
    }

    private func pull(at time: Double) {
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: UInt32(outputChannels), mDataByteSize: UInt32(outputChannels * outputFrames * MemoryLayout<Float>.size),
            mData: outputBuffer))
        engine.renderOutput(output: &list, outputTime: stamp(time + lead))
        for frame in 0..<outputFrames { output.append(outputBuffer[outputChannels * frame]) }
    }

    /// The tone's frequency in real Hz, from a straight line through its rising zero crossings.
    func frequency(from start: Int) -> Double {
        var crossings: [Double] = []
        for index in max(start, 1)..<output.count where output[index - 1] < 0 && output[index] >= 0 {
            let a = Double(output[index - 1]), b = Double(output[index])
            crossings.append(Double(index - 1) + a / (a - b))
        }
        let n = Double(crossings.count)
        let meanX = (n - 1) / 2
        let meanY = crossings.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for (m, y) in crossings.enumerated() {
            num += (Double(m) - meanX) * (y - meanY)
            den += (Double(m) - meanX) * (Double(m) - meanX)
        }
        return outputRate / (num / den)
    }
}

private func sine(_ frequency: Double, rate: Double, amplitude: Float = 0.25) -> (Int) -> Float {
    { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / rate)) }
}

final class RouteEngineTests: XCTestCase {
    func testA48kTapPlaysOnA44kTargetWithDriftWithoutAGapAtItsRealPitch() {
        for drift in [300e-6, -450e-6] {
            let sim = RouteSim(tapRate: 48000, outputRate: 44100, drift: drift)
            sim.run(seconds: 40, signal: sine(1000, rate: 48000))
            XCTAssertEqual(sim.engine.underruns, 0, "drift \(drift)")
            XCTAssertEqual(sim.engine.overruns, 0, "drift \(drift)")
            XCTAssertEqual(sim.engine.dropouts, 0)
            let settled = 25 * 44100
            XCTAssertEqual(sim.frequency(from: settled), 1000 * (1 + drift), accuracy: 0.005, "the app's tone at the speed its own device plays it")
            XCTAssertEqual(sim.engine.correctionPpm, drift * 1e6, accuracy: 5, "the servo found the drift")
            let quietest = stride(from: 44100, to: sim.output.count - 128, by: 128).map { block in
                sim.output[block..<block + 128].map(abs).max()!
            }.min()!
            XCTAssertGreaterThan(quietest, 0.2, "no block of silence once playing")
        }
    }

    func testUpsamplingAndOneToOneKeepThePitchToo() {
        for (tapRate, outputRate, drift) in [(44100.0, 48000.0, 120e-6), (44100.0, 44100.0, -200e-6)] {
            let sim = RouteSim(tapRate: tapRate, outputRate: outputRate, drift: drift, jitter: 50e-6)
            sim.run(seconds: 30, signal: sine(440, rate: tapRate))
            XCTAssertEqual(sim.engine.underruns + sim.engine.overruns, 0, "\(Int(tapRate))→\(Int(outputRate))")
            XCTAssertEqual(sim.frequency(from: 15 * Int(outputRate)), 440 * (1 + drift), accuracy: 0.005)
        }
    }

    func testTheAddedDelayIsTheCushionAndMatchesAClick() throws {
        let sim = RouteSim(tapRate: 48000, outputRate: 44100)
        sim.run(seconds: 2, signal: { _ in 0 })
        let clickAt = 3 * 48000
        sim.run(seconds: 2) { $0 >= clickAt && $0 < clickAt + 10 ? 0.5 : 0 }
        let added = try XCTUnwrap(sim.engine.addedLatencyMs)
        // The ring holds one output read, the resampler's look-ahead, a tap buffer and 64 frames; the
        // output plays `lead` after its callback. The tap's buffer is stamped at its first frame.
        XCTAssertGreaterThan(added, 5)
        XCTAssertLessThan(added, 15)
        let onset = try XCTUnwrap(sim.engine.lastOnset)
        XCTAssertEqual(onset.count, 1)
        XCTAssertEqual((onset.outputHostSeconds - onset.tapHostSeconds) * 1000, added, accuracy: 0.2)
    }

    func testATapStallUnderrunsOnceAndPlaysAgainOnceRefilled() {
        let sim = RouteSim(tapRate: 48000, outputRate: 48000)
        sim.run(seconds: 1, signal: sine(1000, rate: 48000))
        sim.stalled = true
        sim.run(seconds: 0.5, signal: sine(1000, rate: 48000))
        XCTAssertEqual(sim.engine.underruns, 1)
        XCTAssertTrue(sim.output.suffix(4800).allSatisfy { $0 == 0 })
        sim.stalled = false
        sim.run(seconds: 1, signal: sine(1000, rate: 48000))
        XCTAssertEqual(sim.engine.underruns, 1)
        XCTAssertGreaterThan(sim.output.suffix(4800).map(abs).max()!, 0.2)
    }

    func testAMonoTargetGetsTheAverageOfTheTapsChannels() {
        let sim = RouteSim(tapRate: 48000, outputRate: 48000, outputChannels: 1)
        sim.run(seconds: 1) { _ in 0.25 }
        XCTAssertEqual(sim.output.last!, 0, accuracy: 1e-6, "left 0.25 and right -0.25")
    }

    func testStopClearsTheCounters() {
        let sim = RouteSim(tapRate: 48000, outputRate: 44100)
        sim.run(seconds: 0.5, signal: sine(1000, rate: 48000))
        XCTAssertGreaterThan(sim.engine.callbacks, 0)
        sim.engine.stop()
        XCTAssertEqual(sim.engine.callbacks, 0)
        XCTAssertEqual(sim.engine.tapCallbacks, 0)
        XCTAssertNil(sim.engine.lastOnset)
        XCTAssertEqual(sim.engine.correctionPpm, 0)
    }
}

final class DriftServoTests: XCTestCase {
    /// Hours of the servo against a clock pair, on positions alone: the tap produces at its real rate,
    /// the output consumes nominal × (1 + correction), and the delay is what sits between them.
    private func soak(drift: Double, hours: Double, jitter: Double) -> (worst: Double, correction: Double) {
        var servo = DriftServo()
        servo.restart()
        let interval = 128.0 / 44100
        var delay = 0.008
        var worst = 0.0
        var noise: UInt64 = 0x9E3779B97F4A7C15
        let cycles = Int(hours * 3600 / interval)
        for cycle in 0..<cycles {
            noise ^= noise << 13; noise ^= noise >> 7; noise ^= noise << 17
            let measured = delay + (Double(noise % 2001) / 1000 - 1) * jitter
            let correction = servo.update(delay: measured, interval: interval)
            delay += (drift - correction) * interval
            if cycle > 100, let setpoint = servo.setpoint { worst = max(worst, abs(delay - setpoint)) }
        }
        return (worst, servo.correction)
    }

    func testFourHoursAtTheLimitsNeverLeaveTheCushion() {
        for drift in [500e-6, -500e-6, 137e-6] {
            let result = soak(drift: drift, hours: 4, jitter: 50e-6)
            XCTAssertLessThan(result.worst, 0.0015, "drift \(drift): the ring's cushion is several ms")
            XCTAssertEqual(result.correction, drift, accuracy: 2e-6)
        }
    }

    func testJitterBarelyMovesThePitch() {
        var servo = DriftServo()
        servo.restart()
        let interval = 128.0 / 44100
        var delay = 0.008
        var noise: UInt64 = 1
        var extreme = 0.0
        for cycle in 0..<100_000 {
            noise = noise &* 6364136223846793005 &+ 1442695040888963407
            let correction = servo.update(delay: delay + (Double((noise >> 33) % 2001) / 1000 - 1) * 50e-6, interval: interval)
            delay -= correction * interval
            if cycle > 10_000 { extreme = max(extreme, abs(correction)) }
        }
        XCTAssertLessThan(extreme, 5e-6, "50 µs of jitter on every stamp")
    }

    func testARestartKeepsTheDriftItLearned() {
        var servo = DriftServo()
        servo.restart()
        var delay = 0.008
        for _ in 0..<200_000 {
            delay += (200e-6 - servo.update(delay: delay, interval: 0.003)) * 0.003
        }
        XCTAssertEqual(servo.correction, 200e-6, accuracy: 2e-6)
        servo.restart()
        XCTAssertNil(servo.setpoint)
        XCTAssertEqual(servo.correction, 200e-6, accuracy: 2e-6)
    }

    func testNonsenseIsIgnored() {
        var servo = DriftServo()
        servo.restart()
        XCTAssertEqual(servo.update(delay: .nan, interval: 0.003), 0)
        XCTAssertEqual(servo.update(delay: 0.01, interval: 0), 0)
        XCTAssertNil(servo.setpoint)
    }
}
