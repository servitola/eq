import Foundation

/// The steps between tap and driver mode, shared by `eq mode` and the daemon. Every Core Audio call
/// runs under a deadline, so a wedged plug-in or audio server can never hang `eq mode tap`, the
/// escape hatch.
struct ModeSwitch {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case notInstalled
        case tooOld(Int?)
        case disabled
        case noTarget
        case timedOut(String)
        case failed(String)

        var description: String {
            switch self {
            case .notInstalled: return "the EQ driver is not installed — run `eq mode driver` to install it"
            case .tooOld(let version): return DriverInstall.tooOld(version) + " — run `eq mode driver` to update it"
            case .disabled: return "the EQ driver is disabled by its kill file (Contents/Resources/disabled) — remove it and restart coreaudiod"
            case .noTarget: return "no real output device for the EQ device to play on"
            case .timedOut(let what): return "\(what) did not answer within the deadline — the audio server may be wedged"
            case .failed(let what): return what
            }
        }
    }

    struct Left: Equatable {
        /// The real device that is the default output now; nil when the default could not be moved off the EQ device.
        var output: AudioOutputDevice?
        var hidden: Bool
        var problems: [String]
    }

    var system: AudioSystem
    var driver: () -> DriverPort?
    var deadline: TimeInterval = 2
    var wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

    static let recovery = """
        restart the audio server: sudo killall coreaudiod
        if sound is still gone: sudo touch /Library/Audio/Plug-Ins/HAL/EQDriver.driver/Contents/Resources/disabled && sudo killall coreaudiod
        """

    func within<T>(_ what: String, _ body: @escaping () throws -> T) throws -> T {
        guard let result = Deadline.run(deadline, body) else { throw Failure.timedOut(what) }
        return try result.get()
    }

    /// The installed plug-in, new enough and not disabled.
    func ready() throws -> (port: DriverPort, health: DriverHealth) {
        guard let port = try within("finding the EQ device", driver) else { throw Failure.notInstalled }
        let health: DriverHealth
        do {
            health = DriverHealth(try within("the EQ device's health") { try port.health() })
        } catch let error as DriverError {
            throw Failure.failed("\(error)")
        }
        guard let version = health.settingsVersion, version >= DriverControl.requiredVersion else { throw Failure.tooOld(health.settingsVersion) }
        guard !health.killed else { throw Failure.disabled }
        return (port, health)
    }

    /// The default output when it is a real device, else the one the driver already plays on.
    func target(_ health: DriverHealth) throws -> AudioOutputDevice {
        let devices = try within("listing output devices") { system.outputDevices() }
        if let current = try within("reading the default output", { system.defaultOutput() }), current.isFollowable { return current }
        if let known = devices.first(where: { $0.uid == health.target && $0.isFollowable }) { return known }
        throw Failure.noTarget
    }

    /// Shows the EQ device, points it at `target`, has `push` send it the curve and makes it the
    /// default output. Hiding while default (decision 4) is the daemon's to try, not this.
    func enter(target: AudioOutputDevice, port: DriverPort, health: DriverHealth,
               push: @escaping (DriverPort, String) throws -> Void) throws {
        do {
            if health.hidden { try within("showing the EQ device") { try port.setHidden(false) } }
            if health.target != target.uid { try within("pointing the EQ device at \(target.name)") { try port.setTarget(target.uid) } }
        } catch let error as DriverError {
            throw Failure.failed("\(error)")
        }
        try push(port, target.uid)
        try makeDefault(DriverControl.deviceUID, "the EQ device")
    }

    /// The device just shown can take a moment to be default-capable, so the write is retried until it reads back.
    func makeDefault(_ uid: String, _ name: String) throws {
        let tries = 10
        for attempt in 1...tries {
            if try within("making \(name) the default output", { system.setDefaultOutput(uid: uid) }),
               try within("reading the default output", { system.defaultOutput() })?.uid == uid {
                return
            }
            if attempt < tries { wait(deadline / Double(tries)) }
        }
        throw Failure.failed("macOS did not make \(name) the default output")
    }

    /// The escape hatch, in order: the default output back on a real device first, since that is the
    /// system's and needs no answer from the plug-in, then the EQ device hidden. Never throws: each
    /// step that fails is a problem to report, and the next still runs.
    func leave(remembered: String?) -> Left {
        var problems: [String] = []
        func attempt<T>(_ what: String, _ body: @escaping () throws -> T) -> T? {
            do { return try within(what, body) } catch {
                problems.append("\(error)")
                return nil
            }
        }
        let port = attempt("finding the EQ device", driver) ?? nil
        let health = port.flatMap { port in attempt("the EQ device's health") { DriverHealth(try port.health()) } }
        var output: AudioOutputDevice?
        if let current = attempt("reading the default output", { system.defaultOutput() }) ?? nil, !current.isEQDevice {
            output = current
        } else {
            let devices = attempt("listing output devices") { system.outputDevices() } ?? []
            let real = devices.filter(\.isFollowable)
            let goal = [health?.target, remembered].compactMap { $0 }.lazy.compactMap { uid in real.first { $0.uid == uid } }.first
                ?? real.first { $0.transportName == "builtin" } ?? real.first
            if let goal {
                do {
                    try makeDefault(goal.uid, goal.name)
                    output = goal
                } catch {
                    problems.append("\(error)")
                }
            } else {
                problems.append("\(Failure.noTarget)")
            }
        }
        var hidden = false
        if let port {
            hidden = attempt("hiding the EQ device") { try port.setHidden(true) } != nil
        }
        return Left(output: output, hidden: hidden, problems: problems)
    }
}
