import Foundation

/// Tracks how long the IO proc has run without the tap delivering a non-zero sample. A revoked
/// System Audio Recording grant keeps callbacks alive but feeds exact zeros, so this is the only trace it leaves.
struct TapSilence {
    private var signalCallbacks: UInt64 = 0
    private var callbacksAtSignal: UInt64 = 0
    private var since: Date?

    /// Returns nil while the IO proc is not advancing, so a stopped or restarting engine never reads as silence.
    mutating func observe(callbacks: UInt64, signalCallbacks: UInt64, now: Date) -> Double? {
        // Counters drop back to zero on every engine restart.
        if since == nil || signalCallbacks != self.signalCallbacks || callbacks < callbacksAtSignal {
            since = now
            self.signalCallbacks = signalCallbacks
            callbacksAtSignal = callbacks
            return callbacks > 0 ? 0 : nil
        }
        guard callbacks > callbacksAtSignal, let since else { return nil }
        return now.timeIntervalSince(since)
    }
}
