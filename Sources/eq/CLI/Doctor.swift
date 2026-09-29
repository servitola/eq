import Darwin
import Foundation

struct DefaultOutput: Equatable {
    var name: String
    /// nil means the stream-count property itself could not be read — distinct from a device
    /// that legitimately reports zero streams (e.g. a Multi-Output Device with no members).
    var streams: Int?
    var channels: Int
}

struct DoctorProbes {
    var osVersion: () -> OperatingSystemVersion
    var loadConfig: () throws -> Config
    var configFileExists: () -> Bool = { true }
    var readStatus: () -> Status?
    var defaultOutput: () -> DefaultOutput?
    var launcher: () -> Launcher
    var executablePath: (pid_t) -> String?
    var signalStatus: (pid_t) -> Bool
    var sleep: (TimeInterval) -> Void
    var smoke: Bool
    var driver: () -> DriverPort? = { nil }
    var defaultOutputUID: () -> String? = { nil }
    var driverFiles: () -> DriverFiles = { DriverFiles() }

    static func live(store: ConfigStore, statusURL: URL) -> DoctorProbes {
        DoctorProbes(
            osVersion: { ProcessInfo.processInfo.operatingSystemVersion },
            loadConfig: { try store.loadOrDefault { nil } },
            configFileExists: store.exists,
            readStatus: { Status.read(from: statusURL) },
            defaultOutput: {
                guard let id = AudioDeviceManager.defaultOutputDeviceID() else { return nil }
                return DefaultOutput(name: AudioDeviceManager.device(id)?.name ?? "device \(id)",
                                     streams: AudioDeviceManager.outputStreamCount(id),
                                     channels: AudioDeviceManager.outputChannelCount(id))
            },
            launcher: { LaunchAgent.launcher(LiveLaunchAgent()) },
            executablePath: { pid in
                var buffer = [Int8](repeating: 0, count: 4096)
                let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
                guard length > 0 else { return nil }
                return String(cString: buffer)
            },
            signalStatus: { kill($0, SIGUSR1) == 0 },
            sleep: { Thread.sleep(forTimeInterval: $0) },
            smoke: ProcessInfo.processInfo.environment["EQ_SMOKE"] == "1",
            driver: { DriverControl.find() },
            defaultOutputUID: { AudioDeviceManager.defaultOutputDeviceID().flatMap(AudioDeviceManager.device)?.uid },
            driverFiles: { DriverFiles.live() })
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
        let (audio, refreshed) = audioCheck(probes, live)
        let config = try? probes.loadConfig()
        let apps = config.flatMap { $0.followsApps ? appsCheck($0, live) : nil }
        let checks = [
            macOSCheck(probes),
            configCheck(probes),
            hooksCheck(probes),
        ] + [apps].compactMap { $0 } + [
            outputCheck(probes),
            daemonCheck(live),
            permissionCheck(live),
            launchAgentCheck(probes),
            binaryCheck(probes, live),
            audio,
            engineCheck(live),
            tapCheck(refreshed),
            latencyCheck(refreshed),
            ringCheck(refreshed),
            filtersCheck(live),
        ] + driverChecks(probes, mode: config?.audioMode ?? .tap, hidesWhileDefault: config?.hidesWhileDefault == true, live: live)
        let ok = checks.allSatisfy { $0.warning || $0.ok }
        return DoctorReport(ok: ok, checks: checks)
    }

    static func text(_ report: DoctorReport) -> String {
        var lines = report.checks.map { check -> String in
            let symbol = check.warning ? Paint.ink(.yellow, "!") : (check.ok ? Paint.ink(.green, "✓") : Paint.ink(.red, "✗"))
            return "\(symbol) \(Paint.ink(.bold, check.name)) — \(check.detail)"
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
            return configCheck(try probes.loadConfig(), fileExists: probes.configFileExists())
        } catch {
            return DoctorCheck(name: "config", ok: false, detail: "\(error)", warning: false)
        }
    }

    static func configCheck(_ config: Config, fileExists: Bool) -> DoctorCheck {
        let profiles = [("default", config.default)] + config.devices.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            + (config.presets ?? [:]).sorted { $0.key < $1.key }.map { ("preset \($0.key)", $0.value) }
        let problems = profiles.flatMap { key, profile in (profile.dynamics?.unknown ?? []).map { "\(key): no \($0) — ignored" } }
        guard problems.isEmpty else {
            return DoctorCheck(name: "config", ok: false, detail: problems.joined(separator: "; "), warning: true)
        }
        return DoctorCheck(name: "config", ok: true, detail: fileExists ? "ok" : "defaults (no file yet)", warning: false)
    }

    private static func hooksCheck(_ probes: DoctorProbes) -> DoctorCheck {
        guard let hooks = (try? probes.loadConfig())?.hooks, !hooks.isEmpty else {
            return DoctorCheck(name: "hooks", ok: true, detail: "none", warning: false)
        }
        var problems = Hooks.unknown(in: hooks).map { "unknown hook \"\($0)\" is ignored" }
        for (name, command) in hooks.sorted(by: { $0.key < $1.key }) where Hooks.known.contains(name) {
            guard let program = program(of: command), program.hasPrefix("/") else { continue }
            if !FileManager.default.fileExists(atPath: program) {
                problems.append("\(name): \(program) does not exist")
            } else if !FileManager.default.isExecutableFile(atPath: program) {
                problems.append("\(name): \(program) is not executable")
            }
        }
        guard problems.isEmpty else {
            return DoctorCheck(name: "hooks", ok: false, detail: problems.joined(separator: "; "), warning: true)
        }
        return DoctorCheck(name: "hooks", ok: true, detail: hooks.keys.sorted().joined(separator: ", "), warning: false)
    }

    /// Present only while `experimental.apps` is on.
    static func appsCheck(_ config: Config, _ live: Status?, now: Date = Date()) -> DoctorCheck {
        let rules = config.apps ?? []
        var problems = rules.filter { config.preset(named: $0.preset) == nil }.map { "\($0.app): no preset \"\($0.preset)\"" }
        if rules.isEmpty { problems.append("on, but no rules — eq app set <app> <preset>") }
        let detail: String
        if let live {
            if let apps = live.apps {
                if !apps.listening { problems.append("the daemon cannot listen for playing apps") }
                let count = "\(rules.count) rule\(rules.count == 1 ? "" : "s")"
                if let heard = apps.overlay {
                    detail = "listening, \(count); heard now: \(heard.label)"
                } else if let last = apps.lastMatch, let at = apps.lastMatchAt {
                    detail = "listening, \(count); last match \(last.label) \(Table.whole(now.timeIntervalSince(at) / 60)) min ago"
                } else {
                    detail = "listening, \(count); no match yet"
                }
            } else {
                problems.append("the daemon does not follow apps — restart it: " + LaunchAgent.restartHint)
                detail = "on"
            }
        } else {
            detail = "on; daemon not running"
        }
        guard problems.isEmpty else {
            return DoctorCheck(name: "apps", ok: false, detail: ([detail] + problems).joined(separator: "; "), warning: true)
        }
        return DoctorCheck(name: "apps", ok: true, detail: detail, warning: false)
    }

    /// The command's first word, unquoted; nil when it is empty. Only an absolute path can be
    /// checked: anything else is a builtin or found on the hook's own PATH.
    static func program(of command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return nil }
        if first == "\"" || first == "'" {
            let rest = trimmed.dropFirst()
            return String(rest.prefix { $0 != first })
        }
        return String(trimmed.prefix { !$0.isWhitespace })
    }

    private static func outputCheck(_ probes: DoctorProbes) -> DoctorCheck {
        guard let output = probes.defaultOutput() else {
            return DoctorCheck(name: "output", ok: false, detail: "no default output device", warning: false)
        }
        guard let streams = output.streams else {
            return DoctorCheck(name: "output", ok: false, detail: "could not read the output's streams", warning: true)
        }
        guard streams > 0, output.channels > 0 else {
            return DoctorCheck(name: "output", ok: false,
                               detail: "\"\(output.name)\" has no output streams — a Multi-Output Device with no members?"
                                   + " Pick a real output in System Settings → Sound",
                               warning: false)
        }
        return DoctorCheck(name: "output", ok: true, detail: "\(output.name), \(output.channels) ch", warning: false)
    }

    static let tapSilenceLimit: TimeInterval = 30

    private static func tapCheck(_ live: Status?) -> DoctorCheck {
        if live?.mode == .driver { return DoctorCheck(name: "tap", ok: true, detail: "skipped (driver mode)", warning: false) }
        guard let live, live.state == .running || live.state == .bypassed else {
            return DoctorCheck(name: "tap", ok: true, detail: "skipped (engine not running)", warning: false)
        }
        guard let silent = live.tapSilentSeconds else {
            return DoctorCheck(name: "tap", ok: true, detail: "skipped (daemon does not report it)", warning: false)
        }
        guard silent > tapSilenceLimit else {
            return DoctorCheck(name: "tap", ok: true, detail: silent < 1 ? "audio arriving" : "silent for \(Table.whole(silent)) s", warning: false)
        }
        return DoctorCheck(name: "tap", ok: false,
                           detail: "no audio reached the tap for \(Table.whole(silent)) s — if something is playing, check System Audio Recording permission",
                           warning: true)
    }

    /// eq delays sound behind picture, and no player compensates for it. ATSC IS-191 allows sound to
    /// lag by at most 45 ms end to end (EBU R37: 60 ms; its 40 ms is the limit for sound leading).
    static let addedLatencyLimitMs = 45.0

    static func latencyCheck(_ live: Status?) -> DoctorCheck {
        guard let live, live.state == .running || live.state == .bypassed else {
            return DoctorCheck(name: "latency", ok: true, detail: "skipped (engine not running)", warning: false)
        }
        if live.mode == .driver {
            // Players compensate for what a device reports, so in driver mode nothing trails the picture.
            let detail = live.driver?.latencyMs.map { "the EQ device reports \(Table.whole($0)) ms, which players compensate for" } ?? "skipped (not reported yet)"
            return DoctorCheck(name: "latency", ok: true, detail: detail, warning: false)
        }
        guard let added = live.addedLatencyMs else {
            return DoctorCheck(name: "latency", ok: true, detail: "skipped (not measured yet)", warning: false)
        }
        let detail = "eq adds \(Table.whole(added)) ms"
        guard added > addedLatencyLimitMs else {
            return DoctorCheck(name: "latency", ok: true, detail: detail, warning: false)
        }
        return DoctorCheck(name: "latency", ok: false,
                           detail: detail + " — video players do not compensate for it, so sound trails lips past the \(Table.whole(addedLatencyLimitMs)) ms that viewers notice",
                           warning: true)
    }

    static func ringCheck(_ live: Status?) -> DoctorCheck {
        if live?.mode == .driver { return DoctorCheck(name: "ring", ok: true, detail: "skipped (driver mode: see driver slips)", warning: false) }
        guard let live, live.state == .running || live.state == .bypassed else {
            return DoctorCheck(name: "ring", ok: true, detail: "skipped (engine not running)", warning: false)
        }
        guard live.underruns != nil else {
            return DoctorCheck(name: "ring", ok: true, detail: "skipped (not reported by this daemon)", warning: false)
        }
        guard let counts = CLI.ringCounts(live) else {
            return DoctorCheck(name: "ring", ok: true, detail: "no slips", warning: false)
        }
        return DoctorCheck(name: "ring", ok: false,
                           detail: counts + " — the tap and the output slipped, audio had gaps; the daemon rebuilds the engine if it keeps happening",
                           warning: true)
    }

    private static func filtersCheck(_ live: Status?) -> DoctorCheck {
        guard let live else {
            return DoctorCheck(name: "filters", ok: true, detail: "skipped (daemon not running)", warning: false)
        }
        guard live.state == .running || live.state == .bypassed else {
            return DoctorCheck(name: "filters", ok: true, detail: "skipped (engine not running)", warning: false)
        }
        guard let warnings = live.warnings else {
            return DoctorCheck(name: "filters", ok: true, detail: "skipped (daemon does not report it)", warning: false)
        }
        guard !warnings.isEmpty else {
            return DoctorCheck(name: "filters", ok: true, detail: "stable at \(Table.whole(live.sampleRate)) Hz", warning: false)
        }
        return DoctorCheck(name: "filters", ok: false,
                           detail: warnings.joined(separator: "; ") + " — raise its frequency to use it at this rate",
                           warning: true)
    }

    private static func daemonCheck(_ live: Status?) -> DoctorCheck {
        guard let live else {
            return DoctorCheck(name: "daemon", ok: false,
                                detail: "not running — " + LaunchAgent.restartHint, warning: false)
        }
        return DoctorCheck(name: "daemon", ok: true, detail: "running, pid \(live.pid), \(live.version.map { "v\($0)" } ?? "pre-v3")", warning: false)
    }

    private static func permissionCheck(_ live: Status?) -> DoctorCheck {
        guard let live else {
            return DoctorCheck(name: "permission", ok: false, detail: "daemon not running", warning: false)
        }
        if live.mode == .driver { return DoctorCheck(name: "permission", ok: true, detail: "not needed (driver mode)", warning: false) }
        guard live.state == .noPermission else {
            return DoctorCheck(name: "permission", ok: true, detail: "granted", warning: false)
        }
        return DoctorCheck(name: "permission", ok: false, detail: CLI.permissionHint, warning: false)
    }

    private static func launchAgentCheck(_ probes: DoctorProbes) -> DoctorCheck {
        if probes.smoke {
            return DoctorCheck(name: "launch agent", ok: true, detail: "skipped (EQ_SMOKE)", warning: false)
        }
        let summary = LaunchAgent.summary(probes.launcher())
        return DoctorCheck(name: "launch agent", ok: summary.ok, detail: summary.detail, warning: false)
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

    /// Returns the audio row plus the freshest status this check managed to read — used by
    /// `tapCheck` so a silence clock reading right after the SIGUSR1 refresh isn't stale by a
    /// full heartbeat interval. Falls back to `live` at whichever step stops making progress.
    private static func audioCheck(_ probes: DoctorProbes, _ live: Status?) -> (DoctorCheck, Status?) {
        guard let live else {
            return (DoctorCheck(name: "audio", ok: true, detail: "skipped (daemon not running)", warning: false), live)
        }
        guard live.state == .running else {
            return (DoctorCheck(name: "audio", ok: true, detail: "skipped (state: \(live.state.rawValue))", warning: false), live)
        }
        if live.mode == .driver {
            return (DoctorCheck(name: "audio", ok: true, detail: "skipped (driver mode: see driver IO)", warning: false), live)
        }
        let s0 = live
        // Only v3 daemons write `version`, and only v3 has the SIGUSR1 handler — the default action would kill an older one.
        guard let daemonVersion = s0.version else {
            return (DoctorCheck(name: "audio", ok: false,
                               detail: "daemon runs a pre-v3 build, this eq is \(Build.version)"
                                   + " — restart it: " + LaunchAgent.restartHint,
                               warning: true), live)
        }
        guard probes.executablePath(s0.pid)?.hasSuffix("/eq") == true else {
            return (DoctorCheck(name: "audio", ok: false, detail: "pid \(s0.pid) is not an eq daemon — status file is stale", warning: true), live)
        }
        guard probes.signalStatus(s0.pid) else {
            return (DoctorCheck(name: "audio", ok: false, detail: "could not signal the daemon", warning: true), live)
        }
        guard let s1 = freshStatus(probes, after: s0.writes) else {
            return (DoctorCheck(name: "audio", ok: false, detail: staleAfterSignalDetail, warning: true), live)
        }
        probes.sleep(1)
        _ = probes.signalStatus(s1.pid)
        guard let s2 = freshStatus(probes, after: s1.writes) else {
            return (DoctorCheck(name: "audio", ok: false, detail: staleAfterSignalDetail, warning: true), s1)
        }
        let before = s1.callbacks, after = s2.callbacks
        if before == 0 && after == 0 {
            return (DoctorCheck(name: "audio", ok: false,
                               detail: "no IO callbacks — if the daemon predates v2, restart it: " + LaunchAgent.restartHint,
                               warning: true), s2)
        }
        guard after > before else {
            return (DoctorCheck(name: "audio", ok: false, detail: "no IO callbacks in 1 s — is the device asleep?", warning: true), s2)
        }
        let detail = "callbacks \(before) → \(after)"
        guard daemonVersion == Build.version else {
            return (DoctorCheck(name: "audio", ok: false,
                               detail: detail + " (daemon v\(daemonVersion), this eq v\(Build.version)"
                                   + " — restart it: " + LaunchAgent.restartHint + ")",
                               warning: true), s2)
        }
        return (DoctorCheck(name: "audio", ok: true, detail: detail, warning: false), s2)
    }

    private static let staleAfterSignalDetail =
        "status not refreshed after SIGUSR1 — daemon predates v3? restart it: " + LaunchAgent.restartHint

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

    // MARK: - Driver

    /// Past this the plug-in's clock servo is chasing a target that is not a steady clock.
    static let clockPpmLimit = 500.0

    /// Nothing in tap mode without the plug-in; in tap mode with it, that it keeps out of the way;
    /// in driver mode, what it reports about playing, sampled twice a second apart for the slips.
    static func driverChecks(_ probes: DoctorProbes, mode: AudioMode, hidesWhileDefault: Bool, live: Status?) -> [DoctorCheck] {
        func check(_ name: String, _ ok: Bool, _ detail: String, warning: Bool = false) -> DoctorCheck {
            DoctorCheck(name: name, ok: ok, detail: detail, warning: warning)
        }
        let driverMode = mode == .driver
        guard let port = probes.driver() else {
            guard driverMode else { return [] }
            return [check("driver", false, "mode is driver but \(ModeSwitch.Failure.notInstalled), or: eq mode tap")]
        }
        guard let values = try? port.health() else {
            return [check("driver", false, "the EQ device does not report its health", warning: !driverMode)]
        }
        let first = DriverHealth(values)
        guard let version = first.settingsVersion, version >= DriverControl.requiredVersion else {
            return [check("driver", false, "\(ModeSwitch.Failure.tooOld(first.settingsVersion))", warning: !driverMode)]
        }
        guard !first.killed else { return [check("driver", false, "\(ModeSwitch.Failure.disabled)", warning: !driverMode)] }
        let files = probes.driverFiles()
        var checks = [check("driver", true, "installed, protocol \(version)" + (files.installed.map { ", \($0.label)" } ?? ""))]
        if let note = files.updateNote { checks.append(check("driver update", false, note, warning: true)) }
        let isDefault = probes.defaultOutputUID() == DriverControl.deviceUID
        guard driverMode else {
            checks.append(first.hidden ? check("driver hidden", true, "yes (tap mode)")
                : check("driver hidden", false, "no — in tap mode it should be; the daemon hides it, and so does eq mode tap", warning: true))
            if isDefault {
                checks.append(check("default output", false, "the EQ device, in tap mode — eq mode tap moves the default back to a real device"))
            }
            return checks
        }

        let target = first.targetName.isEmpty ? first.target : first.targetName
        if first.target.isEmpty {
            checks.append(check("driver target", false, "none — no real output device to play on"))
        } else {
            checks.append(first.targetAvailable ? check("driver target", true, "\(target) (\(first.target))")
                : check("driver target", false, "\(target) is gone — the EQ device hides until it is back", warning: true))
        }
        checks.append(first.ioRunning ? check("driver IO", true, "running")
            : check("driver IO", false, "idle — nothing plays, or the target stopped calling back", warning: true))
        probes.sleep(1)
        let second = (try? port.health()).map(DriverHealth.init) ?? first
        let underruns = second.underruns &- first.underruns, overruns = second.overruns &- first.overruns
        let slips = "\(underruns) underruns, \(overruns) overruns in 1 s (\(second.underruns), \(second.overruns) since load)"
        checks.append(underruns + overruns == 0 ? check("driver slips", true, slips)
            : check("driver slips", false, slips + " — the EQ device and its target slipped, audio had gaps", warning: true))
        let ppm = String(format: "%+.1f ppm", second.clockPpm)
        checks.append(abs(second.clockPpm) <= clockPpmLimit ? check("driver clock", true, ppm)
            : check("driver clock", false, ppm + " — past \(Int(clockPpmLimit)) ppm the target's clock is not steady", warning: true))
        checks.append(second.eqActive ? check("driver EQ", true, "playing the curve eq sent (serial \(second.settingsSerial))")
            : check("driver EQ", false, "no curve for this target — the daemon sends one; eq driver push does too", warning: true))
        if second.settingsError.isEmpty {
            let refused = second.settingsRejected > 0 ? "; \(second.settingsRejected) refused since load" : ""
            checks.append(check("driver writer", true, "writes accepted (\(second.writerRequirement))\(refused)"))
        } else {
            checks.append(check("driver writer", false, second.settingsError + " — run the eq inside a signed EQ.app", warning: true))
        }
        checks.append(isDefault ? check("default output", true, "the EQ device")
            : check("default output", false, "not the EQ device — sound bypasses eq; the daemon takes it back, or: eq mode driver", warning: true))
        if hidesWhileDefault {
            switch live?.driver?.hiddenDefault {
            case .kept?: checks.append(check("hidden default", true, "kept: macOS keeps the hidden EQ device as the default output"))
            case .dropped?:
                checks.append(check("hidden default", false, "dropped: macOS moved the default off the hidden EQ device, so the daemon shows it", warning: true))
            case nil: checks.append(check("hidden default", true, "not tried yet (the daemon tries it when it makes the EQ device default)"))
            }
        }
        return checks
    }
}
