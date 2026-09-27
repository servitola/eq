import XCTest
@testable import eq

final class AutoEqIndexTests: XCTestCase {
    private func entries() throws -> [AutoEqEntry] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "INDEX", withExtension: "md", subdirectory: "Fixtures"))
        return AutoEqIndex.parse(try String(contentsOf: url))
    }

    func testParseDecodesPathsAndSources() throws {
        let e = try entries()
        XCTAssertEqual(e.count, 9)
        XCTAssertEqual(e[1], AutoEqEntry(name: "Sony WH-1000XM4", path: "oratory1990/over-ear/Sony WH-1000XM4", source: "oratory1990"))
        XCTAssertEqual(e[3].path, "Rtings/Bruel & Kjaer 5128 over-ear/Sony WH-1000XM4")
        XCTAssertEqual(e[8], AutoEqEntry(name: "1MORE Aero (ANC Off)", path: "HypetheSonics/GRAS RA0045 in-ear/1MORE Aero (ANC Off)", source: "HypetheSonics"))
    }

    func testMatchPrefersOratoryThenCrinacleThenRtings() throws {
        let e = try entries()
        XCTAssertEqual(AutoEqIndex.match("wh-1000xm4", in: e, source: nil), .one(e[1]))
        XCTAssertEqual(AutoEqIndex.match("WH-1000XM4", in: e, source: "Rtings"), .one(e[3]))
        XCTAssertEqual(AutoEqIndex.match("WH-1000XM4", in: e, source: "nobody"), .none)
    }

    func testExactNameBeatsSubstringAndAmbiguityLists() throws {
        let e = try entries()
        XCTAssertEqual(AutoEqIndex.match("sony wh-1000xm5", in: e, source: nil), .one(e[4]))
        XCTAssertEqual(AutoEqIndex.match("sony", in: e, source: nil), .ambiguous(["Sony WH-1000XM3", "Sony WH-1000XM4", "Sony WH-1000XM5"]))
        XCTAssertEqual(AutoEqIndex.match("bose", in: e, source: nil), .none)
    }

    func testFileURLIsPercentEncoded() throws {
        let e = try entries()
        XCTAssertEqual(AutoEqIndex.fileURL(for: e[3]).absoluteString,
            "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/Rtings/Bruel%20&%20Kjaer%205128%20over-ear/Sony%20WH-1000XM4/Sony%20WH-1000XM4%20ParametricEQ.txt")
        XCTAssertEqual(AutoEqIndex.fileURL(for: e[8]).absoluteString,
            "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/HypetheSonics/GRAS%20RA0045%20in-ear/1MORE%20Aero%20(ANC%20Off)/1MORE%20Aero%20(ANC%20Off)%20ParametricEQ.txt")
    }

    func testCacheFetchesOnceWithinSevenDays() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = AutoEqCache(directory: dir)
        var fetches = 0
        let fetch: (URL) throws -> Data = { _ in fetches += 1; return Data("- [A](./s/r/A) by s\n".utf8) }
        XCTAssertEqual(try cache.load(fetch: fetch, refresh: false).count, 1)
        XCTAssertEqual(try cache.load(fetch: fetch, refresh: false).count, 1)
        XCTAssertEqual(fetches, 1)
        _ = try cache.load(fetch: fetch, refresh: true)
        XCTAssertEqual(fetches, 2)
        let later = Date().addingTimeInterval(AutoEqIndex.cacheMaxAge + 1)
        _ = try cache.load(fetch: fetch, refresh: false, now: later)
        XCTAssertEqual(fetches, 3)
    }

    func testCacheFallsBackToStaleFileWhenOffline() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = AutoEqCache(directory: dir)
        _ = try cache.load(fetch: { _ in Data("- [A](./s/r/A) by s\n".utf8) }, refresh: false)
        let later = Date().addingTimeInterval(AutoEqIndex.cacheMaxAge + 1)
        let entries = try cache.load(fetch: { _ in throw URLError(.notConnectedToInternet) }, refresh: false, now: later)
        XCTAssertEqual(entries.count, 1)
        XCTAssertThrowsError(try AutoEqCache(directory: dir.appendingPathComponent("empty")).load(fetch: { _ in throw URLError(.notConnectedToInternet) }, refresh: false))
    }

    func testCacheKeepsOldIndexWhenFetchReturnsNoEntries() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = AutoEqCache(directory: dir)
        let portal: (URL) throws -> Data = { _ in Data("<html>sign in</html>".utf8) }
        XCTAssertThrowsError(try cache.load(fetch: portal, refresh: false)) {
            XCTAssertEqual(($0 as? URLError)?.code, .cannotParseResponse)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("INDEX.md").path))
        _ = try cache.load(fetch: { _ in Data("- [A](./s/r/A) by s\n".utf8) }, refresh: false)
        XCTAssertEqual(try cache.load(fetch: portal, refresh: true).count, 1)
        let cached = try String(contentsOf: dir.appendingPathComponent("INDEX.md"))
        XCTAssertTrue(cached.contains("[A]"))
    }

    func testDefaultDirectoryHonoursEQCache() {
        setenv("EQ_CACHE", "/tmp/eqc", 1); defer { unsetenv("EQ_CACHE") }
        XCTAssertEqual(AutoEqCache.defaultDirectory.path, "/tmp/eqc/autoeq")
        unsetenv("EQ_CACHE")
        XCTAssertTrue(AutoEqCache.defaultDirectory.path.hasSuffix("/.cache/eq/autoeq"))
    }
}
