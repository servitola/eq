import Foundation
import CoreAudio

enum DaemonPolicy {
    static let rebuildAttempts = 5
    static let rebuildDelay: TimeInterval = 1
    static let permissionRetry: TimeInterval = 30
    static let failedRetry: TimeInterval = 30
    static let statusInterval: TimeInterval = 5
    static let stallTicks = 2
    static let heartbeat: TimeInterval = 30
    // FineTune #86/#324: device events arrive in bursts and a rate can read 0 mid-negotiation; 150 ms lets both settle.
    static let settleDelay: TimeInterval = 0.15
    static let wakeDelay: TimeInterval = 1
    // Wideband SCO runs at 24 kHz, so a classic-HFP threshold of 16 kHz misses it; every music rate is at least 44.1 kHz.
    static let callModeBelow: Double = 44100
    // A missed wake notification would otherwise leave the daemon silently stopped forever;
    // the watchdog timer itself ticking is proof the process is alive to fall back on.
    static let wakeFallbackTimeout: TimeInterval = 120

    static func shouldWriteStatus(changed: Bool, sinceLastWrite: TimeInterval) -> Bool {
        changed || sinceLastWrite >= heartbeat
    }

    /// A tap that cannot be created is, on a machine that ran yesterday, almost always the
    /// System Audio Recording grant missing or revoked; every other engine failure is transient.
    static func classify(_ failure: String) -> Status.State {
        failure.contains("create audio tap") ? .noPermission : .failed
    }

    static func shouldRebuild(current: AudioObjectID, newDefault: AudioObjectID?) -> Bool {
        guard let newDefault else { return false }
        return newDefault != current
    }

    static func shouldRebuildForRate(old: Double, new: Double) -> Bool {
        new > 0 && new != old
    }

    static func isCallMode(_ rate: Double) -> Bool {
        rate > 0 && rate < callModeBelow
    }

    /// A rate of 0 (or non-finite) right after `engine.start` means the device has not settled
    /// yet; the EQ must never run configured at 0 Hz, so the caller retries instead of using it.
    static func usableRate(_ rate: Double) -> Bool {
        rate.isFinite && rate > 0
    }

    static func wakeFallbackDue(asleepSince: Date, now: Date) -> Bool {
        now.timeIntervalSince(asleepSince) > wakeFallbackTimeout
    }

    enum Reconciliation: Equatable {
        case keep
        case device(AudioObjectID)
        case rate(Double)
        case rateUnsettled
    }

    /// `deviceRate` is nil when no engine is running, so there is no rate to follow.
    static func reconcile(target: AudioObjectID, newDefault: AudioObjectID?,
                          engineRate: Double, deviceRate: Double?) -> Reconciliation {
        if shouldRebuild(current: target, newDefault: newDefault), let newDefault { return .device(newDefault) }
        guard let deviceRate else { return .keep }
        if deviceRate <= 0 { return .rateUnsettled }
        return shouldRebuildForRate(old: engineRate, new: deviceRate) ? .rate(deviceRate) : .keep
    }

    static func stalled(previous: UInt64, current: UInt64, unchangedTicks: Int) -> (stalled: Bool, unchangedTicks: Int) {
        guard current == previous else { return (false, 0) }
        let ticks = unchangedTicks + 1
        return (ticks >= stallTicks, ticks)
    }

    static func ioFrames(from env: [String: String]) -> Int? {
        guard let raw = env["EQ_IO_FRAMES"], let frames = Int(raw), (64...4096).contains(frames) else { return nil }
        return frames
    }
}

final class Daemon {
    private let store: ConfigStore
    private let statusURL: URL
    private let queue = DispatchQueue.main
    private let engine = ProcessTapEngine()
    private var config: Config
    private var watcher: ConfigWatcher?
    private var device: AudioOutputDevice?
    private var profileSource: ProfileSource?
    private var announcedUID: String?
    private var lastError: String?
    private var configError: String?
    private var state: Status.State = .starting
    private var statusTimer: DispatchSourceTimer?
    private var lastStatusWrite = Date.distantPast
    private var statusWrites: UInt64 = 0
    private var lastCallbacks: UInt64 = 0
    private var unchangedTicks = 0
    private var retryWork: DispatchWorkItem?
    // Our own aggregate create/destroy fires the devices listener; cleared only when a rebuild succeeds, and failures retry on a timer, so a self-fired Devices event can never restart the cycle.
    private var rebuilding = false
    private var signalSources: [DispatchSourceSignal] = []
    private var meterServer: MeterServer?
    // The daemon's copy survives engine stops, which clear the processor's; applyProfile re-applies it.
    private var solo: SoloRange?
    private var lastSoloLog = Date.distantPast
    private var pendingSoloLog: String?
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private lazy var settle = Debouncer(delay: DaemonPolicy.settleDelay, queue: queue) { [weak self] in self?.reconcile() }
    private var power: SystemPower?
    private var asleep = false
    private var asleepSince: Date?
    private var loggedZeroRateAtStart = false
    private var inCallMode = false
    private var rateUnsettled = false
    private var tapSilence = TapSilence()
    private var filterWarnings: [String] = []
    private var loggedFilterWarnings: Set<String> = []

    init(store: ConfigStore, statusURL: URL) {
        self.store = store
        self.statusURL = statusURL
        let builtIn = AudioDeviceManager.builtInOutputDevice()
        do {
            config = try store.loadOrCreate(builtInUID: builtIn?.uid, builtInName: builtIn?.name)
            // Reload right before seeding rather than trusting the copy loadOrCreate returned,
            // so seeding always acts on what is actually on disk.
            if let onDisk = try? store.load() { config = onDisk }
            if config.seedPresetsIfNeeded() {
                // .edit — this is the one-time pre-v5 migration, so the file as it was
                // before presets existed stays recoverable as eq.json.1.
                do { try store.save(config, as: .edit) } catch { Log.write("cannot seed presets: \(error)") }
            }
        } catch {
            Log.write("config unreadable (\(error)); starting with the built-in curve")
            config = Config.initial(builtInUID: builtIn?.uid, builtInName: builtIn?.name)
            configError = "config rejected, using the built-in curve: \(error)"
        }
    }

    func run() -> Never {
        if let other = Status.read(from: statusURL), other.isAlive(), other.pid != getpid() {
            Log.write("another eq daemon is running (pid \(other.pid)) — exiting")
            exit(1)
        }
        // A status file carrying `version` tells doctor SIGUSR1 is safe; the handler must exist before that file does.
        installSignalHandlers()
        startMeterServer()
        let env = ProcessInfo.processInfo.environment
        if let frames = DaemonPolicy.ioFrames(from: env) {
            engine.requestedIOBufferFrames = frames
            Log.write("IO buffer requested: \(frames) frames")
        } else if let raw = env["EQ_IO_FRAMES"] {
            Log.write("EQ_IO_FRAMES ignored: \(raw)")
        }
        writeStatus()
        AudioDeviceManager.destroyStaleAggregates()
        engine.onSampleRateChange = { [weak self] in self?.settle.trigger() }
        installListeners()
        installPowerHandler()
        startWatcher()
        startStatusTimer()
        rebuild(attempt: 1)
        RunLoop.main.run()
        exit(0)
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { [weak self] in self?.terminate() }
            source.resume()
            signalSources.append(source)
        }
        signal(SIGUSR1, SIG_IGN)
        let usr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: queue)
        usr1.setEventHandler { [weak self] in self?.writeStatus() }
        usr1.resume()
        signalSources.append(usr1)
    }

    private func terminate() {
        meterServer?.stop()
        engine.stop()
        AudioDeviceManager.destroyStaleAggregates()
        try? FileManager.default.removeItem(at: statusURL)
        exit(0)
    }

    private func startMeterServer() {
        let processor = engine.processor
        let server = MeterServer(
            socketURL: statusURL.deletingLastPathComponent().appendingPathComponent("meter.sock"),
            queue: queue,
            source: { [unowned self] in self.frame() },
            onClientsChanged: { n in
                processor.meteringEnabled = n > 0
                Log.write("meter: \(n) client\(n == 1 ? "" : "s")")
            },
            onSolo: { [unowned self] range in self.setSolo(range) })
        do {
            try server.start()
            meterServer = server
        } catch {
            Log.write("meter socket unavailable: \(error)")
        }
    }

    private func setSolo(_ range: SoloRange?) -> Bool {
        let processor = engine.processor
        guard let range else {
            if solo != nil { logSolo("solo off") }
            solo = nil
            processor.clearSolo()
            return true
        }
        guard processor.setSolo(low: range.low, high: range.high), let effective = processor.effectiveSolo else { return false }
        if solo != range { logSolo(String(format: "solo %.0f–%.0f Hz", effective.low, effective.high)) }
        solo = range
        return true
    }

    /// Focus stepping through instruments sends a solo per key press; one line a second is
    /// enough, and the line that finally lands is the state the daemon ended in.
    private func logSolo(_ message: String) {
        let wait = lastSoloLog.addingTimeInterval(1).timeIntervalSinceNow
        guard wait > 0 || pendingSoloLog != nil else {
            Log.write(message)
            lastSoloLog = Date()
            return
        }
        let scheduled = pendingSoloLog != nil
        pendingSoloLog = message
        guard !scheduled else { return }
        queue.asyncAfter(deadline: .now() + max(wait, 0)) { [weak self] in
            guard let self, let message = self.pendingSoloLog else { return }
            self.pendingSoloLog = nil
            Log.write(message)
            self.lastSoloLog = Date()
        }
    }

    private func frame() -> MeterFrame {
        let processor = engine.processor
        let profile = device.map { config.profile(forDeviceUID: $0.uid).profile }
        return MeterFrame(
            t: Date().timeIntervalSince1970,
            device: device?.name,
            rate: processor.sampleRate,
            in: processor.meter.inputDB.map(MeterFrame.round1),
            out: processor.meter.outputDB.map(MeterFrame.round1),
            peak: MeterFrame.round1(processor.meter.peakDB),
            limiting: processor.limiting,
            gains: (profile?.bands ?? []).map(MeterFrame.round1),
            preamp: MeterFrame.round1(profile?.preamp ?? 0),
            enabled: config.enabled,
            // The daemon's copy, not the processor's: a rebuild clears the processor's for a moment,
            // and the watch would blink SOLO off and on.
            solo: solo.flatMap { EQProcessor.clampSolo(low: $0.low, high: $0.high, sampleRate: processor.sampleRate) })
    }

    // MARK: - Engine

    private func rebuild(attempt: Int) {
        guard !asleep else { return }
        retryWork?.cancel()
        rebuilding = true
        if state == .running || state == .bypassed { setState(.starting, error: nil) }
        guard let deviceID = AudioDeviceManager.defaultOutputDeviceID(),
              let device = AudioDeviceManager.device(deviceID) else {
            fail("No output device found.", retryIn: DaemonPolicy.rebuildDelay)
            return
        }
        if device.uid.hasPrefix(AudioDeviceManager.aggregateUIDPrefix) {
            Log.write("default output is a stale eq aggregate — destroying it")
            AudioDeviceManager.destroyStaleAggregates()
            fail("Default output was a stale aggregate.", retryIn: DaemonPolicy.rebuildDelay)
            return
        }
        self.device = device
        engine.start(outputDeviceID: deviceID)
        if case .failed(let why) = engine.state {
            let state = DaemonPolicy.classify(why)
            if state == .noPermission {
                fail(why, retryIn: DaemonPolicy.permissionRetry, as: .noPermission)
            } else if attempt < DaemonPolicy.rebuildAttempts {
                if attempt == 1 {
                    Log.write("rebuild \(attempt)/\(DaemonPolicy.rebuildAttempts) failed: \(why)")
                }
                lastError = why
                writeStatus()
                scheduleRebuild(attempt: attempt + 1, after: DaemonPolicy.rebuildDelay)
            } else {
                fail("rebuild failed \(DaemonPolicy.rebuildAttempts) times: \(why)", retryIn: DaemonPolicy.failedRetry)
            }
            return
        }
        guard DaemonPolicy.usableRate(engine.processor.sampleRate) else {
            engine.stop()
            if !loggedZeroRateAtStart {
                Log.write("device reports 0 Hz — waiting for it to settle")
                loggedZeroRateAtStart = true
            }
            // Not counted as a failed attempt: `attempt` is unchanged, so this can retry
            // indefinitely without ever tripping the 5-attempt give-up path.
            scheduleRebuild(attempt: attempt, after: DaemonPolicy.settleDelay)
            return
        }
        loggedZeroRateAtStart = false
        noteCallMode(engine.processor.sampleRate)
        applyProfile()
        writeStatus()
        // Bluetooth devices become default a moment before they deliver frames; verify the
        // path is live before declaring success, otherwise retry the whole build.
        retryWork = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.engine.state == .running, self.engine.callbacks > 0 || attempt >= DaemonPolicy.rebuildAttempts {
                if self.engine.callbacks == 0 {
                    Log.write("declaring running without IO callbacks after \(attempt) attempts")
                } else if attempt > 1 {
                    Log.write("running after \(attempt) attempts")
                }
                self.rebuilding = false
                self.setState(self.config.enabled ? .running : .bypassed, error: nil)
            } else if self.engine.state == .running {
                Log.write("no IO callbacks after \(attempt) attempt(s) — rebuilding")
                self.rebuild(attempt: attempt + 1)
            } else {
                let why: String
                if case .failed(let reason) = self.engine.state { why = reason } else { why = "engine stopped before verification" }
                self.fail(why, retryIn: DaemonPolicy.rebuildDelay)
            }
        }
        queue.asyncAfter(deadline: .now() + DaemonPolicy.rebuildDelay, execute: retryWork!)
    }

    private func scheduleRebuild(attempt: Int, after delay: TimeInterval) {
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild(attempt: attempt) }
        retryWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fail(_ why: String, retryIn delay: TimeInterval, as state: Status.State = .failed) {
        rebuilding = true
        engine.stop()
        // A stale warning about a filter/rate combination that no longer applies must not
        // survive into whatever state comes next.
        filterWarnings = []
        setState(state, error: why)
        scheduleRebuild(attempt: 1, after: delay)
    }

    private func applyProfile() {
        guard let device else { return }
        let resolved = config.profile(forDeviceUID: device.uid)
        if resolved.source == .default, announcedUID != device.uid {
            Log.write("new device \"\(device.name)\" (\(device.uid)) — using default profile")
        }
        announcedUID = device.uid
        profileSource = resolved.source
        engine.processor.solo = solo
        let unstable = engine.processor.apply(profile: resolved.profile, enabled: config.enabled)
        let rate = Int(engine.processor.sampleRate)
        filterWarnings = unstable.map { "\(resolved.profile.engineBandLabel($0)) unstable at \(rate) Hz — bypassed" }
        let profileName = resolved.source == .default ? "default" : resolved.profile.name ?? device.name
        for warning in filterWarnings where loggedFilterWarnings.insert("\(device.uid) \(warning)").inserted {
            Log.write("profile \"\(profileName)\": \(warning)")
        }
        // Read-modify-write from disk so a CLI edit not yet reloaded is not reverted, and skipped
        // while the file is rejected so a half-fixed hand edit survives. `config` is deliberately
        // left alone: the save wakes the watcher, whose reload then applies that pending edit too.
        guard configError == nil else { return }
        if var fresh = try? store.load(), var known = fresh.devices[device.uid], known.name != device.name {
            known.name = device.name
            fresh.devices[device.uid] = known
            try? store.save(fresh, as: .bookkeeping)
        }
    }

    // MARK: - Device listeners

    private func installListeners() {
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.settle.trigger() }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block) == noErr {
                listeners.append((addr, block))
            } else {
                Log.write("cannot listen for \(selector) changes")
            }
        }
    }

    // OnlyEQ #23: the device list can change before the default does, so every event only arms one reconcile that reads the settled truth.
    private func reconcile() {
        guard !asleep else { return }
        // Mid-rebuild the engine may be torn down; the device being built is what a new default must differ from.
        let target = rebuilding ? device?.id ?? 0 : engine.targetDeviceID
        let deviceRate = engine.state == .running ? AudioDeviceManager.nominalSampleRate(engine.targetDeviceID) : nil
        let decision = DaemonPolicy.reconcile(target: target, newDefault: AudioDeviceManager.defaultOutputDeviceID(),
                                              engineRate: engine.processor.sampleRate, deviceRate: deviceRate)
        if decision != .rateUnsettled { rateUnsettled = false }
        switch decision {
        case .keep:
            break
        case .device(let id):
            Log.write("default output changed\(rebuilding ? " during rebuild" : "") → \(AudioDeviceManager.device(id)?.name ?? "?")")
            rebuild(attempt: 1)
        case .rate(let rate):
            Log.write("sample rate \(Int(engine.processor.sampleRate)) → \(Int(rate)) Hz — restarting engine on the same device")
            rebuild(attempt: 1)
        case .rateUnsettled:
            if !rateUnsettled { Log.write("sample rate reads 0 mid-negotiation — waiting for it to settle") }
            rateUnsettled = true
            settle.trigger()
        }
    }

    private func noteCallMode(_ rate: Double) {
        let callMode = DaemonPolicy.isCallMode(rate)
        if callMode, !inCallMode { Log.write("device in call mode at \(Int(rate)) Hz") }
        inCallMode = callMode
    }

    // MARK: - Power

    private func installPowerHandler() {
        let power = SystemPower(queue: queue) { [weak self] event in
            switch event {
            case .willSleep: self?.willSleep()
            case .hasPoweredOn: self?.hasPoweredOn()
            }
        }
        if power.start() { self.power = power } else { Log.write("cannot listen for sleep and wake") }
    }

    private func willSleep() {
        Log.write("system going to sleep — stopping the engine")
        settle.cancel()
        retryWork?.cancel()
        // A device event between wake and the delayed rebuild must be judged as mid-rebuild, like after any other teardown.
        rebuilding = true
        engine.stop()
        asleep = true
        asleepSince = Date()
        filterWarnings = []
        tapSilence.reset()
        setState(.starting, error: nil)
    }

    private func hasPoweredOn() {
        Log.write("system woke — rebuilding in \(Int(DaemonPolicy.wakeDelay)) s")
        asleep = false
        asleepSince = nil
        scheduleRebuild(attempt: 1, after: DaemonPolicy.wakeDelay)
    }

    // MARK: - Config

    private func startWatcher() {
        watcher = ConfigWatcher(url: store.url, queue: queue) { [weak self] in self?.reloadConfig() }
        watcher?.start()
    }

    private func reloadConfig() {
        do {
            let fresh = try store.load()
            let hadError = configError != nil
            configError = nil
            guard fresh != config else {
                if hadError { writeStatus() }
                return
            }
            let enabledChanged = fresh.enabled != config.enabled
            config = fresh
            applyProfile()
            if enabledChanged, state == .running || state == .bypassed {
                setState(config.enabled ? .running : .bypassed, error: nil)
            } else {
                writeStatus()
            }
            Log.write("config reloaded")
        } catch {
            configError = "config rejected, keeping the previous one: \(error)"
            Log.write(configError!)
            writeStatus()
        }
    }

    // MARK: - Status

    private func setState(_ new: Status.State, error: String?) {
        state = new
        lastError = error
        Log.write("state → \(new.rawValue)\(error.map { ": \($0)" } ?? "")")
        writeStatus()
    }

    private func startStatusTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + DaemonPolicy.statusInterval, repeating: DaemonPolicy.statusInterval, leeway: .seconds(1))
        // Callbacks, not frames: the silence gate stops frames on a quiet Mac, but a live IO proc keeps calling back.
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if let asleepSince = self.asleepSince, DaemonPolicy.wakeFallbackDue(asleepSince: asleepSince, now: Date()) {
                Log.write("asleep for over \(Int(DaemonPolicy.wakeFallbackTimeout)) s with the watchdog still ticking — assuming a lost wake message")
                self.asleep = false
                self.asleepSince = nil
                self.rebuild(attempt: 1)
                return
            }
            if self.state == .running || self.state == .bypassed {
                let r = DaemonPolicy.stalled(previous: self.lastCallbacks, current: self.engine.callbacks, unchangedTicks: self.unchangedTicks)
                self.unchangedTicks = r.unchangedTicks
                if r.stalled {
                    Log.write("IO stalled for \(Int(Double(DaemonPolicy.stallTicks) * DaemonPolicy.statusInterval)) s — rebuilding")
                    self.unchangedTicks = 0
                    self.rebuild(attempt: 1)
                    return
                }
            } else {
                self.unchangedTicks = 0
            }
            self.lastCallbacks = self.engine.callbacks
            // Observed every tick, not only on writes, so the silence start is known to within one interval.
            _ = self.observeTap()
            // Nothing changed on this tick: only the 30 s heartbeat justifies a write, to keep disk wear low.
            if DaemonPolicy.shouldWriteStatus(changed: false, sinceLastWrite: Date().timeIntervalSince(self.lastStatusWrite)) {
                self.writeStatus()
            }
        }
        timer.resume()
        statusTimer = timer
    }

    private func observeTap() -> Double? {
        let seconds = tapSilence.observe(callbacks: engine.callbacks, signalCallbacks: engine.signalCallbacks, now: Date())
        return state == .running || state == .bypassed ? seconds : nil
    }

    private func writeStatus() {
        statusWrites += 1
        let status = Status(
            state: state,
            device: device.map { Status.Device(uid: $0.uid, name: $0.name, transport: $0.transportName) },
            sampleRate: engine.processor.sampleRate,
            profile: profileSource,
            framesProcessed: engine.framesProcessed,
            callbacks: engine.callbacks,
            writes: statusWrites,
            enabled: config.enabled,
            error: lastError ?? configError,
            pid: getpid(),
            version: Build.version,
            updatedAt: Date(),
            latencyMs: engine.state == .running ? engine.latencyMs : nil,
            tapSilentSeconds: observeTap(),
            warnings: filterWarnings)
        do { try status.write(to: statusURL) } catch { Log.write("cannot write status: \(error)") }
        lastStatusWrite = Date()
    }
}
