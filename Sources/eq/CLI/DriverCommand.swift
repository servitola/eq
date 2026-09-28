import Foundation

/// `eq driver status|push`: hidden, for trying the HAL plug-in before `eq mode` switches to it.
/// Neither starts the daemon.
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

    static func driver(_ args: [String], _ ctx: CLIContext) throws -> Output {
        let usage = "eq driver status | eq driver push"
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

    private static func driverCall<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as DriverError {
            throw CLIError.driver("\(error)")
        }
    }
}
