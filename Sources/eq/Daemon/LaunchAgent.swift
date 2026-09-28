import Foundation
import ServiceManagement

/// The daemon's launchd job as `launchctl print` describes it.
struct LoadedJob: Equatable {
    var path: String?
    var pid: Int32?

    /// Only the job's own top-level `key = value` lines: nested blocks reuse names like `state`.
    static func parse(_ text: String) -> LoadedJob {
        var job = LoadedJob(path: nil, pid: nil)
        for line in text.split(separator: "\n") where line.hasPrefix("\t") && !line.hasPrefix("\t\t") {
            let parts = line.dropFirst().split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "path": job.path = parts[1].hasPrefix("/") ? parts[1] : nil
            case "pid": job.pid = Int32(parts[1])
            default: break
            }
        }
        return job
    }
}

enum AgentServiceStatus: String, Encodable {
    case notRegistered, enabled, requiresApproval, notFound
}

/// Everything eq asks of launchd and ServiceManagement, so tests never register or boot out
/// anything real.
protocol LaunchAgentControl {
    var serviceStatus: AgentServiceStatus { get }
    func register() throws
    func unregister() throws
    func loadedJob(_ label: String) -> LoadedJob?
    func bootout(_ label: String) throws
    var legacyPlist: URL { get }
    func legacyPlistExists() -> Bool
    /// Moves the hand-installed plist out of `~/Library/LaunchAgents` and says where it went.
    func setAsideLegacyPlist() throws -> URL
    var bundlePath: String? { get }
}

enum Launcher: Equatable, Encodable {
    case bundled(loaded: Bool)
    case legacy(path: String, loaded: Bool)
    case needsApproval
    case notRegistered
    case unavailable

    var name: String {
        switch self {
        case .bundled: return "bundled"
        case .legacy: return "legacy"
        case .needsApproval: return "needs-approval"
        case .notRegistered: return "none"
        case .unavailable: return "unavailable"
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }
}

enum LaunchAgent {
    /// Not the hand-installed plist's label: background task management keeps a label a legacy
    /// user agent once had, and SMAppService.register() refuses it with "Operation not
    /// permitted" (SMAppServiceErrorDomain 1). With two labels launchd no longer keeps the two
    /// apart, so nothing registers this one while the legacy job or its plist is there.
    static let label = "com.servitola.eq.daemon"
    static let plistName = "\(label).plist"
    static let legacyLabel = "com.servitola.eq"
    static let legacyPlistName = "\(legacyLabel).plist"
    static let restartHint = "launchctl kickstart -k gui/$UID/\(label)"
    static let loginItemName = "EQ"
    static let approvalHint = "System Settings → General → Login Items → allow \(loginItemName)"
    static let permissionPrompt = "allow System Audio Recording when macOS asks"

    static func launcher(_ agent: LaunchAgentControl) -> Launcher {
        if let legacy = agent.loadedJob(legacyLabel) { return .legacy(path: legacy.path ?? agent.legacyPlist.path, loaded: true) }
        if agent.loadedJob(label) != nil { return .bundled(loaded: true) }
        switch agent.serviceStatus {
        case .enabled: return .bundled(loaded: false)
        case .requiresApproval: return .needsApproval
        case .notRegistered, .notFound:
            if agent.legacyPlistExists() { return .legacy(path: agent.legacyPlist.path, loaded: false) }
            return agent.serviceStatus == .notFound ? .unavailable : .notRegistered
        }
    }

    /// The doctor row and the first line of `eq agent status`.
    static func summary(_ launcher: Launcher) -> (ok: Bool, detail: String) {
        switch launcher {
        case .bundled(loaded: true):
            return (true, "bundled (login item \"\(loginItemName)\")")
        case .bundled(loaded: false):
            return (false, "bundled login item registered but not loaded — eq agent install")
        case .legacy(let path, loaded: true):
            return (true, "legacy \(abbreviate(path)) — to switch to the bundled login item: eq agent install --replace-legacy")
        case .legacy(let path, loaded: false):
            return (false, "legacy \(abbreviate(path)) not loaded — launchctl bootstrap gui/$UID \(abbreviate(path)), "
                + "or switch to the bundled login item: eq agent install --replace-legacy")
        case .needsApproval:
            return (false, "waiting for approval — \(approvalHint)")
        case .notRegistered:
            return (false, "not registered — eq agent install")
        case .unavailable:
            return (false, "this build carries no LaunchAgent — use the installed EQ.app")
        }
    }

    enum Note: Equatable {
        case started
        case needsApproval
        case failed(String)
    }

    static func legacyInUse(_ agent: LaunchAgentControl) -> Bool {
        agent.legacyPlistExists() || agent.loadedJob(legacyLabel) != nil
    }

    /// EQ_LAUNCHER comes from the bundled plist. The CLI never registers it beside the legacy job,
    /// but a registration from before the legacy plist came back still starts at login.
    static func bundledDaemonYields(environment: [String: String], agent: LaunchAgentControl) -> Bool {
        environment["EQ_LAUNCHER"] == "bundled" && legacyInUse(agent)
    }

    /// The file `eq agent uninstall` leaves so later commands do not register the agent again.
    static let optOutName = "agent-off"

    /// What a CLI command does about a daemon that is not running: register the bundled agent
    /// when nothing else launches eq and the user has not turned it off, otherwise leave launchd
    /// alone. A registration launchd no longer holds (`.enabled`, not loaded) is left too: that is
    /// a job booted out on purpose, and a crashed daemon is KeepAlive's to restart. Never throws: a
    /// command must not fail because the daemon could not be started.
    static func ensureRunning(_ agent: LaunchAgentControl, daemonAlive: Bool, optedOut: Bool) -> Note? {
        guard !daemonAlive, !optedOut, agent.loadedJob(label) == nil, !legacyInUse(agent) else { return nil }
        switch agent.serviceStatus {
        case .notRegistered:
            do {
                try agent.register()
                return .started
            } catch {
                return .failed(describe(error))
            }
        case .requiresApproval: return .needsApproval
        case .enabled, .notFound: return nil
        }
    }

    static func text(_ note: Note, paint: Bool) -> String {
        switch note {
        case .started:
            return Paint.ink(.dim, "started the eq daemon (login item \"\(loginItemName)\") — \(permissionPrompt)", on: paint)
        case .needsApproval:
            return Paint.ink(.yellow, "the eq daemon is waiting for approval: \(approvalHint)", on: paint)
        case .failed(let why):
            return Paint.ink(.yellow, "could not start the eq daemon (\(why)) — see eq doctor", on: paint)
        }
    }

    enum InstallResult: Equatable {
        case alreadyRunning
        case started(setAside: URL?)
        case restarted(setAside: URL?)
    }

    static func install(_ agent: LaunchAgentControl, replaceLegacy: Bool) throws -> InstallResult {
        var setAside: URL?
        var bootedOut = false
        let legacyJob = agent.loadedJob(legacyLabel)
        let legacyPath = legacyJob?.path ?? agent.legacyPlist.path
        do {
            if legacyJob != nil || agent.legacyPlistExists() {
                guard replaceLegacy else { throw CLIError.legacyAgent(legacyPath) }
                if legacyJob != nil { try agent.bootout(legacyLabel); bootedOut = true }
                if agent.legacyPlistExists() { setAside = try agent.setAsideLegacyPlist() }
            }
            return try registerBundled(agent, setAside: setAside)
        } catch {
            let why = reason(error)
            if let setAside {
                throw CLIError.agent("\(why); the legacy plist is in \(abbreviate(setAside.path)) — to go back, Put Back in Finder, "
                    + "then: launchctl bootstrap gui/$UID \(abbreviate(agent.legacyPlist.path))")
            }
            if bootedOut {
                throw CLIError.agent("\(why); the legacy job was booted out — to go back: launchctl bootstrap gui/$UID \(abbreviate(legacyPath))")
            }
            throw error
        }
    }

    private static func registerBundled(_ agent: LaunchAgentControl, setAside: URL?) throws -> InstallResult {
        switch agent.serviceStatus {
        case .notRegistered:
            try register(agent)
            return .started(setAside: setAside)
        case .enabled:
            if agent.loadedJob(label) != nil { return .alreadyRunning }
            // Registered but not in launchd — booted out by hand: only unregistering lets
            // launchd take it again.
            try? agent.unregister()
            try register(agent)
            return .restarted(setAside: setAside)
        case .requiresApproval: throw CLIError.agent("waiting for approval: \(approvalHint)")
        case .notFound: throw CLIError.agent("no \(plistName) in \(agent.bundlePath ?? "this build") — run the installed EQ.app's eq")
        }
    }

    /// True when there was something to unregister. The legacy plist is never touched.
    static func uninstall(_ agent: LaunchAgentControl) throws -> Bool {
        switch agent.serviceStatus {
        case .enabled, .requiresApproval:
            do { try agent.unregister() } catch { throw CLIError.agent(describe(error)) }
            return true
        case .notRegistered, .notFound:
            return false
        }
    }

    private static func register(_ agent: LaunchAgentControl) throws {
        do { try agent.register() } catch {
            if agent.serviceStatus == .requiresApproval { throw CLIError.agent("waiting for approval: \(approvalHint)") }
            throw CLIError.agent(describe(error))
        }
    }

    private static func reason(_ error: Error) -> String {
        if case CLIError.agent(let why) = error { return why }
        return describe(error)
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return ns.localizedDescription + (ns.domain == NSOSStatusErrorDomain || ns.domain == "SMAppServiceErrorDomain" ? " (\(ns.code))" : "")
    }

    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

final class LiveLaunchAgent: LaunchAgentControl {
    private var service: SMAppService { SMAppService.agent(plistName: LaunchAgent.plistName) }
    private func target(_ label: String) -> String { "gui/\(getuid())/\(label)" }

    var serviceStatus: AgentServiceStatus {
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/\(LaunchAgent.plistName)")
        return Self.status(service.status, plistShipped: FileManager.default.fileExists(atPath: plist.path))
    }

    /// An agent that was never registered reports `.notFound` on macOS 26 (seen on a fresh
    /// install), not `.notRegistered`; only a missing plist means there is nothing to register.
    static func status(_ status: SMAppService.Status, plistShipped: Bool) -> AgentServiceStatus {
        switch status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return plistShipped ? .notRegistered : .notFound
        @unknown default: return plistShipped ? .notRegistered : .notFound
        }
    }

    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }

    func loadedJob(_ label: String) -> LoadedJob? {
        guard let output = launchctl(["print", target(label)]), output.status == 0 else { return nil }
        return LoadedJob.parse(output.text)
    }

    func bootout(_ label: String) throws {
        guard let output = launchctl(["bootout", target(label)]), output.status == 0 else {
            throw CLIError.agent("launchctl bootout \(target(label)) failed")
        }
    }

    var legacyPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(LaunchAgent.legacyPlistName)")
    }

    func legacyPlistExists() -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: legacyPlist.path)) != nil
    }

    /// To the Trash rather than renamed in place: nothing left in the folder launchd reads at
    /// login, and Finder's Put Back restores it.
    func setAsideLegacyPlist() throws -> URL {
        var moved: NSURL?
        try FileManager.default.trashItem(at: legacyPlist, resultingItemURL: &moved)
        return (moved as URL?) ?? legacyPlist
    }

    var bundlePath: String? {
        Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundlePath : nil
    }

    /// Only an installed EQ.app starts its own daemon: a build in a checkout or a sandboxed
    /// run (EQ_CONFIG, EQ_STATUS — the smoke test) must not register a login item, and root
    /// (sudo eq) has no login session of its own to register one in.
    static func autoStarts(environment: [String: String] = ProcessInfo.processInfo.environment,
                           bundle: URL = Bundle.main.bundleURL, uid: uid_t = getuid()) -> Bool {
        guard uid != 0, ["EQ_CONFIG", "EQ_STATUS"].allSatisfy({ (environment[$0] ?? "").isEmpty }) else { return false }
        return bundle.pathExtension == "app" && bundle.deletingLastPathComponent().lastPathComponent == "Applications"
    }

    /// Bundle.main is looked up beside the path as invoked, and brew's eq is a symlink into EQ.app:
    /// SMAppService would search the symlink's folder for the LaunchAgent. realpath(3), not
    /// resolvingSymlinksInPath, which turns /private/var into /var and would re-exec every run there.
    static func realExecutable(invoked: String) -> String? {
        guard let resolved = realpath(invoked, nil) else { return nil }
        defer { free(resolved) }
        let real = String(cString: resolved)
        return real != invoked && real.hasSuffix(".app/Contents/MacOS/eq") ? real : nil
    }

    private func launchctl(_ arguments: [String]) -> (status: Int32, text: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
