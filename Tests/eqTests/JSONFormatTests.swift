import XCTest
@testable import eq

func formatFixture(_ name: String) throws -> Data {
    try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")))
}

final class JSONFormatTests: XCTestCase {
    private func parse(_ json: String) throws -> ImportResult { try EQFormats.parse(Data(json.utf8)) }

    private func q(octaves bw: Double) -> Double { 1 / (2 * sinh(log(2) / 2 * bw)) }

    // MARK: - eqMac

    func testEqMacAdvancedExportSetsTheTenBandsAndItsGlobalGain() throws {
        let r = try EQFormats.parse(try formatFixture("eqMac Advanced presets.json"))
        XCTAssertEqual(r.format, "eqMac Advanced preset")
        XCTAssertEqual(r.bands, [-4.3, -1.8, -5.8, -1.4, 0.5, -0.6, 6, -0.8, 1, -2.2])
        XCTAssertEqual(r.filters, [])
        XCTAssertEqual(r.preamp, -5.8)
        XCTAssertEqual(r.warnings, ["the file has 2 presets; imported the first, \u{201C}Sony WH-1000XM4\u{201D}"])
    }

    func testEqMacGainsBeyondTheBandRangeBecomeTenPeaks() throws {
        // eqMac's own "Acoustic" preset (AdvancedEqualizerDefaultPresets.swift) goes to +18.22 dB.
        let r = try parse(#"{"name":"Acoustic","gains":{"global":-6,"bands":[-8.3,9.8,-15.68,2.1,18.22,3.5,7,8.2,7.1,4.3]}}"#)
        XCTAssertNil(r.bands)
        XCTAssertEqual(r.filters.count, 10)
        XCTAssertEqual(r.filters[4], Filter(type: .peak, frequency: 500, gain: 18.22, q: 1.41))
        XCTAssertTrue(r.warnings.contains { $0.contains("ten peak filters") })
    }

    func testEqMacAdvancedRefusesAWrongBandCountAndZeroesABadGain() throws {
        XCTAssertThrowsError(try parse(#"[{"gains":{"global":0,"bands":[1,2,3]}}]"#)) {
            guard case .nothingUsable(let reasons) = $0 as? ImportError else { return XCTFail("\($0)") }
            XCTAssertTrue(reasons[0].contains("3 values"))
        }
        let r = try parse(#"[{"gains":{"global":true,"bands":[1,"x",3,4,5,6,7,8,9,1e3]}}]"#)
        XCTAssertEqual(r.bands, [1, 0, 3, 4, 5, 6, 7, 8, 9, 0])
        XCTAssertEqual(r.preamp, 0)
        XCTAssertEqual(r.warnings.count, 3)
        XCTAssertThrowsError(try parse(#"[{"gains":{"global":-40,"bands":[0,0,0,0,0,0,0,0,0,0]}}]"#)) {
            XCTAssertEqual($0 as? ImportError, .preampOutOfRange(-40))
        }
    }

    func testEqMacExpertBandsBecomeFiltersFromTheirBandwidth() throws {
        let r = try EQFormats.parse(try formatFixture("eqMac Expert presets.json"))
        XCTAssertEqual(r.format, "eqMac Expert preset")
        XCTAssertEqual(r.preamp, -6.1)
        XCTAssertEqual(r.warnings, [])
        XCTAssertEqual(r.filters.map(\.type), [.lowShelf, .peak, .peak, .highShelf])
        XCTAssertEqual(r.filters[0].frequency, 105)
        XCTAssertEqual(r.filters[0].q, q(octaves: 1.9), accuracy: 1e-12)
        XCTAssertEqual(r.filters[2], Filter(type: .peak, frequency: 2289, gain: 6.1, q: q(octaves: 0.9)))
        // One octave is Q √2 on the analog RBJ relation.
        XCTAssertEqual(q(octaves: 1), 2.0.squareRoot(), accuracy: 1e-12)
    }

    func testEqMacExpertSkipsWhatItCannotRepresent() throws {
        let r = try parse(#"""
        [{"name":"x","global":0,"bands":[
          {"frequency":100,"gain":3,"bandwidth":1,"type":3},
          {"frequency":100,"gain":3,"bandwidth":0,"type":0},
          {"frequency":5,"gain":3,"bandwidth":1,"type":0},
          {"frequency":1000,"gain":3,"bandwidth":1,"type":42},
          {"frequency":1000,"gain":99,"bandwidth":1,"type":0},
          {"frequency":1000,"gain":-3,"bandwidth":1,"type":6},
          {"frequency":1000,"gain":2,"bandwidth":1,"type":1e300}
        ]}]
        """#)
        XCTAssertEqual(r.filters, [Filter(type: .notch, frequency: 1000, gain: 0, q: q(octaves: 1))])
        XCTAssertEqual(r.warnings.count, 6)
    }

    // MARK: - Poweramp

    func testPowerampGraphicPresetSetsTheBandsAndDropsItsIdleShelves() throws {
        let r = try EQFormats.parse(try formatFixture("Poweramp PA-CEQ 3.0.json"))
        XCTAssertEqual(r.format, "Poweramp graphic preset")
        XCTAssertEqual(r.filters, [])
        XCTAssertEqual(r.preamp, 0)
        XCTAssertEqual(r.warnings, [])
        let bands = try XCTUnwrap(r.bands)
        XCTAssertEqual(bands[0], 0)
        XCTAssertEqual(bands[1], -0.5534720420837402)
        XCTAssertEqual(bands[2], 4.281429767608643)
        XCTAssertEqual(bands[7], -1.8349037170410156)
        XCTAssertEqual(bands[9], 0)
    }

    func testPowerampParametricPresetKeepsItsFiltersAndRefusesTheOdd() throws {
        let r = try parse(#"""
        [{"name":"p","preamp":-3.5,"parametric":true,"bands":[
          {"type":0,"channels":0,"frequency":105,"q":0.7,"gain":4,"color":0},
          {"type":1,"channels":0,"frequency":10000,"q":0.0,"gain":-2,"color":0},
          {"type":2,"channels":0,"frequency":1000,"q":1.5,"gain":-3,"color":0},
          {"type":2,"channels":1,"frequency":2000,"q":1.5,"gain":-3,"color":0},
          {"type":2,"channels":0,"frequency":3000,"q":0,"gain":-3,"color":0},
          {"type":5,"channels":0,"frequency":3000,"q":1,"gain":-3,"color":0},
          {"type":2,"channels":0,"frequency":30000,"q":1,"gain":-3,"color":0},
          {"type":2,"channels":0,"frequency":"x","q":1,"gain":-3,"color":0},
          7
        ]}]
        """#)
        XCTAssertEqual(r.format, "Poweramp parametric preset")
        XCTAssertEqual(r.preamp, -3.5)
        XCTAssertEqual(r.filters, [
            Filter(type: .lowShelf, frequency: 105, gain: 4, q: 0.7),
            Filter(type: .highShelf, frequency: 10000, gain: -2, q: 0.5.squareRoot()),
            Filter(type: .peak, frequency: 1000, gain: -3, q: 1.5),
        ])
        XCTAssertEqual(r.warnings.count, 6)
    }

    func testPowerampWithOtherSlidersIsReducedToTenBands() throws {
        let r = try parse(#"{"preamp":0,"parametric":false,"bands":[{"type":2,"frequency":60,"gain":6},{"type":2,"frequency":230,"gain":3},{"type":2,"frequency":910,"gain":0},{"type":2,"frequency":3600,"gain":-3},{"type":2,"frequency":14000,"gain":20}]}"#)
        XCTAssertEqual(r.bands?.first, 6)
        XCTAssertEqual(r.bands?.last, 12)
        XCTAssertTrue(r.warnings.contains("5 graphic bands reduced to 10"))
        XCTAssertTrue(r.warnings.contains { $0.contains("limited") })
    }

    func testHostileJSONNeverTraps() {
        for json in [#"[{"preamp":1e999,"parametric":true,"bands":[]}]"#, #"[{"parametric":true,"bands":[{"type":1e300,"frequency":1,"gain":1}]}]"#,
                     #"[{"gains":{"bands":[]}}]"#, #"[]"#, #"{"bands":[{"channels":0}]}"#, String(repeating: "[", count: 100_000),
                     #"{"bands":[1,2,3,4,5,6,7,8,9,1e999],"preamp":0,"filters":[1,"x",{}],"preference":{"bass":"y"}}"#,
                     #"{"bands":[0,0,0,0,0,0,0,0,0,0],"preamp":0,"filters":[{"type":"peak","frequency":1e300,"gain":1,"q":1}]}"#] {
            _ = try? parse(json)
        }
    }

    // MARK: - eq's own JSON

    func testEqOwnProfileFixtureImportsExactly() throws {
        let r = try EQFormats.parse(try formatFixture("eq profile.json"))
        XCTAssertEqual(r.format, "eq's own profile")
        XCTAssertEqual(r.bands, [-4.3, -1.8, -5.8, -1.4, 0.5, -0.6, 6, -0.8, 1, -2.2])
        XCTAssertEqual(r.preamp, -5.8)
        XCTAssertEqual(r.filters, [
            Filter(type: .peak, frequency: 143.7, gain: -5.2, q: 1.1),
            Filter(type: .lowShelf, frequency: 105, gain: 4.2, q: 0.7),
        ])
        XCTAssertEqual(r.preference, Preference(bass: 3, treble: -1.5, tilt: 0.3))
        XCTAssertEqual(r.warnings, [])
    }

    func testEqOwnJSONZeroesABandBeyondTheRangeAndDropsBadPreference() throws {
        let r = try parse(#"{"bands":[1,99,3,4,5,6,7,8,9,10],"preamp":-3,"preference":{"bass":99,"treble":0,"tilt":0}}"#)
        XCTAssertEqual(r.bands, [1, 0, 3, 4, 5, 6, 7, 8, 9, 10])
        XCTAssertTrue(r.warnings.contains { $0.contains("band 2 (64 Hz)") })
        XCTAssertNil(r.preference)
        XCTAssertTrue(r.warnings.contains("preference is out of range; dropped"))
    }

    func testEqOwnJSONRefusesAPreampOutsideTheRange() throws {
        XCTAssertThrowsError(try parse(#"{"bands":[0,0,0,0,0,0,0,0,0,0],"preamp":-40}"#)) {
            XCTAssertEqual($0 as? ImportError, .preampOutOfRange(-40))
        }
    }

    func testEqOwnJSONPassesAFlatPreferenceOnToClearTheLayer() throws {
        let r = try parse(#"{"bands":[0,0,0,0,0,0,0,0,0,0],"preamp":0,"preference":{"bass":0,"treble":0,"tilt":0}}"#)
        XCTAssertEqual(r.preference, Preference())
        XCTAssertNil(try parse(#"{"bands":[0,0,0,0,0,0,0,0,0,0],"preamp":0}"#).preference)
    }

    func testEqOwnJSONSkipsUnusableFiltersWithAWarning() throws {
        let r = try parse(#"""
        {"bands":[0,0,0,0,0,0,0,0,0,0],"preamp":0,"filters":[
          {"type":"peak","frequency":1000,"gain":3,"q":1.4},
          {"type":"sawtooth","frequency":1000,"gain":3,"q":1},
          {"type":"peak","gain":3,"q":1},
          {"type":"peak","frequency":100000,"gain":3,"q":1},
          "not an object"
        ]}
        """#)
        XCTAssertEqual(r.filters, [Filter(type: .peak, frequency: 1000, gain: 3, q: 1.4)])
        XCTAssertEqual(r.warnings.count, 4)
        XCTAssertTrue(r.warnings.contains { $0.contains("unknown filter type") })
        XCTAssertTrue(r.warnings.contains { $0.contains("no frequency") })
        XCTAssertTrue(r.warnings.contains { $0.contains("not an object") })
    }
}
