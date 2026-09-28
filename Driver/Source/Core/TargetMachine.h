#pragma once

#include <algorithm>
#include <cstdint>

namespace eqd {

// What the plug-in does to the target's IOProc. Implemented with HAL client calls, so it only ever
// runs on the plug-in's own serial queue.
struct TargetExecutor {
    virtual ~TargetExecutor() = default;
    virtual bool build(uint32_t deviceID) = 0;
    virtual void teardown() = 0;
    virtual bool start() = 0;
    virtual void stop() = 0;
};

struct TargetFacts {
    double now = 0;
    bool found = false;          // the target UID resolves to a live output device
    uint32_t deviceID = 0;
    bool rateMatches = true;     // this device already runs at the target's nominal rate
    bool clientsActive = false;
    double lastCallbackAt = -1;  // when the target IOProc last ran, -1 never
    bool rebuild = false;        // wake, or the target's format or buffer changed
};

struct TargetOutcome {
    bool hidden = false;
    double recheckIn = -1;  // run the next step this many seconds from now, -1 only on events
};

// Decides when to build, start, stop and rebuild the IOProc on the target. Proxy Audio Device b1
// looks the target up once, 1 s after load, and never again if it is missing, which is the silence
// seen live when a Bluetooth speaker appeared a second too late. Here every miss and every failure
// is retried with backoff, a stalled IOProc is rebuilt, and the device only hides after the target
// has been gone for a while.
class TargetMachine {
  public:
    static constexpr double kBackoff[] = {0.1, 0.5, 2.0, 5.0};
    static constexpr double kStallAfter = 1.0;
    static constexpr double kWatchdogEvery = 0.5;
    static constexpr double kIdleStopAfter = 2.0;
    static constexpr double kHideAfter = 3.0;
    static constexpr double kLoadGrace = 10.0;
    static constexpr int kRebuildAfterStartFailures = 3;

    explicit TargetMachine(double loadedAt) : loadedAt_(loadedAt) {}

    TargetOutcome step(const TargetFacts &f, TargetExecutor &x) {
        TargetOutcome out;
        double now = f.now;
        if (f.found) missingSince_ = -1;
        else if (missingSince_ < 0) missingSince_ = now;
        out.hidden = hiddenAt(now);
        if (!f.found && !out.hidden) {
            double flip = std::max(missingSince_ + kHideAfter, loadedAt_ + kLoadGrace);
            recheck(out, flip - now);
        }

        if (!f.found) {
            if (built_) teardown(x);
            if (now >= lookupRetryAt_) lookupRetryAt_ = now + backoff(lookupMisses_++);
            recheck(out, lookupRetryAt_ - now);
            return out;
        }
        lookupMisses_ = 0;
        lookupRetryAt_ = 0;

        bool rebuild = false;
        if (built_ && built_ != f.deviceID) {
            rebuild = true;
        } else if (built_ && f.rebuild) {
            rebuild = true;
            ++requestedRebuilds_;
        } else if (running_ && f.clientsActive) {
            if (f.lastCallbackAt > startedAt_) stallStreak_ = 0;
            double since = std::max(f.lastCallbackAt, startedAt_);
            if (now - since > kStallAfter) {
                rebuild = true;
                ++stalls_;
                retryAt_ = now + backoff(stallStreak_++);
            }
        }
        if (rebuild) teardown(x);

        if (!built_) {
            if (now < retryAt_) {
                recheck(out, retryAt_ - now);
                return out;
            }
            if (!x.build(f.deviceID)) {
                fail(out, now);
                return out;
            }
            built_ = f.deviceID;
            ++builds_;
            startFailures_ = 0;
        }

        if (!f.rateMatches) {
            if (running_) stop(x);
            return out;
        }

        if (f.clientsActive) {
            idleSince_ = -1;
            if (!running_) {
                if (now < retryAt_) {
                    recheck(out, retryAt_ - now);
                    return out;
                }
                if (x.start()) {
                    running_ = true;
                    startedAt_ = now;
                    failures_ = 0;
                    retryAt_ = 0;
                } else {
                    ++startFailureTotal_;
                    if (++startFailures_ >= kRebuildAfterStartFailures) teardown(x);
                    fail(out, now);
                    return out;
                }
            }
            recheck(out, kWatchdogEvery);
        } else if (running_) {
            if (idleSince_ < 0) idleSince_ = now;
            if (now - idleSince_ >= kIdleStopAfter) stop(x);
            else recheck(out, idleSince_ + kIdleStopAfter - now);
        }
        return out;
    }

    bool hiddenAt(double now) const {
        return missingSince_ >= 0 && now - missingSince_ >= kHideAfter && now - loadedAt_ >= kLoadGrace;
    }

    uint32_t builtFor() const { return built_; }
    bool running() const { return running_; }
    uint64_t builds() const { return builds_; }
    uint64_t stalls() const { return stalls_; }
    uint64_t requestedRebuilds() const { return requestedRebuilds_; }
    uint64_t startFailures() const { return startFailureTotal_; }

  private:
    static double backoff(int attempt) {
        constexpr int n = sizeof(kBackoff) / sizeof(kBackoff[0]);
        return kBackoff[std::min(attempt, n - 1)];
    }

    static void recheck(TargetOutcome &out, double in) {
        in = std::max(in, 0.0);
        out.recheckIn = out.recheckIn < 0 ? in : std::min(out.recheckIn, in);
    }

    void fail(TargetOutcome &out, double now) {
        retryAt_ = now + backoff(failures_++);
        recheck(out, retryAt_ - now);
    }

    void teardown(TargetExecutor &x) {
        x.teardown();
        built_ = 0;
        running_ = false;
        idleSince_ = -1;
    }

    void stop(TargetExecutor &x) {
        x.stop();
        running_ = false;
        idleSince_ = -1;
    }

    const double loadedAt_;
    uint32_t built_ = 0;
    bool running_ = false;
    double startedAt_ = 0;
    double idleSince_ = -1;
    double missingSince_ = -1;
    double retryAt_ = 0;
    int failures_ = 0;
    int startFailures_ = 0;
    int stallStreak_ = 0;
    double lookupRetryAt_ = 0;
    int lookupMisses_ = 0;
    uint64_t builds_ = 0;
    uint64_t stalls_ = 0;
    uint64_t requestedRebuilds_ = 0;
    uint64_t startFailureTotal_ = 0;
};

} // namespace eqd
