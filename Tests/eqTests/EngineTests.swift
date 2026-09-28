import XCTest
import CoreAudio
@testable import eq

final class EngineTests: XCTestCase {
    private func asbd(rate: Double = 48000, channels: UInt32 = 2) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    }

    func testTapFormatTakesAnyFloatChannelCountTheAggregateCarries() {
        XCTAssertEqual(TapFormat.channels(tap: asbd(), deviceRate: 48000, aggregateRate: 48000, aggregateInputChannels: [2]), 2)
        XCTAssertEqual(TapFormat.channels(tap: asbd(rate: 16000, channels: 1), deviceRate: 16000, aggregateRate: 16000,
                                          aggregateInputChannels: [1]), 1)
        XCTAssertEqual(TapFormat.channels(tap: asbd(channels: 8), deviceRate: 48000, aggregateRate: 48000, aggregateInputChannels: [8]), 8)
    }

    func testTapFormatRefusesWhatTheRingCannotCarry() {
        var integer = asbd()
        integer.mFormatFlags = kAudioFormatFlagIsSignedInteger
        XCTAssertNil(TapFormat.channels(tap: integer, deviceRate: 48000, aggregateRate: 48000, aggregateInputChannels: [2]))
        XCTAssertNil(TapFormat.channels(tap: asbd(), deviceRate: 44100, aggregateRate: 44100, aggregateInputChannels: [2]),
                     "a tap still at the old rate after a device switch")
        XCTAssertNil(TapFormat.channels(tap: asbd(), deviceRate: 48000, aggregateRate: 44100, aggregateInputChannels: [2]))
        XCTAssertNil(TapFormat.channels(tap: asbd(), deviceRate: 48000, aggregateRate: 48000, aggregateInputChannels: [2, 2]),
                     "anything in the aggregate besides the tap")
        XCTAssertNil(TapFormat.channels(tap: asbd(channels: 32), deviceRate: 48000, aggregateRate: 48000, aggregateInputChannels: [32]))
        XCTAssertNil(TapFormat.channels(tap: asbd(), deviceRate: 0, aggregateRate: 0, aggregateInputChannels: [2]))
    }

    func testPeakFilterAtZeroGainIsUnity() {
        let c = BiquadCoefficients.make(type: .peak, frequency: 1000, gainDB: 0, q: 1.41, sampleRate: 48000)
        XCTAssertEqual(c.magnitudeDB(at: 1000, sampleRate: 48000), 0, accuracy: 1e-4)
        XCTAssertEqual(c.magnitudeDB(at: 100, sampleRate: 48000), 0, accuracy: 1e-4)
    }

    func testPeakFilterGainIsSymmetricAtCentre() {
        let boost = BiquadCoefficients.make(type: .peak, frequency: 1000, gainDB: 6, q: 1.41, sampleRate: 48000)
        let cut = BiquadCoefficients.make(type: .peak, frequency: 1000, gainDB: -6, q: 1.41, sampleRate: 48000)
        XCTAssertEqual(boost.magnitudeDB(at: 1000, sampleRate: 48000), 6, accuracy: 0.01)
        XCTAssertEqual(cut.magnitudeDB(at: 1000, sampleRate: 48000), -6, accuracy: 0.01)
    }

    func testFlatProfilePassesAudioThroughUnchanged() {
        let processor = EQProcessor()
        processor.configure(sampleRate: 48000)
        processor.apply(profile: .flat, enabled: true)
        let frames = 256
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { left.deallocate(); right.deallocate() }
        for i in 0..<frames {
            left[i] = 0.25 * sin(Float(i) * 0.1)
            right[i] = left[i]
        }
        let expected = Array(UnsafeBufferPointer(start: left, count: frames))
        processor.process(channels: [left, right], frameCount: frames)
        for i in 0..<frames {
            XCTAssertEqual(left[i], expected[i], accuracy: 1e-5)
            XCTAssertEqual(right[i], expected[i], accuracy: 1e-5)
        }
    }

    private func sine(amplitude: Float, frames: Int) -> [Float] {
        (0..<frames).map { amplitude * sin(2 * .pi * 1000 * Float($0) / 48000) }
    }

    /// Runs a stereo 1 kHz sine through a fresh processor and returns the processed left channel.
    private func processTone(amplitude: Float, oneKilohertzGain: Double, frames: Int = 4096) -> [Float] {
        let processor = EQProcessor()
        processor.configure(sampleRate: 48000)
        var bands = Array(repeating: 0.0, count: Config.bandFrequencies.count)
        bands[5] = oneKilohertzGain
        processor.apply(profile: Profile(name: nil, preamp: 0, bands: bands), enabled: true)
        let input = sine(amplitude: amplitude, frames: frames)
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { left.deallocate(); right.deallocate() }
        left.initialize(from: input, count: frames)
        right.initialize(from: input, count: frames)
        processor.process(channels: [left, right], frameCount: frames)
        return Array(UnsafeBufferPointer(start: left, count: frames))
    }

    private func rmsDB(_ samples: ArraySlice<Float>) -> Double {
        let meanSquare = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        return 10 * log10(meanSquare)
    }

    func testBoostedBandRaisesLevelAndLimiterHolds() {
        let reference = 20 * log10(0.25 / 2.0.squareRoot())
        let boosted = processTone(amplitude: 0.25, oneKilohertzGain: 6)
        XCTAssertEqual(rmsDB(boosted.suffix(2048)) - reference, 6, accuracy: 0.5)
        let cut = processTone(amplitude: 0.25, oneKilohertzGain: -6)
        XCTAssertEqual(rmsDB(cut.suffix(2048)) - reference, -6, accuracy: 0.5)
        let limited = processTone(amplitude: 0.9, oneKilohertzGain: 12)
        // Ceiling is -1 dBFS ≈ 0.891; instant attack makes the bound hold from the first sample,
        // including the onset right after start, not just once the envelope has settled.
        XCTAssertLessThanOrEqual(limited.map(abs).max() ?? .infinity, 0.90)
    }

    func testDisabledProfileBypasses() {
        let processor = EQProcessor()
        processor.configure(sampleRate: 48000)
        processor.apply(profile: Profile(name: nil, preamp: -12, bands: Array(repeating: -12, count: 10)), enabled: false)
        let frames = 64
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { buffer.deallocate() }
        for i in 0..<frames { buffer[i] = 0.5 }
        processor.process(channels: [buffer], frameCount: frames)
        XCTAssertEqual(buffer[10], 0.5, accuracy: 1e-6)
    }

    func testFilterCountChangeTakesEffectOnNextCycle() {
        let processor = EQProcessor()
        processor.configure(sampleRate: 48000)
        let frames = 4096
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { left.deallocate(); right.deallocate() }
        let input = sine(amplitude: 0.25, frames: frames)
        processor.apply(profile: .flat, enabled: true)
        left.initialize(from: input, count: frames)
        right.initialize(from: input, count: frames)
        processor.process(channels: [left, right], frameCount: frames)

        var cut = Profile.flat
        cut.filters = [Filter(type: .peak, frequency: 1000, gain: -6, q: 1), Filter(type: .peak, frequency: 50, gain: 0, q: 1)]
        processor.apply(profile: cut, enabled: true)
        left.update(from: input, count: frames)
        right.update(from: input, count: frames)
        processor.process(channels: [left, right], frameCount: frames)
        let reference = 20 * log10(0.25 / 2.0.squareRoot())
        XCTAssertEqual(rmsDB(Array(UnsafeBufferPointer(start: left, count: frames)).suffix(2048)) - reference, -6, accuracy: 0.5)
        XCTAssertEqual(rmsDB(Array(UnsafeBufferPointer(start: right, count: frames)).suffix(2048)) - reference, -6, accuracy: 0.5)
    }

    func testLowShelfFilterLowersBass() {
        let coefficients = Profile(name: nil, preamp: 0, bands: Profile.flat.bands,
                                   filters: [Filter(type: .lowShelf, frequency: 105, gain: -4.2, q: 0.7)])
            .engineBands
            .map { BiquadCoefficients.make(type: $0.type, frequency: $0.frequency, gainDB: $0.gain, q: $0.q, sampleRate: 48000) }
        let at50 = coefficients.reduce(0.0) { $0 + $1.magnitudeDB(at: 50, sampleRate: 48000) }
        let at5k = coefficients.reduce(0.0) { $0 + $1.magnitudeDB(at: 5000, sampleRate: 48000) }
        XCTAssertEqual(at50, -4.2, accuracy: 0.3)
        XCTAssertEqual(at5k, 0, accuracy: 0.1)
    }

    func testTransportNames() {
        XCTAssertEqual(AudioOutputDevice(id: 1, uid: "u", name: "n", transportType: kAudioDeviceTransportTypeBluetooth).transportName, "bluetooth")
        XCTAssertEqual(AudioOutputDevice(id: 1, uid: "u", name: "n", transportType: kAudioDeviceTransportTypeBuiltIn).transportName, "builtin")
        XCTAssertEqual(AudioOutputDevice(id: 1, uid: "u", name: "n", transportType: 0).transportName, "other")
    }
}

final class PathLatencyTests: XCTestCase {
    private let latency = PathLatency(outputDevice: 40 + 24, outputStream: 16, outputBuffer: 128, tapInput: 30, ringTarget: 320)

    func testSumsAllStagesAtTheNominalRate() throws {
        XCTAssertEqual(try XCTUnwrap(latency.milliseconds(sampleRate: 48000)), 558.0 / 48, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(latency.milliseconds(sampleRate: 44100)), 558.0 / 44.1, accuracy: 1e-9)
    }

    func testDeviceShareIsWhatAPlayerSees() throws {
        XCTAssertEqual(try XCTUnwrap(latency.deviceMilliseconds(sampleRate: 48000)), 80.0 / 48, accuracy: 1e-9)
    }

    func testAddedShareIsTapHoldRingAndOutputBuffer() throws {
        XCTAssertEqual(try XCTUnwrap(latency.addedMilliseconds(sampleRate: 48000)), 478.0 / 48, accuracy: 1e-9)
    }

    func testNoRateNoNumber() {
        XCTAssertNil(latency.milliseconds(sampleRate: 0))
        XCTAssertNil(latency.deviceMilliseconds(sampleRate: 0))
        XCTAssertNil(latency.addedMilliseconds(sampleRate: 0))
    }
}

final class IODelayTests: XCTestCase {
    /// Apple silicon's timebase: 125/3 ns per tick, so 500 ticks per frame at 48 kHz.
    private let appleSilicon: (UInt64) -> UInt64 = { $0 * 125 / 3 }

    func testCarriesTheTapStampForwardToTheFrameThatLeaves() throws {
        // The tap stamped position 1000 at tick 1_000_000; position 800 left at tick 1_300_000.
        let delay = try XCTUnwrap(IODelay.between(tapPosition: 1000, tapHost: 1_000_000, outputPosition: 800,
                                                  outputHost: 1_300_000, ticksPerFrame: 500))
        XCTAssertEqual(delay, IODelay(hostTicks: 400_000, frames: 800))
        XCTAssertEqual(delay.milliseconds(nanos: appleSilicon), 16.666, accuracy: 0.001)
    }

    func testNoStampOrBackwardsTimeMeasuresNothing() {
        XCTAssertNil(IODelay.between(tapPosition: 0, tapHost: 0, outputPosition: 0, outputHost: 9, ticksPerFrame: 500))
        XCTAssertNil(IODelay.between(tapPosition: 0, tapHost: 9, outputPosition: 0, outputHost: 0, ticksPerFrame: 500))
        XCTAssertNil(IODelay.between(tapPosition: 0, tapHost: 9, outputPosition: 0, outputHost: 9, ticksPerFrame: 500))
        XCTAssertNil(IODelay.between(tapPosition: 0, tapHost: 1, outputPosition: 0, outputHost: 9, ticksPerFrame: 0))
    }

    func testRealClockRoundTrips() {
        let ticks = AudioConvertNanosToHostTime(10_000_000)
        XCTAssertEqual(IODelay(hostTicks: ticks, frames: 0).milliseconds(), 10, accuracy: 0.001)
    }

    func testOnsetSecondsAddTheFrameOffset() {
        XCTAssertEqual(IODelay.seconds(host: 24_000_000, frame: 441, sampleRate: 44100, nanos: appleSilicon), 1.01, accuracy: 1e-12)
        XCTAssertEqual(IODelay.seconds(host: 24_000_000, frame: 441, sampleRate: 0, nanos: appleSilicon), 1.0, accuracy: 1e-12)
    }
}
