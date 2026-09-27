import XCTest
@testable import eq

final class SoloTests: XCTestCase {
    private static let rate = 48000.0
    private static let length = 16384

    private func processor(enabled: Bool = true) -> EQProcessor {
        let p = EQProcessor()
        p.configure(sampleRate: Self.rate)
        p.apply(profile: .flat, enabled: enabled)
        return p
    }

    // 2^-10 keeps the limiter out of the measurement.
    private func impulseResponse(_ p: EQProcessor) -> [Float] {
        let left = UnsafeMutablePointer<Float>.allocate(capacity: Self.length)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: Self.length)
        defer { left.deallocate(); right.deallocate() }
        left.initialize(repeating: 0, count: Self.length)
        right.initialize(repeating: 0, count: Self.length)
        left[0] = 1.0 / 1024
        right[0] = 1.0 / 1024
        p.process(channels: [left, right], frameCount: Self.length)
        return Array(UnsafeBufferPointer(start: left, count: Self.length))
    }

    private func gainDB(_ response: [Float], at frequency: Double) -> Double {
        var re = 0.0, im = 0.0
        for (n, x) in response.enumerated() {
            let w = 2 * Double.pi * frequency * Double(n) / Self.rate
            re += Double(x) * cos(w)
            im -= Double(x) * sin(w)
        }
        return 20 * log10((re * re + im * im).squareRoot() * 1024)
    }

    func testSoloPassesTheRangeAndCutsOutside() {
        let p = processor()
        XCTAssertTrue(p.setSolo(low: 300, high: 2800))
        let response = impulseResponse(p)
        XCTAssertEqual(gainDB(response, at: 1000), 0, accuracy: 1)
        XCTAssertLessThanOrEqual(gainDB(response, at: 100), -20)
        XCTAssertLessThanOrEqual(gainDB(response, at: 8000), -20)
    }

    func testClearingRestoresTheCurve() {
        let p = processor()
        p.setSolo(low: 300, high: 2800)
        p.clearSolo()
        XCTAssertNil(p.solo)
        let response = impulseResponse(p)
        XCTAssertEqual(gainDB(response, at: 100), 0, accuracy: 0.1)
        XCTAssertEqual(gainDB(response, at: 8000), 0, accuracy: 0.1)
    }

    func testSoloSurvivesAProfileReapply() {
        let p = processor()
        p.setSolo(low: 300, high: 2800)
        p.apply(profile: .flat, enabled: true)
        XCTAssertLessThanOrEqual(gainDB(impulseResponse(p), at: 100), -20)
    }

    func testSoloStillIsolatesWithTheEQOff() {
        let p = processor(enabled: false)
        p.setSolo(low: 300, high: 2800)
        let response = impulseResponse(p)
        XCTAssertEqual(gainDB(response, at: 1000), 0, accuracy: 1)
        XCTAssertLessThanOrEqual(gainDB(response, at: 8000), -20)
    }

    func testSoloDoesNotShiftUnstableBandIndices() {
        let p = processor()
        p.setSolo(low: 300, high: 2800)
        let unstable = p.update(bands: [EQBand(type: .peak, frequency: 1000, gain: 0, q: 1)], preampDB: 0,
                                limiterEnabled: true, limiterCeilingDB: -1, bypassed: false)
        XCTAssertEqual(unstable, [])
    }

    func testClamping() {
        XCTAssertEqual(EQProcessor.clampSolo(low: 5, high: 30000, sampleRate: 48000), SoloRange(low: 20, high: 21600))
        XCTAssertNil(EQProcessor.clampSolo(low: 2800, high: 300, sampleRate: 48000))
        XCTAssertNil(EQProcessor.clampSolo(low: 22000, high: 30000, sampleRate: 48000))
        XCTAssertNil(EQProcessor.clampSolo(low: .nan, high: 1000, sampleRate: 48000))
    }

    func testRejectedRangeKeepsThePreviousSolo() {
        let p = processor()
        p.setSolo(low: 300, high: 2800)
        XCTAssertFalse(p.setSolo(low: 5000, high: 100))
        XCTAssertEqual(p.solo, SoloRange(low: 300, high: 2800))
    }

    func testEffectiveSoloFollowsTheRate() {
        let p = processor()
        p.setSolo(low: 300, high: 30000)
        XCTAssertEqual(p.effectiveSolo, SoloRange(low: 300, high: 21600))
        p.configure(sampleRate: 44100)
        XCTAssertEqual(p.effectiveSolo, SoloRange(low: 300, high: 19845))
    }

    func testEngineStopClearsSolo() {
        let engine = ProcessTapEngine()
        engine.processor.setSolo(low: 300, high: 2800)
        engine.stop()
        XCTAssertNil(engine.processor.solo)
    }
}
