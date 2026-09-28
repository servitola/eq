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
        XCTAssertNoThrow(try config.validate())
        config.devices["X"] = Profile(name: nil, preamp: -31, bands: Array(repeating: 0, count: 10))
        XCTAssertThrowsError(try config.validate()) { error in
            XCTAssertEqual(error as? ConfigError, .preampOutOfRange("X", -31))
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

    func testV1ProfileDecodesWithEmptyFilters() throws {
        let json = #"{"preamp":0,"bands":[0,0,0,0,0,0,0,0,0,0]}"#.data(using: .utf8)!
        let profile = try JSONDecoder().decode(Profile.self, from: json)
        XCTAssertEqual(profile.filters, [])
        XCTAssertNil(profile.imported)
    }

    func testFiltersRoundTripAndValidate() throws {
        var config = Config.initial(builtInUID: nil, builtInName: nil)
        config.devices["X"] = Profile(name: "X", preamp: -6.1, bands: Profile.flat.bands,
                                      filters: [Filter(type: .lowShelf, frequency: 105, gain: -4.2, q: 0.7, origin: .import)],
                                      imported: "AutoEq oratory1990 · X · 2026-09-27")
        XCTAssertNoThrow(try config.validate())
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: data), config)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"lowShelf\""))
    }

    func testFilterValidationRanges() {
        var config = Config.initial(builtInUID: nil, builtInName: nil)
        config.devices["X"] = Profile(name: nil, preamp: 0, bands: Profile.flat.bands,
                                      filters: [Filter(type: .peak, frequency: 5, gain: 0, q: 1)])
        XCTAssertThrowsError(try config.validate()) { XCTAssertEqual($0 as? ConfigError, .filterOutOfRange("X", "frequency 5.0 Hz (10…24000 Hz)")) }
        config.devices["X"]?.filters = [Filter(type: .peak, frequency: 1000, gain: 31, q: 1)]
        XCTAssertThrowsError(try config.validate()) { XCTAssertEqual($0 as? ConfigError, .filterOutOfRange("X", "gain 31.0 dB (-30…30 dB)")) }
        config.devices["X"]?.filters = [Filter(type: .peak, frequency: 1000, gain: 0, q: 0.05)]
        XCTAssertThrowsError(try config.validate()) { XCTAssertEqual($0 as? ConfigError, .filterOutOfRange("X", "q 0.05 (0.1…30)")) }
    }

    func testValidateCapsFilterCount() {
        var config = Config.initial(builtInUID: nil, builtInName: nil)
        let filter = Filter(type: .peak, frequency: 1000, gain: 0, q: 1)
        config.devices["X"] = Profile(name: nil, preamp: 0, bands: Profile.flat.bands,
                                      filters: Array(repeating: filter, count: Config.maxFilters))
        XCTAssertNoThrow(try config.validate())
        config.devices["X"]?.filters.append(filter)
        XCTAssertThrowsError(try config.validate()) { XCTAssertEqual($0 as? ConfigError, .filterOutOfRange("X", "count 33 (max 32)")) }
    }

    func testEngineBandsCombineBandsAndFilters() {
        var profile = Profile.flat
        profile.bands[5] = 3
        profile.filters = [Filter(type: .highShelf, frequency: 10000, gain: -1, q: 0.7)]
        let bands = profile.engineBands
        XCTAssertEqual(bands.count, 11)
        XCTAssertEqual(bands[5].frequency, 1000)
        XCTAssertEqual(bands[5].gain, 3)
        XCTAssertEqual(bands[10].type, .highShelf)
        XCTAssertEqual(bands[10].frequency, 10000)
    }

    func testHooksAreOptionalAndRoundTrip() throws {
        let initial = Config.initial(builtInUID: nil, builtInName: nil)
        XCTAssertNil(initial.hooks)
        let encoded = String(decoding: try JSONEncoder().encode(initial), as: UTF8.self)
        XCTAssertFalse(encoded.contains("hooks"), "a config without hooks writes no key")

        var withHooks = initial
        withHooks.hooks = ["device": "echo \"$EQ_DEVICE\"", "volume": "true"]
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(withHooks))
        XCTAssertEqual(decoded.hooks, withHooks.hooks, "an unknown hook name is kept in the file, only the daemon ignores it")
        XCTAssertNoThrow(try decoded.validate())
    }
}
