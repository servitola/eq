/// Keeps a route's delay where it stood when its ring primed, by moving the resampler's ratio: the
/// tap runs on the clock of the device the app plays on, the output on the target's, and nothing
/// else ties the two together. Steering on ring fill instead hunts by a tap buffer, because the fill
/// only moves once per tap cycle (the driver's `Core/Clock.h` notes the same); the delay comes from
/// both IOProcs' host time stamps, so it moves smoothly.
///
/// A PI loop on an integrating plant, 0.3 rad/s at damping 0.9, simulated before it was chosen:
/// 500 ppm pulls in with 0.75 ms of overshoot, well inside the ring's cushion, and 50 µs of time
/// stamp jitter moves the pitch by about 3 ppm. The integral stops growing while the correction is
/// held at its limit, or a large drift would take 45 s instead of 20 to settle. Render thread only:
/// no allocation, no locks.
struct DriftServo {
    static let maxCorrection = 500e-6
    static let proportional = 2 * 0.9 * 0.3
    static let integralGain = 0.3 * 0.3
    /// Error smoothing, seconds: time stamp jitter must not reach the pitch.
    static let smoothing = 0.5
    /// Output cycles averaged into the setpoint after a restart.
    static let settleCycles = 32

    private(set) var correction = 0.0
    private(set) var setpoint: Double?
    private(set) var error = 0.0
    private var integral = 0.0
    private var settleSum = 0.0
    private var settleCount = 0

    /// A new setpoint from the next measurements. The drift learned so far stays: the two clocks did
    /// not change because the ring had to start over.
    mutating func restart() {
        setpoint = nil
        settleSum = 0
        settleCount = 0
        error = 0
        correction = integral * Self.integralGain
    }

    /// `delay` from a tap frame's capture to its output, `interval` since the last update, both in
    /// seconds. Returns the correction to steer by: positive to consume the tap faster.
    mutating func update(delay: Double, interval: Double) -> Double {
        guard delay.isFinite, interval.isFinite, interval > 0 else { return correction }
        guard let setpoint else {
            settleSum += delay
            settleCount += 1
            if settleCount >= Self.settleCycles { self.setpoint = settleSum / Double(settleCount) }
            return correction
        }
        error += (delay - setpoint - error) * interval / (Self.smoothing + interval)
        let limit = Self.maxCorrection / Self.integralGain
        let grown = min(max(integral + error * interval, -limit), limit)
        let wanted = Self.proportional * error + Self.integralGain * grown
        if abs(wanted) <= Self.maxCorrection || (wanted > 0) != (error > 0) { integral = grown }
        correction = min(max(Self.proportional * error + Self.integralGain * integral, -Self.maxCorrection), Self.maxCorrection)
        return correction
    }
}
