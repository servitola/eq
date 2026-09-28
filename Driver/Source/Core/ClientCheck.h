#pragma once

#include <Security/Security.h>
#include <sys/sysctl.h>

#include <cstdint>
#include <mutex>
#include <string>

namespace eqd {

// Whether the process behind a pid satisfies a code requirement. The host hands SetPropertyData
// only the caller's pid; the driver helper runs outside coreaudiod's sandbox, so it can ask the
// Security framework about that process. A pid can be reused, so a verdict is remembered only for
// the same pid with the same start time.
class ClientCheck {
  public:
    explicit ClientCheck(const std::string &requirement) : text_(requirement) {
        CFStringRef s = CFStringCreateWithCString(nullptr, requirement.c_str(), kCFStringEncodingUTF8);
        if (s) {
            if (SecRequirementCreateWithString(s, kSecCSDefaultFlags, &requirement_) != errSecSuccess) requirement_ = nullptr;
            CFRelease(s);
        }
    }
    ~ClientCheck() {
        if (requirement_) CFRelease(requirement_);
    }
    ClientCheck(const ClientCheck &) = delete;
    ClientCheck &operator=(const ClientCheck &) = delete;

    const std::string &requirement() const { return text_; }

    bool allowed(pid_t pid) {
        if (pid <= 0 || !requirement_) return false;
        uint64_t started = startTime(pid);
        if (!started) return false;
        std::lock_guard<std::mutex> lock(mutex_);
        if (pid == lastPID_ && started == lastStart_) return lastVerdict_;
        bool verdict = check(pid) && startTime(pid) == started;
        lastPID_ = pid;
        lastStart_ = started;
        lastVerdict_ = verdict;
        return verdict;
    }

  private:
    // Not proc_pidinfo: its PROC_PIDTBSDINFO answers only for the caller's own user, and the
    // helper runs as _coreaudiod while eq runs as the logged-in user.
    static uint64_t startTime(pid_t pid) {
        kinfo_proc info;
        size_t size = sizeof(info);
        int name[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
        if (sysctl(name, 4, &info, &size, nullptr, 0) != 0 || size != sizeof(info) || info.kp_proc.p_pid != pid) return 0;
        return uint64_t(info.kp_proc.p_starttime.tv_sec) * 1000000 + uint64_t(info.kp_proc.p_starttime.tv_usec);
    }

    bool check(pid_t pid) {
        CFNumberRef number = CFNumberCreate(nullptr, kCFNumberIntType, &pid);
        const void *keys[] = {kSecGuestAttributePid};
        const void *values[] = {number};
        CFDictionaryRef attributes =
            CFDictionaryCreate(nullptr, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFRelease(number);
        SecCodeRef code = nullptr;
        OSStatus err = SecCodeCopyGuestWithAttributes(nullptr, attributes, kSecCSDefaultFlags, &code);
        CFRelease(attributes);
        if (err != errSecSuccess || !code) return false;
        err = SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement_);
        CFRelease(code);
        return err == errSecSuccess;
    }

    std::string text_;
    SecRequirementRef requirement_ = nullptr;
    std::mutex mutex_;
    pid_t lastPID_ = 0;
    uint64_t lastStart_ = 0;
    bool lastVerdict_ = false;
};

} // namespace eqd
