import XCTest
@testable import eq

final class ConfigStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private static var changed: Config {
        var config = Config.initial(builtInUID: nil, builtInName: nil)
        config.enabled = false
        return config
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testDefaultURLHonoursEnvironmentOverride() {
        setenv("EQ_CONFIG", "/tmp/x/eq.json", 1)
        defer { unsetenv("EQ_CONFIG") }
        XCTAssertEqual(ConfigStore.defaultURL.path, "/tmp/x/eq.json")
    }

    func testDefaultURLIsUnderConfigHome() {
        unsetenv("EQ_CONFIG")
        XCTAssertTrue(ConfigStore.defaultURL.path.hasSuffix("/.config/eq/eq.json"))
    }

    func testSaveThenLoadRoundTrips() throws {
        let store = ConfigStore(url: dir.appendingPathComponent("nested/eq.json"))
        var config = Config.initial(builtInUID: "B", builtInName: "Built-in")
        config.enabled = false
        try store.save(config)
        XCTAssertTrue(store.exists())
        XCTAssertEqual(try store.load(), config)
        let text = try String(contentsOf: store.url)
        XCTAssertTrue(text.contains("\n"), "config must be pretty-printed for hand editing")
    }

    func testSaveRefusesInvalidConfig() throws {
        let store = ConfigStore(url: dir.appendingPathComponent("eq.json"))
        var config = Config.initial(builtInUID: nil, builtInName: nil)
        config.default.bands = []
        XCTAssertThrowsError(try store.save(config))
        XCTAssertFalse(store.exists())
    }

    func testLoadReportsInvalidJSON() throws {
        let store = ConfigStore(url: dir.appendingPathComponent("eq.json"))
        try "{ not json".write(to: store.url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.load()) { error in
            guard case .invalidJSON = error as? ConfigError else { return XCTFail("got \(error)") }
        }
    }

    func testLoadOrCreateWritesInitialConfigOnce() throws {
        let store = ConfigStore(url: dir.appendingPathComponent("eq.json"))
        let created = try store.loadOrCreate(builtInUID: "B", builtInName: "Built-in")
        XCTAssertEqual(created.devices["B"]?.name, "Built-in")
        var edited = created
        edited.enabled = false
        try store.save(edited)
        XCTAssertEqual(try store.loadOrCreate(builtInUID: "other", builtInName: nil).enabled, false)
    }

    func testWatcherFiresOnAtomicReplace() throws {
        let store = ConfigStore(url: dir.appendingPathComponent("eq.json"))
        _ = try store.loadOrCreate(builtInUID: nil, builtInName: nil)
        let fired = expectation(description: "onChange")
        fired.assertForOverFulfill = false
        let watcher = ConfigWatcher(url: store.url, queue: DispatchQueue(label: "test"), debounce: 0.05) { fired.fulfill() }
        watcher.start()
        defer { watcher.stop() }
        var config = try store.load()
        config.enabled = false
        try store.save(config)
        wait(for: [fired], timeout: 2)
    }

    func testLoadOrDefaultWritesNothing() throws {
        let store = ConfigStore(url: dir.appendingPathComponent("missing/eq.json"))
        let config = try store.loadOrDefault { ("B", "Built-in") }
        XCTAssertEqual(config, Config.initial(builtInUID: "B", builtInName: "Built-in"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("missing").path))
    }

    func testSavingTheDefaultsOverNoFileWritesNothing() throws {
        let store = ConfigStore(url: dir.appendingPathComponent("missing/eq.json"))
        try store.save(Config.initial(builtInUID: "B", builtInName: "Built-in"))
        try store.save(Config.initial(builtInUID: nil, builtInName: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("missing").path))
        var changed = Config.initial(builtInUID: "B", builtInName: "Built-in")
        changed.enabled = false
        try store.save(changed)
        XCTAssertEqual(try store.load(), changed)
    }

    func testLoadOrDefaultReadsAnExistingFileWithoutAskingForTheBuiltIn() throws {
        let store = ConfigStore(url: dir.appendingPathComponent("eq.json"))
        var saved = Config.initial(builtInUID: nil, builtInName: nil)
        saved.enabled = false
        try store.save(saved)
        XCTAssertEqual(try store.loadOrDefault { XCTFail("device lookup on an existing file"); return nil }, saved)
    }

    func testWatcherCreatesNoDirectoryAndSeesAConfigWrittenLater() throws {
        let store = ConfigStore(url: dir.appendingPathComponent("config/eq/eq.json"))
        let fired = expectation(description: "onChange")
        fired.assertForOverFulfill = false
        let watcher = ConfigWatcher(url: store.url, queue: DispatchQueue(label: "test"), debounce: 0.05) { fired.fulfill() }
        watcher.start()
        defer { watcher.stop() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("config").path))
        try store.save(Self.changed)
        wait(for: [fired], timeout: 2)
    }

    func testWatcherFollowsAConfigWrittenAfterItsDirectoryAppeared() throws {
        let store = ConfigStore(url: dir.appendingPathComponent("config/eq/eq.json"))
        let lock = NSLock()
        var pending: XCTestExpectation?
        let watcher = ConfigWatcher(url: store.url, queue: DispatchQueue(label: "test"), debounce: 0.05) {
            lock.lock(); pending?.fulfill(); pending = nil; lock.unlock()
        }
        watcher.start()
        defer { watcher.stop() }
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        Thread.sleep(forTimeInterval: 0.3)
        let saved = expectation(description: "save seen")
        lock.lock(); pending = saved; lock.unlock()
        try store.save(Self.changed)
        wait(for: [saved], timeout: 2)
    }

    func testWatcherFollowsADirectoryReplacedUnderIt() throws {
        let store = ConfigStore(url: dir.appendingPathComponent("eq/eq.json"))
        let files = FileManager.default
        try files.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = dir.appendingPathComponent("eq.staged")
        try files.createDirectory(at: staged, withIntermediateDirectories: true)
        let lock = NSLock()
        var pending: XCTestExpectation?
        let queue = DispatchQueue(label: "test")
        let watcher = ConfigWatcher(url: store.url, queue: queue, debounce: 0.05) {
            lock.lock(); pending?.fulfill(); pending = nil; lock.unlock()
        }
        watcher.start()
        defer { watcher.stop() }
        // Both moves land before the watcher sees the first event, so the path it re-checks already exists again.
        queue.suspend()
        try files.moveItem(at: store.url.deletingLastPathComponent(), to: dir.appendingPathComponent("eq.old"))
        try files.moveItem(at: staged, to: store.url.deletingLastPathComponent())
        queue.resume()
        Thread.sleep(forTimeInterval: 0.3)
        let saved = expectation(description: "save seen")
        lock.lock(); pending = saved; lock.unlock()
        try store.save(Self.changed)
        wait(for: [saved], timeout: 2)
    }
}
