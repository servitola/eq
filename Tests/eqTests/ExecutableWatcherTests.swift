import XCTest
@testable import eq

final class ExecutableWatcherTests: XCTestCase {
    private var dir: URL!
    private var watcher: ExecutableWatcher?
    private let queue = DispatchQueue(label: "eq-test-executable-watcher")
    private let files = FileManager.default

    override func setUpWithError() throws {
        dir = files.temporaryDirectory.appendingPathComponent("eq-exe-\(UUID().uuidString)")
        try makeApp(at: dir.appendingPathComponent("EQ.app"), contents: "old")
    }

    override func tearDownWithError() throws {
        watcher?.stop()
        try? files.removeItem(at: dir)
    }

    private var executable: URL { dir.appendingPathComponent("EQ.app/Contents/MacOS/eq") }

    private func makeApp(at app: URL, contents: String) throws {
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try files.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: macOS.appendingPathComponent("eq"))
    }

    private func watch(patience: Int = 20) -> XCTestExpectation {
        let fired = expectation(description: "watcher fired")
        var changes: [ExecutableWatcher.Change] = []
        let watcher = ExecutableWatcher(path: executable.path, queue: queue, settle: 0.05, patience: patience) { change in
            changes.append(change)
            self.lastChanges = changes
            fired.fulfill()
        }
        watcher.start()
        self.watcher = watcher
        return fired
    }

    private var lastChanges: [ExecutableWatcher.Change] = []

    /// What `brew upgrade` does: the old EQ.app goes back to the Caskroom, the new one moves in.
    func testAnUpgradeMovingTheBundleOutAndANewOneInIsAReplacement() throws {
        let fired = watch()
        try makeApp(at: dir.appendingPathComponent("staged/EQ.app"), contents: "new")
        try files.createDirectory(at: dir.appendingPathComponent("old"), withIntermediateDirectories: true)
        try files.moveItem(at: dir.appendingPathComponent("EQ.app"), to: dir.appendingPathComponent("old/EQ.app"))
        try files.moveItem(at: dir.appendingPathComponent("staged/EQ.app"), to: dir.appendingPathComponent("EQ.app"))
        wait(for: [fired], timeout: 5)
        XCTAssertEqual(lastChanges, [.replaced])
    }

    func testAFileReplacedInPlaceIsAReplacement() throws {
        let fired = watch()
        let fresh = dir.appendingPathComponent("eq.new")
        try Data("new".utf8).write(to: fresh)
        XCTAssertEqual(rename(fresh.path, executable.path), 0)
        wait(for: [fired], timeout: 5)
        XCTAssertEqual(lastChanges, [.replaced])
    }

    func testAttributesAloneChangeNothing() throws {
        let fired = watch()
        fired.isInverted = true
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        XCTAssertEqual(setxattr(executable.path, "com.apple.quarantine", "x", 1, 0, 0), 0)
        XCTAssertEqual(removexattr(executable.path, "com.apple.quarantine", 0), 0)
        try Data().write(to: dir.appendingPathComponent("Other.app"))
        wait(for: [fired], timeout: 0.5)
    }

    func testABinaryGoneForGoodIsARemovalAfterPatience() throws {
        let fired = watch(patience: 3)
        try files.removeItem(at: dir.appendingPathComponent("EQ.app"))
        wait(for: [fired], timeout: 5)
        XCTAssertEqual(lastChanges, [.removed])
    }

    func testABinaryBackWithinPatienceIsAReplacement() throws {
        let fired = watch(patience: 40)
        try files.moveItem(at: dir.appendingPathComponent("EQ.app"), to: dir.appendingPathComponent("away.app"))
        Thread.sleep(forTimeInterval: 0.3)
        try makeApp(at: dir.appendingPathComponent("EQ.app"), contents: "new")
        wait(for: [fired], timeout: 5)
        XCTAssertEqual(lastChanges, [.replaced])
    }
}
