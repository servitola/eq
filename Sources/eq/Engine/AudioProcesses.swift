import Foundation
import CoreAudio

/// The HAL's client processes, with listeners on the list and on each process.
/// On macOS 26.6 `kAudioProcessPropertyIsRunningOutput` never notified when a process started or
/// stopped playing, while `kAudioProcessPropertyIsRunning` did, both ways; both are watched, and
/// every event re-reads the output flag, so either one is enough.
final class CoreAudioProcesses: AudioProcessSource {
    struct HAL {
        var objects: () -> [AudioObjectID]
        var add: (AudioObjectID, AudioObjectPropertyAddress, @escaping AudioObjectPropertyListenerBlock) -> Bool
        var remove: (AudioObjectID, AudioObjectPropertyAddress, @escaping AudioObjectPropertyListenerBlock) -> Void

        static func live(queue: DispatchQueue) -> HAL {
            HAL(objects: processObjects,
                add: { id, address, block in
                    var addr = address
                    return AudioObjectAddPropertyListenerBlock(id, &addr, queue, block) == noErr
                },
                remove: { id, address, block in
                    var addr = address
                    AudioObjectRemovePropertyListenerBlock(id, &addr, queue, block)
                })
        }
    }

    private let hal: HAL
    private var changed: (() -> Void)?
    private var listListener: AudioObjectPropertyListenerBlock?
    private var processListeners: [AudioObjectID: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)]] = [:]

    private static let watched = [kAudioProcessPropertyIsRunning, kAudioProcessPropertyIsRunningOutput]

    init(hal: HAL) {
        self.hal = hal
    }

    convenience init(queue: DispatchQueue) {
        self.init(hal: .live(queue: queue))
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func processObjects() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    /// Every app with audio open, playing or not, as a person would name it. System daemons outside
    /// any `.app` and eq itself (this process, or the daemon in EQ.app) are left out.
    static func apps() -> [PlayingApp] {
        var apps: [PlayingApp] = []
        for id in processObjects() {
            guard var process = process(id), process.pid != getpid() else { continue }
            process.path = process.path ?? executablePath(process.pid)
            guard process.path.flatMap(AppIdentity.outermostApp) != nil,
                  let app = AppIdentity.identify(process, bundleInfo: AppIdentity.liveBundleInfo),
                  app.id != Build.bundleID, !apps.contains(app) else { continue }
            apps.append(app)
        }
        return apps
    }

    static func process(_ id: AudioObjectID) -> AudioProcess? {
        var addr = address(kAudioProcessPropertyPID)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &pid) == noErr, pid > 0 else { return nil }
        let playing = (uint32(id, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0
        return AudioProcess(pid: pid, bundleID: AudioDeviceManager.stringProperty(id, kAudioProcessPropertyBundleID),
                            path: playing ? executablePath(pid) : nil, playing: playing, object: id)
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [Int8](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    func snapshot() -> [AudioProcess] {
        hal.objects().compactMap(Self.process)
    }

    func start(_ changed: @escaping () -> Void) -> Bool {
        guard listListener == nil else { return true }
        self.changed = changed
        // Removing a listener does not cancel a block the HAL already queued, so one may run after `stop`.
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.listListener != nil else { return }
            self.watchProcesses()
            self.changed?()
        }
        guard hal.add(AudioObjectID(kAudioObjectSystemObject), Self.address(kAudioHardwarePropertyProcessObjectList), block) else { return false }
        listListener = block
        watchProcesses()
        return true
    }

    func stop() {
        if let block = listListener {
            hal.remove(AudioObjectID(kAudioObjectSystemObject), Self.address(kAudioHardwarePropertyProcessObjectList), block)
        }
        listListener = nil
        changed = nil
        for id in Array(processListeners.keys) { unwatch(id) }
    }

    private func watchProcesses() {
        guard listListener != nil else { return }
        let current = Set(hal.objects())
        for id in processListeners.keys where !current.contains(id) { unwatch(id) }
        for id in current where processListeners[id] == nil {
            processListeners[id] = Self.watched.compactMap { selector in
                let addr = Self.address(selector)
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.changed?() }
                return hal.add(id, addr, block) ? (addr, block) : nil
            }
        }
    }

    // A process that exited took its object along; removing from it fails harmlessly.
    private func unwatch(_ id: AudioObjectID) {
        for (address, block) in processListeners.removeValue(forKey: id) ?? [] { hal.remove(id, address, block) }
    }
}
