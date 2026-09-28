#pragma once

#include <CoreAudio/CoreAudioTypes.h>

#include <cstdint>
#include <cstring>
#include <vector>

namespace eqd {

struct ChannelTap {
    uint32_t buffer = 0;
    uint32_t offset = 0;
};

// Where this device's left and right land in the target's buffer list, which may be interleaved,
// one buffer per channel, or wider than stereo. Channel numbers are 1-based across all buffers, as
// kAudioDevicePropertyPreferredChannelsForStereo gives them.
struct ChannelMap {
    ChannelTap left, right;
    bool valid = false;
    bool mono = false;
};

inline bool locateChannel(const std::vector<uint32_t> &channelsPerBuffer, uint32_t channel, ChannelTap &tap) {
    uint32_t first = 1;
    for (uint32_t b = 0; b < channelsPerBuffer.size(); ++b) {
        uint32_t n = channelsPerBuffer[b];
        if (channel >= first && channel < first + n) {
            tap = {b, channel - first};
            return true;
        }
        first += n;
    }
    return false;
}

inline ChannelMap makeChannelMap(const std::vector<uint32_t> &channelsPerBuffer, uint32_t preferredLeft,
                                 uint32_t preferredRight) {
    ChannelMap map;
    uint32_t total = 0;
    for (uint32_t n : channelsPerBuffer) total += n;
    if (total == 0) return map;
    auto usable = [&](uint32_t c) { return c >= 1 && c <= total; };
    if (!usable(preferredLeft) || !usable(preferredRight) || preferredLeft == preferredRight) {
        preferredLeft = 1;
        preferredRight = total >= 2 ? 2 : 1;
    }
    if (!locateChannel(channelsPerBuffer, preferredLeft, map.left)) return map;
    if (!locateChannel(channelsPerBuffer, preferredRight, map.right)) return map;
    map.mono = preferredLeft == preferredRight;
    map.valid = true;
    return map;
}

// Writes interleaved stereo into the target's buffers, silence on every other channel. A mono
// target gets the average of left and right.
inline void scatter(const float *stereo, uint32_t frames, const ChannelMap &map, AudioBufferList *out, float gainLeft,
                    float gainRight) {
    for (uint32_t b = 0; b < out->mNumberBuffers; ++b)
        if (out->mBuffers[b].mData) std::memset(out->mBuffers[b].mData, 0, out->mBuffers[b].mDataByteSize);
    if (!map.valid) return;
    if (map.left.buffer >= out->mNumberBuffers || map.right.buffer >= out->mNumberBuffers) return;
    AudioBuffer &l = out->mBuffers[map.left.buffer];
    AudioBuffer &r = out->mBuffers[map.right.buffer];
    if (!l.mData || !r.mData || l.mNumberChannels == 0 || r.mNumberChannels == 0) return;
    if (map.left.offset >= l.mNumberChannels || map.right.offset >= r.mNumberChannels) return;
    uint32_t lFrames = l.mDataByteSize / (l.mNumberChannels * sizeof(float));
    uint32_t rFrames = r.mDataByteSize / (r.mNumberChannels * sizeof(float));
    if (frames > lFrames) frames = lFrames;
    if (frames > rFrames) frames = rFrames;
    float *lp = static_cast<float *>(l.mData) + map.left.offset;
    float *rp = static_cast<float *>(r.mData) + map.right.offset;
    if (map.mono) {
        for (uint32_t i = 0; i < frames; ++i)
            lp[size_t(i) * l.mNumberChannels] = 0.5f * (stereo[2 * i] * gainLeft + stereo[2 * i + 1] * gainRight);
        return;
    }
    for (uint32_t i = 0; i < frames; ++i) {
        lp[size_t(i) * l.mNumberChannels] = stereo[2 * i] * gainLeft;
        rp[size_t(i) * r.mNumberChannels] = stereo[2 * i + 1] * gainRight;
    }
}

} // namespace eqd
