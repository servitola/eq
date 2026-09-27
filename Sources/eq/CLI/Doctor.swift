import Darwin
import Foundation

struct DoctorProbes {
    var osVersion: () -> OperatingSystemVersion
    var loadConfig: () throws -> Config
    var readStatus: () -> Status?
    var launchAgentLoaded: () -> Bool
    var executablePath: (pid_t) -> String?
    var signalStatus: (pid_t) -> Bool
    var sleep: (TimeInterval) -> Void
    var smoke: Bool

    static func live(store: ConfigStore, statusURL: URL) -> DoctorProbes {
        DoctorProbes(
            osVersion: { ProcessInfo.processInfo.operatingSystemVersion },
            loadConfig: {
                guard store.exists() else { throw CLIError.usage("no config at \(store.url.path) — run `eq init` first") }
                return try store.load()
            },
            readStatus: { Status.read(from: statusURL) },
            launchAgentLoaded: {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                process.arguments = ["print", "gui/\(getuid())/com.servitola.eq"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    return process.terminationStatus == 0
                } catch {
                    return false
                }
            },
            executablePath: { pid in
                var buffer = [Int8](repeating: 0, count: 4096)
                let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
                guard length > 0 else { return nil }
                return String(cString: buffer)
            },
            signalStatus: { kill($0, SIGUSR1) == 0 },
            sleep: { Thread.sleep(forTimeInterval: $0) },
            smoke: ProcessInfo.processInfo.environment["EQ_SMOKE"] == "1")
    }
}

struct DoctorCheck: Encodable, Equatable {
    var name: String
    var ok: Bool
    var detail: String
    var warning: Bool
}

struct DoctorReport: Encodable {
    var ok: Bool
    var checks: [DoctorCheck]
}

enum Doctor {
    static func run(_ probes: DoctorProbes) -> DoctorReport {
        let status = probes.readStatus()
        let live = status.flatMap { $0.isAlive() ? $0 : nil }
        let checks = [
            macOSCheck(probes),
            configCheck(probes),
            daemonCheck(live),
            permissionCheck(live),
            launchAgentCheck(probes),
            binaryCheck(probes, live),
            audioCheck(probes, live),
            engineCheck(live),
        ]
        let ok = checks.allSatisfy { $0.warning || $0.ok }
        return DoctorReport(ok: ok, checks: checks)
    }

    static func text(_ report: DoctorReport) -> String {
        var lines = report.checks.map { check -> String in
            let symbol = check.warning ? Paint.ink(.yellow, "!") : (check.ok ? Paint.ink(.green, "✓") : Paint.ink(.red, "✗"))
            return "\(symbol) \(check.name) — \(check.detail)"
        }
        lines.append(report.ok ? Paint.ink(.green, "ok") : Paint.ink(.red, "problems found"))
        return lines.joined(separator: "\n")
    }

    private static func macOSCheck(_ probes: DoctorProbes) -> DoctorCheck {
        let v = probes.osVersion()
        let ok = v.majorVersion > 14 || (v.majorVersion == 14 && v.minorVersion >= 4)
        let version = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        return DoctorCheck(name: "macOS", ok: ok, detail: ok ? version : "\(version) — need 14.4+", warning: false)
    }

    private static func configCheck(_ probes: DoctorProbes) -> DoctorCheck {
        do {
            _ = try probes.loadConfig()
            return DoctorCheck(name: "config", ok: true, detail: "ok", warning: false)
        } catch {
            return DoctorCheck(name: "config", ok: false, detail: "\(error)", warning: false)
        }
    }

    private static func daemonCheck(_ live: Status?) -> DoctorCheck {
        guard let live else {
            return DoctorCheck(name: "daemon", ok: false,
                                detail: "not running — launchctl kickstart -k gui/$UID/com.servitola.eq", warning: false)
        }
        return DoctorCheck(name: "daemon", ok: true, detail: "running, pid \(live.pid), \(live.version.map { "v\($0)" } ?? "pre-v3")", warning: false)
    }

    private static func permissionCheck(_ live: Status?) -> DoctorCheck {
        guard let live else {
            return DoctorCheck(name: "permission", ok: false, detail: "daemon not running", warning: false)
        }
        guard live.state == .noPermission else {
            return DoctorCheck(name: "permission", ok: true, detail: "granted", warning: false)
        }
        return DoctorCheck(name: "permission", ok: false, detail: CLI.permissionHint, warning: false)
    }

    private static func launchAgentCheck(_ probes: DoctorProbes) -> DoctorCheck {
        if probes.smoke {
            return DoctorCheck(name: "launch agent", ok: true, detail: "skipped (EQ_SMOKE)", warning: false)
        }
        guard probes.launchAgentLoaded() else {
            return DoctorCheck(name: "launch agent", ok: false,
                                detail: "not loaded — launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.servitola.eq.plist", warning: false)
        }
        return DoctorCheck(name: "launch agent", ok: true, detail: "loaded", warning: false)
    }

    private static func binaryCheck(_ probes: DoctorProbes, _ live: Status?) -> DoctorCheck {
        guard let live, let path = probes.executablePath(live.pid) else {
            return DoctorCheck(name: "binary", ok: false, detail: "daemon pid unknown", warning: false)
        }
        guard path.hasPrefix("/Applications/EQ.app/") else {
            return DoctorCheck(name: "binary", ok: false, detail: path, warning: true)
        }
        return DoctorCheck(name: "binary", ok: true, detail: path, warning: false)
    }

    private static func audioCheck(_ probes: DoctorProbes, _ live: Status?) -> DoctorCheck {
        guard let live else {
            return DoctorCheck(name: "audio", ok: true, detail: "skipped (daemon not running)", warning: false)
        }
        guard live.state == .running else {
            return DoctorCheck(name: "audio", ok: true, detail: "skipped (state: \(live.state.rawValue))", warning: false)
        }
        let s0 = live
        // Only v3 daemons write `version`, and only v3 has the SIGUSR1 handler — the default action would kill an older one.
        guard let daemonVersion = s0.version else {
            return DoctorCheck(name: "audio", ok: false,
                               detail: "daemon runs a pre-v3 build, this eq is \(Build.version)"
                                   + " — restart it: launchctl kickstart -k gui/$UID/com.servitola.eq",
                               warning: true)
        }
        guard probes.executablePath(s0.pid)?.hasSuffix("/eq") == true else {
            return DoctorCheck(name: "audio", ok: false, detail: "pid \(s0.pid) is not an eq daemon — status file is stale", warning: true)
        }
        guard probes.signalStatus(s0.pid) else {
            return DoctorCheck(name: "audio", ok: false, detail: "could not signal the daemon", warning: true)
        }
        guard let s1 = freshStatus(probes, after: s0.writes) else {
            return DoctorCheck(name: "audio", ok: false, detail: staleAfterSignalDetail, warning: true)
        }
        probes.sleep(1)
        _ = probes.signalStatus(s1.pid)
        guard let s2 = freshStatus(probes, after: s1.writes) else {
            return DoctorCheck(name: "audio", ok: false, detail: staleAfterSignalDetail, warning: true)
        }
        let before = s1.callbacks, after = s2.callbacks
        if before == 0 && after == 0 {
            return DoctorCheck(name: "audio", ok: false,
                               detail: "no IO callbacks — if the daemon predates v2, restart it: launchctl kickstart -k gui/$UID/com.servitola.eq",
                               warning: true)
        }
        guard after > before else {
            return DoctorCheck(name: "audio", ok: false, detail: "no IO callbacks in 1 s — is the device asleep?", warning: true)
        }
        let detail = "callbacks \(before) → \(after)"
        guard daemonVersion == Build.version else {
            return DoctorCheck(name: "audio", ok: false,
                               detail: detail + " (daemon v\(daemonVersion), this eq v\(Build.version)"
                                   + " — restart it: launchctl kickstart -k gui/$UID/com.servitola.eq)",
                               warning: true)
        }
        return DoctorCheck(name: "audio", ok: true, detail: detail, warning: false)
    }

    private static let staleAfterSignalDetail =
        "status not refreshed after SIGUSR1 — daemon predates v3? restart it: launchctl kickstart -k gui/$UID/com.servitola.eq"

    // SIGUSR1 makes the daemon rewrite immediately, so a 2 s / 0.1 s poll is enough —
    // no more waiting out the heartbeat.
    private static func freshStatus(_ probes: DoctorProbes, after: UInt64) -> Status? {
        for _ in 0..<20 {
            probes.sleep(0.1)
            guard let next = probes.readStatus() else { return nil }
            if next.writes > after { return next }
        }
        return nil
    }

    private static func engineCheck(_ live: Status?) -> DoctorCheck {
        guard let live else {
            return DoctorCheck(name: "engine", ok: false, detail: "daemon not running", warning: false)
        }
        guard live.state == .running || live.state == .bypassed else {
            let detail = live.error.map { "\(live.state.rawValue): \($0)" } ?? live.state.rawValue
            return DoctorCheck(name: "engine", ok: false, detail: detail, warning: false)
        }
        return DoctorCheck(name: "engine", ok: true, detail: live.state.rawValue, warning: false)
    }
}
