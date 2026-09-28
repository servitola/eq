import XCTest
import CoreAudio
@testable import eq

/// Drives the engine's two render functions the way the two IO threads do, without Core Audio:
/// one tap buffer, then one output buffer, per cycle, on a clock of 500 host ticks per frame.
final class TapPathTests: XCTestCase {
    private static let rate = 48000.0
    private static let frames = 128
    private static let largest = 8192
    private let ticksPerFrame = Double(AudioConvertNanosToHostTime(1_000_000_000)) / TapPathTests.rate

    private var engine: ProcessTapEngine!
    private var tapBuffer: UnsafeMutablePointer<Float>!
    private var outBuffer: UnsafeMutablePointer<Float>!
    private var tapPosition = 0

    override func setUp() {
        engine = ProcessTapEngine()
        engine.processor.configure(sampleRate: Self.rate, channels: 2)
        engine.processor.apply(profile: .flat, enabled: true)
        engine.prepare(channels: 2, tapFrames: Self.frames, outputFrames: Self.frames)
        tapBuffer = .allocate(capacity: 2 * Self.largest)
        outBuffer = .allocate(capacity: 2 * Self.largest)
        tapPosition = 0
    }

    override func tearDown() {
        tapBuffer.deallocate()
        outBuffer.deallocate()
        engine = nil
    }

    private func stamp(frame: Int) -> AudioTimeStamp {
        var t = AudioTimeStamp()
        t.mHostTime = UInt64(1_000_000_000 + Double(frame) * ticksPerFrame)
        t.mSampleTime = Double(frame)
        t.mFlags = [.hostTimeValid, .sampleTimeValid]
        return t
    }

    /// One tap buffer whose left sample is `signal(position)` and right its negation.
    private func tap(frames: Int = TapPathTests.frames, channels: Int = 2, _ signal: (Int) -> Float) {
        for f in 0..<frames {
            for c in 0..<channels { tapBuffer[channels * f + c] = c % 2 == 0 ? signal(tapPosition + f) : -signal(tapPosition + f) }
        }
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: UInt32(channels), mDataByteSize: UInt32(channels * frames * MemoryLayout<Float>.size), mData: tapBuffer))
        engine.renderTap(input: &list, inputTime: stamp(frame: tapPosition))
        tapPosition += frames
    }

    /// One output buffer, handed to the device `lead` frames after the tap's latest buffer began.
    @discardableResult
    private func output(frames: Int = TapPathTests.frames, lead: Int = 500) -> [Float] {
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 2, mDataByteSize: UInt32(2 * frames * MemoryLayout<Float>.size), mData: outBuffer))
        engine.renderOutput(output: &list, outputTime: stamp(frame: tapPosition - Self.frames + lead))
        return (0..<frames).map { outBuffer[2 * $0] }
    }

    private func level(_ position: Int) -> Float { 0.25 * sin(Float(position) * 0.05) }

    func testAudioCrossesTheRingUnchangedOneTargetLater() {
        var outputs: [Float] = []
        for _ in 0..<40 {
            tap(level)
            outputs += output()
        }
        let target = RingPacer.forBuffers(output: Self.frames, tap: Self.frames).target
        // The ring primes on the cycle its fill first reaches the target, then reads from there on.
        let primedCycle = (target + Self.frames - 1) / Self.frames - 1
        let firstPosition = (primedCycle + 1) * Self.frames - target
        for (index, sample) in outputs.enumerated().dropFirst(primedCycle * Self.frames) {
            let position = firstPosition + index - primedCycle * Self.frames
            XCTAssertEqual(sample, level(position), accuracy: 1e-5, "output frame \(index)")
        }
        XCTAssertEqual(engine.underruns, 0)
        XCTAssertEqual(engine.overruns, 0)
        XCTAssertEqual(engine.callbacks, 40)
        XCTAssertEqual(engine.tapCallbacks, 40)
        XCTAssertEqual(engine.signalCallbacks, 40)
    }

    func testAddedLatencyIsTheRingCushionPlusTheOutputLead() throws {
        for _ in 0..<10 {
            tap(level)
            output(lead: 500)
        }
        // Each read starts `target` frames behind the newest written frame, whose buffer began
        // `frames` earlier; the output leaves `lead` frames after that buffer began.
        let target = RingPacer.forBuffers(output: Self.frames, tap: Self.frames).target
        let added = try XCTUnwrap(engine.addedLatency)
        XCTAssertEqual(added.frames, Double(target - Self.frames + 500), accuracy: 0.01)
    }

    func testTapStallUnderrunsOnceAndPlaysSilenceUntilRefilled() {
        for _ in 0..<10 {
            tap(level)
            output()
        }
        var silent: [Float] = []
        for _ in 0..<4 { silent += output() }
        XCTAssertEqual(engine.underruns, 1)
        XCTAssertTrue(silent.suffix(2 * Self.frames).allSatisfy { $0 == 0 })
        for _ in 0..<6 {
            tap(level)
            output()
        }
        XCTAssertEqual(engine.underruns, 1)
        XCTAssertNotEqual(output().filter { $0 != 0 }.count, 0)
    }

    func testBacklogAfterAStallSnapsBack() {
        for _ in 0..<10 {
            tap(level)
            output()
        }
        for _ in 0..<12 { tap(level) }
        output()
        XCTAssertEqual(engine.overruns, 1)
        tap(level)
        output()
        XCTAssertEqual(engine.overruns, 1)
    }

    func testOnsetIsStampedByTheTapAndByTheOutput() throws {
        let clickAt = 8000
        let click: (Int) -> Float = { $0 >= clickAt && $0 < clickAt + 10 ? 0.5 : 0 }
        for _ in 0..<80 {
            tap(click)
            output(lead: 500)
        }
        let onset = try XCTUnwrap(engine.lastOnset)
        XCTAssertEqual(onset.count, 1)
        let tapSeconds = Double(AudioConvertHostTimeToNanos(1_000_000_000)) / 1e9 + Double(clickAt) / Self.rate
        XCTAssertEqual(onset.tapHostSeconds, tapSeconds, accuracy: 1e-6)
        let target = RingPacer.forBuffers(output: Self.frames, tap: Self.frames).target
        XCTAssertEqual((onset.outputHostSeconds - onset.tapHostSeconds) * Self.rate,
                       Double(target - Self.frames + 500), accuracy: 0.05)
    }

    func testLongSilenceGatesTheOutput() {
        for _ in 0..<(Int(Self.rate) / Self.frames + 20) {
            tap { _ in 0 }
            output()
        }
        let processed = engine.framesProcessed
        tap { _ in 0 }
        output()
        XCTAssertEqual(engine.framesProcessed, processed, "silence past one second skips the EQ")
        XCTAssertEqual(engine.signalCallbacks, 0)
    }

    /// Buffers the HAL grows after `prepare` sized the ring for 128 frames on both sides.
    func testOutputBufferGrowingMidRunKeepsTheRingFed() {
        for _ in 0..<40 {
            for _ in 0..<8 { tap(level) }
            output(frames: 1024)
        }
        XCTAssertLessThanOrEqual(engine.underruns, 1)
        XCTAssertEqual(engine.overruns, 0)
    }

    func testTapBufferGrowingMidRunKeepsTheRingFed() {
        for _ in 0..<40 {
            tap(frames: 1024, level)
            for _ in 0..<8 { output() }
        }
        XCTAssertLessThanOrEqual(engine.underruns, 1)
        XCTAssertEqual(engine.overruns, 0)
    }

    func testTapBuffersTheRingCannotTakeCountAsDropouts() {
        tap(level)
        XCTAssertEqual(engine.dropouts, 0)
        tap(channels: 1, level)
        XCTAssertEqual(engine.dropouts, 1, "fewer channels than prepared")
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 1024, mData: nil))
        engine.renderTap(input: &list, inputTime: stamp(frame: tapPosition))
        XCTAssertEqual(engine.dropouts, 2, "no data")
        XCTAssertEqual(engine.tapCallbacks, 3)
    }

    func testOutputBufferPastTheScratchIsSilentAndCountsAsADropout() {
        for _ in 0..<10 {
            tap(level)
            output()
        }
        outBuffer.update(repeating: 1, count: 2 * Self.largest)
        let played = output(frames: Self.largest)
        XCTAssertTrue(played.allSatisfy { $0 == 0 })
        XCTAssertEqual(engine.dropouts, 1)
        XCTAssertEqual(engine.underruns, 0)
    }

    func testStopClearsTheCounters() {
        tap(level)
        output()
        tap(channels: 1, level)
        engine.stop()
        XCTAssertEqual(engine.callbacks, 0)
        XCTAssertEqual(engine.tapCallbacks, 0)
        XCTAssertEqual(engine.underruns, 0)
        XCTAssertEqual(engine.dropouts, 0)
        XCTAssertNil(engine.addedLatency)
    }
}
