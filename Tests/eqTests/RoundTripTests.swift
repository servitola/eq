import XCTest
@testable import eq

/// What an import result plays at `frequency`, preamp included, at 48 kHz.
func heard(_ result: ImportResult, at frequency: Double) -> Double {
    Exporter.response(Profile(name: nil, preamp: result.preamp, bands: result.bands ?? Profile.flat.bands, filters: result.filters), at: frequency)
}

/// Export → import through the real `EQFormats` entry point, judged by what is heard: the whole
/// cascade's magnitude at 200 log-spaced frequencies, 20 Hz–20 kHz, at 48 kHz.
final class RoundTripTests: XCTestCase {
    private let header = Exporter.Header(device: "HD 600", date: "2026-09-28")

    private static let screenshot = Profile(name: "JBL", preamp: -4.8, bands: Config.screenshotCurve)

    /// Ten imported filters, every type at least once, off-grid numbers that only survive exact printing.
    private static let withFilters: Profile = {
        var profile = screenshot
        profile.filters = [
            Filter(type: .peak, frequency: 143.7, gain: -5.2, q: 1.1, origin: .import),
            Filter(type: .peak, frequency: 3150.25, gain: 2.35, q: 4.3, origin: .import),
            Filter(type: .lowShelf, frequency: 105, gain: 4.2, q: 0.7, origin: .import),
            Filter(type: .highShelf, frequency: 10000, gain: -1, q: 0.7, origin: .import),
            Filter(type: .lowPass, frequency: 18000, gain: 0, q: 0.707, origin: .import),
            Filter(type: .highPass, frequency: 25, gain: 0, q: 0.5, origin: .import),
            Filter(type: .notch, frequency: 6123.4, gain: 0, q: 8, origin: .import),
            Filter(type: .bandPass, frequency: 1000, gain: 0, q: 0.3, origin: .import),
            Filter(type: .lowShelf, frequency: 42.5, gain: -3.3, q: 1.2, origin: .import),
            Filter(type: .highShelf, frequency: 7777, gain: 6.1, q: 0.55, origin: .import),
        ]
        return profile
    }()

    private static let withPreference: Profile = {
        var profile = withFilters
        profile.preference = Preference(bass: 3, treble: -1.5, tilt: 0.3)
        return profile
    }()

    private static let profiles = [("screenshot curve", screenshot), ("+ 10 filters", withFilters), ("+ bass/treble/tilt", withPreference)]

    static let frequencies: [Double] = (0..<200).map { 20 * pow(1000, Double($0) / 199) }

    private func response(_ profile: Profile) -> [Double] {
        Self.frequencies.map { Exporter.response(profile, at: $0) }
    }

    private func profile(_ result: ImportResult) -> Profile {
        Profile(name: nil, preamp: result.preamp, bands: result.bands ?? Profile.flat.bands, filters: result.filters, preference: result.preference)
    }

    private func worstDifference(_ a: Profile, _ b: Profile) -> (dB: Double, at: Double) {
        zip(Self.frequencies, zip(response(a), response(b))).map { (abs($1.0 - $1.1), $0) }.max { $0.0 < $1.0 }!
    }

    private func roundTrip(_ profile: Profile, _ format: ExportFormat) throws -> ImportResult {
        try EQFormats.parse(Data(try Exporter.render(profile, as: format, header: header).utf8))
    }

    func testAPORoundTripsWithinFiveHundredthsOfADecibel() throws {
        for (name, original) in Self.profiles {
            let back = try roundTrip(original, .apo)
            XCTAssertEqual(back.warnings, [], name)
            let worst = worstDifference(original, profile(back))
            XCTAssertLessThanOrEqual(worst.dB, 0.05, "\(name): \(worst.dB) dB at \(worst.at) Hz")
        }
    }

    func testCamillaRoundTripsWithinFiveHundredthsOfADecibel() throws {
        for (name, original) in Self.profiles {
            let back = try roundTrip(original, .camilla)
            XCTAssertEqual(back.format, "CamillaDSP config", name)
            XCTAssertEqual(back.warnings, [], name)
            let worst = worstDifference(original, profile(back))
            XCTAssertLessThanOrEqual(worst.dB, 0.05, "\(name): \(worst.dB) dB at \(worst.at) Hz")
        }
    }

    func testJSONRoundTripsWithinFiveHundredthsOfADecibel() throws {
        for (name, original) in Self.profiles {
            let text = try Exporter.render(original, as: .json, header: header)
            let back = try JSONDecoder().decode(Profile.self, from: Data(text.utf8))
            let worst = worstDifference(original, back)
            XCTAssertLessThanOrEqual(worst.dB, 0.05, "\(name): \(worst.dB) dB at \(worst.at) Hz")
        }
    }

    /// eq's own JSON is not fitted or reduced like a borrowed format: it round-trips exactly,
    /// bands, preamp, filters and the preference layer alike, through `eq import` itself.
    func testJSONRoundTripsThroughEQImportExactly() throws {
        for (name, original) in Self.profiles {
            let back = try roundTrip(original, .json)
            XCTAssertEqual(back.format, "eq's own profile", name)
            XCTAssertEqual(back.warnings, [], name)
            XCTAssertEqual(back.bands, original.bands, name)
            XCTAssertEqual(back.preamp, original.preamp, name)
            XCTAssertEqual(back.filters.count, original.filters.count, name)
            XCTAssertTrue(zip(back.filters, original.filters).allSatisfy { $0.sounds(like: $1) }, name)
            XCTAssertEqual(back.preference ?? Preference(), original.preference ?? Preference(), name)
            XCTAssertEqual(response(profile(back)), response(original), name)
        }
    }

    func testEqMacRoundTripOfTenBandsIsExactAndTheRestIsRefused() throws {
        let back = try roundTrip(Self.screenshot, .eqmac)
        XCTAssertEqual(back.format, "eqMac Advanced preset")
        XCTAssertEqual(back.bands, Self.screenshot.bands)
        XCTAssertEqual(back.filters, [])
        XCTAssertEqual(back.preamp, Self.screenshot.preamp)
        XCTAssertEqual(response(profile(back)), response(Self.screenshot))
        for original in [Self.withFilters, Self.withPreference] {
            XCTAssertThrowsError(try Exporter.render(original, as: .eqmac, header: header))
        }
    }

    /// A GraphicEQ.txt is the response sampled on AutoEq's grid, and eq reads it back as ten
    /// band gains. What survives is what ten Q 1.41 peaks can draw: the ten-band curve itself.
    func testGraphicEQRoundTripOfTenBandsIsWithinHalfADecibel() throws {
        let back = try roundTrip(Self.screenshot, .graphiceq)
        let bands = try XCTUnwrap(back.bands)
        XCTAssertEqual(back.filters, [])
        let heard = Profile(name: nil, preamp: back.preamp, bands: bands)
        let worst = worstDifference(Self.screenshot, heard)
        XCTAssertLessThanOrEqual(worst.dB, 0.5, "\(worst.dB) dB at \(worst.at) Hz")
    }
}
