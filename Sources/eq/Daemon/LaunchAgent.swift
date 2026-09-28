import Foundation
import ServiceManagement

/// The daemon's launchd job as `launchctl print` describes it.
struct LoadedJob: Equatable {
    var managedByServiceManagement: Bool
    var path: String?
    var pid: Int32?

    /// Only the job's own top-level `key = value` lines: nested blocks reuse names like `state`.
    static func parse(_ text: String) -> LoadedJob {
        var job = LoadedJob(managedByServiceManagement: false, path: nil, pid: nil)
        for line in text.split(separator: "\n") where line.hasPrefix("\t") && !line.hasPrefix("\t\t") {
            let parts = line.dropFirst().split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "managed_by": job.managedByServiceManagement = parts[1] == "com.apple.xpc.ServiceManagement"
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
    func loadedJob() -> LoadedJob?
    func bootout() throws
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
    /// The same label as the hand-installed plist: launchd refuses a second job under a loaded
    /// label, so the two can never both start a daemon, and every `launchctl kickstart
    /// gui/$UID/com.servitola.eq` hint works whichever one is in use.
    static let label = "com.servitola.eq"
    static let plistName = "\(label).plist"
    static let loginItemName = "EQ"
    static let approvalHint = "System Settings → General → Login Items → allow \(loginItemName)"
    static let permissionPrompt = "allow System Audio Recording when macOS asks"

    static func launcher(_ agent: LaunchAgentControl) -> Launcher {
        if let job = agent.loadedJob() {
            return job.managedByServiceManagement
                ? .bundled(loaded: true)
                : .legacy(path: job.path ?? agent.legacyPlist.path, loaded: true)
        }
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

    /// What a CLI command does about a daemon that is not running: register the bundled agent
    /// when nothing else launches eq, otherwise leave launchd alone. Never throws: a command
    /// must not fail because the daemon could not be started.
    static func ensureRunning(_ agent: LaunchAgentControl, daemonAlive: Bool) -> Note? {
        guard !daemonAlive, agent.loadedJob() == nil, !agent.legacyPlistExists() else { return nil }
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
        let job = agent.loadedJob()
        let legacyLoaded = job.map { !$0.managedByServiceManagement } ?? false
        if legacyLoaded || agent.legacyPlistExists() {
            let path = job?.path ?? agent.legacyPlist.path
            guard replaceLegacy else { throw CLIError.legacyAgent(path) }
            if legacyLoaded { try agent.bootout() }
            if agent.legacyPlistExists() { setAside = try agent.setAsideLegacyPlist() }
        }
        switch agent.serviceStatus {
        case .notRegistered:
            try register(agent)
            return .started(setAside: setAside)
        case .enabled:
            if !legacyLoaded, job != nil { return .alreadyRunning }
            // Registered but not in launchd — booted out by hand, or refused a second job under
            // the legacy label: only unregistering lets launchd take it again.
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
    private var target: String { "gui/\(getuid())/\(LaunchAgent.label)" }

    var serviceStatus: AgentServiceStatus {
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }

    func loadedJob() -> LoadedJob? {
        guard let output = launchctl(["print", target]), output.status == 0 else { return nil }
        return LoadedJob.parse(output.text)
    }

    func bootout() throws {
        guard let output = launchctl(["bootout", target]), output.status == 0 else {
            throw CLIError.agent("launchctl bootout \(target) failed")
        }
    }

    var legacyPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(LaunchAgent.plistName)")
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
    /// run (EQ_CONFIG, EQ_STATUS — the smoke test) must not register a login item.
    static func autoStarts(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard ["EQ_CONFIG", "EQ_STATUS"].allSatisfy({ (environment[$0] ?? "").isEmpty }) else { return false }
        let bundle = Bundle.main.bundleURL
        return bundle.pathExtension == "app" && bundle.deletingLastPathComponent().lastPathComponent == "Applications"
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
