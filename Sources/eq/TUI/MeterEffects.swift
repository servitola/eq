import Darwin
import EQTerm
import Foundation

/// What the TUI's commands do outside the model: the session's edits, the daemon's sockets, the
/// terminal's mouse mode, the palette's child processes. Tests give fakes for each.
struct MeterEffects {
    static let meterSource = 1
    static let eventsSource = 2
    static let childSource = 3
    static let retryTimer = 1
    static let eventsTimer = 2
    static let reapTimer = 3

    var edit: (WatchAction) throws -> Void
    var header: () -> Watch.Header
    var send: (String) throws -> Void
    var mouse: (Bool) -> Void
    /// Opens the meter socket anew; its descriptor, or nil while the daemon is away.
    var connect: () -> Int32?
    var disconnect: () -> Void = {}
    /// A connection subscribed to the daemon's events; nil while the daemon is away.
    var connectEvents: () -> Int32? = { nil }
    var complete: (Completions.Kind) -> [String] = { _ in [] }
    var children: ChildRunner?
    var saveHistory: ([String]) -> Void = { _ in }
    var library: () -> Library = { Library(loaded: true) }
    /// Points the session's edits at a device other than the playing one, or back at it.
    var target: (DeviceChoice?) -> Void = { _ in }

    func perform(_ cmd: MeterCmd, _ runtime: Runtime<MeterModel>) -> [MeterMsg] {
        switch cmd {
        case .edit(let action):
            do {
                try edit(action)
                return [.edited(action, failure: nil)]
            } catch {
                return [.edited(action, failure: String(describing: error))]
            }
        case .send(let line):
            do {
                try send(line)
                return []
            } catch {
                return [.sendFailed]
            }
        case .redraw:
            runtime.renderer.invalidate()
            return []
        case .refreshHeader:
            return [.header(header())]
        case .mouse(let on):
            mouse(on)
            return []
        case .retry(let delay):
            runtime.after(delay, id: Self.retryTimer)
            return []
        case .connect:
            guard let fd = connect() else { return [.connectFailed] }
            runtime.watch(fd: fd, id: Self.meterSource, latestOnly: true)
            return [.connected]
        case .disconnect:
            runtime.unwatch(Self.meterSource)
            disconnect()
            return []
        case .connectEvents:
            guard let fd = connectEvents() else { return [.eventsConnectFailed] }
            runtime.watch(fd: fd, id: Self.eventsSource)
            return [.eventsConnected]
        case .retryEvents(let delay):
            runtime.after(delay, id: Self.eventsTimer)
            return []
        case .complete(let kind):
            return [.completions(kind, complete(kind))]
        case .run(let words, let columns):
            guard let children, let fd = children.start(words, columns: columns) else {
                return [.childOutput("error: eq could not be started"), .childExit(127)]
            }
            runtime.watch(fd: fd, id: Self.childSource)
            return []
        case .stop:
            children?.stop()
            return []
        case .reap:
            guard let children else { return [] }
            guard let code = children.reap() else {
                runtime.after(0.05, id: Self.reapTimer)
                return []
            }
            return [.childExit(code)]
        case .saveHistory(let lines):
            saveHistory(lines)
            return []
        case .refreshLibrary:
            return [.library(library())]
        case .target(let device):
            target(device)
            return []
        case .quit(let code):
            runtime.quit(code)
            return []
        }
    }

    private static let decoder = JSONDecoder()

    static func translate(_ event: Event) -> MeterMsg? {
        switch event {
        case .input(let input): return .input(input)
        case .line(meterSource, let line): return (try? decoder.decode(MeterFrame.self, from: Data(line.utf8))).map(MeterMsg.frame)
        case .closed(meterSource): return .meterClosed
        case .line(eventsSource, let line): return EventEntry.decode(line).map(MeterMsg.event)
        case .closed(eventsSource): return .eventsClosed
        case .line(childSource, let line): return .childOutput(line)
        case .closed(childSource), .timer(reapTimer): return .childClosed
        case .timer(retryTimer): return .retry
        case .timer(eventsTimer): return .eventsRetry
        case .resize(let size): return .resize(size)
        case .signal: return .signal
        default: return nil
        }
    }
}

/// One `eq` child at a time, in its own process group so it can be stopped whole and never
/// gets the terminal's keys; stdout and stderr share one pipe the loop reads.
final class ChildRunner {
    let executable: String
    var environment: [String: String]
    private(set) var pid: pid_t?
    private var fd: Int32?

    init(executable: String, environment: [String: String]) {
        self.executable = executable
        self.environment = environment
    }

    /// The read end of the child's output, or nil when it could not be started.
    func start(_ words: [String], columns: Int) -> Int32? {
        var pipes: [Int32] = [-1, -1]
        guard pipe(&pipes) == 0 else { return nil }
        _ = fcntl(pipes[0], F_SETFD, FD_CLOEXEC)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, pipes[1], 1)
        posix_spawn_file_actions_adddup2(&actions, pipes[1], 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the descriptors above reach the child: never the meter or events sockets.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
                                                     | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)
        var env = environment
        env["COLUMNS"] = String(columns)
        let argv = ([executable] + words).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var child: pid_t = 0
        let status = posix_spawn(&child, executable, &actions, &attributes, argv, envp)
        close(pipes[1])
        guard status == 0 else {
            close(pipes[0])
            return nil
        }
        _ = fcntl(pipes[0], F_SETFL, fcntl(pipes[0], F_GETFL) | O_NONBLOCK)
        pid = child
        fd = pipes[0]
        return pipes[0]
    }

    func stop() {
        guard let pid else { return }
        killpg(pid, SIGTERM)
    }

    /// The exit code once the child is gone (128 + the signal that ended it), nil while it runs.
    func reap() -> Int32? {
        guard let child = pid else { return 0 }
        var status: Int32 = 0
        let result = waitpid(child, &status, WNOHANG)
        guard result == child || result < 0 else { return nil }
        pid = nil
        if let fd { close(fd) }
        fd = nil
        guard result == child else { return 1 }
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }

    /// On the way out: a command still running goes with the TUI.
    func finish() {
        stop()
        if let child = pid {
            var status: Int32 = 0
            waitpid(child, &status, 0)
        }
        if let fd { close(fd) }
        pid = nil
        fd = nil
    }
}
