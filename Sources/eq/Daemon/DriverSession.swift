import EQCore
import Foundation

/// Tap or driver, never both: the running path always stops before the other starts, and a driver
/// that will not start leaves the tap running rather than no EQ at all.
final class AudioPaths {
    enum Path: String, Codable { case tap, driver }

    private let startTap: () -> Void
    private let stopTap: () -> Void
    private let startDriver: () -> Bool
    private let stopDriver: (_ restoring: Bool) -> Void
    private(set) var active: Path?

    init(startTap: @escaping () -> Void, stopTap: @escaping () -> Void,
         startDriver: @escaping () -> Bool, stopDriver: @escaping (_ restoring: Bool) -> Void) {
        self.startTap = startTap
        self.stopTap = stopTap
        self.startDriver = startDriver
        self.stopDriver = stopDriver
    }

    /// The path the config and the plug-in allow.
    static func wanted(_ mode: AudioMode, driverPresent: Bool) -> Path {
        mode == .driver && driverPresent ? .driver : .tap
    }

    /// `restoring` false when the EQ device is gone, so there is no default output to take back from it.
    @discardableResult
    func run(_ wanted: Path, restoring: Bool = true) -> Path {
        guard wanted != active else { return wanted }
        switch active {
        case .tap?: stopTap()
        case .driver?: stopDriver(restoring)
        case nil: break
        }
        active = nil
        return start(wanted)
    }

    /// Stops and starts the driver path again, for an option that only takes effect at the start.
    func restart() {
        guard active == .driver else { return }
        stopDriver(false)
        active = nil
        start(.driver)
    }

    @discardableResult
    private func start(_ wanted: Path) -> Path {
        if wanted == .driver, startDriver() {
            active = .driver
        } else {
            startTap()
            active = .tap
        }
        return active!
    }
}

/// Decision 2: the user keeps picking real devices in the Sound menu, and eq plays on the one picked
/// with the EQ device put back in front of it.
///
/// Every default-output event restarts a short wait, so a burst of them (the user clicking through
/// the menu, Bluetooth connecting) is judged once, on the device it settled on. The EQ device
/// becoming default is never acted on, which makes eq's own write, and its echo, a no-op. Taking the
/// default back more than `burstLimit` times in `burstWindow` means something keeps moving it: eq
/// stops fighting for `cooldown`, then looks once more.
final class DefaultFollower {
    static let settle: TimeInterval = 0.4
    static let burstLimit = 3
    static let burstWindow: TimeInterval = 10
    static let cooldown: TimeInterval = 30

    enum Decision: Equatable {
        case stay
        case follow(AudioOutputDevice)
        case leave(AudioOutputDevice)
    }

    static func decide(_ current: AudioOutputDevice?) -> Decision {
        guard let current, !current.isEQDevice else { return .stay }
        return current.isFollowable ? .follow(current) : .leave(current)
    }

    private let schedule: Debouncer.Schedule
    private let now: () -> Date
    private let current: () -> AudioOutputDevice?
    private let follow: (AudioOutputDevice) -> Void
    private let log: (String) -> Void
    private lazy var debounce = Debouncer(delay: Self.settle, schedule: schedule) { [weak self] in self?.judge() }
    private var follows: [Date] = []
    private var backingOffUntil: Date?
    private var leftAlone: String?
    /// While true, events are dropped: the hidden-default experiment moves the default on purpose.
    var paused = false

    init(schedule: @escaping Debouncer.Schedule, now: @escaping () -> Date, current: @escaping () -> AudioOutputDevice?,
         follow: @escaping (AudioOutputDevice) -> Void, log: @escaping (String) -> Void) {
        self.schedule = schedule
        self.now = now
        self.current = current
        self.follow = follow
        self.log = log
    }

    func changed() {
        guard !paused else { return }
        debounce.trigger()
    }

    func stop() {
        debounce.cancel()
        follows = []
        backingOffUntil = nil
    }

    private func judge() {
        guard !paused else { return }
        switch Self.decide(current()) {
        case .stay:
            leftAlone = nil
        case .leave(let device):
            if leftAlone != device.uid { log("follow: \(device.name) is not a device the EQ device plays on — left as the default output") }
            leftAlone = device.uid
        case .follow(let device):
            leftAlone = nil
            let t = now()
            if let until = backingOffUntil, t < until { return }
            follows = follows.filter { t.timeIntervalSince($0) < Self.burstWindow }
            guard follows.count < Self.burstLimit else {
                backingOffUntil = t.addingTimeInterval(Self.cooldown)
                follows = []
                log("follow: the default output moved \(Self.burstLimit + 1) times in \(Int(Self.burstWindow)) s — "
                    + "leaving \(device.name) as it is for \(Int(Self.cooldown)) s")
                schedule(Self.cooldown) { [weak self] in self?.changed() }
                return
            }
            follows.append(t)
            follow(device)
        }
    }
}

/// The daemon's side of driver mode: the EQ device default, pointed at the device the user picked,
/// and playing the curve the config gives that device. The plug-in plays on without the daemon, so
/// stopping a session changes nothing on the device.
final class DriverSession {
    struct Environment {
        var system: AudioSystem
        var driver: () -> DriverPort?
        var schedule: Debouncer.Schedule
        var now: () -> Date = Date.init
        var serial: () -> UInt64 = { UInt64(Date().timeIntervalSince1970 * 1000) }
        var log: (String) -> Void = Log.write
        /// Read from disk before taking the default back: `eq mode tap` saves the mode before it moves the default.
        var stillDriverMode: () -> Bool = { true }
        var deadline: TimeInterval = 2
        var wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    }

    enum HiddenDefault: String, Codable { case kept, dropped }

    /// How long macOS gets to move the default off the hidden EQ device before the experiment counts it kept.
    static let hiddenCheckDelay: TimeInterval = 1.5

    private let env: Environment
    private let settings: (String) -> eqc_settings?
    private let hideWhileDefault: Bool
    private let onTarget: (AudioOutputDevice) -> Void
    private lazy var switcher = ModeSwitch(system: env.system, driver: env.driver, deadline: env.deadline, wait: env.wait)
    private lazy var follower = DefaultFollower(
        schedule: env.schedule, now: env.now, current: { [weak self] in self?.defaultOutput() },
        follow: { [weak self] in self?.follow($0) }, log: env.log)
    private var running = false
    private var loggedPushError: String?

    private(set) var target: AudioOutputDevice?
    private(set) var health: DriverHealth?
    private(set) var error: String?
    private(set) var hiddenDefault: HiddenDefault?
    /// Writes to the plug-in; tests count them.
    private(set) var pushes = 0

    init(env: Environment, hideWhileDefault: Bool, settings: @escaping (String) -> eqc_settings?,
         onTarget: @escaping (AudioOutputDevice) -> Void = { _ in }) {
        self.env = env
        self.hideWhileDefault = hideWhileDefault
        self.settings = settings
        self.onTarget = onTarget
    }

    var isRunning: Bool { running }

    /// Throws what keeps driver mode from starting, so the caller can fall back to the tap.
    func start() throws {
        let (port, health) = try switcher.ready()
        let target = try switcher.target(health)
        try switcher.enter(target: target, port: port, health: health) { [weak self] port, uid in self?.write(port, uid) }
        running = true
        self.target = target
        env.log("driver: \(target.name) · EQ is the default output, playing on \(target.name)")
        onTarget(target)
        refresh()
        hideIfAsked()
    }

    func stop() {
        running = false
        follower.stop()
        follower.paused = false
    }

    /// The config, preset, app overlay, on/off, dynamics or solo changed.
    func push() {
        guard running, let target, let port = port() else { return }
        write(port, target.uid)
    }

    func defaultOutputChanged() {
        guard running else { return }
        follower.changed()
    }

    /// Re-reads the plug-in's health; a target the plug-in picked by itself (its own went away) gets its curve.
    func refresh() {
        guard running, let port = port() else {
            health = nil
            return
        }
        guard let values = try? switcher.within("the EQ device's health", { try port.health() }) else { return }
        let health = DriverHealth(values)
        self.health = health
        guard !health.target.isEmpty, health.target != target?.uid else { return }
        let devices = (try? switcher.within("listing output devices") { self.env.system.outputDevices() }) ?? []
        let device = devices.first { $0.uid == health.target }
            ?? AudioOutputDevice(id: 0, uid: health.target, name: health.targetName.isEmpty ? health.target : health.targetName, transportType: 0)
        env.log("driver: the plug-in moved to \(device.name) by itself")
        target = device
        onTarget(device)
        write(port, device.uid)
    }

    func meter() -> DriverMeter? {
        guard running, let port = port() else { return nil }
        return try? port.meter()
    }

    private func port() -> DriverPort? {
        (try? switcher.within("finding the EQ device", env.driver)) ?? nil
    }

    private func defaultOutput() -> AudioOutputDevice? {
        (try? switcher.within("reading the default output") { self.env.system.defaultOutput() }) ?? nil
    }

    private func follow(_ device: AudioOutputDevice) {
        guard running, env.stillDriverMode() else { return }
        guard let port = port() else { return }
        do {
            if device.uid != target?.uid { try switcher.within("pointing the EQ device at \(device.name)") { try port.setTarget(device.uid) } }
            target = device
            write(port, device.uid)
            do {
                try switcher.makeDefault(DriverControl.deviceUID, "the EQ device")
            } catch where hideWhileDefault && hiddenDefault != .dropped {
                hiddenDefault = .dropped
                env.log("driver: macOS will not make the hidden EQ device the default output — showing it again")
                try switcher.within("showing the EQ device") { try port.setHidden(false) }
                try switcher.makeDefault(DriverControl.deviceUID, "the EQ device")
            }
            env.log("follow: \(device.name) picked — the EQ device plays on it and is the default output again")
            onTarget(device)
            hideIfAsked()
        } catch {
            env.log("follow: \(error)")
        }
    }

    private func write(_ port: DriverPort, _ uid: String) {
        guard let settings = settings(uid), let record = DriverControl.record(settings, targetUID: uid, serial: env.serial()) else { return }
        pushes += 1
        do {
            try switcher.within("sending the curve") { try port.write(settings: record) }
            error = nil
            loggedPushError = nil
        } catch {
            let message = error as? DriverError == .refused
                ? "the driver refused eq's curve: this eq is not signed the way the driver requires — the device plays the curve it has"
                : "sending the curve: \(error)"
            self.error = message
            if loggedPushError != message { env.log("driver: \(message)") }
            loggedPushError = message
        }
    }

    /// Decision 4, an experiment: hide the EQ device while it is the default, and keep it hidden only if macOS keeps it default.
    private func hideIfAsked() {
        guard hideWhileDefault, hiddenDefault != .dropped, let port = port() else { return }
        follower.paused = true
        do {
            try switcher.within("hiding the EQ device") { try port.setHidden(true) }
        } catch {
            follower.paused = false
            env.log("driver: cannot hide the EQ device: \(error)")
            return
        }
        env.schedule(Self.hiddenCheckDelay) { [weak self] in self?.checkHiddenDefault() }
    }

    private func checkHiddenDefault() {
        defer { follower.paused = false }
        guard running else { return }
        if defaultOutput()?.isEQDevice == true {
            if hiddenDefault != .kept { env.log("driver: macOS keeps the hidden EQ device as the default output") }
            hiddenDefault = .kept
            return
        }
        hiddenDefault = .dropped
        env.log("driver: macOS moved the default output off the hidden EQ device — showing it again")
        guard let port = port() else { return }
        do {
            try switcher.within("showing the EQ device") { try port.setHidden(false) }
            try switcher.makeDefault(DriverControl.deviceUID, "the EQ device")
        } catch {
            env.log("driver: \(error)")
        }
    }
}
