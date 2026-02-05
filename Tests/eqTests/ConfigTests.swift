import XCTest
@testable import eq

final class ConfigTests: XCTestCase {
    func testInitialConfigCarriesScreenshotCurveForDefaultAndBuiltIn() {
        let config = Config.initial(builtInUID: "BuiltInSpeakerDevice", builtInName: "MacBook Pro Speakers")
        XCTAssertEqual(config.version, 1)
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.default.bands, Config.screenshotCurve)
        XCTAssertEqual(config.devices["BuiltInSpeakerDevice"]?.bands, Config.screenshotCurve)
        XCTAssertEqual(config.devices["BuiltInSpeakerDevice"]?.name, "MacBook Pro Speakers")
        XCTAssertNoThrow(try config.validate())
    }

    func testInitialConfigWithoutBuiltInHasNoDevices() {
        let config = Config.initial(builtInUID: nil, builtInName: nil)
        XCTAssertTrue(config.devices.isEmpty)
    }

    func testProfileFallsBackToDefault() {
        var config = Config.initial(builtInUID: nil, builtInName: nil)
        config.devices["JBL"] = Profile(name: "JBL Big", preamp: -2, bands: Array(repeating: 1, count: 10))
        let known = config.profile(forDeviceUID: "JBL")
        XCTAssertEqual(known.source, .device)
        XCTAssertEqual(known.profile.preamp, -2)
        let unknown = config.profile(forDeviceUID: "AirPods")
        XCTAssertEqual(unknown.source, .default)
        XCTAssertEqual(unknown.profile.bands, Config.screenshotCurve)
    }

    func testValidateRejectsWrongBandCount() {
        var config = Config.initial(builtInUID: nil, builtInName: nil)
        config.default.bands = [0, 0, 0]
        XCTAssertThrowsError(try config.validate()) { error in
            XCTAssertEqual(error as? ConfigError, .bandCount("default", 3))
        }
    }

    func testValidateRejectsGainOutOfRange() {
        var config = Config.initial(builtInUID: nil, builtInName: nil)
        config.devices["X"] = Profile(name: nil, preamp: 0, bands: [0, 0, 0, 0, 0, 12.5, 0, 0, 0, 0])
        XCTAssertThrowsError(try config.validate()) { error in
            XCTAssertEqual(error as? ConfigError, .gainOutOfRange("X", 12.5))
        }
        config.devices["X"] = Profile(name: nil, preamp: -13, bands: Array(repeating: 0, count: 10))
        XCTAssertThrowsError(try config.validate()) { error in
            XCTAssertEqual(error as? ConfigError, .gainOutOfRange("X", -13))
        }
    }

    func testValidateRejectsUnsupportedVersion() {
        var config = Config.initial(builtInUID: nil, builtInName: nil)
        config.version = 2
        XCTAssertThrowsError(try config.validate()) { error in
            XCTAssertEqual(error as? ConfigError, .unsupportedVersion(2))
        }
    }

    func testJSONRoundTripKeepsDefaultKeyName() throws {
        let config = Config.initial(builtInUID: "B", builtInName: "Built-in")
        let data = try JSONEncoder().encode(config)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["default"])
        XCTAssertNotNil(json["devices"])
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: data), config)
    }

    func testBandTablesAreConsistent() {
        XCTAssertEqual(Config.bandFrequencies.count, 10)
        XCTAssertEqual(Config.bandLabels.count, 10)
        XCTAssertEqual(Config.bandLabels[5], "1kHz")
        XCTAssertEqual(Config.bandFrequencies[9], 16000)
    }
}
