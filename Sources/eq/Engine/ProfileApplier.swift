import Foundation

extension EQProcessor {
    /// The limiter at -1 dBFS is what lets a +4.8 dB bass boost on an already-loud track
    /// not clip the DAC; the preamp stays the user's, the limiter is the safety net.
    func apply(profile: Profile, enabled: Bool) {
        let bands = zip(Config.bandFrequencies, profile.bands).map {
            EQBand(type: .peak, frequency: $0, gain: $1, q: 1.41)
        }
        update(bands: bands, preampDB: profile.preamp, limiterEnabled: true, limiterCeilingDB: -1, bypassed: !enabled)
    }
}
