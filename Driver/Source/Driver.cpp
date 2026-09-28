// EQDriver: an output-only virtual device that plays its mix on a real output device from inside the
// plug-in. Derived from briankendall/proxy-audio-device v1.1.0b1 (Unlicense): the object model, the
// rule that HAL client calls run on a separate serial queue, the target lookup and the choice of a
// default target. The clock servo and timeline checks live in Core/.

#include "Core/ChannelMap.h"
#include "Core/Clock.h"
#include "Core/DeviceMatch.h"
#include "Core/Latency.h"
#include "Core/Pipeline.h"
#include "Core/TargetMachine.h"
#include "HAL.h"

#include <CoreAudio/AudioServerPlugIn.h>
#include <IOKit/IOMessage.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <os/log.h>
#include <sys/stat.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace eqd {
namespace {

enum : AudioObjectID {
    kObjectPlugIn = kAudioObjectPlugInObject,
    kObjectDevice = 2,
    kObjectStream = 3,
    kObjectVolume = 4,
    kObjectMute = 5,
};

constexpr const char *kBundleID = "com.servitola.eq.driver";
constexpr const char *kDeviceUID = "com.servitola.eq.device";
constexpr const char *kModelUID = "com.servitola.eq.model";
constexpr AudioObjectPropertySelector kPropertyTarget = 'eqTg';
constexpr AudioObjectPropertySelector kPropertyHidden = 'eqHd';
constexpr AudioObjectPropertySelector kPropertyHealth = 'eqHl';
constexpr UInt64 kChangeApplyPending = 1;
constexpr Float32 kVolumeMinDB = -64.0f;
constexpr UInt32 kMaxTargetFrames = 8192;

os_log_t logger() {
    static os_log_t log = os_log_create(kBundleID, "driver");
    return log;
}

Float32 scalarToDB(Float32 s) { return s <= 0 ? kVolumeMinDB : std::max(kVolumeMinDB, 40.0f * std::log10(s)); }
Float32 dbToScalar(Float32 db) { return db <= kVolumeMinDB ? 0.0f : std::min(1.0f, std::pow(10.0f, db / 40.0f)); }

CFStringRef makeString(const std::string &s) {
    return CFStringCreateWithBytes(nullptr, reinterpret_cast<const UInt8 *>(s.data()), CFIndex(s.size()),
                                   kCFStringEncodingUTF8, false);
}

// One answer for HasProperty, GetPropertyDataSize and GetPropertyData, so the three cannot drift.
struct Reply {
    bool sizeOnly;
    UInt32 capacity;
    UInt32 *size;
    void *data;

    template <typename T>
    OSStatus value(const T &v) {
        *size = sizeof(T);
        if (sizeOnly) return noErr;
        if (capacity < sizeof(T)) return kAudioHardwareBadPropertySizeError;
        std::memcpy(data, &v, sizeof(T));
        *size = sizeof(T);
        return noErr;
    }

    template <typename T>
    OSStatus list(const std::vector<T> &items) {
        *size = UInt32(items.size() * sizeof(T));
        if (sizeOnly) return noErr;
        UInt32 n = std::min<UInt32>(UInt32(items.size()), capacity / sizeof(T));
        if (n) std::memcpy(data, items.data(), n * sizeof(T));
        *size = n * sizeof(T);
        return noErr;
    }

    template <typename Make>
    OSStatus cf(Make make) {
        *size = sizeof(CFTypeRef);
        if (sizeOnly) return noErr;
        if (capacity < sizeof(CFTypeRef)) return kAudioHardwareBadPropertySizeError;
        CFTypeRef object = make();
        std::memcpy(data, &object, sizeof(CFTypeRef));
        *size = sizeof(CFTypeRef);
        return noErr;
    }
};

class Driver;

// One per IOProc built on a target. The IOProc gets it as client data and it is deleted only after
// AudioDeviceDestroyIOProcID has returned, so no IO cycle can still be using it.
struct TargetIO {
    Driver *driver;
    AudioObjectID device;
    AudioDeviceIOProcID proc = nullptr;
    Reader reader;
    ChannelMap map;
    std::vector<float> scratch;
    TargetTiming timing;
    std::vector<AudioObjectPropertyElement> volumeElements, muteElements;

    TargetIO(Driver *d, AudioObjectID id, Pipeline &p, uint32_t cushion)
        : driver(d), device(id), reader(p, cushion), scratch(size_t(kMaxTargetFrames) * Pipeline::kChannels) {}
};

class Driver : TargetExecutor {
  public:
    static Driver &shared() {
        static Driver *driver = new Driver;
        return *driver;
    }

    // MARK: Plug-in lifecycle

    OSStatus initialize(AudioServerPlugInHostRef host) {
        host_ = host;
        mach_timebase_info_data_t base;
        mach_timebase_info(&base);
        ticksPerSecond_ = 1e9 * double(base.denom) / double(base.numer);
        loadedAt_ = now();
        machine_ = std::make_unique<TargetMachine>(loadedAt_);

        killed_ = killFileExists();
        // A target of this very device would feed its own mix back into itself.
        if (std::string uid = storedString("target"); uid != kDeviceUID) targetUID_ = uid;
        targetName_ = storedString("targetName");
        hiddenPref_ = storedBool("hidden");
        if (double rate = storedDouble("sampleRate"); rate >= 8000 && rate <= 768000) sampleRate_ = rate;
        if (double latency = storedDouble("latency"); latency > 0 && latency < 1e6) latency_ = UInt32(latency);
        ticksPerFrame_ = ticksPerSecond_ / sampleRate_.load();
        clock_.setNominal(ticksPerFrame_.load());

        if (killed_) {
            os_log(logger(), "kill file present: hidden, no IO");
            return noErr;
        }
        queue_ = dispatch_queue_create(kBundleID, dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                                                           QOS_CLASS_USER_INITIATED, 0));
        timer_ = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue_);
        dispatch_source_set_event_handler(timer_, ^{ reconcile(); });
        dispatch_source_set_timer(timer_, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
        dispatch_resume(timer_);
        // Proxy Audio Device waits a second before its first HAL client call, while coreaudiod is
        // still bringing plug-ins up; calls made from Initialize itself deadlock.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), queue_, ^{ begin(); });
        return noErr;
    }

    // MARK: IO (HAL threads)

    OSStatus startIO() {
        std::lock_guard<std::mutex> lock(clientsMutex_);
        if (clients_ == UINT32_MAX) return kAudioHardwareIllegalOperationError;
        if (clients_++ == 0) {
            clockGeneration_.fetch_add(1);
            pipeline_.firstClientStarted();
        }
        poke();
        return noErr;
    }

    OSStatus stopIO() {
        std::lock_guard<std::mutex> lock(clientsMutex_);
        if (clients_ == 0) return kAudioHardwareIllegalOperationError;
        if (--clients_ == 0) pipeline_.lastClientStopped();
        poke();
        return noErr;
    }

    OSStatus zeroTimeStamp(Float64 *sample, UInt64 *host, UInt64 *seed) {
        os_unfair_lock_lock(&clockLock_);
        uint64_t now = mach_absolute_time();
        uint64_t generation = clockGeneration_.load(std::memory_order_acquire);
        if (generation != clockSeen_ || !clock_.anchored()) {
            if (clock_.anchored()) ++seed_;
            clock_.setNominal(ticksPerFrame_.load(std::memory_order_relaxed));
            clock_.anchor(now);
            clockSeen_ = generation;
        }
        ServoFeedback feedback;
        bool fresh = pipeline_.feedback.read(feedback, 3);
        clock_.advance(now, fresh ? &feedback : nullptr);
        pipeline_.clock.publish(clock_.snapshot());
        correctionPpm_.store(clock_.correctionPpm(), std::memory_order_relaxed);
        rateRatio_.store(clock_.rateRatio(), std::memory_order_relaxed);
        *sample = clock_.zeroSample();
        *host = clock_.zeroHost();
        *seed = seed_;
        os_unfair_lock_unlock(&clockLock_);
        return noErr;
    }

    void writeMix(const void *buffer, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle) {
        if (killed_ || !buffer || !cycle) return;
        pipeline_.write(static_cast<const float *>(buffer), frames, std::llround(cycle->mOutputTime.mSampleTime));
    }

    static OSStatus targetIOProc(AudioObjectID, const AudioTimeStamp *, const AudioBufferList *, const AudioTimeStamp *,
                                 AudioBufferList *out, const AudioTimeStamp *outTime, void *context) {
        auto *io = static_cast<TargetIO *>(context);
        Driver &d = *io->driver;
        d.lastCallback_.store(mach_absolute_time(), std::memory_order_relaxed);
        if (!out || out->mNumberBuffers == 0 || !outTime) return noErr;
        const AudioBuffer &first = out->mBuffers[0];
        uint32_t frames = first.mNumberChannels ? first.mDataByteSize / (first.mNumberChannels * sizeof(float)) : 0;
        frames = std::min(frames, kMaxTargetFrames);
        TargetCycle cycle;
        cycle.sampleTime = outTime->mSampleTime;
        cycle.hostTime = outTime->mHostTime;
        cycle.hostValid = outTime->mFlags & kAudioTimeStampHostTimeValid;
        cycle.rateScalar = outTime->mRateScalar;
        cycle.rateValid = outTime->mFlags & kAudioTimeStampRateScalarValid;
        cycle.frames = frames;
        io->reader.render(cycle, io->scratch.data());
        float gain = 1.0f;
        if (io->volumeElements.empty()) {
            float s = d.volume_.load(std::memory_order_relaxed);
            gain = s * s;
        }
        if (io->muteElements.empty() && d.mute_.load(std::memory_order_relaxed)) gain = 0.0f;
        scatter(io->scratch.data(), frames, io->map, out, gain, gain);
        return noErr;
    }

    // MARK: Configuration changes (HAL thread; no HAL client calls here, unlike Proxy b1)

    OSStatus performConfigurationChange(UInt64 action) {
        if (action != kChangeApplyPending) return kAudioHardwareIllegalOperationError;
        {
            std::lock_guard<std::mutex> lock(configMutex_);
            sampleRate_ = pendingRate_;
            latency_ = pendingLatency_;
            configRequested_ = false;
        }
        ticksPerFrame_ = ticksPerSecond_ / sampleRate_.load();
        clockGeneration_.fetch_add(1);
        poke();
        return noErr;
    }

    OSStatus abortConfigurationChange() {
        {
            std::lock_guard<std::mutex> lock(configMutex_);
            configRequested_ = false;
        }
        if (queue_) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), queue_, ^{ reconcile(); });
        return noErr;
    }

    // MARK: Properties (HAL threads)

    OSStatus property(AudioObjectID object, const AudioObjectPropertyAddress &a, UInt32 qualifierSize,
                      const void *qualifier, Reply r) {
        switch (object) {
        case kObjectPlugIn: return plugInProperty(a, qualifierSize, qualifier, r);
        case kObjectDevice: return deviceProperty(a, r);
        case kObjectStream: return streamProperty(a, r);
        case kObjectVolume:
        case kObjectMute: return controlProperty(object, a, r);
        default: return kAudioHardwareBadObjectError;
        }
    }

    bool settable(AudioObjectID object, const AudioObjectPropertyAddress &a) {
        switch (object) {
        case kObjectDevice:
            return a.mSelector == kAudioDevicePropertyNominalSampleRate || a.mSelector == kPropertyTarget ||
                   a.mSelector == kPropertyHidden;
        case kObjectStream:
            return a.mSelector == kAudioStreamPropertyVirtualFormat || a.mSelector == kAudioStreamPropertyPhysicalFormat;
        case kObjectVolume:
            return a.mSelector == kAudioLevelControlPropertyScalarValue ||
                   a.mSelector == kAudioLevelControlPropertyDecibelValue;
        case kObjectMute: return a.mSelector == kAudioBooleanControlPropertyValue;
        default: return false;
        }
    }

    OSStatus setProperty(AudioObjectID object, const AudioObjectPropertyAddress &a, UInt32 size, const void *data) {
        if (!data) return kAudioHardwareIllegalOperationError;
        if (object == kObjectDevice) {
            switch (a.mSelector) {
            case kAudioDevicePropertyNominalSampleRate:
                if (size != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
                // The rate follows the target; the only one on offer is the current one.
                return *static_cast<const Float64 *>(data) == sampleRate_.load() ? noErr
                                                                                  : kAudioDeviceUnsupportedFormatError;
            case kPropertyTarget: return setTarget(size, data);
            case kPropertyHidden: return setHidden(size, data);
            }
        } else if (object == kObjectStream) {
            if (size != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
            auto *f = static_cast<const AudioStreamBasicDescription *>(data);
            AudioStreamBasicDescription ours = format();
            return f->mSampleRate == ours.mSampleRate && f->mFormatID == ours.mFormatID &&
                           f->mChannelsPerFrame == ours.mChannelsPerFrame && f->mBitsPerChannel == ours.mBitsPerChannel
                       ? noErr
                       : kAudioDeviceUnsupportedFormatError;
        } else if (object == kObjectVolume) {
            if (size != sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
            Float32 v = *static_cast<const Float32 *>(data);
            if (!std::isfinite(v)) return kAudioHardwareIllegalOperationError;
            Float32 scalar = a.mSelector == kAudioLevelControlPropertyDecibelValue ? dbToScalar(v)
                                                                                   : std::clamp(v, 0.0f, 1.0f);
            volume_ = scalar;
            async(^{
                notifyVolume();
                forwardVolume();
            });
            return noErr;
        } else if (object == kObjectMute) {
            if (size != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            mute_ = *static_cast<const UInt32 *>(data) != 0;
            async(^{
                notify(kObjectMute, kAudioBooleanControlPropertyValue);
                forwardMute();
            });
            return noErr;
        }
        return kAudioHardwareUnknownPropertyError;
    }

  private:
    Driver() = default;

    double now() const { return double(mach_absolute_time()) / ticksPerSecond_; }

    void async(dispatch_block_t block) {
        if (queue_) dispatch_async(queue_, block);
    }

    void poke() {
        async(^{ reconcile(); });
    }

    bool killFileExists() {
        CFBundleRef bundle = CFBundleGetBundleWithIdentifier(CFSTR("com.servitola.eq.driver"));
        if (!bundle) return false;
        CFURLRef resources = CFBundleCopyResourcesDirectoryURL(bundle);
        if (!resources) return false;
        char path[PATH_MAX];
        bool ok = CFURLGetFileSystemRepresentation(resources, true, reinterpret_cast<UInt8 *>(path), sizeof(path));
        CFRelease(resources);
        if (!ok) return false;
        struct stat st;
        return stat((std::string(path) + "/disabled").c_str(), &st) == 0;
    }

    // MARK: Storage

    CFPropertyListRef stored(const char *key) {
        CFPropertyListRef value = nullptr;
        CFStringRef k = CFStringCreateWithCString(nullptr, key, kCFStringEncodingUTF8);
        host_->CopyFromStorage(host_, k, &value);
        CFRelease(k);
        return value;
    }

    std::string storedString(const char *key) {
        CFPropertyListRef v = stored(key);
        std::string s = v && CFGetTypeID(v) == CFStringGetTypeID() ? hal::string(static_cast<CFStringRef>(v)) : "";
        if (v) CFRelease(v);
        return s;
    }

    bool storedBool(const char *key) {
        CFPropertyListRef v = stored(key);
        bool b = v && CFGetTypeID(v) == CFBooleanGetTypeID() && CFBooleanGetValue(static_cast<CFBooleanRef>(v));
        if (v) CFRelease(v);
        return b;
    }

    double storedDouble(const char *key) {
        CFPropertyListRef v = stored(key);
        double d = 0;
        if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(static_cast<CFNumberRef>(v), kCFNumberDoubleType, &d);
        if (v) CFRelease(v);
        return d;
    }

    void store(const char *key, CFPropertyListRef value) {
        CFStringRef k = CFStringCreateWithCString(nullptr, key, kCFStringEncodingUTF8);
        host_->WriteToStorage(host_, k, value);
        CFRelease(k);
    }

    void storeString(const char *key, const std::string &s) {
        CFStringRef v = makeString(s);
        store(key, v);
        CFRelease(v);
    }

    void storeDouble(const char *key, double d) {
        CFNumberRef v = CFNumberCreate(nullptr, kCFNumberDoubleType, &d);
        store(key, v);
        CFRelease(v);
    }

    // MARK: Custom properties

    OSStatus setTarget(UInt32 size, const void *data) {
        if (size != sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
        CFStringRef uid = *static_cast<const CFStringRef *>(data);
        if (!uid || CFGetTypeID(uid) != CFStringGetTypeID() || CFStringGetLength(uid) > 512)
            return kAudioHardwareIllegalOperationError;
        std::string value = hal::string(uid);
        if (value == kDeviceUID) return kAudioHardwareIllegalOperationError;
        {
            std::lock_guard<std::mutex> lock(stringsMutex_);
            if (value == targetUID_) return noErr;
            targetUID_ = value;
        }
        async(^{
            if (value.empty()) chooseDefaultTarget();
            else storeString("target", value);
            notify(kObjectDevice, kPropertyTarget);
            reconcile();
        });
        return noErr;
    }

    OSStatus setHidden(UInt32 size, const void *data) {
        if (size != sizeof(CFPropertyListRef)) return kAudioHardwareBadPropertySizeError;
        CFPropertyListRef v = *static_cast<const CFPropertyListRef *>(data);
        bool hidden;
        if (v && CFGetTypeID(v) == CFBooleanGetTypeID()) {
            hidden = CFBooleanGetValue(static_cast<CFBooleanRef>(v));
        } else if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
            int n = 0;
            CFNumberGetValue(static_cast<CFNumberRef>(v), kCFNumberIntType, &n);
            hidden = n != 0;
        } else {
            return kAudioHardwareIllegalOperationError;
        }
        hiddenPref_ = hidden;
        async(^{
            store("hidden", hidden ? kCFBooleanTrue : kCFBooleanFalse);
            notify(kObjectDevice, kPropertyHidden);
            notify(kObjectDevice, kAudioDevicePropertyIsHidden);
        });
        return noErr;
    }

    CFDictionaryRef copyHealth() {
        CFMutableDictionaryRef d =
            CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        auto put = [&](const char *key, CFTypeRef value) {
            CFStringRef k = CFStringCreateWithCString(nullptr, key, kCFStringEncodingUTF8);
            CFDictionarySetValue(d, k, value);
            CFRelease(k);
            CFRelease(value);
        };
        auto number = [&](const char *key, double v) { put(key, CFNumberCreate(nullptr, kCFNumberDoubleType, &v)); };
        auto integer = [&](const char *key, int64_t v) { put(key, CFNumberCreate(nullptr, kCFNumberSInt64Type, &v)); };
        auto boolean = [&](const char *key, bool v) { put(key, CFRetain(v ? kCFBooleanTrue : kCFBooleanFalse)); };
        {
            std::lock_guard<std::mutex> lock(stringsMutex_);
            put("target", makeString(targetUID_));
            put("targetName", makeString(targetName_));
            put("lastError", makeString(lastError_));
            integer("lastStatus", lastStatus_);
        }
        uint64_t last = lastCallback_.load(std::memory_order_relaxed);
        double age = last ? double(mach_absolute_time() - last) / ticksPerSecond_ : -1;
        boolean("targetAvailable", targetAvailable_);
        boolean("ioRunning", ioRunning_ && age >= 0 && age < TargetMachine::kStallAfter);
        integer("lastCallbackAgeMs", age < 0 ? -1 : int64_t(age * 1000));
        integer("clients", clients_);
        integer("underruns", int64_t(pipeline_.counters.underruns.load()));
        integer("overruns", int64_t(pipeline_.counters.overruns.load()));
        integer("resyncs", int64_t(pipeline_.counters.resyncs.load()));
        integer("phaseErrorFrames", pipeline_.counters.phaseError.load());
        number("clockCorrectionPpm", correctionPpm_);
        number("rateRatio", rateRatio_);
        integer("retargets", int64_t(builds_.load()));
        integer("stalls", int64_t(stalls_.load()));
        integer("rebuilds", int64_t(rebuilds_.load()));
        integer("startFailures", int64_t(startFailures_.load()));
        number("sampleRate", sampleRate_);
        integer("latencyFrames", latency_);
        integer("cushionFrames", cushion_);
        boolean("hardwareVolume", hardwareVolume_);
        boolean("hidden", hidden());
        boolean("killed", killed_);
        return d;
    }

    // MARK: Object properties

    OSStatus plugInProperty(const AudioObjectPropertyAddress &a, UInt32 qualifierSize, const void *qualifier, Reply r) {
        switch (a.mSelector) {
        case kAudioObjectPropertyBaseClass: return r.value<AudioClassID>(kAudioObjectClassID);
        case kAudioObjectPropertyClass: return r.value<AudioClassID>(kAudioPlugInClassID);
        case kAudioObjectPropertyOwner: return r.value<AudioObjectID>(kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: return r.cf([] { return CFSTR("eq"); });
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: return r.list(std::vector<AudioObjectID>{kObjectDevice});
        case kAudioPlugInPropertyBoxList: return r.list(std::vector<AudioObjectID>{});
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            AudioObjectID id = kAudioObjectUnknown;
            if (qualifierSize == sizeof(CFStringRef) && qualifier) {
                CFStringRef uid = *static_cast<const CFStringRef *>(qualifier);
                if (uid && CFGetTypeID(uid) == CFStringGetTypeID() && hal::string(uid) == kDeviceUID) id = kObjectDevice;
            }
            return r.value(id);
        }
        case kAudioPlugInPropertyResourceBundle: return r.cf([] { return CFSTR(""); });
        default: return kAudioHardwareUnknownPropertyError;
        }
    }

    AudioStreamBasicDescription format() const {
        AudioStreamBasicDescription f{};
        f.mSampleRate = sampleRate_.load();
        f.mFormatID = kAudioFormatLinearPCM;
        f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
        f.mChannelsPerFrame = Pipeline::kChannels;
        f.mBitsPerChannel = 32;
        f.mBytesPerFrame = f.mBytesPerPacket = Pipeline::kChannels * sizeof(Float32);
        f.mFramesPerPacket = 1;
        return f;
    }

    bool hidden() const { return killed_ || hiddenPref_ || autoHidden_; }

    OSStatus deviceProperty(const AudioObjectPropertyAddress &a, Reply r) {
        bool input = a.mScope == kAudioObjectPropertyScopeInput;
        switch (a.mSelector) {
        case kAudioObjectPropertyBaseClass: return r.value<AudioClassID>(kAudioObjectClassID);
        case kAudioObjectPropertyClass: return r.value<AudioClassID>(kAudioDeviceClassID);
        case kAudioObjectPropertyOwner: return r.value<AudioObjectID>(kObjectPlugIn);
        case kAudioObjectPropertyName:
            return r.cf([this] {
                std::lock_guard<std::mutex> lock(stringsMutex_);
                return makeString(targetName_.empty() ? "EQ" : targetName_ + " \xC2\xB7 EQ");
            });
        case kAudioObjectPropertyManufacturer: return r.cf([] { return CFSTR("eq"); });
        case kAudioObjectPropertyOwnedObjects:
            return r.list(input ? std::vector<AudioObjectID>{}
                                : std::vector<AudioObjectID>{kObjectStream, kObjectVolume, kObjectMute});
        case kAudioDevicePropertyDeviceUID: return r.cf([] { return CFStringCreateWithCString(nullptr, kDeviceUID, kCFStringEncodingUTF8); });
        case kAudioDevicePropertyModelUID: return r.cf([] { return CFStringCreateWithCString(nullptr, kModelUID, kCFStringEncodingUTF8); });
        case kAudioDevicePropertyTransportType: return r.value<UInt32>(kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: return r.list(std::vector<AudioObjectID>{kObjectDevice});
        case kAudioDevicePropertyClockDomain: return r.value<UInt32>(0);
        case kAudioDevicePropertyDeviceIsAlive: return r.value<UInt32>(1);
        case kAudioDevicePropertyDeviceIsRunning: return r.value<UInt32>(clients_ > 0);
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            return r.value<UInt32>(a.mScope == kAudioObjectPropertyScopeOutput && !killed_);
        case kAudioDevicePropertyLatency: return r.value<UInt32>(input ? 0 : latency_.load());
        case kAudioDevicePropertySafetyOffset: return r.value<UInt32>(0);
        case kAudioDevicePropertyStreams:
            return r.list(input ? std::vector<AudioObjectID>{} : std::vector<AudioObjectID>{kObjectStream});
        case kAudioObjectPropertyControlList: return r.list(std::vector<AudioObjectID>{kObjectVolume, kObjectMute});
        case kAudioDevicePropertyNominalSampleRate: return r.value<Float64>(sampleRate_);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            Float64 rate = sampleRate_;
            return r.list(std::vector<AudioValueRange>{{rate, rate}});
        }
        case kAudioDevicePropertyIsHidden: return r.value<UInt32>(hidden());
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            struct Pair { UInt32 l, r; };
            return r.value(Pair{1, 2});
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            struct Stereo {
                AudioChannelLayoutTag tag;
                AudioChannelBitmap bitmap;
                UInt32 count;
                AudioChannelDescription d[2];
            };
            Stereo s{kAudioChannelLayoutTag_UseChannelDescriptions, 0, 2, {}};
            s.d[0].mChannelLabel = kAudioChannelLabel_Left;
            s.d[1].mChannelLabel = kAudioChannelLabel_Right;
            return r.value(s);
        }
        case kAudioDevicePropertyZeroTimeStampPeriod: return r.value<UInt32>(VirtualClock::kPeriod);
        case kAudioObjectPropertyCustomPropertyInfoList:
            return r.list(std::vector<AudioServerPlugInCustomPropertyInfo>{
                {kPropertyTarget, kAudioServerPlugInCustomPropertyDataTypeCFString, kAudioServerPlugInCustomPropertyDataTypeNone},
                {kPropertyHidden, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone},
                {kPropertyHealth, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone},
            });
        case kPropertyTarget:
            return r.cf([this] {
                std::lock_guard<std::mutex> lock(stringsMutex_);
                return makeString(targetUID_);
            });
        case kPropertyHidden: return r.cf([this] { return CFRetain(hiddenPref_ ? kCFBooleanTrue : kCFBooleanFalse); });
        case kPropertyHealth: return r.cf([this] { return copyHealth(); });
        default: return kAudioHardwareUnknownPropertyError;
        }
    }

    OSStatus streamProperty(const AudioObjectPropertyAddress &a, Reply r) {
        switch (a.mSelector) {
        case kAudioObjectPropertyBaseClass: return r.value<AudioClassID>(kAudioObjectClassID);
        case kAudioObjectPropertyClass: return r.value<AudioClassID>(kAudioStreamClassID);
        case kAudioObjectPropertyOwner: return r.value<AudioObjectID>(kObjectDevice);
        case kAudioObjectPropertyOwnedObjects: return r.list(std::vector<AudioObjectID>{});
        case kAudioStreamPropertyIsActive: return r.value<UInt32>(1);
        case kAudioStreamPropertyDirection: return r.value<UInt32>(0);
        case kAudioStreamPropertyTerminalType: return r.value<UInt32>(kAudioStreamTerminalTypeSpeaker);
        case kAudioStreamPropertyStartingChannel: return r.value<UInt32>(1);
        case kAudioStreamPropertyLatency: return r.value<UInt32>(0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: return r.value(format());
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamBasicDescription f = format();
            return r.list(std::vector<AudioStreamRangedDescription>{{f, {f.mSampleRate, f.mSampleRate}}});
        }
        default: return kAudioHardwareUnknownPropertyError;
        }
    }

    OSStatus controlProperty(AudioObjectID object, const AudioObjectPropertyAddress &a, Reply r) {
        bool volume = object == kObjectVolume;
        switch (a.mSelector) {
        case kAudioObjectPropertyBaseClass:
            return r.value<AudioClassID>(volume ? kAudioLevelControlClassID : kAudioBooleanControlClassID);
        case kAudioObjectPropertyClass:
            return r.value<AudioClassID>(volume ? kAudioVolumeControlClassID : kAudioMuteControlClassID);
        case kAudioObjectPropertyOwner: return r.value<AudioObjectID>(kObjectDevice);
        case kAudioObjectPropertyOwnedObjects: return r.list(std::vector<AudioObjectID>{});
        case kAudioControlPropertyScope: return r.value<AudioObjectPropertyScope>(kAudioObjectPropertyScopeOutput);
        case kAudioControlPropertyElement: return r.value<AudioObjectPropertyElement>(kAudioObjectPropertyElementMain);
        }
        if (!volume) {
            if (a.mSelector == kAudioBooleanControlPropertyValue) return r.value<UInt32>(mute_.load());
            return kAudioHardwareUnknownPropertyError;
        }
        switch (a.mSelector) {
        case kAudioLevelControlPropertyScalarValue: return r.value<Float32>(volume_);
        case kAudioLevelControlPropertyDecibelValue: return r.value<Float32>(scalarToDB(volume_));
        case kAudioLevelControlPropertyDecibelRange: return r.value(AudioValueRange{kVolumeMinDB, 0});
        case kAudioLevelControlPropertyConvertScalarToDecibels:
        case kAudioLevelControlPropertyConvertDecibelsToScalar: {
            if (r.sizeOnly) return r.value<Float32>(0);
            if (r.capacity < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
            Float32 in;
            std::memcpy(&in, r.data, sizeof(in));
            if (!std::isfinite(in)) in = 0;
            return r.value<Float32>(a.mSelector == kAudioLevelControlPropertyConvertScalarToDecibels
                                        ? scalarToDB(std::clamp(in, 0.0f, 1.0f))
                                        : dbToScalar(std::clamp(in, kVolumeMinDB, 0.0f)));
        }
        default: return kAudioHardwareUnknownPropertyError;
        }
    }

    // MARK: Control queue: everything below runs on queue_ only

    void notify(AudioObjectID object, AudioObjectPropertySelector selector) {
        AudioObjectPropertyAddress a = hal::address(selector);
        host_->PropertiesChanged(host_, object, 1, &a);
    }

    void notifyVolume() {
        AudioObjectPropertyAddress a[2] = {hal::address(kAudioLevelControlPropertyScalarValue),
                                           hal::address(kAudioLevelControlPropertyDecibelValue)};
        host_->PropertiesChanged(host_, kObjectVolume, 2, a);
    }

    void setError(const std::string &message, OSStatus status) {
        {
            std::lock_guard<std::mutex> lock(stringsMutex_);
            lastError_ = message;
            lastStatus_ = status;
        }
        os_log_error(logger(), "%{public}s (%d)", message.c_str(), int(status));
    }

    void begin() {
        if (currentTargetUID().empty()) chooseDefaultTarget();
        AudioObjectPropertyAddress devicesAddress = hal::address(kAudioHardwarePropertyDevices);
        OSStatus err = AudioObjectAddPropertyListener(kAudioObjectSystemObject, &devicesAddress, &systemChanged, this);
        if (err != noErr) setError("could not listen for device list changes; relying on retries", err);
        registerForWake();
        reconcile();
    }

    std::string currentTargetUID() {
        std::lock_guard<std::mutex> lock(stringsMutex_);
        return targetUID_;
    }

    // A real output device other than this one: the system default if it qualifies, else the first
    // external device, else the built-in one. Virtual devices are skipped so that a chain of proxies
    // (another Proxy Audio Device as default, say) is never the first guess, and AirPlay because
    // nobody has driven it from a plug-in yet.
    void chooseDefaultTarget() {
        auto usable = [](AudioObjectID id) {
            if (id == kAudioObjectUnknown || hal::stringProperty(id, kAudioDevicePropertyDeviceUID) == kDeviceUID) return false;
            UInt32 transport = hal::uint32Property(id, kAudioDevicePropertyTransportType);
            if (transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate ||
                transport == kAudioDeviceTransportTypeAirPlay || hal::uint32Property(id, kAudioDevicePropertyIsHidden))
                return false;
            std::vector<UInt32> channels = hal::outputChannelsPerBuffer(id);
            return std::any_of(channels.begin(), channels.end(), [](UInt32 n) { return n > 0; });
        };
        AudioObjectID pick = kAudioObjectUnknown;
        AudioObjectID fallback = hal::defaultOutput();
        if (usable(fallback)) pick = fallback;
        for (AudioObjectID id : hal::devices()) {
            if (pick) break;
            if (!usable(id)) continue;
            if (hal::uint32Property(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn) {
                if (!usable(fallback)) fallback = id;
            } else {
                pick = id;
            }
        }
        if (!pick && usable(fallback)) pick = fallback;
        if (!pick) {
            setError("no output device to play on", noErr);
            return;
        }
        std::string uid = hal::stringProperty(pick, kAudioDevicePropertyDeviceUID);
        {
            std::lock_guard<std::mutex> lock(stringsMutex_);
            targetUID_ = uid;
        }
        storeString("target", uid);
        os_log(logger(), "target defaults to %{public}s", uid.c_str());
    }

    AudioObjectID resolveTarget(const std::string &uid) {
        if (uid.empty() || uid == kDeviceUID) return kAudioObjectUnknown;
        std::vector<std::pair<AudioObjectID, std::string>> uids;
        for (AudioObjectID id : hal::devices()) {
            std::string u = hal::stringProperty(id, kAudioDevicePropertyDeviceUID);
            if (u != kDeviceUID) uids.push_back({id, u});
        }
        AudioObjectID found = kAudioObjectUnknown;
        for (auto &[id, u] : uids)
            if (u == uid) found = id;
        for (auto &[id, u] : uids)
            if (!found && sameDeviceIgnoringUSBLocation(u, uid)) found = id;
        if (!found || !hal::isAlive(found)) return kAudioObjectUnknown;
        if (hal::uint32Property(found, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeAggregate) {
            std::vector<std::string> subs = hal::aggregateSubDeviceUIDs(found);
            if (std::find(subs.begin(), subs.end(), kDeviceUID) != subs.end()) {
                setError("target is an aggregate that contains this device", kAudioHardwareIllegalOperationError);
                return kAudioObjectUnknown;
            }
        }
        return found;
    }

    void reconcile() {
        if (killed_) return;
        double t = now();
        std::string uid = currentTargetUID();
        AudioObjectID target;
        // The watchdog runs this twice a second while playing; a full device scan each time would be
        // dozens of IPC round trips. Listeners mark the cache dirty, and it expires anyway in case a
        // listener could not be added (Proxy Audio Device #43).
        if (!resolveDirty_ && uid == resolvedUID_ && t - resolvedAt_ < 5.0) {
            target = resolvedID_ && hal::isAlive(resolvedID_) ? resolvedID_ : kAudioObjectUnknown;
        } else {
            target = resolveTarget(uid);
            resolvedUID_ = uid;
            resolvedAt_ = t;
            resolveDirty_ = false;
        }
        resolvedID_ = target;
        TargetFacts f;
        f.now = t;
        f.found = target != kAudioObjectUnknown;
        f.deviceID = target;
        f.clientsActive = clients_ > 0;
        uint64_t last = lastCallback_.load(std::memory_order_relaxed);
        f.lastCallbackAt = last ? double(last) / ticksPerSecond_ : -1;
        f.rebuild = rebuildRequested_;
        rebuildRequested_ = false;
        std::optional<double> rate;
        if (f.found) {
            Float64 targetRate = 0;
            hal::get(target, hal::address(kAudioDevicePropertyNominalSampleRate), targetRate);
            f.rateMatches = targetRate > 0 && std::fabs(targetRate - sampleRate_.load()) < 0.5;
            if (targetRate > 0 && !f.rateMatches) rate = targetRate;
        }

        wantedLatency_.reset();
        TargetOutcome out = machine_->step(f, *this);
        // One configuration change for both: each one stops every client's IO for a moment.
        if (rate || (wantedLatency_ && *wantedLatency_ != latency_)) requestConfiguration(rate, wantedLatency_);
        targetAvailable_ = f.found;
        ioRunning_ = machine_->running();
        builds_ = machine_->builds();
        stalls_ = machine_->stalls();
        rebuilds_ = machine_->requestedRebuilds();
        startFailures_ = machine_->startFailures();
        if (out.hidden != autoHidden_) {
            autoHidden_ = out.hidden;
            notify(kObjectDevice, kAudioDevicePropertyIsHidden);
            os_log(logger(), "target %{public}s, device %{public}s", f.found ? "back" : "gone",
                   out.hidden ? "hidden" : "shown");
        }
        dispatch_source_set_timer(timer_,
                                  out.recheckIn < 0 ? DISPATCH_TIME_FOREVER
                                                    : dispatch_time(DISPATCH_TIME_NOW, int64_t(out.recheckIn * NSEC_PER_SEC)),
                                  DISPATCH_TIME_FOREVER, NSEC_PER_MSEC * 10);
    }

    // No lock may be held across a host call: the host may run Perform or Abort, which take
    // configMutex_, inside Request on this thread or on another thread while Request waits.
    void requestConfiguration(std::optional<double> rate, std::optional<UInt32> latency) {
        double wantRate;
        UInt32 wantLatency;
        bool send;
        {
            std::lock_guard<std::mutex> lock(configMutex_);
            if (!configRequested_) {
                pendingRate_ = sampleRate_;
                pendingLatency_ = latency_;
            }
            if (rate) pendingRate_ = *rate;
            if (latency) pendingLatency_ = *latency;
            if (pendingRate_ == sampleRate_.load() && pendingLatency_ == latency_.load()) return;
            wantRate = pendingRate_;
            wantLatency = pendingLatency_;
            send = !configRequested_;
            configRequested_ = true;
        }
        storeDouble("sampleRate", wantRate);
        storeDouble("latency", wantLatency);
        if (!send) return;
        OSStatus err = host_->RequestDeviceConfigurationChange(host_, kObjectDevice, kChangeApplyPending, nullptr);
        if (err != noErr) {
            {
                std::lock_guard<std::mutex> lock(configMutex_);
                configRequested_ = false;
            }
            setError("configuration change refused", err);
        }
    }

    // MARK: TargetExecutor

    bool build(uint32_t device) override {
        std::vector<UInt32> channels = hal::outputChannelsPerBuffer(device);
        UInt32 pair[2] = {1, 2};
        hal::get(device, hal::address(kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput), pair);
        ChannelMap map = makeChannelMap(channels, pair[0], pair[1]);
        if (!map.valid) {
            setError("target has no output channels", kAudioHardwareIllegalOperationError);
            return false;
        }

        AudioObjectID stream = kAudioObjectUnknown;
        {
            AudioObjectPropertyAddress where = hal::address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput);
            UInt32 size = sizeof(stream);
            AudioObjectGetPropertyData(device, &where, 0, nullptr, &size, &stream);
        }
        AudioStreamBasicDescription f{};
        if (stream) hal::get(stream, hal::address(kAudioStreamPropertyVirtualFormat), f);
        if (stream && (f.mFormatID != kAudioFormatLinearPCM || !(f.mFormatFlags & kAudioFormatFlagIsFloat) ||
                       f.mBitsPerChannel != 32)) {
            setError("target stream is not Float32", kAudioDeviceUnsupportedFormatError);
            return false;
        }

        TargetTiming timing;
        timing.deviceLatency = hal::uint32Property(device, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput);
        timing.safetyOffset = hal::uint32Property(device, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput);
        timing.bufferFrames = hal::uint32Property(device, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, 512);
        timing.streamLatency = stream ? hal::uint32Property(stream, kAudioStreamPropertyLatency) : 0;
        uint32_t cushion = std::min(cushionFrames(timing), pipeline_.ring.capacity() / 2);

        auto io = std::make_unique<TargetIO>(this, device, pipeline_, cushion);
        io->map = map;
        io->timing = timing;
        detectVolume(*io, pair);

        OSStatus err = AudioDeviceCreateIOProcID(device, &targetIOProc, io.get(), &io->proc);
        if (err != noErr || !io->proc) {
            setError("AudioDeviceCreateIOProcID failed", err);
            return false;
        }
        io_ = io.release();
        listen(true);

        std::string name = hal::stringProperty(device, kAudioObjectPropertyName);
        bool renamed;
        {
            std::lock_guard<std::mutex> lock(stringsMutex_);
            renamed = name != targetName_;
            targetName_ = name;
            lastError_.clear();
            lastStatus_ = noErr;
        }
        if (renamed) {
            storeString("targetName", name);
            notify(kObjectDevice, kAudioObjectPropertyName);
        }
        cushion_ = cushion;
        hardwareVolume_ = !io_->volumeElements.empty();
        adoptTargetVolume();
        wantedLatency_ = reportedLatency(timing, cushion);
        os_log(logger(), "built IOProc on %{public}s: %u ch in %zu buffers, buffer %u, safety %u, latency %u + %u, cushion %u",
               name.c_str(), unsigned(channels.size() ? channels[0] : 0), channels.size(), timing.bufferFrames,
               timing.safetyOffset, timing.deviceLatency, timing.streamLatency, cushion);
        return true;
    }

    void teardown() override {
        if (!io_) return;
        listen(false);
        AudioDeviceStop(io_->device, io_->proc);
        OSStatus err = AudioDeviceDestroyIOProcID(io_->device, io_->proc);
        // A failed destroy on a device that still exists could leave the IOProc running on this
        // context; leaking it is safer than freeing it under a live callback.
        if (err == noErr || !hal::isAlive(io_->device)) delete io_;
        else setError("AudioDeviceDestroyIOProcID failed; IOProc context leaked", err);
        io_ = nullptr;
        lastCallback_ = 0;
    }

    bool start() override {
        if (!io_) return false;
        OSStatus err = AudioDeviceStart(io_->device, io_->proc);
        if (err != noErr) setError("AudioDeviceStart failed", err);
        return err == noErr;
    }

    void stop() override {
        if (io_) AudioDeviceStop(io_->device, io_->proc);
    }

    // MARK: Target listeners, volume, wake

    std::vector<AudioObjectPropertyAddress> structuralAddresses() const {
        return {hal::address(kAudioDevicePropertyDeviceIsAlive),
                hal::address(kAudioDevicePropertyNominalSampleRate),
                hal::address(kAudioDevicePropertyBufferFrameSize),
                hal::address(kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput),
                hal::address(kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput),
                hal::address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)};
    }

    void listen(bool add) {
        auto apply = [&](AudioObjectPropertyAddress a, AudioObjectPropertyListenerProc proc) {
            if (add) AudioObjectAddPropertyListener(io_->device, &a, proc, this);
            else AudioObjectRemovePropertyListener(io_->device, &a, proc, this);
        };
        for (auto a : structuralAddresses()) apply(a, &targetChanged);
        for (auto e : io_->volumeElements)
            apply(hal::address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, e), &targetVolumeChanged);
        for (auto e : io_->muteElements)
            apply(hal::address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, e), &targetVolumeChanged);
    }

    static OSStatus systemChanged(AudioObjectID, UInt32, const AudioObjectPropertyAddress *, void *self) {
        auto *d = static_cast<Driver *>(self);
        d->async(^{
            d->resolveDirty_ = true;
            d->reconcile();
        });
        return noErr;
    }

    static OSStatus targetChanged(AudioObjectID, UInt32 count, const AudioObjectPropertyAddress *addresses, void *self) {
        auto *d = static_cast<Driver *>(self);
        bool alive = count == 1 && addresses[0].mSelector == kAudioDevicePropertyDeviceIsAlive;
        d->async(^{
            if (alive) d->resolveDirty_ = true;
            else d->rebuildRequested_ = true;
            d->reconcile();
        });
        return noErr;
    }

    static OSStatus targetVolumeChanged(AudioObjectID, UInt32, const AudioObjectPropertyAddress *, void *self) {
        auto *d = static_cast<Driver *>(self);
        d->async(^{ d->adoptTargetVolume(); });
        return noErr;
    }

    // Volume keys act on this device; the target's own control does the work, so Bluetooth keeps
    // its absolute volume. Without one, gain is applied in the IOProc.
    void detectVolume(TargetIO &io, const UInt32 pair[2]) {
        auto pick = [&](AudioObjectPropertySelector selector) {
            std::vector<AudioObjectPropertyElement> elements;
            if (hal::settable(io.device, hal::address(selector, kAudioObjectPropertyScopeOutput))) return std::vector<AudioObjectPropertyElement>{kAudioObjectPropertyElementMain};
            for (UInt32 e : {pair[0], pair[1]})
                if (hal::settable(io.device, hal::address(selector, kAudioObjectPropertyScopeOutput, e)) &&
                    std::find(elements.begin(), elements.end(), e) == elements.end())
                    elements.push_back(e);
            return elements;
        };
        io.volumeElements = pick(kAudioDevicePropertyVolumeScalar);
        io.muteElements = pick(kAudioDevicePropertyMute);
    }

    void adoptTargetVolume() {
        if (!io_) return;
        if (!io_->volumeElements.empty()) {
            Float32 v = volume_;
            if (hal::get(io_->device, hal::address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput,
                                                  io_->volumeElements[0]),
                         v) == noErr &&
                std::fabs(v - volume_.load()) > 1e-4f) {
                volume_ = v;
                notifyVolume();
            }
        }
        if (!io_->muteElements.empty()) {
            UInt32 m = mute_;
            if (hal::get(io_->device, hal::address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput,
                                                  io_->muteElements[0]),
                         m) == noErr &&
                (m != 0) != mute_.load()) {
                mute_ = m != 0;
                notify(kObjectMute, kAudioBooleanControlPropertyValue);
            }
        }
    }

    void forwardVolume() {
        if (!io_) return;
        Float32 v = volume_;
        for (auto e : io_->volumeElements)
            hal::set(io_->device, hal::address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, e), v);
    }

    void forwardMute() {
        if (!io_) return;
        UInt32 m = mute_;
        for (auto e : io_->muteElements)
            hal::set(io_->device, hal::address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, e), m);
    }

    // After wake the target's engine may come back with a new timeline or not at all (Proxy Audio
    // Device #14, #62); the pokoblin fork rebuilds the IOProc on power-on, and so does this.
    void registerForWake() {
        powerRoot_ = IORegisterForSystemPower(this, &powerPort_, &powerChanged, &powerNotifier_);
        if (!powerRoot_) {
            setError("no power notifications; stalls are still caught by the watchdog", noErr);
            return;
        }
        IONotificationPortSetDispatchQueue(powerPort_, queue_);
    }

    static void powerChanged(void *self, io_service_t, natural_t message, void *argument) {
        auto *d = static_cast<Driver *>(self);
        switch (message) {
        case kIOMessageCanSystemSleep:
        case kIOMessageSystemWillSleep: IOAllowPowerChange(d->powerRoot_, long(argument)); break;
        case kIOMessageSystemHasPoweredOn:
            d->rebuildRequested_ = true;
            d->reconcile();
            break;
        }
    }

    AudioServerPlugInHostRef host_ = nullptr;
    dispatch_queue_t queue_ = nullptr;
    dispatch_source_t timer_ = nullptr;
    double ticksPerSecond_ = 1e9;
    double loadedAt_ = 0;
    bool killed_ = false;

    Pipeline pipeline_;
    os_unfair_lock clockLock_ = OS_UNFAIR_LOCK_INIT;
    VirtualClock clock_{1.0};
    uint64_t clockSeen_ = 0;
    UInt64 seed_ = 1;
    std::atomic<uint64_t> clockGeneration_{1};
    std::atomic<double> ticksPerFrame_{0};

    std::mutex clientsMutex_;
    std::atomic<UInt32> clients_{0};
    std::atomic<double> sampleRate_{48000};
    std::atomic<UInt32> latency_{0};
    std::atomic<Float32> volume_{1.0f};
    std::atomic<bool> mute_{false};
    std::atomic<bool> hiddenPref_{false};
    std::atomic<bool> autoHidden_{false};
    std::atomic<uint64_t> lastCallback_{0};
    std::atomic<double> correctionPpm_{0}, rateRatio_{1};

    std::mutex configMutex_;
    double pendingRate_ = 48000;
    UInt32 pendingLatency_ = 0;
    bool configRequested_ = false;

    std::mutex stringsMutex_;
    std::string targetUID_, targetName_, lastError_;
    OSStatus lastStatus_ = noErr;

    // Written on the queue, read by the health property.
    std::atomic<bool> targetAvailable_{false}, ioRunning_{false}, hardwareVolume_{false};
    std::atomic<uint64_t> builds_{0}, stalls_{0}, rebuilds_{0}, startFailures_{0};
    std::atomic<uint32_t> cushion_{0};

    // Queue only.
    std::unique_ptr<TargetMachine> machine_;
    TargetIO *io_ = nullptr;
    bool rebuildRequested_ = false;
    std::optional<UInt32> wantedLatency_;
    bool resolveDirty_ = true;
    std::string resolvedUID_;
    AudioObjectID resolvedID_ = kAudioObjectUnknown;
    double resolvedAt_ = 0;
    io_connect_t powerRoot_ = 0;
    IONotificationPortRef powerPort_ = nullptr;
    io_object_t powerNotifier_ = 0;
};

// MARK: The AudioServerPlugInDriverInterface

AudioServerPlugInDriverRef driverRef();

bool isDriver(AudioServerPlugInDriverRef d) { return d == driverRef(); }

HRESULT queryInterface(void *driver, REFIID uuid, LPVOID *out) {
    if (!isDriver(static_cast<AudioServerPlugInDriverRef>(driver))) return kAudioHardwareBadObjectError;
    if (!out) return kAudioHardwareIllegalOperationError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(nullptr, uuid);
    if (!requested) return kAudioHardwareIllegalOperationError;
    bool ok = CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(requested);
    if (!ok) return E_NOINTERFACE;
    *out = driverRef();
    return S_OK;
}

// The HAL never releases a plug-in it opened; counting is only for the API's sake.
std::atomic<ULONG> refCount{1};
ULONG addRef(void *) { return ++refCount; }
ULONG release(void *) { return refCount > 0 ? --refCount : 0; }

OSStatus initialize(AudioServerPlugInDriverRef d, AudioServerPlugInHostRef host) {
    return isDriver(d) ? Driver::shared().initialize(host) : kAudioHardwareBadObjectError;
}

OSStatus createDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo *, AudioObjectID *) {
    return kAudioHardwareUnsupportedOperationError;
}

OSStatus destroyDevice(AudioServerPlugInDriverRef, AudioObjectID) { return kAudioHardwareUnsupportedOperationError; }

OSStatus deviceClient(AudioServerPlugInDriverRef d, AudioObjectID device, const AudioServerPlugInClientInfo *) {
    return isDriver(d) && device == kObjectDevice ? noErr : kAudioHardwareBadObjectError;
}

OSStatus performChange(AudioServerPlugInDriverRef d, AudioObjectID device, UInt64 action, void *) {
    if (!isDriver(d) || device != kObjectDevice) return kAudioHardwareBadObjectError;
    return Driver::shared().performConfigurationChange(action);
}

OSStatus abortChange(AudioServerPlugInDriverRef d, AudioObjectID device, UInt64, void *) {
    if (!isDriver(d) || device != kObjectDevice) return kAudioHardwareBadObjectError;
    return Driver::shared().abortConfigurationChange();
}

Boolean hasProperty(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t, const AudioObjectPropertyAddress *a) {
    if (!isDriver(d) || !a) return false;
    UInt32 size = 0;
    return Driver::shared().property(object, *a, 0, nullptr, {true, 0, &size, nullptr}) == noErr;
}

OSStatus isPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t,
                            const AudioObjectPropertyAddress *a, Boolean *out) {
    if (!isDriver(d)) return kAudioHardwareBadObjectError;
    if (!a || !out) return kAudioHardwareIllegalOperationError;
    UInt32 size = 0;
    OSStatus err = Driver::shared().property(object, *a, 0, nullptr, {true, 0, &size, nullptr});
    if (err != noErr) return err;
    *out = Driver::shared().settable(object, *a);
    return noErr;
}

OSStatus getPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t,
                             const AudioObjectPropertyAddress *a, UInt32 qualifierSize, const void *qualifier,
                             UInt32 *out) {
    if (!isDriver(d)) return kAudioHardwareBadObjectError;
    if (!a || !out) return kAudioHardwareIllegalOperationError;
    return Driver::shared().property(object, *a, qualifierSize, qualifier, {true, 0, out, nullptr});
}

OSStatus getPropertyData(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t, const AudioObjectPropertyAddress *a,
                         UInt32 qualifierSize, const void *qualifier, UInt32 capacity, UInt32 *outSize, void *out) {
    if (!isDriver(d)) return kAudioHardwareBadObjectError;
    if (!a || !outSize || !out) return kAudioHardwareIllegalOperationError;
    return Driver::shared().property(object, *a, qualifierSize, qualifier, {false, capacity, outSize, out});
}

OSStatus setPropertyData(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t, const AudioObjectPropertyAddress *a,
                         UInt32, const void *, UInt32 size, const void *data) {
    if (!isDriver(d)) return kAudioHardwareBadObjectError;
    if (!a) return kAudioHardwareIllegalOperationError;
    Boolean can = false;
    OSStatus err = isPropertySettable(d, object, 0, a, &can);
    if (err != noErr) return err;
    if (!can) return kAudioHardwareUnsupportedOperationError;
    return Driver::shared().setProperty(object, *a, size, data);
}

OSStatus startIO(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32) {
    if (!isDriver(d) || device != kObjectDevice) return kAudioHardwareBadObjectError;
    return Driver::shared().startIO();
}

OSStatus stopIO(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32) {
    if (!isDriver(d) || device != kObjectDevice) return kAudioHardwareBadObjectError;
    return Driver::shared().stopIO();
}

OSStatus getZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32, Float64 *sample, UInt64 *host,
                          UInt64 *seed) {
    if (!isDriver(d) || device != kObjectDevice) return kAudioHardwareBadObjectError;
    return Driver::shared().zeroTimeStamp(sample, host, seed);
}

OSStatus willDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32, UInt32 operation,
                           Boolean *willDo, Boolean *inPlace) {
    if (!isDriver(d) || device != kObjectDevice) return kAudioHardwareBadObjectError;
    if (willDo) *willDo = operation == kAudioServerPlugInIOOperationWriteMix;
    if (inPlace) *inPlace = true;
    return noErr;
}

OSStatus beginEndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32, UInt32, UInt32,
                             const AudioServerPlugInIOCycleInfo *) {
    return isDriver(d) && device == kObjectDevice ? noErr : kAudioHardwareBadObjectError;
}

OSStatus doIOOperation(AudioServerPlugInDriverRef d, AudioObjectID device, AudioObjectID stream, UInt32,
                       UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle, void *main, void *) {
    if (!isDriver(d) || device != kObjectDevice || stream != kObjectStream) return kAudioHardwareBadObjectError;
    if (operation == kAudioServerPlugInIOOperationWriteMix) Driver::shared().writeMix(main, frames, cycle);
    return noErr;
}

AudioServerPlugInDriverInterface driverInterface = {
    nullptr,          queryInterface,     addRef,          release,         initialize,
    createDevice,     destroyDevice,      deviceClient,    deviceClient,    performChange,
    abortChange,      hasProperty,        isPropertySettable, getPropertyDataSize, getPropertyData,
    setPropertyData,  startIO,            stopIO,          getZeroTimeStamp, willDoIOOperation,
    beginEndIOOperation, doIOOperation,   beginEndIOOperation,
};
AudioServerPlugInDriverInterface *interfacePointer = &driverInterface;

AudioServerPlugInDriverRef driverRef() { return &interfacePointer; }

} // namespace
} // namespace eqd

extern "C" __attribute__((visibility("default"))) void *EQDriver_Create(CFAllocatorRef, CFUUIDRef type) {
    return CFEqual(type, kAudioServerPlugInTypeUUID) ? eqd::driverRef() : nullptr;
}
