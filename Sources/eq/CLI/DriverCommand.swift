import Foundation

/// `eq driver status|push`: hidden, for trying the HAL plug-in before `eq mode` switches to it.
/// `eq driver uninstall` takes it out of /Library again. None starts the daemon.
extension CLI {
    enum DriverValue: Encodable, Equatable {
        case text(String), number(Double), flag(Bool)

        init?(_ value: Any) {
            switch value {
            case let s as String: self = .text(s)
            case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): self = .flag(n.boolValue)
            case let n as NSNumber: self = .number(n.doubleValue)
            default: return nil
            }
        }

        var description: String {
            switch self {
            case .text(let s): return s.isEmpty ? "\"\"" : s
            case .flag(let b): return b ? "yes" : "no"
            case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .text(let s): try c.encode(s)
            case .flag(let b): try c.encode(b)
            case .number(let n): try c.encode(n)
            }
        }
    }

    struct DriverPushReport: Encodable {
        var target: DeviceRef
        var source: ProfileSource
        var serial: UInt64
        var playing: Bool
    }

    struct DriverUninstallReport: Encodable {
        var removed: Bool
        var build: DriverBuild?
        var brew: String?
        var dryRun: Bool? = nil
        var elevation: DriverInstall.Elevation? = nil
        var tap: AnyEncodable? = nil
    }

    static func driver(_ args: [String], _ ctx: CLIContext) throws -> Output {
        let usage = "eq driver status | eq driver push | eq driver uninstall"
        if args.first == "uninstall" { return try driverUninstall(Array(args.dropFirst()), ctx, dryRun: false) }
        guard args == ["status"] || args == ["push"] else { throw CLIError.usage(usage) }
        guard let port = ctx.driver() else { throw CLIError.driver("not installed: no audio device \(DriverControl.deviceUID)") }
        let health = try driverCall { try port.health() }.compactMapValues(DriverValue.init)
        if args == ["status"] {
            let lines = health.keys.sorted().map { Paint.ink(.dim, $0 + ":") + " " + health[$0]!.description }
            return Output(lines.joined(separator: "\n"), health)
        }

        guard case .text(let target)? = health["target"], !target.isEmpty else { throw CLIError.driver("the driver has no target yet") }
        let name: String
        if case .text(let n)? = health["targetName"], !n.isEmpty { name = n } else { name = target }
        let config = try loadConfig(ctx)
        let resolved = config.profile(forDeviceUID: target)
        let serial = ctx.driverSerial()
        guard let record = DriverControl.record(EQProcessor.settings(profile: resolved.profile, enabled: config.enabled),
                                                targetUID: target, serial: serial) else {
            throw CLIError.driver("the target UID \(target) does not fit the settings record")
        }
        do {
            try port.write(settings: record)
        } catch DriverError.refused {
            var requirement = ""
            if case .text(let r)? = health["writerRequirement"] { requirement = r }
            throw CLIError.driver("\(DriverError.refused) (\(requirement)); run the eq inside a signed EQ.app")
        } catch let error as DriverError {
            throw CLIError.driver("\(error)")
        }
        // The plug-in applies a record on its own queue, a moment after the write returns.
        var playing = false
        for attempt in 0..<20 {
            if case .number(let n)? = (try? port.health())?["settingsSerial"].flatMap(DriverValue.init), UInt64(exactly: n) == serial {
                playing = true
                break
            }
            if attempt < 19 { Thread.sleep(forTimeInterval: 0.05) }
        }
        let source = resolved.source == .device ? "own profile" : "default profile"
        let text = "pushed the \(source) of \(name) to the driver" + (playing ? "; playing" : "; stored, not playing yet")
        return Output(text, DriverPushReport(target: DeviceRef(uid: target, name: name), source: resolved.source, serial: serial, playing: playing))
    }

    /// Tap mode first, so the default output is back on a real device and no daemon takes it back, then
    /// the bundle removed and coreaudiod restarted in one privileged step. `--cask` is the cask's
    /// uninstall step, which Homebrew also runs on `brew upgrade` and `brew reinstall`: there the
    /// driver stays, and the new eq keeps playing through it.
    static func driverUninstall(_ args: [String], _ ctx: CLIContext, dryRun: Bool) throws -> Output {
        guard args == [] || args == ["--cask"] else { throw CLIError.usage("eq driver uninstall") }
        let files = ctx.driverFiles()
        let (device, _) = driverReport(ctx)
        var brew: String?
        if args == ["--cask"] {
            brew = ctx.brewCommand()
            guard BrewParent.removes(brew) else {
                let text = "brew \(brew ?? "(not found)") is not removing eq: the EQ driver stays installed"
                return Output(text, DriverUninstallReport(removed: false, build: files.installed, brew: brew, dryRun: dryRun ? true : nil))
            }
        }
        guard files.installed != nil || device.installed else {
            return Output("the EQ driver is not installed", DriverUninstallReport(removed: false, build: nil, brew: brew, dryRun: dryRun ? true : nil))
        }
        let elevation = ctx.driverElevation()
        if dryRun {
            let lines = [Paint.ink(.yellow, "dry run") + ": nothing changed",
                         "would switch to tap mode: the default output back on a real device, the EQ device hidden",
                         "would remove \(DriverInstall.installedURL.path)"
                             + (files.installed.map { ", \($0.label)" } ?? "") + ": " + elevationText(elevation, uninstall: true)]
            return Output(lines.joined(separator: "\n"),
                          DriverUninstallReport(removed: false, build: files.installed, brew: brew, dryRun: true, elevation: elevation))
        }
        let tap = try mode(["tap"], ctx)
        ctx.warn(Paint.ink(.yellow, "driver:", on: Paint.enabled(fd: 2)) + " about to remove \(DriverInstall.installedURL.path) — "
                 + elevationText(elevation, uninstall: true))
        do {
            try ctx.privileged(.uninstall, elevation)
        } catch {
            throw CLIError.driver("cannot remove the EQ driver: \(error) — by hand: sudo rm -rf \(DriverInstall.installedURL.path) && sudo killall coreaudiod")
        }
        let text = tap.text + "\n" + Paint.ink(.green, "removed") + " \(DriverInstall.installedURL.path); coreaudiod restarted"
        return Output(text, DriverUninstallReport(removed: true, build: files.installed, brew: brew, elevation: elevation, tap: tap.json))
    }

    private static func driverCall<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as DriverError {
            throw CLIError.driver("\(error)")
        }
    }
}
