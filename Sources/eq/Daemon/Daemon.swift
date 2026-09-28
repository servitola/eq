import Foundation
import CoreAudio

enum DaemonPolicy {
    static let rebuildAttempts = 5
    static let rebuildDelay: TimeInterval = 1
    static let permissionRetry: TimeInterval = 30
    static let failedRetry: TimeInterval = 30
    static let statusInterval: TimeInterval = 5
    static let stallTicks = 2
    // 15 s of slips on every tick: a healthy ring never slips, since the tap writes zeros through
    // silence, so this is a path that stopped keeping pace, not one glitch.
    static let ringFailingTicks = 3
    static let heartbeat: TimeInterval = 30
    // FineTune #86/#324: device events arrive in bursts and a rate can read 0 mid-negotiation; 150 ms lets both settle.
    static let settleDelay: TimeInterval = 0.15
    static let wakeDelay: TimeInterval = 1
    // Wideband SCO runs at 24 kHz, so a classic-HFP threshold of 16 kHz misses it; every music rate is at least 44.1 kHz.
    static let callModeBelow: Double = 44100
    // A missed wake notification would otherwise leave the daemon silently stopped forever;
    // the watchdog timer itself ticking is proof the process is alive to fall back on.
    static let wakeFallbackTimeout: TimeInterval = 120
    // KeepAlive restarts an exited daemon after ThrottleInterval (5 s); a refused one waits
    // first, so a lasting conflict costs a log line a minute, not twelve.
    static let refusedExitDelay: TimeInterval = 60

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

    /// `current` is underruns + overruns + dropouts; a restarted engine starts again from zero.
    static func ringFailing(previous: UInt64, current: UInt64, risingTicks: Int) -> (failing: Bool, risingTicks: Int) {
        guard current > previous else { return (false, 0) }
        let ticks = risingTicks + 1
        return (ticks >= ringFailingTicks, ticks)
    }

    static func ioFrames(from env: [String: String]) -> Int? {
        guard let raw = env["EQ_IO_FRAMES"], let frames = Int(raw), (64...4096).contains(frames) else { return nil }
        return frames
    }

    static func driftCompensation(from env: [String: String]) -> Bool? {
        switch env["EQ_DRIFT_COMPENSATION"] {
        case "1": return true
        case "0": return false
        default: return nil
        }
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
    private var lastTapCallbacks: UInt64 = 0
    private var unchangedTapTicks = 0
    private var lastRingSlips: UInt64 = 0
    private var risingRingTicks = 0
    private var loggedDropout = false
    private var loggedUnderrun = false
    private var loggedOverrun = false
    private var retryWork: DispatchWorkItem?
    // Our own aggregate create/destroy fires the devices listener; cleared only when a rebuild succeeds, and failures retry on a timer, so a self-fired Devices event can never restart the cycle.
    private var rebuilding = false
    private var signalSources: [DispatchSourceSignal] = []
    // Held open for the process's life: closing it would release the lock.
    private var lock: Int32?
    private var executableWatcher: ExecutableWatcher?
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
    private let hooks: Hooks
    private lazy var events = EventTracker(enabled: config.enabled, hooks: hooks) { [weak self] in self?.meterServer?.publish($0) }
    private lazy var apps = AppFollower(
        source: CoreAudioProcesses(queue: queue),
        identify: { AppIdentity.identify($0, bundleInfo: AppIdentity.liveBundleInfo) },
        nowPlaying: NowPlaying.live(queue: queue),
        schedule: { [queue] delay, work in queue.asyncAfter(deadline: .now() + delay, execute: work) },
        onChange: { [weak self] in self?.appChanged($0, previous: $1) })

    init(store: ConfigStore, statusURL: URL, runHook: @escaping (HookRun) -> Void = HookRunner.live()) {
        self.store = store
        self.statusURL = statusURL
        hooks = Hooks(queue: queue, run: runHook)
        let builtIn = AudioDeviceManager.builtInOutputDevice()
        do {
            config = try store.loadOrDefault { builtIn.map { ($0.uid, $0.name) } }
            if store.exists(), config.seedPresetsIfNeeded() {
                // .edit — this is the one-time pre-v5 migration, so the file as it was
                // before presets existed stays recoverable as eq.json.1.
                do { try store.save(config, as: .edit) } catch { Log.write("cannot seed presets: \(error)") }
            }
        } catch {
            Log.write("config unreadable (\(error)); starting with the built-in curve")
            config = Config.initial(builtInUID: builtIn?.uid, builtInName: builtIn?.name)
            configError = "config rejected, using the built-in curve: \(error)"
        }
        hooks.configure(config.hooks)
    }

    func run() -> Never {
        if let reason = refusal() {
            Log.write("\(reason) — exiting")
            Thread.sleep(forTimeInterval: DaemonPolicy.refusedExitDelay)
            exit(0)
        }
        // A status file carrying `version` tells doctor SIGUSR1 is safe; the handler must exist before that file does.
        installSignalHandlers()
        Self.ignoreBrokenPipes()
        watchExecutable()
        startMeterServer()
        let env = ProcessInfo.processInfo.environment
        if let frames = DaemonPolicy.ioFrames(from: env) {
            engine.requestedIOBufferFrames = frames
            Log.write("IO buffer requested: \(frames) frames")
        } else if let raw = env["EQ_IO_FRAMES"] {
            Log.write("EQ_IO_FRAMES ignored: \(raw)")
        }
        if let drift = DaemonPolicy.driftCompensation(from: env) {
            engine.driftCompensation = drift
            Log.write("tap drift compensation: \(drift)")
        } else if let raw = env["EQ_DRIFT_COMPENSATION"] {
            Log.write("EQ_DRIFT_COMPENSATION ignored: \(raw)")
        }
        writeStatus()
        AudioDeviceManager.destroyStaleAggregates()
        engine.onSampleRateChange = { [weak self] in self?.settle.trigger() }
        installListeners()
        installPowerHandler()
        startWatcher()
        apps.configure(config)
        startStatusTimer()
        rebuild(attempt: 1)
        RunLoop.main.run()
        exit(0)
    }

    /// The status check catches a daemon from before the lock existed.
    private func refusal() -> String? {
        if LaunchAgent.bundledDaemonYields(environment: ProcessInfo.processInfo.environment, agent: LiveLaunchAgent()) {
            return "the legacy \(LaunchAgent.legacyLabel) agent is in use; the bundled daemon stays off"
        }
        if let other = Status.read(from: statusURL), other.isAlive(), other.pid != getpid() {
            return "another eq daemon is running (pid \(other.pid))"
        }
        let lockURL = DaemonLock.url(beside: statusURL)
        switch DaemonLock.acquire(lockURL) {
        case .acquired(let fd): lock = fd
        case .held(let pid): return "another eq daemon holds \(lockURL.path)" + (pid.map { " (pid \($0))" } ?? "")
        case .failed(let why): Log.write("\(why); running without the single-instance lock")
        }
        return nil
    }

    /// Every client socket also sets SO_NOSIGPIPE; this covers one where that failed or was never set.
    static func ignoreBrokenPipes() {
        signal(SIGPIPE, SIG_IGN)
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

    /// launchd's KeepAlive starts the new binary once this one exits.
    private func watchExecutable() {
        guard let path = Bundle.main.executablePath else { return }
        let watcher = ExecutableWatcher(path: path, queue: queue) { [weak self] change in
            Log.write(change == .replaced ? "binary replaced — restarting" : "binary removed — exiting")
            self?.terminate()
        }
        watcher.start()
        executableWatcher = watcher
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
            onSolo: { [unowned self] range in self.setSolo(range) },
            hello: { [unowned self] in self.events.current })
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
            events.solo(nil)
            return true
        }
        guard processor.setSolo(low: range.low, high: range.high), let effective = processor.effectiveSolo else { return false }
        if solo != range { logSolo(String(format: "solo %.0f–%.0f Hz", effective.low, effective.high)) }
        solo = range
        events.solo(effective)
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
        let profile = device.map { heard(config.profile(forDeviceUID: $0.uid).profile) }
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
            solo: solo.flatMap { EQProcessor.clampSolo(low: $0.low, high: $0.high, sampleRate: processor.sampleRate) },
            app: apps.overlay,
            comp: compReduction(profile).map(MeterFrame.round1))
    }

    private func heard(_ base: Profile) -> Profile {
        AppOverlay.heard(base, apps.overlay, in: config)
    }

    /// Only while a compressor runs: a bypassed or compressor-less curve has no reduction to report.
    private func compReduction(_ profile: Profile?) -> Double? {
        guard config.enabled, engine.state == .running, profile?.dynamics?.comp != nil else { return nil }
        return Double(engine.processor.compressorReductionDB)
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
            let live = self.engine.callbacks > 0 && self.engine.tapCallbacks > 0
            if self.engine.state == .running, live || attempt >= DaemonPolicy.rebuildAttempts {
                if !live {
                    Log.write("declaring running without IO callbacks after \(attempt) attempts")
                } else if attempt > 1 {
                    Log.write("running after \(attempt) attempts")
                }
                self.rebuilding = false
                self.engine.logActualSampleRates()
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
        let playing = heard(resolved.profile)
        let unstable = engine.processor.apply(profile: playing, enabled: config.enabled)
        let rate = Int(engine.processor.sampleRate)
        filterWarnings = unstable.map { "\(playing.engineBandLabel($0)) unstable at \(rate) Hz — bypassed" }
        let profileName = apps.overlay.map { "preset \($0.preset)" } ?? (resolved.source == .default ? "default" : resolved.profile.name ?? device.name)
        for warning in filterWarnings where loggedFilterWarnings.insert("\(device.uid) \(warning)").inserted {
            Log.write("profile \"\(profileName)\": \(warning)")
        }
        for name in playing.unknownInstruments where loggedFilterWarnings.insert("\(device.uid) instrument \(name)").inserted {
            Log.write("profile \"\(profileName)\": no instrument \"\(name)\" — its boost is ignored")
        }
        // Profile events and hooks stay about the device's own curve; an app rule has its own event.
        if engine.state == .running {
            events.applied(device: Status.Device(uid: device.uid, name: device.name, transport: device.transportName),
                           rate: engine.processor.sampleRate, profile: resolved.profile, source: resolved.source)
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
            // A deleted file means the defaults again, exactly as if it had never been written.
            let fresh = try store.loadOrDefault { AudioDeviceManager.builtInOutputDevice().map { ($0.uid, $0.name) } }
            let hadError = configError != nil
            configError = nil
            guard fresh != config else {
                if hadError { writeStatus() }
                return
            }
            let enabledChanged = fresh.enabled != config.enabled
            let edited = device.map { AppOverlay.edited(config, fresh, uid: $0.uid) } ?? false
            let held = edited ? apps.hold() : nil
            config = fresh
            hooks.configure(config.hooks)
            apps.configure(config)
            if let held {
                Log.write("apps: the curve was edited while \(held.name) plays — the edit plays until it stops")
                events.app(nil, previous: held)
            }
            events.enabled(config.enabled)
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

    // MARK: - Apps

    private func appChanged(_ match: AppMatch?, previous: AppMatch?) {
        if let match {
            Log.write("apps: \(match.name) plays — \(match.preset)")
        } else if let previous {
            Log.write("apps: \(previous.name) stopped — back to the device's curve")
        }
        events.app(match, previous: previous)
        applyProfile()
        writeStatus()
    }

    // MARK: - Status

    private func setState(_ new: Status.State, error: String?) {
        state = new
        lastError = error
        Log.write("state → \(new.rawValue)\(error.map { ": \($0)" } ?? "")")
        events.state(new, error: error)
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
                let output = DaemonPolicy.stalled(previous: self.lastCallbacks, current: self.engine.callbacks, unchangedTicks: self.unchangedTicks)
                let tap = DaemonPolicy.stalled(previous: self.lastTapCallbacks, current: self.engine.tapCallbacks, unchangedTicks: self.unchangedTapTicks)
                self.unchangedTicks = output.unchangedTicks
                self.unchangedTapTicks = tap.unchangedTicks
                if output.stalled || tap.stalled {
                    Log.write("\(output.stalled ? "output" : "tap") IO stalled for \(Int(Double(DaemonPolicy.stallTicks) * DaemonPolicy.statusInterval)) s — rebuilding")
                    self.unchangedTicks = 0
                    self.unchangedTapTicks = 0
                    self.rebuild(attempt: 1)
                    return
                }
                self.noteRingEvents()
                let slips = self.ringSlips
                let ring = DaemonPolicy.ringFailing(previous: self.lastRingSlips, current: slips, risingTicks: self.risingRingTicks)
                self.lastRingSlips = slips
                self.risingRingTicks = ring.risingTicks
                if ring.failing {
                    Log.write("ring slipped on \(DaemonPolicy.ringFailingTicks) status ticks in a row (\(self.engine.underruns) underruns, \(self.engine.overruns) overruns, \(self.engine.dropouts) dropouts) — rebuilding")
                    self.lastRingSlips = 0
                    self.risingRingTicks = 0
                    self.rebuild(attempt: 1)
                    return
                }
            } else {
                self.unchangedTicks = 0
                self.unchangedTapTicks = 0
                self.risingRingTicks = 0
                self.lastRingSlips = self.ringSlips
                self.noteRingEvents()
            }
            self.lastCallbacks = self.engine.callbacks
            self.lastTapCallbacks = self.engine.tapCallbacks
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

    private var ringSlips: UInt64 { engine.underruns &+ engine.overruns &+ engine.dropouts }

    /// The first of each kind per engine run; the rest only count in the status.
    private func noteRingEvents() {
        if engine.underruns == 0 {
            loggedUnderrun = false
        } else if !loggedUnderrun {
            Log.write("ring underrun: the tap fell behind the output, which played silence for the gap and refilled")
            loggedUnderrun = true
        }
        if engine.overruns == 0 {
            loggedOverrun = false
        } else if !loggedOverrun {
            Log.write("ring overrun: audio piled up behind the output, which dropped the oldest to keep the delay down")
            loggedOverrun = true
        }
        if engine.dropouts == 0 {
            loggedDropout = false
        } else if !loggedDropout {
            Log.write("dropout: a tap or output buffer came in a shape eq did not prepare for and was dropped whole")
            loggedDropout = true
        }
    }

    private func observeTap() -> Double? {
        let seconds = tapSilence.observe(callbacks: engine.tapCallbacks, signalCallbacks: engine.signalCallbacks, now: Date())
        return state == .running || state == .bypassed ? seconds : nil
    }

    private func writeStatus() {
        statusWrites += 1
        let running = engine.state == .running
        let added = engine.addedLatency
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
            latencyMs: running ? engine.latencyMs : nil,
            tapSilentSeconds: observeTap(),
            warnings: filterWarnings,
            deviceLatencyMs: running ? engine.deviceLatencyMs : nil,
            addedLatencyMs: running ? added?.milliseconds() : nil,
            addedLatencyFrames: running ? added?.frames : nil,
            lastOnset: running ? engine.lastOnset : nil,
            underruns: running ? engine.underruns : nil,
            overruns: running ? engine.overruns : nil,
            dropouts: running ? engine.dropouts : nil,
            apps: apps.status,
            compReductionDB: compReduction(device.map { heard(config.profile(forDeviceUID: $0.uid).profile) }).map(MeterFrame.round1))
        do { try status.write(to: statusURL) } catch { Log.write("cannot write status: \(error)") }
        lastStatusWrite = Date()
    }
}
