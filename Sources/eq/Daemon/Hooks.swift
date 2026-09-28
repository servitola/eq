import Foundation

struct HookRun: Equatable {
    var name: String
    var command: String
    var environment: [String: String]
}

/// The `hooks` of `eq.json`, debounced per name: a burst of changes runs a hook once, with the
/// environment of the last one. Not thread-safe; used on the daemon's queue only.
final class Hooks {
    static let known: Set<String> = ["device", "preset"]
    // A device switch is a rebuild or two and its verification, about a second; one run for the settled state.
    static let debounce: TimeInterval = 1

    private let schedule: Debouncer.Schedule
    private let run: (HookRun) -> Void
    private var commands: [String: String] = [:]
    private var pending: [String: [String: String]] = [:]
    private var debouncers: [String: Debouncer] = [:]
    private var loggedUnknown: Set<String> = []

    init(schedule: @escaping Debouncer.Schedule, run: @escaping (HookRun) -> Void) {
        self.schedule = schedule
        self.run = run
    }

    convenience init(queue: DispatchQueue, run: @escaping (HookRun) -> Void) {
        self.init(schedule: { delay, work in queue.asyncAfter(deadline: .now() + delay, execute: work) }, run: run)
    }

    static func unknown(in hooks: [String: String]?) -> [String] {
        (hooks ?? [:]).keys.filter { !known.contains($0) }.sorted()
    }

    func configure(_ hooks: [String: String]?) {
        let unknown = Self.unknown(in: hooks)
        for name in unknown where loggedUnknown.insert(name).inserted {
            Log.write("hooks: ignoring unknown hook \"\(name)\" (known: \(Self.known.sorted().joined(separator: ", ")))")
        }
        loggedUnknown.formIntersection(unknown)
        commands = (hooks ?? [:]).filter { Self.known.contains($0.key) && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    func fire(_ name: String, environment: [String: String]) {
        guard commands[name] != nil else { return }
        pending[name] = environment
        let debouncer = debouncers[name] ?? Debouncer(delay: Self.debounce, schedule: schedule) { [weak self] in self?.flush(name) }
        debouncers[name] = debouncer
        debouncer.trigger()
    }

    // The command is read when the wait ends, so a hook removed meanwhile does not run.
    private func flush(_ name: String) {
        guard let environment = pending.removeValue(forKey: name), let command = commands[name] else { return }
        run(HookRun(name: name, command: command, environment: environment))
    }
}

/// Runs a hook with `/bin/sh -c` in its own process group, so a timeout takes its children down too.
enum HookRunner {
    struct Result: Equatable {
        var status: Int32?
        var timedOut: Bool
        var output: String
        var truncated: Bool
    }

    static let timeout: TimeInterval = 10
    static let outputCap = 4096
    // Hooks run one at a time, off the daemon's queue and far from the audio thread.
    private static let queue = DispatchQueue(label: "eq.hooks", qos: .utility)

    static func live(timeout: TimeInterval = timeout, log: @escaping (String) -> Void = Log.write) -> (HookRun) -> Void {
        { hook in
            queue.async { log(describe(hook.name, run(hook, timeout: timeout))) }
        }
    }

    static func describe(_ name: String, _ result: Result) -> String {
        let verdict: String
        if result.timedOut {
            verdict = "timed out — killed"
        } else if let status = result.status {
            verdict = status == 0 ? "ok" : "exited \(status)"
        } else {
            verdict = "could not start"
        }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return "hook \(name): \(verdict)" + (output.isEmpty ? "" : ": \(output)") + (result.truncated ? " … (output cut at \(outputCap) bytes)" : "")
    }

    static func run(_ hook: HookRun, timeout: TimeInterval = timeout, cap: Int = outputCap) -> Result {
        var pipe: [Int32] = [-1, -1]
        guard Darwin.pipe(&pipe) == 0 else { return Result(status: nil, timedOut: false, output: "pipe: errno \(errno)", truncated: false) }
        let (readEnd, writeEnd) = (pipe[0], pipe[1])
        defer { close(readEnd) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 2)
        posix_spawn_file_actions_addclose(&actions, readEnd)
        posix_spawn_file_actions_addclose(&actions, writeEnd)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        let environment = ProcessInfo.processInfo.environment.merging(hook.environment) { $1 }.map { "\($0.key)=\($0.value)" }
        let argv = ["/bin/sh", "-c", hook.command].map { (arg: String) in strdup(arg) } + [nil]
        let envp = environment.map { (pair: String) in strdup(pair) } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, envp)
        close(writeEnd)
        guard spawned == 0 else {
            return Result(status: nil, timedOut: false, output: String(cString: strerror(spawned)), truncated: false)
        }

        _ = fcntl(readEnd, F_SETFL, fcntl(readEnd, F_GETFL) | O_NONBLOCK)
        var output = Data()
        var truncated = false
        var buffer = [UInt8](repeating: 0, count: 4096)
        // Drained even past the cap: a hook blocked on a full pipe would only ever end by timeout.
        func drain() {
            while true {
                let n = read(readEnd, &buffer, buffer.count)
                guard n > 0 else { return }
                let room = max(cap - output.count, 0)
                output.append(contentsOf: buffer[0..<min(n, room)])
                if n > room { truncated = true }
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var killAt: Date?
        var timedOut = false
        var status: Int32 = 0
        while true {
            var poller = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
            _ = poll(&poller, 1, 50)
            drain()
            // Not waiting for EOF: a child the hook left in the background may hold the pipe for ever.
            if waitpid(pid, &status, WNOHANG) == pid {
                drain()
                break
            }
            if !timedOut, Date() >= deadline {
                timedOut = true
                kill(-pid, SIGTERM)
                killAt = Date().addingTimeInterval(1)
            } else if let at = killAt, Date() >= at {
                kill(-pid, SIGKILL)
                killAt = nil
            }
        }
        let exitStatus: Int32? = (status & 0x7f) == 0 ? (status >> 8) & 0xff : nil
        return Result(status: timedOut ? nil : exitStatus ?? 128 + (status & 0x7f),
                      timedOut: timedOut, output: String(decoding: output, as: UTF8.self), truncated: truncated)
    }
}
