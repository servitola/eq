import Foundation

/// `eq mode [driver|tap]`: which path carries the EQ. The switch runs here, not only in the daemon,
/// so it works with the daemon stopped and says at once what went wrong.
extension CLI {
    struct ModeDriverReport: Encodable {
        var installed: Bool
        var version: Int?
        var target: DeviceRef?
        var hidden: Bool?
    }

    struct ModeReport: Encodable {
        /// What the config asks for.
        var mode: AudioMode
        /// What a live daemon runs; nil when none runs.
        var running: AudioMode?
        var driver: ModeDriverReport
        var from: AudioMode? = nil
        var output: DeviceRef? = nil
        var dryRun: Bool? = nil
        var notes: [String]? = nil
    }

    static func mode(_ args: [String], _ ctx: CLIContext, dryRun: Bool = false) throws -> Output {
        switch args {
        case []: return showMode(ctx)
        case ["driver"]: return try enterDriverMode(ctx, dryRun: dryRun)
        case ["tap"]: return try enterTapMode(ctx, dryRun: dryRun)
        default: throw CLIError.usage("eq mode [driver|tap]")
        }
    }

    private static func switcher(_ ctx: CLIContext) -> ModeSwitch {
        ModeSwitch(system: ctx.audioSystem, driver: ctx.driver, deadline: ctx.modeDeadline, wait: ctx.modeWait)
    }

    private static func liveStatus(_ ctx: CLIContext) -> Status? {
        Status.read(from: ctx.statusURL).flatMap { $0.isAlive() ? $0 : nil }
    }

    private static func driverReport(_ ctx: CLIContext) -> (ModeDriverReport, DriverHealth?) {
        let switcher = switcher(ctx)
        guard let port = (try? switcher.within("finding the EQ device", ctx.driver)) ?? nil else {
            return (ModeDriverReport(installed: false), nil)
        }
        guard let values = try? switcher.within("the EQ device's health", { try port.health() }) else {
            return (ModeDriverReport(installed: true), nil)
        }
        let health = DriverHealth(values)
        let target = health.target.isEmpty ? nil : DeviceRef(uid: health.target, name: health.targetName.isEmpty ? health.target : health.targetName)
        return (ModeDriverReport(installed: true, version: health.settingsVersion, target: target, hidden: health.hidden), health)
    }

    private static func showMode(_ ctx: CLIContext) -> Output {
        let configured = (try? loadConfig(ctx))?.audioMode ?? .tap
        let live = liveStatus(ctx)
        let (driver, _) = driverReport(ctx)
        var line = "mode: " + Paint.ink(.bold, configured.rawValue)
        if let status = live, status.mode == .driver, let running = status.driver {
            line += configured == .driver ? " (\(running.deviceName) → \(running.target?.name ?? "no target"))"
                : Paint.ink(.yellow, " — the daemon still runs the driver until it reloads the config")
        } else if configured == .driver {
            if let status = live {
                if status.mode == .tap {
                    let why = (status.warnings ?? []).first { $0.hasPrefix("driver mode:") }
                    line += Paint.ink(.yellow, " — the daemon runs the tap" + (why.map { ": " + $0.dropFirst("driver mode: ".count) } ?? ""))
                }
            } else {
                line += Paint.ink(.dim, " — daemon not running")
            }
        }
        var lines = [line]
        if driver.installed {
            var parts = ["installed"]
            if let version = driver.version { parts.append("protocol \(version)") }
            if let target = driver.target { parts.append("plays on \(target.name)") }
            if driver.hidden == true { parts.append("hidden") }
            lines.append(Paint.ink(.dim, "driver:") + " " + parts.joined(separator: ", "))
        } else {
            lines.append(Paint.ink(.dim, "driver:") + " not installed")
        }
        return Output(lines.joined(separator: "\n"), ModeReport(mode: configured, running: live?.mode, driver: driver))
    }

    private static func enterDriverMode(_ ctx: CLIContext, dryRun: Bool) throws -> Output {
        let switcher = switcher(ctx)
        let port: DriverPort, health: DriverHealth, target: AudioOutputDevice
        do {
            (port, health) = try switcher.ready()
            target = try switcher.target(health)
        } catch let failure as ModeSwitch.Failure {
            throw CLIError.mode("cannot switch to driver: \(failure)")
        }
        var config = try loadConfig(ctx)
        let before = config.audioMode
        let resolved = config.profile(forDeviceUID: target.uid)
        let curve = resolved.source == .device ? "its own profile" : "the default profile"
        let (driver, _) = driverReport(ctx)
        let ref = DeviceRef(uid: target.uid, name: target.name)
        if dryRun {
            let text = [
                Paint.ink(.yellow, "dry run") + ": nothing changed",
                "mode \(before.rawValue) → " + Paint.ink(.bold, "driver"),
                "would show \(target.name) · EQ, point it at \(target.name), send it \(curve) and make it the default output",
            ].joined(separator: "\n")
            return Output(text, ModeReport(mode: .driver, running: liveStatus(ctx)?.mode, driver: driver, from: before, output: ref, dryRun: true))
        }
        let live = liveStatus(ctx)
        var notes: [String] = []
        do {
            try switcher.enter(target: target, port: port, health: health) { port, uid in
                let profile = config.profile(forDeviceUID: uid).profile
                guard let record = DriverControl.record(EQProcessor.settings(profile: profile, enabled: config.enabled),
                                                        targetUID: uid, serial: ctx.driverSerial()) else {
                    throw ModeSwitch.Failure.failed("the target UID \(uid) does not fit the settings record")
                }
                do {
                    try switcher.within("sending the curve") { try port.write(settings: record) }
                } catch DriverError.refused where live != nil {
                    notes.append("this eq may not send the driver a curve (\(health.writerRequirement)); the daemon does")
                } catch DriverError.refused {
                    throw ModeSwitch.Failure.failed("\(DriverError.refused) (\(health.writerRequirement)); run the eq inside a signed EQ.app")
                }
            }
        } catch let failure as ModeSwitch.Failure {
            throw CLIError.mode("cannot switch to driver: \(failure)")
        }
        config.mode = .driver
        try ctx.store.save(config)
        if live == nil {
            notes.append("the daemon is not running: the EQ device plays, but picking another output in the Sound menu bypasses eq until it runs")
        }
        var lines = ["mode: \(before.rawValue) → " + Paint.ink(.green, "driver"),
                     Paint.ink(.bold, "\(target.name) · EQ") + " is the default output, playing on \(target.name) with \(curve)"]
        lines += notes.map { Paint.ink(.yellow, "note:") + " " + $0 }
        let report = ModeReport(mode: .driver, running: live?.mode, driver: driverReport(ctx).0, from: before, output: ref,
                                notes: notes.isEmpty ? nil : notes)
        return Output(lines.joined(separator: "\n"), report)
    }

    /// The escape hatch: it must restore sound even with a broken config or a wedged driver, so a
    /// config it cannot save is a problem to report, not a reason to stop.
    private static func enterTapMode(_ ctx: CLIContext, dryRun: Bool) throws -> Output {
        var config = try? loadConfig(ctx)
        let before = config?.audioMode ?? .tap
        let (driver, health) = driverReport(ctx)
        let remembered = liveStatus(ctx)?.driver?.target?.uid
        if dryRun {
            let back = health.map(\.targetName).flatMap { $0.isEmpty ? nil : $0 } ?? "a real output"
            var lines = [Paint.ink(.yellow, "dry run") + ": nothing changed", "mode \(before.rawValue) → " + Paint.ink(.bold, "tap")]
            if driver.installed { lines.append("would make \(back) the default output if the EQ device is, hide the EQ device, and leave the tap to the daemon") }
            return Output(lines.joined(separator: "\n"), ModeReport(mode: .tap, running: liveStatus(ctx)?.mode, driver: driver, from: before, dryRun: true))
        }
        var problems: [String] = []
        if config != nil {
            config!.mode = .tap
            do { try ctx.store.save(config!) } catch { problems.append("cannot save the mode: \(error)") }
        } else {
            problems.append("the config is unreadable, so the mode stays as written there — fix it, then run eq mode tap again")
        }
        var output: DeviceRef?
        var lines = ["mode: \(before.rawValue) → " + Paint.ink(.green, "tap")]
        if driver.installed {
            let left = switcher(ctx).leave(remembered: remembered)
            problems += left.problems
            if let device = left.output {
                output = DeviceRef(uid: device.uid, name: device.name)
                lines.append("the default output is " + Paint.ink(.bold, device.name) + (left.hidden ? "; the EQ device is hidden" : ""))
            } else {
                lines.append(Paint.ink(.red, "sound may be gone: the default output is still the EQ device"))
                lines += ModeSwitch.recovery.split(separator: "\n").map { "  " + $0 }
            }
        }
        lines += problems.map { Paint.ink(.yellow, "warning:") + " " + $0 }
        var result = Output(lines.joined(separator: "\n"),
                            ModeReport(mode: .tap, running: liveStatus(ctx)?.mode, driver: driverReport(ctx).0, from: before, output: output,
                                       notes: problems.isEmpty ? nil : problems))
        if driver.installed, output == nil { result.exitCode = 1 }
        return result
    }
}
