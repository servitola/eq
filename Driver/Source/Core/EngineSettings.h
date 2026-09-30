#pragma once

#include "EQDriverProtocol.h"

#include <algorithm>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace eqd {

// The plug-in's host storage, or a map in the tests.
struct SettingsStorage {
    virtual ~SettingsStorage() = default;
    virtual std::vector<uint8_t> read(const std::string &key) = 0;
    virtual void write(const std::string &key, const std::vector<uint8_t> &bytes) = 0;
};

struct TargetSettings {
    eqc_settings settings;
    uint64_t serial = 0;
};

// Which curve the engine plays: the last one eq sent for the current target, kept in storage per
// target so it survives coreaudiod restarts and plays while the daemon is away. A target eq never
// sent anything for plays untouched. Runs on the plug-in's serial queue only, which makes it the
// engine's one publisher thread.
class EngineSettings {
  public:
    explicit EngineSettings(eqc_engine *engine) : engine_(engine) {}

    static std::string key(const std::string &uid) { return "settings." + uid; }

    // Solo is a moment's listening, not part of the curve, so it is never stored.
    static std::optional<TargetSettings> recall(SettingsStorage &storage, const std::string &uid) {
        if (uid.empty()) return std::nullopt;
        std::vector<uint8_t> bytes = storage.read(key(uid));
        TargetSettings t;
        char stored[EQC_BLOB_UID_CAPACITY];
        if (bytes.empty() || eqc_blob_decode(bytes.data(), bytes.size(), &t.settings, stored, &t.serial) != EQC_BLOB_OK ||
            uid != stored)
            return std::nullopt;
        t.settings.solo = false;
        return t;
    }

    // Follows a new target: its stored curve, or none. False when the target is the same.
    bool follow(SettingsStorage &storage, const std::string &uid) {
        if (followed_ && uid == uid_) return false;
        followed_ = true;
        uid_ = uid;
        std::optional<TargetSettings> t = recall(storage, uid);
        if (t) play(*t);
        else wire();
        return true;
    }

    // A validated record from eq. Stored for its own target; true when that is the current one,
    // which then plays it.
    bool accept(SettingsStorage &storage, const TargetSettings &t, const std::string &uid) {
        eqc_settings kept = t.settings;
        kept.solo = false;
        eqc_blob blob;
        if (!eqc_blob_encode(&blob, &kept, uid.c_str(), t.serial)) return false;
        const uint8_t *raw = reinterpret_cast<const uint8_t *>(&blob);
        storage.write(key(uid), std::vector<uint8_t>(raw, raw + sizeof(blob)));
        if (!followed_ || uid != uid_) return false;
        play(t);
        return true;
    }

    // What plays, as the record eq would have sent; empty for none.
    std::vector<uint8_t> record() const {
        eqc_blob blob;
        if (!playing_ || !eqc_blob_encode(&blob, &playing_->settings, uid_.c_str(), playing_->serial)) return {};
        const uint8_t *raw = reinterpret_cast<const uint8_t *>(&blob);
        return std::vector<uint8_t>(raw, raw + sizeof(blob));
    }

    bool active() const { return playing_.has_value(); }
    uint64_t serial() const { return playing_ ? playing_->serial : 0; }
    const std::string &uid() const { return uid_; }

  private:
    void play(const TargetSettings &t) {
        eqc_update(engine_, &t.settings, nullptr);
        playing_ = t;
    }

    void wire() {
        eqc_settings none{};
        none.bypassed = true;
        eqc_update(engine_, &none, nullptr);
        playing_.reset();
    }

    eqc_engine *engine_;
    bool followed_ = false;
    std::string uid_;
    std::optional<TargetSettings> playing_;
};

// The target IOProc's EQ: the ring hands out interleaved stereo, EQCore wants channels, and a
// call longer than the meter's capacity is split so that it stays metered. Realtime: no
// allocation, no locks.
inline void processStereo(eqc_engine *engine, const float *stereo, float *left, float *right, uint32_t frames,
                          bool metering, bool spectrum = false) {
    for (uint32_t i = 0; i < frames; ++i) {
        left[i] = stereo[2 * i];
        right[i] = stereo[2 * i + 1];
    }
    eqc_set_metering(engine, metering);
    eqc_set_spectrum(engine, spectrum);
    for (uint32_t done = 0; done < frames;) {
        uint32_t n = std::min<uint32_t>(frames - done, EQC_METER_CAPACITY);
        float *channels[2] = {left + done, right + done};
        eqc_process(engine, channels, 2, int32_t(n));
        done += n;
    }
}

} // namespace eqd
