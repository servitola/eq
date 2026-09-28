#pragma once

#include <algorithm>

namespace eqd {

// The one RequestDeviceConfigurationChange allowed in flight. The host answers it with Perform or
// Abort; one it refuses, aborts or never answers within kTimeout is sent again with backoff, so a
// lost request cannot leave the device at the wrong rate for good.
class ChangeRequest {
  public:
    static constexpr double kTimeout = 3.0;
    static constexpr double kBackoff[] = {1.0, 2.0, 5.0, 10.0};

    bool pending(double now) {
        if (sentAt_ >= 0 && now - sentAt_ >= kTimeout) failed(now);
        return sentAt_ >= 0;
    }

    // Whether to send one now; if so it counts as in flight from now.
    bool send(double now) {
        if (pending(now) || now < retryAt_) return false;
        sentAt_ = now;
        return true;
    }

    void performed() {
        sentAt_ = -1;
        retryAt_ = 0;
        misses_ = 0;
    }

    void failed(double now) {
        sentAt_ = -1;
        constexpr int n = sizeof(kBackoff) / sizeof(kBackoff[0]);
        retryAt_ = now + kBackoff[std::min(misses_++, n - 1)];
    }

    // When the next send could go out or the one in flight expires; -1 when neither.
    double recheckIn(double now) const {
        if (sentAt_ >= 0) return std::max(sentAt_ + kTimeout - now, 0.0);
        return now < retryAt_ ? retryAt_ - now : -1;
    }

  private:
    double sentAt_ = -1;
    double retryAt_ = 0;
    int misses_ = 0;
};

} // namespace eqd
