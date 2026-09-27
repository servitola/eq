import XCTest
@testable import eq

final class FilterTests: XCTestCase {
    private var dir: URL!
    private var context: CLIContext!

    override func setUpWithError() throws {
        Paint.forced = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-filter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        context = CLIContext(
            store: ConfigStore(url: dir.appendingPathComponent("eq.json")),
            statusURL: dir.appendingPathComponent("status.json"),
            connectedDevices: { [("BUILTIN", "MacBook Pro Speakers", "builtin"), ("BT-1", "JBL Big", "bluetooth")] },
            defaultOutput: { ("BUILTIN", "MacBook Pro Speakers") },
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            cacheDirectory: dir.appendingPathComponent("cache"),
            today: { "2026-09-27" })
        _ = CLI.run(["init"], context: context)
    }

    override func tearDownWithError() throws {
        Paint.forced = nil
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func run(_ args: String...) -> (exitCode: Int32, output: String, isError: Bool, streamed: Bool) {
        CLI.run(args, context: context)
    }

    private func filters(_ uid: String = "BUILTIN") throws -> [Filter] {
        try XCTUnwrap(try context.store.load().devices[uid]).filters
    }

    private func importFixture() throws {
        let file = dir.appendingPathComponent("xm4.txt")
        let text = try String(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "Sony WH-1000XM4 ParametricEQ",
                                                                            withExtension: "txt", subdirectory: "Fixtures")))
        try text.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(run("import", file.path).exitCode, 0)
    }

    func testImportKeepsOnlyAsManyFiltersAsTheHandOnesLeaveRoomFor() throws {
        for _ in 0..<(Config.maxFilters - 2) { XCTAssertEqual(run("filter", "add", "peak", "1k", "1").exitCode, 0) }
        let file = dir.appendingPathComponent("xm4.txt")
        let text = try String(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "Sony WH-1000XM4 ParametricEQ",
                                                                            withExtension: "txt", subdirectory: "Fixtures")))
        try text.write(to: file, atomically: true, encoding: .utf8)
        let result = run("import", file.path)
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(result.output.contains("kept the first 2 of 10 imported filters"), result.output)
        let list = try filters()
        XCTAssertEqual(list.count, Config.maxFilters)
        XCTAssertEqual(list.prefix(2).map(\.origin), [.import, .import])
    }

    func testRemovingTheLastImportedFilterClearsTheImportLabel() throws {
        try importFixture()
        run("filter", "add", "peak", "1k", "1")
        XCTAssertEqual(run("filter", "rm", "11").exitCode, 0)
        XCTAssertNotNil(try context.store.load().devices["BUILTIN"]?.imported, "imported filters remain")
        XCTAssertEqual(run("filter", "rm", "all").exitCode, 0)
        XCTAssertNil(try context.store.load().devices["BUILTIN"]?.imported)
    }

    func testAddStoresAHandFilterWithTheGivenQ() throws {
        let result = run("filter", "add", "peak", "3k", "-2", "2")
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(result.output.contains("added filter 1"), result.output)
        XCTAssertEqual(try filters(), [Filter(type: .peak, frequency: 3000, gain: -2, q: 2, origin: .hand)])
    }

    func testAddDefaultsQByType() throws {
        run("filter", "add", "peak", "1000hz", "+3")
        run("filter", "add", "HighPass", "30", "0")
        run("filter", "add", "lowshelf", "2.5k", "1,5")
        run("filter", "add", "notch", "60Hz", "0")
        let added = try filters()
        XCTAssertEqual(added.map(\.q), [1.41, 0.707, 0.707, 1.41])
        XCTAssertEqual(added.map(\.frequency), [1000, 30, 2500, 60])
        XCTAssertEqual(added.map(\.type), [.peak, .highPass, .lowShelf, .notch])
        XCTAssertEqual(added[2].gain, 1.5)
    }

    func testAddRejectsBadInput() throws {
        XCTAssertEqual(run("filter", "add", "wobble", "3k", "-2").exitCode, 2)
        XCTAssertEqual(run("filter", "add", "peak", "loud", "-2").exitCode, 2)
        XCTAssertEqual(run("filter", "add", "peak", "3k", "much").exitCode, 2)
        XCTAssertEqual(run("filter", "add", "peak", "3k").exitCode, 2)
        let range = run("filter", "add", "peak", "3k", "40")
        XCTAssertEqual(range.exitCode, 1)
        XCTAssertTrue(range.output.contains("gain 40.0 dB (-30…30 dB)"), range.output)
        XCTAssertEqual(run("filter", "add", "peak", "50k", "1").exitCode, 1)
        XCTAssertEqual(try filters(), [])
    }

    func testAddStopsAtTheCap() throws {
        for _ in 0..<Config.maxFilters { XCTAssertEqual(run("filter", "add", "peak", "1k", "1").exitCode, 0) }
        let result = run("filter", "add", "peak", "1k", "1")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("count 33 (max 32)"), result.output)
    }

    func testSetChangesOnlyTheNamedFields() throws {
        run("filter", "add", "peak", "3k", "-2", "2")
        run("filter", "add", "peak", "5k", "1")
        let result = run("filter", "set", "2", "gain=-3", "q=4", "freq=6k")
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(try filters()[1], Filter(type: .peak, frequency: 6000, gain: -3, q: 4, origin: .hand))
        XCTAssertEqual(run("filter", "set", "1", "type=highshelf").exitCode, 0)
        XCTAssertEqual(try filters()[0], Filter(type: .highShelf, frequency: 3000, gain: -2, q: 2, origin: .hand))
    }

    func testSetAndRmRejectMissingFiltersAndKeys() throws {
        let none = run("filter", "rm", "1")
        XCTAssertEqual(none.exitCode, 1)
        XCTAssertTrue(none.output.contains("has no filters"), none.output)
        run("filter", "add", "peak", "3k", "-2")
        XCTAssertEqual(run("filter", "set", "2", "gain=1").exitCode, 1)
        XCTAssertEqual(run("filter", "set", "0", "gain=1").exitCode, 1)
        XCTAssertEqual(run("filter", "set", "1", "width=1").exitCode, 2)
        XCTAssertEqual(run("filter", "set", "1", "gain").exitCode, 2)
        XCTAssertEqual(run("filter", "set", "1").exitCode, 2)
        XCTAssertEqual(run("filter", "set", "1", "q=100").exitCode, 1)
        XCTAssertEqual(try filters()[0].q, 1.41)
    }

    func testRmOneAndAll() throws {
        run("filter", "add", "peak", "1k", "1")
        run("filter", "add", "peak", "2k", "2")
        run("filter", "add", "peak", "3k", "3")
        XCTAssertEqual(run("filter", "rm", "2").exitCode, 0)
        XCTAssertEqual(try filters().map(\.frequency), [1000, 3000])
        let all = run("filter", "rm", "all")
        XCTAssertTrue(all.output.contains("removed 2 filters"), all.output)
        XCTAssertEqual(try filters(), [])
    }

    func testDeviceOptionEditsThatDevice() throws {
        XCTAssertEqual(run("filter", "add", "peak", "3k", "-2", "--device", "jbl").exitCode, 0)
        XCTAssertEqual(try filters("BT-1").count, 1)
        XCTAssertEqual(try filters().count, 0)
        XCTAssertTrue(run("filter", "--device", "jbl").output.contains("3000 Hz"))
    }

    func testListShowsNumberSourceAndJSON() throws {
        XCTAssertTrue(run("filter").output.contains("no filters"))
        try importFixture()
        run("filter", "add", "notch", "3.2k", "0", "8")
        let text = run("filter").output
        XCTAssertTrue(text.contains("imported: file xm4 · 2026-09-27"), text)
        let last = try XCTUnwrap(text.components(separatedBy: "\n").last)
        XCTAssertTrue(last.hasPrefix("  11  notch"), last)
        XCTAssertTrue(last.hasSuffix("hand"), last)
        XCTAssertTrue(text.contains("import\n"), text)

        let result = CLI.run(["filter", "--json"], context: context)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        let rows = try XCTUnwrap(json["filters"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 11)
        XCTAssertEqual(rows[10]["number"] as? Int, 11)
        XCTAssertEqual(rows[10]["origin"] as? String, "hand")
        XCTAssertEqual(rows[10]["type"] as? String, "notch")
        XCTAssertEqual(rows[0]["origin"] as? String, "import")
        XCTAssertEqual(json["source"] as? String, "device")
    }

    func testShowNumbersFiltersWithTheirSource() throws {
        run("filter", "add", "peak", "3k", "-2", "2")
        let text = run().output
        XCTAssertTrue(text.contains("  filters:\n"), text)
        XCTAssertTrue(text.contains("source"), text)
        XCTAssertTrue(text.contains("   1  peak"), text)
    }

    func testImportTagsItsFiltersAndClearKeepsHandOnes() throws {
        run("filter", "add", "notch", "3.2k", "0", "8")
        try importFixture()
        var list = try filters()
        XCTAssertEqual(list.count, 11)
        XCTAssertEqual(list.prefix(10).map(\.origin), Array(repeating: .import, count: 10))
        XCTAssertEqual(list.last?.origin, .hand)
        XCTAssertEqual(list.last?.type, .notch)

        try importFixture()
        XCTAssertEqual(try filters().count, 11, "a second import replaces the first, not the hand filter")

        XCTAssertEqual(run("import", "--clear").exitCode, 0)
        list = try filters()
        XCTAssertEqual(list, [Filter(type: .notch, frequency: 3200, gain: 0, q: 8, origin: .hand)])
        XCTAssertNil(try context.store.load().devices["BUILTIN"]?.imported)
    }

    func testEditedImportedFilterStaysImported() throws {
        try importFixture()
        XCTAssertEqual(run("filter", "set", "1", "gain=-3").exitCode, 0)
        XCTAssertEqual(try filters()[0].origin, .import)
        XCTAssertEqual(try context.store.load().devices["BUILTIN"]?.imported, "file xm4 · 2026-09-27")
    }

    func testLegacyFiltersTakeTheirOriginFromTheImportLabel() throws {
        let filter = #"{"type":"peak","frequency":1000,"gain":-2,"q":1}"#
        let imported = #"{"preamp":0,"bands":[0,0,0,0,0,0,0,0,0,0],"imported":"file x","filters":[\#(filter)]}"#
        let hand = #"{"preamp":0,"bands":[0,0,0,0,0,0,0,0,0,0],"filters":[\#(filter)]}"#
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: Data(imported.utf8)).filters[0].origin, .import)
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: Data(hand.utf8)).filters[0].origin, .hand)
        let marked = #"{"preamp":0,"bands":[0,0,0,0,0,0,0,0,0,0],"imported":"file x","filters":[{"type":"peak","frequency":1000,"gain":-2,"q":1,"origin":"hand"}]}"#
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: Data(marked.utf8)).filters[0].origin, .hand)
    }

    func testOriginDoesNotMakeAPresetModified() {
        var a = Profile(name: nil, preamp: 0, bands: Profile.flat.bands, filters: [Filter(type: .peak, frequency: 1000, gain: 1, q: 1, origin: .import)])
        let b = Profile(name: nil, preamp: 0, bands: Profile.flat.bands, filters: [Filter(type: .peak, frequency: 1000, gain: 1, q: 1, origin: .hand)])
        XCTAssertTrue(a.sameCurve(as: b))
        a.filters[0].gain = 2
        XCTAssertFalse(a.sameCurve(as: b))
    }

    func testUnknownVerbIsUsage() {
        XCTAssertEqual(run("filter", "move", "1").exitCode, 2)
        XCTAssertEqual(run("filter", "list", "extra").exitCode, 2)
    }
}
