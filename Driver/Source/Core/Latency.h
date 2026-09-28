#pragma once

#include <cstdint>

namespace eqd {

struct TargetTiming {
    uint32_t deviceLatency = 0;
    uint32_t streamLatency = 0;
    uint32_t safetyOffset = 0;
    uint32_t bufferFrames = 0;
};

// Covers HAL wake-up jitter on both IO threads; the soak run tunes it.
constexpr uint32_t kCushionMarginFrames = 256;

// How far the target's reads trail this device's timeline. The HAL writes this device's frames
// just in time (safety offset 0), while the target's IOProc runs a buffer plus its safety offset
// ahead of the hardware and then reads one more buffer; anything shorter underruns.
inline uint32_t cushionFrames(const TargetTiming &t) {
    return t.safetyOffset + 2 * t.bufferFrames + kCushionMarginFrames;
}

// A frame written at this device's time S reaches the target's output at S + cushion and leaves
// the speaker after the target's own latencies. Players add this device's buffer and safety offset
// themselves.
inline uint32_t reportedLatency(const TargetTiming &t, uint32_t cushion) {
    return t.deviceLatency + t.streamLatency + cushion;
}

} // namespace eqd
