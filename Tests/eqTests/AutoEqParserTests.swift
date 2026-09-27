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
        let r = try AutoEqParser.parseParametric(text)
        XCTAssertEqual(r.preamp, -3.5)
        XCTAssertEqual(r.filters.count, 2)
        XCTAssertEqual(r.filters[0].frequency, 1200)
        XCTAssertEqual(r.filters[0].q, sqrt(2) / (2 - 1), accuracy: 1e-9)
        XCTAssertEqual(r.filters[1], Filter(type: .lowShelf, frequency: 80, gain: 3, q: 0.707))
        XCTAssertEqual(r.warnings, ["Skipped unsupported all-pass filter."])
    }

    func testLeadingPlusIsAccepted() throws {
        let r = try AutoEqParser.parseParametric("""
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
        XCTAssertEqual(bands[0], -10.1, accuracy: 0.15)   // the file has "32 -10.1"
        XCTAssertTrue(r.filters.isEmpty)
        XCTAssertLessThanOrEqual(r.preamp, 0)
        // preamp only compensates a boost (positive max band); this fixture is all-cut, so max(0, …) clamps it to 0.
        XCTAssertEqual(r.preamp, -(max(0, bands.max() ?? 0) * 10).rounded() / 10, accuracy: 1e-9)
        XCTAssertEqual(r.format, "GraphicEQ (reduced to 10 bands)")
        XCTAssertEqual(r.warnings.count, 1)
    }

    func testGraphicInterpolatesBetweenPoints() throws {
        let r = try AutoEqParser.parseGraphic("GraphicEQ: 20 0; 40 6; 80 0; 20000 0")
        let bands = try XCTUnwrap(r.bands)
        // accuracy 0.05: implementation rounds each band to 0.1, which can shift the raw log-linear value by up to half a step
        XCTAssertEqual(bands[0], 6 * log(32.0 / 20) / log(40.0 / 20), accuracy: 0.05)     // 32 Hz between 20 (0) and 40 (6), log-linear
        XCTAssertEqual(bands[1], 6 * (1 - log(64.0 / 40) / log(80.0 / 40)), accuracy: 0.05) // 64 Hz between 40 (6) and 80 (0)
        XCTAssertEqual(bands[9], 0, accuracy: 1e-9)
    }

    func testGarbageIsRejected() {
        XCTAssertThrowsError(try AutoEqParser.parse("hello")) { XCTAssertEqual($0 as? AutoEqParser.ParseError, .unrecognized) }
        XCTAssertThrowsError(try AutoEqParser.parse("   ")) { XCTAssertEqual($0 as? AutoEqParser.ParseError, .empty) }
    }
}
