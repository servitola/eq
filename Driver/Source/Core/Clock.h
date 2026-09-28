#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace eqd {

// The clock servo and the timeline checks are Proxy Audio Device v1.1.0b1's (vlasky's PR #74),
// reshaped so the two sides only meet through SeqLocks instead of a shared mutex.

// A forward jump of a device's IO sample time larger than this, or any backward jump, means the
// device started a new timeline: coreaudiod restarts an engine in place on display wake or a
// usbaudiod restart, and its sample time falls back to about 13 700 with no notification.
constexpr double kTimelineJumpTolerance = 16384.0;

struct TimelineWatch {
    double expected = -1.0;

    bool observe(double sampleTime, uint32_t frames) {
        bool jumped = false;
        if (expected >= 0.0) {
            double jump = sampleTime - expected;
            jumped = jump < -0.5 || jump > kTimelineJumpTolerance;
        }
        expected = sampleTime + frames;
        return jumped;
    }
};

struct ClockSnapshot {
    double zeroSample;
    uint64_t zeroHost;
    double ticksPerFrame;
};

inline double projectSample(const ClockSnapshot &clock, uint64_t hostTime) {
    return clock.zeroSample + double(int64_t(hostTime - clock.zeroHost)) / clock.ticksPerFrame;
}

// What the target's IOProc tells the clock: cumulative sums since `epoch` began. A new epoch is a
// new anchor, so the clock restarts its integral.
struct ServoFeedback {
    uint64_t epoch;
    uint64_t rateCount;
    uint64_t phaseCount;
    double rateSum;
    double phaseSum;
};

// Gains are per frame of phase error, applied once per zero time stamp period: a ~24 s time
// constant with damping ~0.7 at 44.1 kHz. Steering on ring fill instead "hunts" by ±256 frames
// (PR #74), because the write position only moves once per client IO cycle.
constexpr double kServoGainP = 1.0 / (64.0 * 16384.0);
constexpr double kServoGainI = kServoGainP / 128.0;
constexpr double kServoMaxCorrection = 500e-6;
constexpr double kServoMaxIntegral = kServoMaxCorrection / kServoGainI;

// The virtual device's synthetic clock. Zero time stamps advance by every whole period elapsed; the
// period's length is nominal × the target's measured rate scalar (feed-forward) × a clamped PI
// correction on the phase between this timeline and the target's IO cycles (feedback).
class VirtualClock {
  public:
    static constexpr uint32_t kPeriod = 16384;

    explicit VirtualClock(double nominalTicksPerFrame) : nominal_(nominalTicksPerFrame) {}

    void setNominal(double ticksPerFrame) { nominal_ = ticksPerFrame; }
    bool anchored() const { return anchored_; }

    void anchor(uint64_t now) {
        anchorHost_ = now;
        elapsedTicks_ = 0.0;
        stamps_ = 0;
        anchored_ = true;
    }

    void advance(uint64_t now, const ServoFeedback *feedback) {
        double period = ticksPerPeriod();
        double since = double(int64_t(now - anchorHost_)) - elapsedTicks_;
        if (period <= 0.0 || since < period) return;
        uint64_t periods = uint64_t(since / period);
        stamps_ += periods;
        elapsedTicks_ += double(periods) * period;
        if (feedback) steer(*feedback);
    }

    double zeroSample() const { return double(stamps_) * kPeriod; }
    uint64_t zeroHost() const { return anchorHost_ + uint64_t(elapsedTicks_); }
    ClockSnapshot snapshot() const { return {zeroSample(), zeroHost(), ticksPerPeriod() / kPeriod}; }
    double correctionPpm() const { return (correction_ - 1.0) * 1e6; }
    double rateRatio() const { return rateRatio_; }

  private:
    double ticksPerPeriod() const { return nominal_ * kPeriod * rateRatio_ * correction_; }

    void steer(const ServoFeedback &feedback) {
        if (feedback.epoch != epoch_) {
            epoch_ = feedback.epoch;
            seen_ = {feedback.epoch, 0, 0, 0.0, 0.0};
            integral_ = 0.0;
        }
        uint64_t rates = feedback.rateCount - seen_.rateCount;
        if (rates > 0) rateRatio_ = (feedback.rateSum - seen_.rateSum) / double(rates);
        uint64_t phases = feedback.phaseCount - seen_.phaseCount;
        if (phases > 0) {
            double error = (feedback.phaseSum - seen_.phaseSum) / double(phases);
            integral_ = std::clamp(integral_ + error, -kServoMaxIntegral, kServoMaxIntegral);
            // Positive error: this clock gained on the target (written faster than read), so
            // lengthen the period.
            double correction = kServoGainP * error + kServoGainI * integral_;
            correction_ = 1.0 + std::clamp(correction, -kServoMaxCorrection, kServoMaxCorrection);
        }
        seen_ = feedback;
    }

    double nominal_;
    double rateRatio_ = 1.0;
    double correction_ = 1.0;
    double integral_ = 0.0;
    uint64_t epoch_ = 0;
    ServoFeedback seen_{0, 0, 0, 0.0, 0.0};
    uint64_t anchorHost_ = 0;
    double elapsedTicks_ = 0.0;
    uint64_t stamps_ = 0;
    bool anchored_ = false;
};

} // namespace eqd
