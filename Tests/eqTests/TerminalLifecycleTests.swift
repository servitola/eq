import Darwin
import XCTest
@testable import eq

/// The built eq on a pseudo-terminal, against an in-process meter server: every way out must
/// leave cooked mode, a visible cursor and the main screen behind. The child runs in its own
/// session, so the stop in its Ctrl-Z path can never reach this test process.
final class TerminalLifecycleTests: XCTestCase {
    private var dir: URL!
    private var queue: DispatchQueue!
    private var server: MeterServer!

    override func setUpWithError() throws {
        let eq = Self.binary
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: eq.path), "no built eq beside the tests")
        dir = URL(fileURLWithPath: "/tmp/eq-pty-\(getpid())-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        queue = DispatchQueue(label: "pty-meter")
        server = MeterServer(socketURL: dir.appendingPathComponent("meter.sock"), queue: queue, tick: 0.05,
                             source: { MeterFrameTests.sample }, onClientsChanged: { _ in })
        try server.start()
    }

    override func tearDownWithError() throws {
        if let server { queue.sync { server.stop() } }
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private static var binary: URL { Bundle(for: TerminalLifecycleTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("eq") }

    private struct Child {
        var pid: pid_t
        var master: Int32
        var slave: Int32
        var output: [UInt8] = []

        var text: String { String(decoding: output, as: UTF8.self) }

        /// Reads until `done` holds for what arrived so far, or five seconds pass.
        mutating func read(until done: (String) -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(5)
            var chunk = [UInt8](repeating: 0, count: 65536)
            while Date() < deadline {
                if done(text) { return true }
                var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
                guard poll(&pfd, 1, 100) > 0 else { continue }
                let n = Darwin.read(master, &chunk, chunk.count)
                if n <= 0 { return done(text) }
                output += chunk.prefix(n)
            }
            return done(text)
        }

        mutating func drain() {
            var chunk = [UInt8](repeating: 0, count: 65536)
            var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            while poll(&pfd, 1, 20) > 0 {
                let n = Darwin.read(master, &chunk, chunk.count)
                guard n > 0 else { return }
                output += chunk.prefix(n)
            }
        }

        mutating func wait() -> Int32? {
            let deadline = Date().addingTimeInterval(5)
            var status: Int32 = 0
            while Date() < deadline {
                drain()
                if waitpid(pid, &status, WNOHANG) == pid {
                    drain()
                    return status
                }
            }
            kill(pid, SIGKILL)
            waitpid(pid, &status, 0)
            return nil
        }

        var cooked: Bool {
            var modes = termios()
            tcgetattr(slave, &modes)
            return modes.c_lflag & tcflag_t(ICANON) != 0 && modes.c_lflag & tcflag_t(ECHO) != 0
        }
    }

    private func spawn() throws -> Child {
        var master: Int32 = 0, slave: Int32 = 0
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        XCTAssertEqual(openpty(&master, &slave, nil, nil, &size), 0)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in [0, 1, 2] { posix_spawn_file_actions_adddup2(&actions, slave, fd) }
        posix_spawn_file_actions_addclose(&actions, master)
        posix_spawn_file_actions_addclose(&actions, slave)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        let arguments = [Self.binary.path, "watch"]
        let environment = ["EQ_CONFIG=\(dir.path)/eq.json", "EQ_STATUS=\(dir.path)/status.json", "EQ_CACHE=\(dir.path)/cache/autoeq",
                           "TERM=xterm-256color", "PATH=/usr/bin:/bin", "HOME=\(dir.path)"]
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        XCTAssertEqual(posix_spawn(&pid, Self.binary.path, &actions, &attributes, argv, envp), 0)
        var child = Child(pid: pid, master: master, slave: slave)
        XCTAssertTrue(child.read { $0.contains(Watch.enter) && $0.contains(" quit") }, child.text)
        XCTAssertFalse(child.cooked, "raw while the watch runs")
        return child
    }

    private func close(_ child: Child) {
        Darwin.close(child.master)
        Darwin.close(child.slave)
    }

    private func assertRestored(_ child: Child, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(child.cooked, "cooked mode and echo are back", file: file, line: line)
        let last = child.text.range(of: Watch.leave, options: .backwards)
        XCTAssertNotNil(last, "cursor shown, main screen back", file: file, line: line)
        if let last { XCTAssertFalse(child.text[last.upperBound...].contains(Watch.enter), "nothing took the screen again", file: file, line: line) }
    }

    func testQuitAndInterruptRestore() throws {
        for quit in [{ (child: Child) in _ = write(child.master, "q", 1) }, { (child: Child) in _ = kill(child.pid, SIGINT) }] {
            var child = try spawn()
            defer { close(child) }
            quit(child)
            let status = try XCTUnwrap(child.wait())
            XCTAssertEqual(status, 0, "exit 0, not a signal")
            assertRestored(child)
        }
    }

    func testTermAndHangUpRestoreAndStillEndBySignal() throws {
        for signal in [SIGTERM, SIGHUP] {
            var child = try spawn()
            defer { close(child) }
            kill(child.pid, signal)
            let status = try XCTUnwrap(child.wait())
            XCTAssertEqual(status & 0x7F, signal, "the parent sees the signal")
            assertRestored(child)
        }
    }

    func testACrashRestoresAndStillCrashes() throws {
        for signal in [SIGSEGV, SIGTRAP, SIGABRT] {
            var child = try spawn()
            defer { close(child) }
            kill(child.pid, signal)
            let status = try XCTUnwrap(child.wait())
            XCTAssertEqual(status & 0x7F, signal, "the default action still runs, so a crash report is still written")
            assertRestored(child)
        }
    }

    func testSuspendGivesTheScreenBackAndResumeRedrawsIt() throws {
        var child = try spawn()
        defer { close(child) }
        func resumed(_ text: String) -> Bool {
            guard let left = text.range(of: Watch.leave),
                  let entered = text.range(of: Watch.enter, range: left.upperBound..<text.endIndex) else { return false }
            return text.range(of: "\u{1B}[2J\u{1B}[H", range: entered.upperBound..<text.endIndex) != nil
        }
        kill(child.pid, SIGTSTP)
        // The child's session is orphaned, so the stop itself is discarded and the resume path runs at once.
        XCTAssertTrue(child.read(until: resumed), "left, entered again, redrew in full: \(child.text.suffix(300).debugDescription)")
        XCTAssertFalse(child.cooked, "raw again")
        _ = write(child.master, "q", 1)
        XCTAssertEqual(try XCTUnwrap(child.wait()) >> 8, 0)
        assertRestored(child)
    }
}
