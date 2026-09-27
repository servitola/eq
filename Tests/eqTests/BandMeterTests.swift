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
}
