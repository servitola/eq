import XCTest
@testable import eq

final class AutoEqParserTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
        return try String(contentsOf: url)
    }

    func testParametricFixture() throws {
        let r = try AutoEqParser.parse(try fixture("Sony WH-1000XM4 ParametricEQ"))
        XCTAssertEqual(r.preamp, -6.1)
        XCTAssertEqual(r.filters.count, 10)
        XCTAssertEqual(r.filters[0], Filter(type: .lowShelf, frequency: 105, gain: -4.2, q: 0.7))
        XCTAssertEqual(r.filters[1], Filter(type: .peak, frequency: 143, gain: -5.2, q: 1.1))
        XCTAssertEqual(r.filters[5].type, .highShelf)
        XCTAssertNil(r.bands)
        XCTAssertEqual(r.format, "AutoEq / Equalizer APO parametric")
        XCTAssertTrue(r.warnings.isEmpty)
    }

    func testParametricVariants() throws {
        let text = """
        Preamp: -3,5 dB
        Filter 1: ON PK Fc 1.2 kHz Gain 2,0 dB BW Oct 1.0
        Filter 2: OFF PK Fc 100 Hz Gain 0 dB Q 1
        Filter 3: ON AP Fc 100 Hz Gain 0 dB Q 1
        Filter 4: ON LS 6dB Fc 80 Hz Gain 3 dB
        """
        let r = try AutoEqParser.parse(text)
        XCTAssertEqual(r.preamp, -3.5)
        XCTAssertEqual(r.filters.count, 2)
        XCTAssertEqual(r.filters[0].frequency, 1200)
        XCTAssertEqual(r.filters[0].q, APOFormat.qFromBandwidth(1, frequency: 1200), accuracy: 1e-12)
        XCTAssertEqual(r.filters[0].q, sqrt(2) / (2 - 1), accuracy: 0.01, "the 48 kHz warp is small at 1.2 kHz")
        XCTAssertEqual(r.filters[1].type, .lowShelf)
        // A 6 dB/oct corner shelf: S 0.5, moved up from its corner to the centre the biquad needs.
        let a = pow(10, 3.0 / 40)
        XCTAssertEqual(r.filters[1].q, 1 / sqrt((a + 1 / a) * (1 / 0.5 - 1) + 2), accuracy: 1e-12)
        XCTAssertEqual(r.filters[1].frequency, 80 * pow(10, 3.0 / 80 / 0.5), accuracy: 1e-9)
        XCTAssertEqual(r.warnings, ["line 4: skipped a filter: an all-pass filter is not supported"])
    }

    func testLeadingPlusIsAccepted() throws {
        let r = try AutoEqParser.parse("""
        Preamp: +1 dB
        Filter 1: ON PK Fc 1000 Hz Gain +3.0 dB Q 1
        """)
        XCTAssertEqual(r.preamp, 1)
        XCTAssertEqual(r.filters, [Filter(type: .peak, frequency: 1000, gain: 3, q: 1)])
    }

    func testGraphicFixtureReducesToTenBands() throws {
        let r = try AutoEqParser.parse(try fixture("Sony WH-1000XM4 GraphicEQ"))
        let bands = try XCTUnwrap(r.bands)
        XCTAssertEqual(bands.count, 10)
        XCTAssertTrue(r.filters.isEmpty)
        // The curve sits around -9 dB (it dips to -12.3 at 128 Hz); that level is the preamp, so the bands keep their range.
        XCTAssertEqual(r.preamp, -9.1, accuracy: 0.2)
        XCTAssertEqual(heard(r, at: 32), -10.1, accuracy: 0.5)   // the file has "32 -10.1"
        XCTAssertEqual(heard(r, at: 128), -12.3, accuracy: 1)    // and "128 -12.3"
        XCTAssertEqual(r.format, "GraphicEQ (reduced to 10 bands)")
        XCTAssertEqual(r.warnings, ["GraphicEQ has 127 points; reduced to 10 bands \u{2014} the model's ParametricEQ.txt is exact"])
    }

    func testGraphicInterpolatesBetweenPoints() throws {
        let r = try AutoEqParser.parse("GraphicEQ: 20 0; 40 6; 80 0; 20000 0")
        XCTAssertNotNil(r.bands)
        // Ten octave-wide peaks cannot draw a one-octave spike exactly; they get its middle and its edges.
        XCTAssertGreaterThan(heard(r, at: 40), 3)
        XCTAssertEqual(heard(r, at: 1000), 0, accuracy: 0.3)
        XCTAssertEqual(heard(r, at: 16000), 0, accuracy: 0.3)
    }

    func testGarbageIsRejected() {
        XCTAssertThrowsError(try AutoEqParser.parse("hello")) { XCTAssertEqual($0 as? ImportError, .unrecognized) }
        XCTAssertThrowsError(try AutoEqParser.parse("   ")) { XCTAssertEqual($0 as? ImportError, .empty) }
    }
}
