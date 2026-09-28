// Loads the built EQDriver.driver into this process with a fake AudioServerPlugInHost and drives it
// the way coreaudiod would: property queries, a configuration change, StartIO, zero time stamps and
// WriteMix from a timed IO thread. The plug-in's target side is a normal HAL client, so it really
// opens IO; the harness points it at the built-in output and writes silence.

#include "../Source/HAL.h"

#include <CoreAudio/AudioServerPlugIn.h>
#include <dispatch/dispatch.h>
#include <mach/mach_init.h>
#include <mach/mach_time.h>
#include <mach/thread_act.h>
#include <mach/thread_policy.h>

#include <atomic>
#include <cmath>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>

using namespace eqd;

static int failures = 0;
#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        if (!(cond)) {                                                                                                 \
            ++failures;                                                                                                \
            std::printf("  FAIL line %d: %s\n", __LINE__, #cond);                                                      \
        }                                                                                                              \
    } while (0)

static AudioServerPlugInDriverRef driver;
static AudioServerPlugInDriverInterface *vt() { return *driver; }
static CFMutableDictionaryRef storage;
static std::atomic<int> configChanges{0};
static std::atomic<int> notifications{0};
static std::atomic<bool> ioPaused{false};
static std::atomic<bool> ioInCycle{false};

static OSStatus propertiesChanged(AudioServerPlugInHostRef, AudioObjectID, UInt32 n, const AudioObjectPropertyAddress *) {
    notifications += int(n);
    return noErr;
}
static OSStatus copyFromStorage(AudioServerPlugInHostRef, CFStringRef key, CFPropertyListRef *out) {
    CFPropertyListRef v = CFDictionaryGetValue(storage, key);
    *out = v ? CFRetain(v) : nullptr;
    return noErr;
}
static OSStatus writeToStorage(AudioServerPlugInHostRef, CFStringRef key, CFPropertyListRef value) {
    CFDictionarySetValue(storage, key, value);
    return noErr;
}
static OSStatus deleteFromStorage(AudioServerPlugInHostRef, CFStringRef key) {
    CFDictionaryRemoveValue(storage, key);
    return noErr;
}
// Like the HAL: stop IO, perform the change on another thread, resume.
static OSStatus requestChange(AudioServerPlugInHostRef, AudioObjectID device, UInt64 action, void *info) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        ioPaused = true;
        while (ioInCycle) std::this_thread::yield();
        vt()->PerformDeviceConfigurationChange(driver, device, action, info);
        ++configChanges;
        ioPaused = false;
    });
    return noErr;
}
static AudioServerPlugInHostInterface host = {propertiesChanged, copyFromStorage, writeToStorage, deleteFromStorage,
                                              requestChange};

template <typename T>
static bool get(AudioObjectID object, AudioObjectPropertySelector selector, T &out,
                AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    AudioObjectPropertyAddress a = {selector, scope, kAudioObjectPropertyElementMain};
    UInt32 size = sizeof(T);
    return vt()->GetPropertyData(driver, object, 0, &a, 0, nullptr, sizeof(T), &size, &out) == noErr;
}

static std::string cfString(CFStringRef s) {
    std::string out = hal::string(s);
    if (s) CFRelease(s);
    return out;
}

static CFDictionaryRef health() {
    CFDictionaryRef d = nullptr;
    get(2, 'eqHl', d);
    return d;
}

static double number(CFDictionaryRef d, const char *key) {
    CFStringRef k = CFStringCreateWithCString(nullptr, key, kCFStringEncodingUTF8);
    CFTypeRef v = CFDictionaryGetValue(d, k);
    CFRelease(k);
    double out = NAN;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(static_cast<CFNumberRef>(v), kCFNumberDoubleType, &out);
    if (v && CFGetTypeID(v) == CFBooleanGetTypeID()) out = CFBooleanGetValue(static_cast<CFBooleanRef>(v));
    return out;
}

static std::string text(CFDictionaryRef d, const char *key) {
    CFStringRef k = CFStringCreateWithCString(nullptr, key, kCFStringEncodingUTF8);
    CFTypeRef v = CFDictionaryGetValue(d, k);
    CFRelease(k);
    return v && CFGetTypeID(v) == CFStringGetTypeID() ? hal::string(static_cast<CFStringRef>(v)) : "";
}

static void dump(const char *when) {
    CFDictionaryRef h = health();
    std::printf("  %s: target %s, available %.0f, io %.0f, clients %.0f, underruns %.0f, overruns %.0f, resyncs %.0f, "
                "phase %.0f fr, correction %+.2f ppm, rate ratio %.6f, latency %.0f, cushion %.0f, retargets %.0f, "
                "hidden %.0f, error \"%s\"\n",
                when, text(h, "targetName").c_str(), number(h, "targetAvailable"), number(h, "ioRunning"),
                number(h, "clients"), number(h, "underruns"), number(h, "overruns"), number(h, "resyncs"),
                number(h, "phaseErrorFrames"), number(h, "clockCorrectionPpm"), number(h, "rateRatio"),
                number(h, "latencyFrames"), number(h, "cushionFrames"), number(h, "retargets"), number(h, "hidden"),
                text(h, "lastError").c_str());
    CFRelease(h);
}

// Every property the objects claim must answer with the size they announced.
static void checkPropertySurface() {
    struct Probe {
        AudioObjectID object;
        std::vector<AudioObjectPropertySelector> selectors;
    };
    std::vector<Probe> probes = {
        {1, {'bcls', 'clas', 'stdv', 'lmak', 'ownd', 'dev#', 'box#', 'rsrc'}},
        {2, {'bcls', 'clas', 'stdv', 'lnam', 'lmak', 'ownd', 'uid ', 'muid', 'tran', 'akin', 'clkd', 'livn', 'goin',
             'dflt', 'sflt', 'ltnc', 'saft', 'stm#', 'ctrl', 'nsrt', 'nsr#', 'hidn', 'dch2', 'srnd', 'ring', 'cust',
             'eqTg', 'eqHd', 'eqHl'}},
        {3, {'bcls', 'clas', 'stdv', 'ownd', 'sact', 'sdir', 'term', 'schn', 'ltnc', 'sfmt', 'pft ', 'sfma', 'pfta'}},
        {4, {'bcls', 'clas', 'stdv', 'cscp', 'celm', 'lcsv', 'lcdv', 'lcdr'}},
        {5, {'bcls', 'clas', 'stdv', 'cscp', 'celm', 'bcvl'}},
    };
    int checked = 0;
    for (auto &p : probes) {
        for (auto selector : p.selectors) {
            AudioObjectPropertyAddress a = {selector, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
            char name[5] = {char(selector >> 24), char(selector >> 16), char(selector >> 8), char(selector), 0};
            if (!vt()->HasProperty(driver, p.object, 0, &a)) {
                std::printf("  object %u lacks '%s'\n", p.object, name);
                ++failures;
                continue;
            }
            UInt32 size = 0;
            OSStatus err = vt()->GetPropertyDataSize(driver, p.object, 0, &a, 0, nullptr, &size);
            std::vector<UInt8> data(size + 16);
            UInt32 got = 0;
            OSStatus err2 = vt()->GetPropertyData(driver, p.object, 0, &a, 0, nullptr, size, &got, data.data());
            if (err || err2 || got != size) {
                std::printf("  object %u '%s': size %u/%u, errors %d %d\n", p.object, name, size, got, int(err), int(err2));
                ++failures;
            }
            if (size == sizeof(CFTypeRef) && (selector == 'lnam' || selector == 'lmak' || selector == 'uid ' ||
                                              selector == 'muid' || selector == 'rsrc' || selector == 'eqTg' ||
                                              selector == 'eqHd' || selector == 'eqHl')) {
                CFTypeRef object;
                std::memcpy(&object, data.data(), sizeof(object));
                if (object) CFRelease(object);
            }
            ++checked;
        }
    }
    AudioObjectPropertyAddress input = {'stm#', kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
    UInt32 inputStreams = 1;
    vt()->GetPropertyDataSize(driver, 2, 0, &input, 0, nullptr, &inputStreams);
    CHECK(inputStreams == 0);
    std::printf("  %d properties answer with their announced size; input streams: %u\n", checked, inputStreams / 4);
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "build/EQDriver.driver";
    AudioObjectID speakers = kAudioObjectUnknown;
    for (AudioObjectID id : hal::devices()) {
        if (hal::uint32Property(id, kAudioDevicePropertyTransportType) != kAudioDeviceTransportTypeBuiltIn) continue;
        auto ch = hal::outputChannelsPerBuffer(id);
        if (!ch.empty()) speakers = id;
    }
    if (!speakers) {
        std::printf("no built-in output device; skipping\n");
        return 0;
    }
    std::string speakersUID = hal::stringProperty(speakers, kAudioDevicePropertyDeviceUID);
    std::printf("target for this run: %s (%s)\n", hal::stringProperty(speakers, kAudioObjectPropertyName).c_str(),
                speakersUID.c_str());

    storage = CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFStringRef uid = CFStringCreateWithCString(nullptr, speakersUID.c_str(), kCFStringEncodingUTF8);
    CFDictionarySetValue(storage, CFSTR("target"), uid);
    CFRelease(uid);

    CFURLRef url = CFURLCreateFromFileSystemRepresentation(nullptr, reinterpret_cast<const UInt8 *>(path),
                                                           CFIndex(strlen(path)), true);
    CFBundleRef bundle = CFBundleCreate(nullptr, url);
    CFRelease(url);
    if (!bundle || !CFBundleLoadExecutable(bundle)) {
        std::printf("cannot load %s\n", path);
        return 1;
    }
    auto create = reinterpret_cast<void *(*)(CFAllocatorRef, CFUUIDRef)>(
        CFBundleGetFunctionPointerForName(bundle, CFSTR("EQDriver_Create")));
    driver = static_cast<AudioServerPlugInDriverRef>(create(nullptr, kAudioServerPlugInTypeUUID));
    CHECK(driver != nullptr);
    void *iface = nullptr;
    CHECK(vt()->QueryInterface(driver, CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID), &iface) == 0);
    CHECK(vt()->Initialize(driver, &host) == noErr);

    if (argc > 2 && std::string(argv[2]) == "--killed") {
        std::this_thread::sleep_for(std::chrono::milliseconds(1500));
        UInt32 hidden = 0, canBeDefault = 1;
        get(2, kAudioDevicePropertyIsHidden, hidden);
        get(2, kAudioDevicePropertyDeviceCanBeDefaultDevice, canBeDefault, kAudioObjectPropertyScopeOutput);
        CHECK(vt()->StartIO(driver, 2, 1) == noErr);
        std::vector<float> silence(512 * 2, 0.0f);
        AudioServerPlugInIOCycleInfo cycle{};
        CHECK(vt()->DoIOOperation(driver, 2, 3, 1, kAudioServerPlugInIOOperationWriteMix, 512, &cycle, silence.data(),
                                  nullptr) == noErr);
        std::this_thread::sleep_for(std::chrono::milliseconds(1500));
        CFDictionaryRef h = health();
        std::printf("kill file: hidden %u, can be default %u, killed %.0f, io %.0f, retargets %.0f\n", hidden,
                    canBeDefault, number(h, "killed"), number(h, "ioRunning"), number(h, "retargets"));
        CHECK(hidden == 1 && canBeDefault == 0 && number(h, "killed") == 1 && number(h, "retargets") == 0);
        CFRelease(h);
        vt()->StopIO(driver, 2, 1);
        return failures ? 1 : 0;
    }

    std::printf("load\n");
    std::this_thread::sleep_for(std::chrono::milliseconds(2500));
    checkPropertySurface();
    std::string name = cfString([] { CFStringRef s = nullptr; get(2, kAudioObjectPropertyName, s); return s; }());
    std::printf("  device name: \"%s\", configuration changes: %d\n", name.c_str(), configChanges.load());
    CHECK(name.find(" \xC2\xB7 EQ") != std::string::npos);
    UInt32 latency = 0;
    get(2, kAudioDevicePropertyLatency, latency, kAudioObjectPropertyScopeOutput);
    CHECK(latency > 0);
    dump("after load");

    std::printf("play silence for 12 s\n");
    CHECK(vt()->StartIO(driver, 2, 1) == noErr);
    std::atomic<bool> running{true};
    std::thread io([&] {
        mach_timebase_info_data_t base;
        mach_timebase_info(&base);
        double ticksPerSecond = 1e9 * base.denom / base.numer;
        // The HAL's IO threads are time-constraint threads; without this a late wake-up reads as an
        // underrun that the real host would not produce.
        thread_time_constraint_policy_data_t policy;
        policy.period = uint32_t(ticksPerSecond * 512 / 48000);
        policy.computation = policy.period / 10;
        policy.constraint = policy.period / 2;
        policy.preemptible = 1;
        thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY, reinterpret_cast<thread_policy_t>(&policy),
                          THREAD_TIME_CONSTRAINT_POLICY_COUNT);
        std::vector<float> silence(512 * 2, 0.0f);
        UInt64 lastSeed = 0;
        for (Float64 next = 0; running;) {
            while (ioPaused && running) std::this_thread::sleep_for(std::chrono::milliseconds(1));
            ioInCycle = true;
            Float64 zeroSample;
            UInt64 zeroHost, seed;
            vt()->GetZeroTimeStamp(driver, 2, 1, &zeroSample, &zeroHost, &seed);
            Float64 rate = 48000;
            get(2, kAudioDevicePropertyNominalSampleRate, rate);
            if (seed != lastSeed) {
                next = zeroSample + std::floor(double(mach_absolute_time() - zeroHost) * rate / ticksPerSecond);
                lastSeed = seed;
            }
            uint64_t due = zeroHost + uint64_t((next - zeroSample) * ticksPerSecond / rate);
            ioInCycle = false;
            mach_wait_until(due);
            ioInCycle = true;
            AudioServerPlugInIOCycleInfo cycle{};
            cycle.mOutputTime.mSampleTime = next;
            cycle.mOutputTime.mFlags = kAudioTimeStampSampleTimeValid;
            vt()->DoIOOperation(driver, 2, 3, 1, kAudioServerPlugInIOOperationWriteMix, 512, &cycle, silence.data(), nullptr);
            ioInCycle = false;
            next += 512;
        }
    });
    for (int i = 0; i < 4; ++i) {
        std::this_thread::sleep_for(std::chrono::seconds(3));
        dump(("t+" + std::to_string(3 * (i + 1)) + " s").c_str());
    }
    CFDictionaryRef h = health();
    CHECK(number(h, "ioRunning") == 1);
    CHECK(number(h, "overruns") == 0);
    std::printf("  underruns after start-up: %.0f\n", number(h, "underruns"));
    CFRelease(h);

    std::printf("point at a device that does not exist\n");
    CFStringRef bogus = CFSTR("com.servitola.eq.no-such-device");
    AudioObjectPropertyAddress target = {'eqTg', kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    CHECK(vt()->SetPropertyData(driver, 2, 0, &target, 0, nullptr, sizeof(bogus), &bogus) == noErr);
    std::this_thread::sleep_for(std::chrono::milliseconds(3600));
    dump("gone 3.6 s");
    h = health();
    CHECK(number(h, "targetAvailable") == 0 && number(h, "ioRunning") == 0 && number(h, "hidden") == 1);
    CFRelease(h);

    std::printf("point back at the speakers\n");
    CFStringRef back = CFStringCreateWithCString(nullptr, speakersUID.c_str(), kCFStringEncodingUTF8);
    CHECK(vt()->SetPropertyData(driver, 2, 0, &target, 0, nullptr, sizeof(back), &back) == noErr);
    CFRelease(back);
    std::this_thread::sleep_for(std::chrono::seconds(2));
    dump("back 2 s");
    h = health();
    CHECK(number(h, "targetAvailable") == 1 && number(h, "ioRunning") == 1 && number(h, "hidden") == 0);
    CHECK(number(h, "retargets") >= 2);
    CFRelease(h);

    std::printf("stop; the target should idle out after 2 s\n");
    running = false;
    io.join();
    CHECK(vt()->StopIO(driver, 2, 1) == noErr);
    std::this_thread::sleep_for(std::chrono::milliseconds(2800));
    dump("stopped 2.8 s");
    h = health();
    CHECK(number(h, "ioRunning") == 0);
    CFRelease(h);

    std::printf("\nhost harness: %s (%d notifications, %d configuration changes)\n", failures ? "FAILED" : "ok",
                notifications.load(), configChanges.load());
    return failures ? 1 : 0;
}
