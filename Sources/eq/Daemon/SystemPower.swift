import Foundation
import IOKit
import IOKit.pwr_mgt

/// Sleep and wake from IOKit's root power domain; NSWorkspace would pull AppKit back into a daemon that dropped it for footprint.
final class SystemPower {
    enum Event { case willSleep, hasPoweredOn }

    // IOMessage.h builds these with iokit_common_msg(), a function-like macro Swift does not import: sys_iokit (0x38 << 26) | message.
    static let canSystemSleep: UInt32 = 0xE000_0270
    static let systemWillSleep: UInt32 = 0xE000_0280
    static let systemHasPoweredOn: UInt32 = 0xE000_0300

    private let queue: DispatchQueue
    private let onEvent: (Event) -> Void
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    init(queue: DispatchQueue, onEvent: @escaping (Event) -> Void) {
        self.queue = queue
        self.onEvent = onEvent
    }

    func start() -> Bool {
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refCon, &notifyPort, { refCon, _, message, argument in
            guard let refCon else { return }
            Unmanaged<SystemPower>.fromOpaque(refCon).takeUnretainedValue().handle(message, argument)
        }, &notifier)
        guard rootPort != 0, let notifyPort else { return false }
        IONotificationPortSetDispatchQueue(notifyPort, queue)
        return true
    }

    private func handle(_ message: UInt32, _ argument: UnsafeMutableRawPointer?) {
        switch message {
        case Self.canSystemSleep:
            allow(argument)
        case Self.systemWillSleep:
            // Stop before acknowledging: once acked the machine may sleep mid-teardown and wake to a half-destroyed aggregate.
            onEvent(.willSleep)
            allow(argument)
        case Self.systemHasPoweredOn:
            onEvent(.hasPoweredOn)
        default:
            break
        }
    }

    // An unacknowledged sleep message stalls system sleep for 30 s.
    private func allow(_ argument: UnsafeMutableRawPointer?) {
        IOAllowPowerChange(rootPort, Int(bitPattern: argument))
    }

    deinit {
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if rootPort != 0 { IOServiceClose(rootPort) }
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
    }
}
