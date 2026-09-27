import XCTest
@testable import eq

final class OPRATests: XCTestCase {
    private func fixture() throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "opra", withExtension: "jsonl", subdirectory: "Fixtures")))
    }

    private func entries() throws -> [OPRAEntry] { OPRA.parse(try fixture()) }

    func testParseNamesPresetsByVendorAndProductAndSkipsJunk() throws {
        let e = try entries()
        XCTAssertEqual(e.map(\.name), [
            "Sony WH-1000XM4", "Sony WH-1000XM4", "Sony WH-1000XM4 (ANC on)",
            "Sennheiser HD 600", "Apple AirPods Pro 2", "Sennheiser HD 600",
        ])
        XCTAssertEqual(e[1].id, "sony:wh_1000xm4::oratory1990_harman_target")
        XCTAssertEqual(e[1].credit, "oratory1990 (Harman Target)")
        XCTAssertEqual(e[1].source, "OPRA")
        XCTAssertEqual(e[1].preamp, -5.6)
        XCTAssertEqual(e[1].bands.first, OPRAEntry.Band(type: "low_shelf", frequency: 105, gainDb: 5.5, q: 0.71, slope: nil))
        XCTAssertEqual(OPRA.parse(Data("<html>sign in</html>".utf8)), [])
    }

    func testVendorIsNotRepeated() {
        XCTAssertEqual(OPRA.fullName(vendor: "Sony", product: "WH-1000XM4"), "Sony WH-1000XM4")
        XCTAssertEqual(OPRA.fullName(vendor: "Moondrop", product: "Moondrop x Crinacle DUSK"), "Moondrop x Crinacle DUSK")
        XCTAssertEqual(OPRA.fullName(vendor: "Nura", product: "Nuraphone"), "Nura Nuraphone")
        XCTAssertEqual(OPRA.fullName(vendor: nil, product: "Ghost"), "Ghost")
    }

    func testTagInTheCreditBecomesAVariantAndDuplicatesCollapse() {
        let bands = #"[{"type":"peak_dip","frequency":1000,"gain_db":1,"q":1}]"#
        let lines = [
            #"{"type":"vendor","id":"apple","data":{"name":"Apple"}}"#,
            #"{"type":"product","id":"apple::app2","data":{"name":"AirPods Pro 2","vendor_id":"apple"}}"#,
            #"{"type":"product","id":"apple::app2_anc","data":{"name":"AirPods Pro 2 (ANC mode)","vendor_id":"apple"}}"#,
            #"{"type":"eq","id":"a","data":{"author":"AutoEQ","details":"Measured by crinacle (ANC mode)","parameters":{"gain_db":0,"bands":\#(bands)},"product_id":"apple::app2"}}"#,
            #"{"type":"eq","id":"b","data":{"author":"AutoEQ","details":"Measured by crinacle","parameters":{"gain_db":0,"bands":\#(bands)},"product_id":"apple::app2_anc"}}"#,
        ]
        let e = OPRA.parse(Data(lines.joined(separator: "\n").utf8))
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e.first?.name, "Apple AirPods Pro 2 (ANC mode)")
        XCTAssertEqual(e.first?.details, "Measured by crinacle")
    }

    func testMatchPrefersTheHandMadePreset() throws {
        let e = try entries()
        XCTAssertEqual(HeadphoneMatch.match("wh1000xm4", in: e, source: nil, variant: nil, rank: OPRA.rank), .one(e[1]))
        XCTAssertEqual(HeadphoneMatch.match("wh1000xm4", in: e, source: nil, variant: "anc on", rank: OPRA.rank), .one(e[2]))
        XCTAssertLessThan(OPRA.rank(e[0]), OPRA.rank(e[4]))
    }

    func testResultMapsEveryBandType() throws {
        let hd600 = try XCTUnwrap(try entries().first { $0.author == "oratory1990" && $0.name == "Sennheiser HD 600" })
        let result = OPRA.result(hd600)
        XCTAssertEqual(result.preamp, -9.3)
        XCTAssertEqual(result.filters.count, 10)
        XCTAssertEqual(result.format, "OPRA parametric")
        XCTAssertEqual(result.warnings, [])

        let edge = try XCTUnwrap(try entries().last)
        let mapped = OPRA.result(edge)
        XCTAssertEqual(mapped.filters, [
            Filter(type: .lowPass, frequency: 12000, gain: 0, q: 0.707),
            Filter(type: .notch, frequency: 6000, gain: 0, q: 4),
            Filter(type: .highPass, frequency: 20, gain: 0, q: 0.707),
        ])
        XCTAssertEqual(mapped.warnings, [
            "low_pass at 12000 Hz has a 24 dB/oct slope; applied as 12 dB/oct.",
            "Skipped unknown filter type \u{201C}all_pass\u{201D}.",
        ])
        XCTAssertEqual(mapped.preamp, -1)
    }

    func testResultKeepsTheFirstBandsWhenThereAreTooMany() {
        let bands = (1...40).map { OPRAEntry.Band(type: "peak_dip", frequency: Double($0 * 100), gainDb: 1, q: 1, slope: nil) }
        let result = OPRA.result(OPRAEntry(id: "x", name: "X", author: "a", details: nil, preamp: 0, bands: bands))
        XCTAssertEqual(result.filters.count, Config.maxFilters)
        XCTAssertEqual(result.filters.last?.frequency, 3200)
        XCTAssertEqual(result.warnings, ["OPRA preset has 40 filters; kept the first 32."])
    }

    func testMalformedBandsAreSkippedWithAWarningInsteadOfTrapping() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "opra-malformed", withExtension: "jsonl", subdirectory: "Fixtures"))
        let entry = try XCTUnwrap(OPRA.parse(try Data(contentsOf: url)).first)
        let result = OPRA.result(entry)
        XCTAssertEqual(result.filters, [
            Filter(type: .peak, frequency: 1000, gain: -3, q: 1.4),
            Filter(type: .lowPass, frequency: 16000, gain: 0, q: 0.707),
        ])
        let preset = "OPRA preset \u{201C}acme:broken::garbage\u{201D}"
        XCTAssertEqual(result.warnings, [
            "Skipped a peak_dip band in \(preset): frequency 1e+300 Hz is outside 10–24000 Hz.",
            "Skipped a peak_dip band in \(preset): gain 1e+300 dB is outside ±30 dB.",
            "Skipped a peak_dip band in \(preset): Q 0 is outside 0.1–30.",
            "Skipped a low_pass band in \(preset): slope 1e+300 dB/oct is not a whole number from 1 to 96.",
            "Skipped a high_pass band in \(preset): slope 2.5 dB/oct is not a whole number from 1 to 96.",
            "Skipped a high_shelf band in \(preset): frequency 5 Hz is outside 10–24000 Hz.",
            "low_pass at 16000 Hz has a 24 dB/oct slope; applied as 12 dB/oct.",
        ])
        XCTAssertNoThrow(try result.filters.forEach { filter in
            var config = Config.initial(builtInUID: nil, builtInName: nil)
            config.default.filters = [filter]
            try config.validate()
        })
    }

    func testAttributionCreditsThePresetBeforeOPRA() throws {
        let e = try entries()
        XCTAssertEqual(OPRA.attribution(e[1]),
                       "preset by oratory1990 (Harman Target) · via OPRA (https://github.com/opra-project/OPRA), CC BY-SA 4.0")
    }

    func testCacheFetchesOnceAndRejectsAnEmptyDatabase() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-opra-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = try fixture()
        var fetched: [URL] = []
        let cache = OPRACache(directory: dir)
        XCTAssertThrowsError(try cache.load(fetch: { _ in Data("<html>sign in</html>".utf8) }, refresh: false))
        XCTAssertEqual(try cache.load(fetch: { fetched.append($0); return data }, refresh: false).count, 6)
        XCTAssertEqual(try cache.load(fetch: { fetched.append($0); return data }, refresh: false).count, 6)
        XCTAssertEqual(fetched, [OPRA.databaseURL])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("database_v1.jsonl").path))
        let later = Date().addingTimeInterval(AutoEqIndex.cacheMaxAge + 1)
        XCTAssertEqual(try cache.load(fetch: { _ in throw URLError(.notConnectedToInternet) }, refresh: false, now: later).count, 6)
    }
}
