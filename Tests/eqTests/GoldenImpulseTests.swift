import XCTest
@testable import eq

/// Pins the rendered impulse response of the real `EQProcessor.process`, so a change to the
/// state update, the coefficient narrowing or the chain order shows up as numbers, not as a
/// closed-form magnitude that never touches the render path.
///
/// The impulse is 2^-10, not 1: small enough that the limiter never engages, and a power of two,
/// so dividing it back out is exact and the fixture is the response to a unit impulse.
/// `EQ_WRITE_GOLDEN=1 swift test --filter GoldenImpulseTests` regenerates the fixtures from the
/// current code; do that only for an intended change to the sound.
final class GoldenImpulseTests: XCTestCase {
    private static let impulse: Float = 1.0 / 1024
    private static let length = 64
    private static let rate = 48000.0

    private struct Golden: Codable, Equatable {
        var note: String
        var sampleRate: Double
        var samples: [Double]
    }

    func testPeakAtOneKilohertz() throws {
        let processor = EQProcessor()
        processor.configure(sampleRate: Self.rate)
        processor.update(bands: [EQBand(type: .peak, frequency: 1000, gain: 6, q: 1.41)], preampDB: 0,
                         limiterEnabled: true, limiterCeilingDB: -1, bypassed: false)
        try check(processor, fixture: "golden-peak1k",
                  note: "left channel, first 64 samples, unit impulse, one peak +6 dB at 1 kHz Q 1.41")
    }

    func testFullCurve() throws {
        let processor = EQProcessor()
        processor.configure(sampleRate: Self.rate)
        processor.apply(profile: Self.fullProfile, enabled: true)
        try check(processor, fixture: "golden-full",
                  note: "left channel, first 64 samples, unit impulse, screenshot curve + 22 filters, preamp -6.1 dB")
    }

    // Ten bands plus 22 filters fill the 32-biquad cap and cover every filter type.
    private static let fullProfile = Profile(name: nil, preamp: -6.1, bands: Config.screenshotCurve, filters: [
        Filter(type: .lowShelf, frequency: 105, gain: -4.2, q: 0.7),
        Filter(type: .peak, frequency: 143, gain: -5.2, q: 1.1),
        Filter(type: .peak, frequency: 2289, gain: 6.1, q: 1.57),
        Filter(type: .peak, frequency: 56, gain: 1.2, q: 1.19),
        Filter(type: .peak, frequency: 5144, gain: -3.2, q: 6),
        Filter(type: .highShelf, frequency: 10000, gain: -1, q: 0.7),
        Filter(type: .peak, frequency: 407, gain: 1.7, q: 3.14),
        Filter(type: .peak, frequency: 6715, gain: 3, q: 5.99),
        Filter(type: .peak, frequency: 1007, gain: 1, q: 3.41),
        Filter(type: .peak, frequency: 576, gain: -1.2, q: 3.55),
        Filter(type: .lowPass, frequency: 20000, gain: 0, q: 0.7),
        Filter(type: .highPass, frequency: 20, gain: 0, q: 0.7),
        Filter(type: .notch, frequency: 60, gain: 0, q: 30),
        Filter(type: .bandPass, frequency: 1000, gain: 0, q: 0.1),
        Filter(type: .peak, frequency: 30, gain: 3, q: 0.5),
        Filter(type: .peak, frequency: 12000, gain: -2, q: 2),
        Filter(type: .peak, frequency: 16000, gain: 4, q: 0.7),
        Filter(type: .peak, frequency: 3000, gain: -1.5, q: 8),
        Filter(type: .peak, frequency: 800, gain: 2, q: 0.3),
        Filter(type: .peak, frequency: 250, gain: -2.5, q: 1),
        Filter(type: .lowShelf, frequency: 60, gain: 2, q: 0.5),
        Filter(type: .highShelf, frequency: 8000, gain: 1.5, q: 0.9),
    ])

    private func render(_ processor: EQProcessor) -> [Double] {
        let count = Self.length
        let left = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { left.deallocate(); right.deallocate() }
        left.initialize(repeating: 0, count: count)
        right.initialize(repeating: 0, count: count)
        left[0] = Self.impulse
        right[0] = Self.impulse
        processor.process(channels: [left, right], frameCount: count)
        XCTAssertFalse(processor.limiting, "the limiter engaged; the fixture would not be the filter chain alone")
        return (0..<count).map { Double(left[$0] / Self.impulse) }
    }

    private func check(_ processor: EQProcessor, fixture: String, note: String) throws {
        let samples = render(processor)
        if ProcessInfo.processInfo.environment["EQ_WRITE_GOLDEN"] == "1" {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/\(fixture).json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Golden(note: note, sampleRate: Self.rate, samples: samples)).write(to: url)
            return
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: fixture, withExtension: "json", subdirectory: "Fixtures"))
        let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
        XCTAssertEqual(golden.sampleRate, Self.rate)
        XCTAssertEqual(golden.samples.count, Self.length)
        XCTAssertTrue(samples.contains { abs($0) > 1e-3 }, "an all-zero render would match nothing useful")
        for (index, (actual, expected)) in zip(samples, golden.samples).enumerated() {
            XCTAssertEqual(actual, expected, accuracy: 1e-6, "sample \(index) of \(fixture)")
        }
    }
}
