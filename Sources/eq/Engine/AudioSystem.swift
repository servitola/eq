import CoreAudio
import Foundation

/// The system's output devices and default output; a fake in tests, so nothing there ever moves the real default.
protocol AudioSystem {
    func outputDevices() -> [AudioOutputDevice]
    func defaultOutput() -> AudioOutputDevice?
    func setDefaultOutput(uid: String) -> Bool
}

struct LiveAudioSystem: AudioSystem {
    func outputDevices() -> [AudioOutputDevice] { AudioDeviceManager.outputDevices() }

    func defaultOutput() -> AudioOutputDevice? {
        AudioDeviceManager.defaultOutputDeviceID().flatMap(AudioDeviceManager.device)
    }

    func setDefaultOutput(uid: String) -> Bool {
        guard let id = AudioDeviceManager.deviceID(uid: uid) else { return false }
        return AudioDeviceManager.setDefaultOutputDevice(id) == noErr
    }
}

/// A context with no audio system: every lookup is empty and every change fails.
struct NoAudioSystem: AudioSystem {
    func outputDevices() -> [AudioOutputDevice] { [] }
    func defaultOutput() -> AudioOutputDevice? { nil }
    func setDefaultOutput(uid: String) -> Bool { false }
}

extension AudioOutputDevice {
    var isEQDevice: Bool { uid == DriverControl.deviceUID }

    /// A device the driver may play on and the daemon follows the user to. Virtual devices and
    /// aggregates may be the EQ device itself or contain it; AirPlay nobody has driven from a plug-in
    /// yet, and the plug-in skips it too.
    var isFollowable: Bool {
        guard !isEQDevice, !uid.hasPrefix(AudioDeviceManager.aggregateUIDPrefix) else { return false }
        return ![kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate,
                 kAudioDeviceTransportTypeAirPlay].contains(transportType)
    }
}

/// Runs Core Audio calls that a wedged plug-in or audio server could block forever.
enum Deadline {
    /// nil when `body` has not returned within `seconds`; it keeps running on its own thread, which
    /// is leaked rather than waited for.
    static func run<T>(_ seconds: TimeInterval, _ body: @escaping () throws -> T) -> Result<T, Error>? {
        let done = DispatchSemaphore(value: 0)
        let box = Box<Result<T, Error>>()
        DispatchQueue.global(qos: .userInitiated).async {
            box.set(Result { try body() })
            done.signal()
        }
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        return box.get()
    }

    private final class Box<T> {
        private let lock = NSLock()
        private var value: T?
        func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
        func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
    }
}
