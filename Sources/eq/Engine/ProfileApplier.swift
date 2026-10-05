import EQCore
import Foundation

extension EQProcessor {
    /// The limiter at -1 dBFS is what lets a +4.8 dB bass boost on an already-loud track
    /// not clip the DAC; the preamp stays the user's, the limiter is the safety net.
    /// Returns the engine-band indices bypassed as unstable at the current rate.
    @discardableResult
    func apply(profile: Profile, enabled: Bool, silent: Bool = false) -> [Int] {
        var s = Self.settings(profile: profile, enabled: enabled, silent: silent)
        return publish(&s)
    }

    /// What `apply` hands EQCore, solo aside; the driver gets the same.
    static func settings(profile: Profile, enabled: Bool, silent: Bool = false) -> eqc_settings {
        var s = settings(bands: profile.engineBands, preampDB: profile.preamp, limiterEnabled: true, limiterCeilingDB: -1, bypassed: !enabled,
                         dynamics: profile.dynamics)
        s.silent = silent
        return s
    }
}
