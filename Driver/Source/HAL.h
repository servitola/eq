#pragma once

// HAL client calls on other devices. Derived from Proxy Audio Device v1.1.0b1's shared/AudioDevice.cpp
// (Unlicense). AudioServerPlugIn.h forbids these in a plug-in; the plug-in makes them only on its own
// serial queue, never on a thread the host called in on.

#include <CoreAudio/CoreAudio.h>

#include <cstring>
#include <string>
#include <vector>

namespace eqd::hal {

inline AudioObjectPropertyAddress address(AudioObjectPropertySelector selector,
                                          AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal,
                                          AudioObjectPropertyElement element = kAudioObjectPropertyElementMain) {
    return {selector, scope, element};
}

template <typename T>
OSStatus get(AudioObjectID object, AudioObjectPropertyAddress where, T &out) {
    UInt32 size = sizeof(T);
    return AudioObjectGetPropertyData(object, &where, 0, nullptr, &size, &out);
}

template <typename T>
OSStatus set(AudioObjectID object, AudioObjectPropertyAddress where, const T &value) {
    return AudioObjectSetPropertyData(object, &where, 0, nullptr, sizeof(T), &value);
}

inline std::string string(CFStringRef s) {
    if (!s) return {};
    CFIndex size = CFStringGetMaximumSizeForEncoding(CFStringGetLength(s), kCFStringEncodingUTF8) + 1;
    std::string out(size_t(size), '\0');
    if (!CFStringGetCString(s, out.data(), size, kCFStringEncodingUTF8)) return {};
    out.resize(std::strlen(out.c_str()));
    return out;
}

inline std::string stringProperty(AudioObjectID object, AudioObjectPropertySelector selector) {
    CFStringRef value = nullptr;
    if (get(object, address(selector), value) != noErr || !value) return {};
    std::string out = string(value);
    CFRelease(value);
    return out;
}

inline std::vector<AudioObjectID> devices() {
    AudioObjectPropertyAddress where = address(kAudioHardwarePropertyDevices);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &where, 0, nullptr, &size) != noErr) return {};
    std::vector<AudioObjectID> ids(size / sizeof(AudioObjectID));
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &where, 0, nullptr, &size, ids.data()) != noErr) return {};
    ids.resize(size / sizeof(AudioObjectID));
    return ids;
}

inline AudioObjectID defaultOutput() {
    AudioObjectID id = kAudioObjectUnknown;
    get(kAudioObjectSystemObject, address(kAudioHardwarePropertyDefaultOutputDevice), id);
    return id;
}

inline std::vector<UInt32> outputChannelsPerBuffer(AudioObjectID device) {
    AudioObjectPropertyAddress where = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &where, 0, nullptr, &size) != noErr || size < sizeof(AudioBufferList))
        return {};
    std::vector<UInt8> storage(size);
    auto *list = reinterpret_cast<AudioBufferList *>(storage.data());
    if (AudioObjectGetPropertyData(device, &where, 0, nullptr, &size, list) != noErr) return {};
    std::vector<UInt32> channels;
    for (UInt32 b = 0; b < list->mNumberBuffers; ++b) channels.push_back(list->mBuffers[b].mNumberChannels);
    return channels;
}

inline bool isAlive(AudioObjectID device) {
    UInt32 alive = 0;
    return get(device, address(kAudioDevicePropertyDeviceIsAlive), alive) == noErr && alive != 0;
}

inline UInt32 uint32Property(AudioObjectID object, AudioObjectPropertySelector selector,
                             AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal, UInt32 fallback = 0) {
    UInt32 value = fallback;
    return get(object, address(selector, scope), value) == noErr ? value : fallback;
}

inline bool settable(AudioObjectID object, AudioObjectPropertyAddress where) {
    Boolean can = false;
    return AudioObjectHasProperty(object, &where) && AudioObjectIsPropertySettable(object, &where, &can) == noErr && can;
}

inline std::vector<std::string> aggregateSubDeviceUIDs(AudioObjectID device) {
    CFArrayRef list = nullptr;
    if (get(device, address(kAudioAggregateDevicePropertyFullSubDeviceList), list) != noErr || !list) return {};
    std::vector<std::string> uids;
    for (CFIndex i = 0; i < CFArrayGetCount(list); ++i) {
        CFTypeRef item = CFArrayGetValueAtIndex(list, i);
        if (item && CFGetTypeID(item) == CFStringGetTypeID()) uids.push_back(string(static_cast<CFStringRef>(item)));
    }
    CFRelease(list);
    return uids;
}

} // namespace eqd::hal
