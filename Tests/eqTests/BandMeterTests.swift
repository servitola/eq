import XCTest
@testable import eq

final class BandMeterTests: XCTestCase {
    private let rate = 48000.0
    private let frames = 4096
    private var left: UnsafeMutablePointer<Float>!
    private var right: UnsafeMutablePointer<Float>!
    private var phase = 0

    override func setUp() {
        left = .allocate(capacity: frames)
        right = .allocate(capacity: frames)
    }

    override func tearDown() {
        left.deallocate()
        right.deallocate()
    }

    private func makeProcessor(metering: Bool) -> EQProcessor {
        let processor = EQProcessor()
        processor.configure(sampleRate: rate)
        processor.apply(profile: .flat, enabled: true)
        processor.meteringEnabled = metering
        return processor
    }

    private func feedSine(_ processor: EQProcessor) {
        for i in 0..<frames {
            left[i] = 0.5 * Float(sin(2 * Double.pi * 1000 * Double(phase + i) / rate))
            right[i] = left[i]
        }
        phase += frames
        processor.process(channels: [left, right], frameCount: frames)
    }

    private func feedSilence(_ processor: EQProcessor) {
        left.update(repeating: 0, count: frames)
        right.update(repeating: 0, count: frames)
        processor.process(channels: [left, right], frameCount: frames)
    }

    func testSineLandsInItsBand() {
        let processor = makeProcessor(metering: true)
        feedSine(processor)
        feedSine(processor)
        let output = processor.meter.outputDB
        let input = processor.meter.inputDB
        XCTAssertEqual(output[5], -6, accuracy: 1.5)
        XCTAssertEqual(input[5], -6, accuracy: 1.5)
        XCTAssertEqual(processor.meter.peakDB, -6, accuracy: 1.5)
        XCTAssertFalse(processor.limiting)
        // Q 1.41 band-pass is ~7 dB down one octave off-centre and ~15 dB down two octaves off,
        // so only bands three or more octaves away are held to the -21 dB floor.
        XCTAssertLessThanOrEqual(output[4], -12)
        XCTAssertLessThanOrEqual(output[6], -12)
        XCTAssertLessThanOrEqual(output[3], -18)
        XCTAssertLessThanOrEqual(output[7], -18)
        for band in output.indices where abs(band - 5) >= 3 {
            XCTAssertLessThanOrEqual(output[band], -21, "band \(band)")
        }
    }

    func testReleaseFalls() {
        let processor = makeProcessor(metering: true)
        feedSine(processor)
        feedSine(processor)
        let loud = processor.meter.outputDB[5]
        for _ in 0..<Int(0.5 * rate) / frames + 1 { feedSilence(processor) }
        XCTAssertLessThanOrEqual(processor.meter.outputDB[5], loud - 10)
    }

    func testDisabledMeterCostsNothing() {
        let processor = makeProcessor(metering: false)
        feedSine(processor)
        feedSine(processor)
        XCTAssertEqual(processor.meter.outputDB, Array(repeating: -60, count: 10))
        XCTAssertEqual(processor.meter.inputDB, Array(repeating: -60, count: 10))
        XCTAssertEqual(processor.meter.peakDB, -60)
    }

    func testInputIsMeasuredBeforeTheChain() {
        let processor = EQProcessor()
        processor.configure(sampleRate: rate)
        processor.apply(profile: Profile(name: nil, preamp: -12, bands: Profile.flat.bands), enabled: true)
        processor.meteringEnabled = true
        feedSine(processor)
        feedSine(processor)
        XCTAssertEqual(processor.meter.inputDB[5], -6, accuracy: 1.5)
        XCTAssertEqual(processor.meter.outputDB[5], -18, accuracy: 1.5)
    }

    func testLimitingFlagWhileHot() {
        var bands = Profile.flat.bands
        bands[5] = 12
        let processor = EQProcessor()
        processor.configure(sampleRate: rate)
        processor.apply(profile: Profile(name: nil, preamp: 0, bands: bands), enabled: true)
        for i in 0..<frames {
            left[i] = 0.9 * Float(sin(2 * Double.pi * 1000 * Double(i) / rate))
            right[i] = left[i]
        }
        processor.process(channels: [left, right], frameCount: frames)
        XCTAssertTrue(processor.limiting)

        // One 4096-frame buffer (85 ms) is less than the 80 ms release time constant needs to
        // unwind a 12 dB overshoot; loop a few buffers of zeros to give the envelope room to fall
        // below the ceiling, same pattern as testReleaseFalls below. `process` mutates its buffers
        // in place, so each iteration must re-zero them — otherwise it feeds the previous filter
        // ring-down back in as new input instead of silence.
        for _ in 0..<3 {
            left.update(repeating: 0, count: frames)
            right.update(repeating: 0, count: frames)
            processor.process(channels: [left, right], frameCount: frames)
        }
        XCTAssertFalse(processor.limiting)
    }

    func testNaNSampleDoesNotStick() {
        let meter = BandMeter(frequencies: Config.bandFrequencies)
        meter.configure(sampleRate: rate)

        left[0] = Float.nan
        for i in 1..<frames { left[i] = 0 }
        meter.feed(input: [left], output: [left], frameCount: frames)
        XCTAssertTrue(meter.outputDB.allSatisfy { $0.isFinite }, "\(meter.outputDB)")
        XCTAssertTrue(meter.inputDB.allSatisfy { $0.isFinite }, "\(meter.inputDB)")
        XCTAssertTrue(meter.peakDB.isFinite)

        for i in 0..<frames {
            left[i] = 0.5 * Float(sin(2 * Double.pi * 1000 * Double(i) / rate))
        }
        meter.feed(input: [left], output: [left], frameCount: frames)
        meter.feed(input: [left], output: [left], frameCount: frames)
        XCTAssertEqual(meter.outputDB[5], -6, accuracy: 1.5)
    }

    func testMeterSkipsOversizedCallbacks() {
        let processor = makeProcessor(metering: true)
        let oversized = 5000
        let bigLeft = UnsafeMutablePointer<Float>.allocate(capacity: oversized)
        let bigRight = UnsafeMutablePointer<Float>.allocate(capacity: oversized)
        defer {
            bigLeft.deallocate()
            bigRight.deallocate()
        }
        for i in 0..<oversized {
            bigLeft[i] = 0.5 * Float(sin(2 * Double.pi * 1000 * Double(i) / rate))
            bigRight[i] = bigLeft[i]
        }
        processor.process(channels: [bigLeft, bigRight], frameCount: oversized)
        XCTAssertEqual(processor.meter.outputDB[5], -60)
    }
}
