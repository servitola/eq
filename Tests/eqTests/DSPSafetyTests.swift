import XCTest
@testable import eq

final class DSPSafetyTests: XCTestCase {
    private let rate = 48000.0
    private let block = 512

    private func isZeroOrNormal(_ value: Float) -> Bool { value == 0 || value.isNormal }

    func testFlushZeroesOnlySubnormalState() {
        var state = BiquadState(z1: Float.leastNormalMagnitude / 2, z2: -Float.leastNonzeroMagnitude)
        state.flushDenormals()
        XCTAssertEqual(state.z1, 0)
        XCTAssertEqual(state.z2, 0)
        state = BiquadState(z1: Float.leastNormalMagnitude, z2: -0.25)
        state.flushDenormals()
        XCTAssertEqual(state.z1, Float.leastNormalMagnitude)
        XCTAssertEqual(state.z2, -0.25)
    }

    // A tone just above the subnormal range, so the tail crosses into it within a second or two
    // instead of after the ~25 s the meter's 300 ms release takes to fall from full scale.
    func testDecayingTailEndsInExactZeros() {
        let processor = EQProcessor()
        processor.configure(sampleRate: rate)
        var profile = Profile(name: nil, preamp: 0, bands: Config.screenshotCurve)
        profile.filters = [Filter(type: .lowShelf, frequency: 20, gain: 6, q: 0.7), Filter(type: .peak, frequency: 40, gain: 4, q: 8)]
        processor.apply(profile: profile, enabled: true)
        processor.meteringEnabled = true
        let left = UnsafeMutablePointer<Float>.allocate(capacity: block)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: block)
        defer { left.deallocate(); right.deallocate() }
        for i in 0..<block {
            left[i] = 1e-36 * Float(sin(2 * Double.pi * 40 * Double(i) / rate))
            right[i] = left[i]
        }
        processor.process(channels: [left, right], frameCount: block)

        var blocksLeavingSubnormals = 0
        var silentBlocks = 0
        var state: [Float] = []
        repeat {
            left.update(repeating: 0, count: block)
            right.update(repeating: 0, count: block)
            processor.process(channels: [left, right], frameCount: block)
            silentBlocks += 1
            state = processor.renderStateForTesting() + processor.meter.stateForTesting()
            if !state.allSatisfy(isZeroOrNormal) { blocksLeavingSubnormals += 1 }
        } while state.contains { $0 != 0 } && silentBlocks < Int(4 * rate) / block
        XCTAssertEqual(blocksLeavingSubnormals, 0)
        XCTAssertEqual(state.filter { $0 != 0 }, [], "still ringing after \(silentBlocks * block) frames")
        XCTAssertEqual(Array(UnsafeBufferPointer(start: left, count: block)).filter { $0 != 0 }, [])
    }

    func testStabilityTriangle() {
        XCTAssertTrue(BiquadCoefficients().isStable)
        XCTAssertTrue(BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: -1.9, a2: 0.95).isStable)
        // A pole on or outside the unit circle: a2 at the edge, then a1 past 1 + a2 (a pole at z > 1).
        XCTAssertFalse(BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 1).isStable)
        XCTAssertFalse(BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: -1.2).isStable)
        XCTAssertFalse(BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: -1.95, a2: 0.95).isStable)
        XCTAssertFalse(BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 2.1, a2: 0.9).isStable)
        XCTAssertFalse(BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: .nan, a2: 0).isStable)
    }

    func testEveryAllowedCornerIsStableAt48k() {
        let frequencies = [Config.filterFrequencyRange.lowerBound, 1000, Config.filterFrequencyRange.upperBound]
        let qs = [Config.filterQRange.lowerBound, 1.41, Config.filterQRange.upperBound]
        let gains = [Config.filterGainRange.lowerBound, 0, Config.filterGainRange.upperBound]
        for type in FilterType.allCases {
            for frequency in frequencies {
                for q in qs {
                    for gain in gains {
                        let c = BiquadCoefficients.make(type: type, frequency: frequency, gainDB: gain, q: q, sampleRate: Config.stabilityCheckRate)
                        XCTAssertTrue(c.isStable, "\(type) \(frequency) Hz q \(q) gain \(gain)")
                    }
                }
            }
        }
    }

    // Nothing inside the allowed ranges is unstable at 48 kHz, so the rejecting branch is driven
    // at 192 kHz, where Float32 rounding puts a 10 Hz low-Q peak's pole on the unit circle.
    func testUnstableFilterIsFoundByItsNumber() {
        let filters = [Filter(type: .peak, frequency: 1000, gain: 3, q: 1), Filter(type: .peak, frequency: 10, gain: 4, q: 0.1)]
        XCTAssertNil(Config.firstUnstableFilter(filters, sampleRate: 48000))
        XCTAssertEqual(Config.firstUnstableFilter(filters, sampleRate: 192_000), 2)
    }

    func testUnstableFilterMessageNamesProfileAndFilter() {
        XCTAssertEqual(ConfigError.filterUnstable("X", 3).description,
                       "profile \"X\": filter 3 would be unstable at 48 kHz (its output would ring or grow without end); change its frequency or Q")
    }
}
