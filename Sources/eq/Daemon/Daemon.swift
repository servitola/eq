import Foundation
import CoreAudio

enum DaemonPolicy {
    static let rebuildAttempts = 5
    static let rebuildDelay: TimeInterval = 1
    static let permissionRetry: TimeInterval = 30
    static let statusInterval: TimeInterval = 5

    /// A tap that cannot be created is, on a machine that ran yesterday, almost always the
    /// System Audio Recording grant missing or revoked; every other engine failure is transient.
    static func classify(_ failure: String) -> Status.State {
        failure.contains("create audio tap") ? .noPermission : .failed
    }

    static func shouldRebuild(current: AudioObjectID, newDefault: AudioObjectID?) -> Bool {
        guard let newDefault else { return false }
        return newDefault != current
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
    private var state: Status.State = .starting
    private var statusTimer: DispatchSourceTimer?
    private var retryWork: DispatchWorkItem?
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
        }
    }

    func run() -> Never {
        if let other = Status.read(from: statusURL), other.isAlive(), other.pid != getpid() {
            Log.write("another eq daemon is running (pid \(other.pid)) — exiting")
            exit(1)
        }
        AudioDeviceManager.destroyStaleAggregates()
        engine.onStateChange = { [weak self] state in self?.engineChanged(state) }
        engine.onSampleRateChange = { [weak self] in
            Log.write("sample rate changed — restarting engine on the same device")
            self?.rebuild(attempt: 1)
        }
        installListeners()
        startWatcher()
        startStatusTimer()
        signal(SIGTERM) { _ in Daemon.terminate() }
        signal(SIGINT) { _ in Daemon.terminate() }
        Daemon.current = self
        rebuild(attempt: 1)
        RunLoop.main.run()
        exit(0)
    }

    private static var current: Daemon?

    private static func terminate() {
        current?.engine.stop()
        AudioDeviceManager.destroyStaleAggregates()
        try? FileManager.default.removeItem(at: current?.statusURL ?? Status.defaultURL)
        exit(0)
    }

    // MARK: - Engine

    private func rebuild(attempt: Int) {
        retryWork?.cancel()
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
        applyProfile()
        engine.start(outputDeviceID: deviceID)
        if case .failed(let why) = engine.state {
            let state = DaemonPolicy.classify(why)
            if state == .noPermission {
                fail(why, retryIn: DaemonPolicy.permissionRetry, as: .noPermission)
            } else if attempt < DaemonPolicy.rebuildAttempts {
                Log.write("rebuild \(attempt)/\(DaemonPolicy.rebuildAttempts) failed: \(why)")
                scheduleRebuild(attempt: attempt + 1, after: DaemonPolicy.rebuildDelay)
            } else {
                fail(why, retryIn: nil)
            }
            return
        }
        // Bluetooth devices become default a moment before they deliver frames; verify the
        // path is live before declaring success, otherwise retry the whole build.
        retryWork = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.engine.state == .running, self.engine.framesProcessed > 0 || attempt >= DaemonPolicy.rebuildAttempts {
                self.setState(self.config.enabled ? .running : .bypassed, error: nil)
            } else if self.engine.state == .running {
                Log.write("no frames after \(attempt) attempt(s) — rebuilding")
                self.rebuild(attempt: attempt + 1)
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

    private func fail(_ why: String, retryIn delay: TimeInterval?, as state: Status.State = .failed) {
        engine.stop()
        setState(state, error: why)
        if let delay { scheduleRebuild(attempt: 1, after: delay) }
    }

    private func engineChanged(_ state: ProcessTapEngine.State) {
        if case .failed(let why) = state, self.state == .running || self.state == .bypassed {
            fail(why, retryIn: DaemonPolicy.rebuildDelay)
        }
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
        if var known = config.devices[device.uid], known.name != device.name {
            known.name = device.name
            config.devices[device.uid] = known
            try? store.save(config)
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
        if DaemonPolicy.shouldRebuild(current: engine.targetDeviceID, newDefault: newDefault) {
            Log.write("default output changed → \(newDefault.flatMap(AudioDeviceManager.device)?.name ?? "?")")
            rebuild(attempt: 1)
        } else if state == .failed, newDefault != nil {
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
            guard fresh != config else { return }
            let enabledChanged = fresh.enabled != config.enabled
            config = fresh
            lastError = nil
            applyProfile()
            if enabledChanged, state == .running || state == .bypassed {
                setState(config.enabled ? .running : .bypassed, error: nil)
            } else {
                writeStatus()
            }
            Log.write("config reloaded")
        } catch {
            lastError = "config rejected, keeping the previous one: \(error)"
            Log.write(lastError!)
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
        timer.setEventHandler { [weak self] in self?.writeStatus() }
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
            enabled: config.enabled,
            error: lastError,
            pid: getpid(),
            updatedAt: Date())
        do { try status.write(to: statusURL) } catch { Log.write("cannot write status: \(error)") }
    }
}
