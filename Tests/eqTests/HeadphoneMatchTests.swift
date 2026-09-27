import XCTest
@testable import eq

final class HeadphoneMatchTests: XCTestCase {
    private func entries() throws -> [AutoEqEntry] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "INDEX", withExtension: "md", subdirectory: "Fixtures"))
        return AutoEqIndex.parse(try String(contentsOf: url))
    }

    private func entry(_ name: String, _ source: String) throws -> AutoEqEntry {
        try XCTUnwrap(try entries().first { $0.name == name && $0.source == source })
    }

    func testNameSplitsTrailingVariantTag() {
        XCTAssertEqual(HeadphoneName("Sony WH-1000XM4 (ANC on)").model, "Sony WH-1000XM4")
        XCTAssertEqual(HeadphoneName("Sony WH-1000XM4 (ANC on)").variant, "ANC on")
        XCTAssertEqual(HeadphoneName("Apple AirPods Pro 2 (51dB + ANC)").variantKey, "51db-anc")
        XCTAssertEqual(HeadphoneName("Sony WH-1000XM4").model, "Sony WH-1000XM4")
        XCTAssertNil(HeadphoneName("Sony WH-1000XM4").variant)
        XCTAssertEqual(HeadphoneName("(odd)").variant, nil)
    }

    func testVariantKeysFoldSpellingAndANCSynonyms() {
        XCTAssertEqual(HeadphoneMatch.variantKey("ANC On"), "anc-on")
        XCTAssertEqual(HeadphoneMatch.variantKey("anc_on"), "anc-on")
        XCTAssertEqual(HeadphoneMatch.variantKey("ANC mode"), "anc-on")
        XCTAssertEqual(HeadphoneMatch.variantKey("Transparency  Mode"), "transparency-mode")
    }

    func testSeparatorsCaseAndAliasesDoNotMatter() throws {
        let e = try entries()
        let xm4 = try entry("Sony WH-1000XM4", "oratory1990")
        let airpods = try entry("AirPods Pro 2", "oratory1990")
        XCTAssertEqual(AutoEqIndex.match("wh1000xm4", in: e, source: nil), .one(xm4))
        XCTAssertEqual(AutoEqIndex.match("SONY WH 1000 XM4", in: e, source: nil), .one(xm4))
        XCTAssertEqual(AutoEqIndex.match("xm4", in: e, source: nil), .one(xm4))
        XCTAssertEqual(AutoEqIndex.match("airpods pro2", in: e, source: nil), .one(airpods))
        XCTAssertEqual(AutoEqIndex.match("airpods pro 2nd gen", in: e, source: nil), .one(airpods))
    }

    func testPlainEntryBeatsVariantsThenANCOn() throws {
        let e = try entries()
        XCTAssertEqual(AutoEqIndex.match("airpods pro 2", in: e, source: nil), .one(try entry("AirPods Pro 2", "oratory1990")))
        XCTAssertEqual(AutoEqIndex.match("wh-1000xm4", in: e, source: "HypetheSonics"),
                       .one(try entry("Sony WH-1000XM4 (ANC on)", "HypetheSonics")))
        XCTAssertEqual(AutoEqIndex.match("airpods pro 2", in: e, source: "crinacle"),
                       .one(try entry("Apple AirPods Pro 2 (ANC mode)", "crinacle")))
        XCTAssertEqual(AutoEqIndex.match("1more aero", in: e, source: nil), .one(e[8]))
    }

    func testVariantOptionAndTagInTheQuery() throws {
        let e = try entries()
        let off = try entry("Sony WH-1000XM4 (ANC Off)", "HypetheSonics")
        XCTAssertEqual(AutoEqIndex.match("wh1000xm4", in: e, source: nil, variant: "anc-off"), .one(off))
        XCTAssertEqual(AutoEqIndex.match("Sony WH-1000XM4 (ANC Off)", in: e, source: nil), .one(off))
        XCTAssertEqual(AutoEqIndex.match("airpods pro 2", in: e, source: nil, variant: "transparency"),
                       .one(try entry("Apple AirPods Pro 2 (transparency mode)", "crinacle")))
        XCTAssertEqual(AutoEqIndex.match("airpods pro 2", in: e, source: nil, variant: "51dB"),
                       .one(try entry("Apple AirPods Pro 2 (51dB + ANC)", "crinacle")))
        XCTAssertEqual(AutoEqIndex.match("airpods pro 2", in: e, source: nil, variant: "bogus"),
                       .variants(model: "AirPods Pro 2", ["51db-anc", "anc-on", "passive-mode", "transparency-mode"]))
        XCTAssertEqual(AutoEqIndex.match("sony wh-1000xm5", in: e, source: nil, variant: "anc-on"),
                       .variants(model: "Sony WH-1000XM5", []))
    }

    func testSeveralVariantsAndNoPlainOneAsks() throws {
        let e = try entries()
        XCTAssertEqual(AutoEqIndex.match("moondrop aria", in: e, source: nil), .variants(model: "Moondrop Aria", ["sample-1", "sample-2"]))
        XCTAssertEqual(AutoEqIndex.match("moondrop aria", in: e, source: nil, variant: "sample 2"),
                       .one(try entry("Moondrop Aria (sample 2)", "Super Review")))
    }

    func testSameModelNameFromTwoVendorsIsAmbiguous() throws {
        XCTAssertEqual(AutoEqIndex.match("aria", in: try entries(), source: nil), .ambiguous(["Kiwi Ears Aria", "Moondrop Aria"]))
    }

    func testTyposSuggestInsteadOfGuessing() throws {
        let e = try entries()
        XCTAssertEqual(AutoEqIndex.match("sony wh-1000xm6", in: e, source: nil),
                       .didYouMean(["Sony WH-1000XM3", "Sony WH-1000XM4", "Sony WH-1000XM5"]))
        XCTAssertEqual(AutoEqIndex.match("moondorp aria", in: e, source: nil), .didYouMean(["Moondrop Aria"]))
        XCTAssertEqual(AutoEqIndex.match("bose", in: e, source: nil), .none)
    }

    func testSearchListsEverySourceAndVariantPlainFirst() throws {
        let found = HeadphoneMatch.search("wh1000xm4", in: try entries(), rank: AutoEqIndex.rank)
        XCTAssertEqual(found.hits.map { "\($0.name) · \($0.source)" }, [
            "Sony WH-1000XM4 · oratory1990", "Sony WH-1000XM4 · crinacle", "Sony WH-1000XM4 · Rtings",
            "Sony WH-1000XM4 (ANC Off) · HypetheSonics", "Sony WH-1000XM4 (ANC on) · HypetheSonics",
        ])
        XCTAssertEqual(found.suggestions, [])
        let typo = HeadphoneMatch.search("moondorp aria", in: try entries(), rank: AutoEqIndex.rank)
        XCTAssertEqual(typo.hits, [])
        XCTAssertEqual(typo.suggestions, ["Moondrop Aria"])
    }

    func testLevenshtein() {
        XCTAssertEqual(HeadphoneMatch.levenshtein("kitten", "sitting"), 3)
        XCTAssertEqual(HeadphoneMatch.levenshtein("", "abc"), 3)
        XCTAssertEqual(HeadphoneMatch.levenshtein("xm4", "xm4"), 0)
    }
}
