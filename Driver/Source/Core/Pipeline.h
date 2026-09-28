#pragma once

#include "Clock.h"
#include "FrameRing.h"
#include "SeqLock.h"

#include <atomic>
#include <climits>
#include <cmath>
#include <cstdint>
#include <cstring>

namespace eqd {

struct Counters {
    std::atomic<uint64_t> underruns{0};
    std::atomic<uint64_t> overruns{0};
    std::atomic<uint64_t> resyncs{0};
    std::atomic<int64_t> phaseError{0};  // frames the target's reads sit off the anchored cushion
};

// Everything the virtual device's IO thread and the target's IOProc share. Both sides only touch
// atomics, the ring and SeqLocks; nothing here blocks.
struct Pipeline {
    static constexpr uint32_t kChannels = 2;
    static constexpr uint32_t kRingFrames = 32768;

    FrameRing ring{kChannels, kRingFrames, int64_t(kTimelineJumpTolerance)};
    SeqLock<ClockSnapshot> clock;
    SeqLock<ServoFeedback> feedback;
    std::atomic<uint64_t> feedbackEpoch{0};
    std::atomic<bool> startPending{false};
    std::atomic<bool> producing{false};
    std::atomic<int64_t> finalFrame{INT64_MAX};
    Counters counters;

    // HAL IO thread, WriteMix.
    void write(const float *interleaved, uint32_t frames, int64_t sampleTime) {
        if (startPending.exchange(false, std::memory_order_acq_rel)) {
            finalFrame.store(INT64_MAX, std::memory_order_relaxed);
            producing.store(true, std::memory_order_release);
        }
        if (ring.write(interleaved, frames, sampleTime) == FrameRing::Write::Restart)
            counters.resyncs.fetch_add(1, std::memory_order_relaxed);
    }

    // First StartIO and last StopIO. A non-final client's StopIO must not end playback, and a
    // later client's StartIO must not wipe the ring under the ones already playing (PR #74).
    void firstClientStarted() { startPending.store(true, std::memory_order_release); }
    void lastClientStopped() {
        startPending.store(false, std::memory_order_relaxed);
        finalFrame.store(ring.end(), std::memory_order_relaxed);
        producing.store(false, std::memory_order_release);
    }
};

struct TargetCycle {
    double sampleTime = 0;
    uint64_t hostTime = 0;
    bool hostValid = false;
    double rateScalar = 1.0;
    bool rateValid = false;
    uint32_t frames = 0;
};

// The target IOProc's side: one per built target IOProc, never shared by two threads. It reads the
// ring at the target's sample time plus an anchored offset, keeps that offset `cushion` frames
// behind this device's clock, and reports the phase error for the clock servo.
class Reader {
  public:
    Reader(Pipeline &pipeline, uint32_t cushion) : p_(pipeline), cushion_(cushion) {}

    uint32_t cushion() const { return cushion_; }

    void render(const TargetCycle &cycle, float *stereo) {
        if (watch_.observe(cycle.sampleTime, cycle.frames) && anchored_) {
            anchored_ = false;
            p_.counters.resyncs.fetch_add(1, std::memory_order_relaxed);
        }
        if (cycle.rateValid && cycle.rateScalar > 0.9 && cycle.rateScalar < 1.1) {
            rateSum_ += cycle.rateScalar;
            ++rateCount_;
        }

        bool producing = p_.producing.load(std::memory_order_acquire);
        uint64_t ringEpoch = p_.ring.epoch();
        if (anchored_ && ringEpoch != anchorRingEpoch_) anchored_ = false;

        ClockSnapshot snap;
        if (p_.clock.read(snap, 3)) {
            clock_ = snap;
            haveClock_ = true;
        }
        if (!haveClock_ || !p_.ring.hasData() || (!anchored_ && (!producing || !cycle.hostValid))) {
            std::memset(stereo, 0, size_t(cycle.frames) * Pipeline::kChannels * sizeof(float));
            publish();
            return;
        }
        if (!anchored_) anchor(cycle, ringEpoch);

        int64_t start = std::llround(cycle.sampleTime + delta_);
        if (producing) {
            int64_t fill = p_.ring.end() - start;
            int64_t capacity = p_.ring.capacity();
            if (fill > capacity || fill < -capacity) {
                anchor(cycle, ringEpoch);
                start = std::llround(cycle.sampleTime + delta_);
                p_.counters.resyncs.fetch_add(1, std::memory_order_relaxed);
            }
            if (cycle.hostValid) {
                double error = projectSample(clock_, cycle.hostTime) - double(start) - double(cushion_);
                phaseSum_ += error;
                ++phaseCount_;
                p_.counters.phaseError.store(std::llround(error), std::memory_order_relaxed);
            }
        }

        FrameRing::Read got = p_.ring.read(stereo, cycle.frames, start);
        if (producing && got.valid) {
            if (got.underrun) p_.counters.underruns.fetch_add(1, std::memory_order_relaxed);
            if (got.overrun) p_.counters.overruns.fetch_add(1, std::memory_order_relaxed);
        }
        publish();
    }

  private:
    void anchor(const TargetCycle &cycle, uint64_t ringEpoch) {
        double start = std::floor(projectSample(clock_, cycle.hostTime) - double(cushion_));
        delta_ = start - cycle.sampleTime;
        anchored_ = true;
        anchorRingEpoch_ = ringEpoch;
        epoch_ = p_.feedbackEpoch.fetch_add(1, std::memory_order_relaxed) + 1;
        rateSum_ = phaseSum_ = 0.0;
        rateCount_ = phaseCount_ = 0;
    }

    void publish() {
        if (epoch_ != 0) p_.feedback.publish({epoch_, rateCount_, phaseCount_, rateSum_, phaseSum_});
    }

    Pipeline &p_;
    const uint32_t cushion_;
    TimelineWatch watch_;
    ClockSnapshot clock_{0, 0, 1};
    bool haveClock_ = false;
    bool anchored_ = false;
    uint64_t anchorRingEpoch_ = 0;
    double delta_ = 0.0;
    uint64_t epoch_ = 0;
    double rateSum_ = 0.0, phaseSum_ = 0.0;
    uint64_t rateCount_ = 0, phaseCount_ = 0;
};

} // namespace eqd
