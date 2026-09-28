#pragma once

#include <string>
#include <vector>

namespace eqd {

inline std::vector<std::string> splitColons(const std::string &s) {
    std::vector<std::string> parts;
    size_t from = 0;
    for (;;) {
        size_t at = s.find(':', from);
        parts.push_back(s.substr(from, at == std::string::npos ? std::string::npos : at - from));
        if (at == std::string::npos) return parts;
        from = at + 1;
    }
}

// USB audio UIDs embed the port's location ID when the device has no serial number
// ("AppleUSBAudioEngine:<maker>:<product>:<location>:<interface>"), so the same dock on another
// port gets another UID (Proxy Audio Device PR #71, seen on macOS 26.4). Callers try an exact
// match over every device first.
inline bool sameDeviceIgnoringUSBLocation(const std::string &a, const std::string &b) {
    static const std::string prefix = "AppleUSBAudioEngine:";
    if (a.compare(0, prefix.size(), prefix) != 0 || b.compare(0, prefix.size(), prefix) != 0) return false;
    std::vector<std::string> pa = splitColons(a), pb = splitColons(b);
    if (pa.size() != pb.size() || pa.size() < 5) return false;
    for (size_t i = 0; i < pa.size(); ++i)
        if (i != pa.size() - 2 && pa[i] != pb[i]) return false;
    return true;
}

} // namespace eqd
