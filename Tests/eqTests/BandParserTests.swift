import XCTest
@testable import eq

final class BandParserTests: XCTestCase {
    func testBandIndexAcceptsLabelsAndPlainHertz() {
        XCTAssertEqual(BandParser.bandIndex("32hz"), 0)
        XCTAssertEqual(BandParser.bandIndex("64Hz"), 1)
        XCTAssertEqual(BandParser.bandIndex("1khz"), 5)
        XCTAssertEqual(BandParser.bandIndex("1KHz"), 5)
        XCTAssertEqual(BandParser.bandIndex("1000hz"), 5)
        XCTAssertEqual(BandParser.bandIndex("1k"), 5)
        XCTAssertEqual(BandParser.bandIndex("16khz"), 9)
        XCTAssertEqual(BandParser.bandIndex("125"), 2)
        XCTAssertNil(BandParser.bandIndex("100hz"))
        XCTAssertNil(BandParser.bandIndex("bass"))
    }

    func testGainParsesSignedDecimals() throws {
        XCTAssertEqual(try BandParser.gain("+4"), 4)
        XCTAssertEqual(try BandParser.gain("-3.1"), -3.1)
        XCTAssertEqual(try BandParser.gain("0"), 0)
        XCTAssertEqual(try BandParser.gain("2,5"), 2.5)
    }

    func testGainRejectsGarbageAndRange() {
        XCTAssertThrowsError(try BandParser.gain("loud")) { XCTAssertEqual($0 as? CLIError, .badGain("loud")) }
        XCTAssertThrowsError(try BandParser.gain("13")) { XCTAssertEqual($0 as? CLIError, .gainOutOfRange(13)) }
        XCTAssertThrowsError(try BandParser.gain("-12.01")) { XCTAssertEqual($0 as? CLIError, .gainOutOfRange(-12.01)) }
    }

    func testAssignmentsPairsTokens() throws {
        let result = try BandParser.assignments(["64hz", "+4", "1khz", "-3"])
        XCTAssertEqual(result.map(\.index), [1, 5])
        XCTAssertEqual(result.map(\.gain), [4, -3])
    }

    func testAssignmentsRejectsOddCountUnknownBandAndNothingWritten() {
        XCTAssertThrowsError(try BandParser.assignments(["64hz"])) { XCTAssertEqual($0 as? CLIError, .usage("expected pairs of <band> <gain>")) }
        XCTAssertThrowsError(try BandParser.assignments(["64hz", "+4", "77hz", "1"])) { XCTAssertEqual($0 as? CLIError, .unknownBand("77hz")) }
        XCTAssertThrowsError(try BandParser.assignments([])) { XCTAssertEqual($0 as? CLIError, .usage("expected pairs of <band> <gain>")) }
    }
}
