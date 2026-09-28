// Reads the EQ device's health, and sets its target or hidden flag, through the HAL like any client.
//   probe                   print the health dictionary
//   probe target <UID>      play through the device with this UID ("" picks the default output)
//   probe hidden 0|1

#include <CoreAudio/CoreAudio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const AudioObjectPropertySelector kTarget = 'eqTg', kHidden = 'eqHd', kHealth = 'eqHl';

static AudioObjectID findDevice(void) {
    CFStringRef uid = CFSTR("com.servitola.eq.device");
    AudioObjectID device = kAudioObjectUnknown;
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    UInt32 size = sizeof(device);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof(uid), &uid, &size, &device) != noErr)
        return kAudioObjectUnknown;
    return device;
}

static void printValue(const void *key, const void *value, void *context) {
    (void)context;
    char k[128] = "", v[1024] = "";
    CFStringGetCString(key, k, sizeof(k), kCFStringEncodingUTF8);
    CFTypeID type = CFGetTypeID(value);
    if (type == CFStringGetTypeID()) {
        CFStringGetCString(value, v, sizeof(v), kCFStringEncodingUTF8);
    } else if (type == CFBooleanGetTypeID()) {
        snprintf(v, sizeof(v), "%s", CFBooleanGetValue(value) ? "yes" : "no");
    } else if (type == CFNumberGetTypeID()) {
        double d = 0;
        CFNumberGetValue(value, kCFNumberDoubleType, &d);
        if (CFNumberIsFloatType(value)) snprintf(v, sizeof(v), "%.3f", d);
        else snprintf(v, sizeof(v), "%.0f", d);
    }
    printf("%s: %s\n", k, v);
}

static int compareKeys(const void *a, const void *b) {
    return CFStringCompare(*(CFStringRef const *)a, *(CFStringRef const *)b, 0);
}

int main(int argc, char **argv) {
    AudioObjectID device = findDevice();
    if (device == kAudioObjectUnknown) {
        fprintf(stderr, "probe: no EQ device (EQDriver.driver not installed, or coreaudiod not restarted)\n");
        return 1;
    }
    AudioObjectPropertyAddress a = {kHealth, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    OSStatus err;

    if (argc == 3 && strcmp(argv[1], "target") == 0) {
        a.mSelector = kTarget;
        CFStringRef uid = CFStringCreateWithCString(NULL, argv[2], kCFStringEncodingUTF8);
        err = AudioObjectSetPropertyData(device, &a, 0, NULL, sizeof(uid), &uid);
        CFRelease(uid);
    } else if (argc == 3 && strcmp(argv[1], "hidden") == 0) {
        a.mSelector = kHidden;
        CFBooleanRef value = strcmp(argv[2], "0") == 0 ? kCFBooleanFalse : kCFBooleanTrue;
        err = AudioObjectSetPropertyData(device, &a, 0, NULL, sizeof(value), &value);
    } else if (argc == 1) {
        CFDictionaryRef health = NULL;
        UInt32 size = sizeof(health);
        err = AudioObjectGetPropertyData(device, &a, 0, NULL, &size, &health);
        if (err == noErr && health && CFGetTypeID(health) == CFDictionaryGetTypeID()) {
            CFIndex n = CFDictionaryGetCount(health);
            const void **keys = calloc((size_t)n, sizeof(void *));
            const void **values = calloc((size_t)n, sizeof(void *));
            CFDictionaryGetKeysAndValues(health, keys, values);
            qsort(keys, (size_t)n, sizeof(void *), compareKeys);
            for (CFIndex i = 0; i < n; ++i) printValue(keys[i], CFDictionaryGetValue(health, keys[i]), NULL);
            free(keys);
            free(values);
        }
        if (health) CFRelease(health);
    } else {
        fprintf(stderr, "usage: probe [target <UID> | hidden 0|1]\n");
        return 2;
    }
    if (err != noErr) {
        fprintf(stderr, "probe: HAL error %d\n", (int)err);
        return 1;
    }
    return 0;
}
