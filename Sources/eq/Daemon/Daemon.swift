import Foundation
import CoreAudio

enum DaemonPolicy {
    static let rebuildAttempts = 5
    static let rebuildDelay: TimeInterval = 1
    static let permissionRetry: TimeInterval = 30
    static let failedRetry: TimeInterval = 30
    static let statusInterval: TimeInterval = 5
    static let stallTicks = 2

    /// A tap that cannot be created is, on a machine that ran yesterday, almost always the
    /// System Audio Recording grant missing or revoked; every other engine failure is transient.
    static func classify(_ failure: String) -> Status.State {
        failure.contains("create audio tap") ? .noPermission : .failed
    }

    static func shouldRebuild(current: AudioObjectID, newDefault: AudioObjectID?) -> Bool {
        guard let newDefault else { return false }
        return newDefault != current
    }

    static func stalled(previous: UInt64, current: UInt64, unchangedTicks: Int) -> (stalled: Bool, unchangedTicks: Int) {
        guard current == previous else { return (false, 0) }
        let ticks = unchangedTicks + 1
        return (ticks >= stallTicks, ticks)
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
    private var lastCallbacks: UInt64 = 0
    private var unchangedTicks = 0
    private var retryWork: DispatchWorkItem?
    // Our own aggregate create/destroy fires the devices listener; cleared only when a rebuild succeeds, and failures retry on a timer, so a self-fired Devices event can never restart the cycle.
    private var rebuilding = false
    private var signalSources: [DispatchSourceSignal] = []
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(store: ConfigStore, statusURL: URL) {
        self.store = store
        self.statusURL = statusURL
        let builtIn = AudioDeviceManager.builtInOutputDevice()
        do {
            config = try store.loadOrCreate(builtInUID: builtIn?.uid, builtInName: builtIn?.name)
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
        writeStatus()
        AudioDeviceManager.destroyStaleAggregates()
        engine.onSampleRateChange = { [weak self] in
            Log.write("sample rate changed — restarting engine on the same device")
            self?.queue.async { [weak self] in self?.rebuild(attempt: 1) }
        }
        installListeners()
        startWatcher()
        startStatusTimer()
        installSignalHandlers()
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
    }

    private func terminate() {
        engine.stop()
        AudioDeviceManager.destroyStaleAggregates()
        try? FileManager.default.removeItem(at: statusURL)
        exit(0)
    }

    // MARK: - Engine

    private func rebuild(attempt: Int) {
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
                Log.write("rebuild \(attempt)/\(DaemonPolicy.rebuildAttempts) failed: \(why)")
                lastError = why
                writeStatus()
                scheduleRebuild(attempt: attempt + 1, after: DaemonPolicy.rebuildDelay)
            } else {
                fail(why, retryIn: DaemonPolicy.failedRetry)
            }
            return
        }
        applyProfile()
        writeStatus()
        // Bluetooth devices become default a moment before they deliver frames; verify the
        // path is live before declaring success, otherwise retry the whole build.
        retryWork = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.engine.state == .running, self.engine.callbacks > 0 || attempt >= DaemonPolicy.rebuildAttempts {
                if self.engine.callbacks == 0 {
                    Log.write("declaring running without IO callbacks after \(attempt) attempts")
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
        engine.processor.apply(profile: resolved.profile, enabled: config.enabled)
        // Read-modify-write from disk so a CLI edit not yet reloaded is not reverted, and skipped
        // while the file is rejected so a half-fixed hand edit survives. `config` is deliberately
        // left alone: the save wakes the watcher, whose reload then applies that pending edit too.
        guard configError == nil else { return }
        if var fresh = try? store.load(), var known = fresh.devices[device.uid], known.name != device.name {
            known.name = device.name
            fresh.devices[device.uid] = known
            try? store.save(fresh)
        }
    }

    // MARK: - Device listeners

    private func installListeners() {
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.devicesChanged() }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block) == noErr {
                listeners.append((addr, block))
            } else {
                Log.write("cannot listen for \(selector) changes")
            }
        }
    }

    private func devicesChanged() {
        let newDefault = AudioDeviceManager.defaultOutputDeviceID()
        if rebuilding {
            if let newDefault, newDefault != device?.id {
                Log.write("default output changed during rebuild → \(AudioDeviceManager.device(newDefault)?.name ?? "?")")
                rebuild(attempt: 1)
            }
            return
        }
        if DaemonPolicy.shouldRebuild(current: engine.targetDeviceID, newDefault: newDefault) {
            Log.write("default output changed → \(newDefault.flatMap(AudioDeviceManager.device)?.name ?? "?")")
            rebuild(attempt: 1)
        }
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
        timer.schedule(deadline: .now() + DaemonPolicy.statusInterval, repeating: DaemonPolicy.statusInterval)
        // Callbacks, not frames: the silence gate stops frames on a quiet Mac, but a live IO proc keeps calling back.
        timer.setEventHandler { [weak self] in
            guard let self else { return }
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
            self.writeStatus()
        }
        timer.resume()
        statusTimer = timer
    }

    private func writeStatus() {
        let status = Status(
            state: state,
            device: device.map { Status.Device(uid: $0.uid, name: $0.name, transport: $0.transportName) },
            sampleRate: engine.processor.sampleRate,
            profile: profileSource,
            framesProcessed: engine.framesProcessed,
            callbacks: engine.callbacks,
            enabled: config.enabled,
            error: lastError ?? configError,
            pid: getpid(),
            updatedAt: Date())
        do { try status.write(to: statusURL) } catch { Log.write("cannot write status: \(error)") }
    }
}
