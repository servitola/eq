import CoreAudio
import Foundation

/// An output device's mute, per element; a fake in tests, so nothing there touches a real device.
protocol MuteControl: AnyObject {
    /// The output-scope elements whose mute can be set, main first; nil when the device is not there.
    func muteElements(_ uid: String) -> [UInt32]?
    func isMuted(_ uid: String, _ element: UInt32) -> Bool?
    func setMuted(_ uid: String, _ element: UInt32, _ muted: Bool) -> Bool
    /// Calls `changed` whenever one of the elements' mute changes, until `unwatch`; replaces an earlier watch.
    func watch(_ uid: String, _ elements: [UInt32], _ changed: @escaping () -> Void)
    func unwatch(_ uid: String)
}

final class CoreAudioMute: MuteControl {
    private let queue: DispatchQueue
    private var watches: [String: (device: AudioObjectID, listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)])] = [:]

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    private static func address(_ element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }

    private static func settable(_ device: AudioObjectID, _ element: UInt32) -> Bool {
        var address = address(element)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &address) && AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    func muteElements(_ uid: String) -> [UInt32]? {
        guard let device = AudioDeviceManager.deviceID(uid: uid) else { return nil }
        let channels = UInt32(min(AudioDeviceManager.outputChannelCount(device), 64))
        return ([kAudioObjectPropertyElementMain] + (channels > 0 ? Array(1...channels) : [])).filter { Self.settable(device, $0) }
    }

    func isMuted(_ uid: String, _ element: UInt32) -> Bool? {
        guard let device = AudioDeviceManager.deviceID(uid: uid) else { return nil }
        var address = Self.address(element)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value != 0 : nil
    }

    func setMuted(_ uid: String, _ element: UInt32, _ muted: Bool) -> Bool {
        guard let device = AudioDeviceManager.deviceID(uid: uid) else { return false }
        var address = Self.address(element)
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    func watch(_ uid: String, _ elements: [UInt32], _ changed: @escaping () -> Void) {
        unwatch(uid)
        guard let device = AudioDeviceManager.deviceID(uid: uid) else { return }
        var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
        for element in elements {
            var address = Self.address(element)
            let block: AudioObjectPropertyListenerBlock = { _, _ in changed() }
            if AudioObjectAddPropertyListenerBlock(device, &address, queue, block) == noErr { listeners.append((address, block)) }
        }
        watches[uid] = (device, listeners)
    }

    func unwatch(_ uid: String) {
        guard let watch = watches.removeValue(forKey: uid) else { return }
        for (address, block) in watch.listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(watch.device, &address, queue, block)
        }
    }
}
