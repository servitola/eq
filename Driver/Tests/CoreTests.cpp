#include "../Source/Core/ChangeRequest.h"
#include "../Source/Core/ChannelMap.h"
#include "../Source/Core/ClientCheck.h"
#include "../Source/Core/Clock.h"
#include "../Source/Core/DeviceMatch.h"
#include "../Source/Core/EngineSettings.h"
#include "../Source/Core/FrameRing.h"
#include "../Source/Core/Latency.h"
#include "../Source/Core/Pipeline.h"
#include "../Source/Core/SeqLock.h"
#include "../Source/Core/TargetMachine.h"

#include <cmath>
#include <cstdio>
#include <functional>
#include <map>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

using namespace eqd;

static int failures = 0;
static int checks = 0;
#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        ++checks;                                                                                                      \
        if (!(cond)) {                                                                                                 \
            ++failures;                                                                                                \
            std::printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                                              \
        }                                                                                                              \
    } while (0)
#define CHECK_NEAR(a, b, tol)                                                                                          \
    do {                                                                                                               \
        ++checks;                                                                                                      \
        double va = (a), vb = (b);                                                                                     \
        if (!(std::fabs(va - vb) <= (tol))) {                                                                          \
            ++failures;                                                                                                \
            std::printf("  FAIL %s:%d: %s = %g, want %g ± %g\n", __FILE__, __LINE__, #a, va, vb, double(tol));         \
        }                                                                                                              \
    } while (0)

static std::vector<std::pair<const char *, std::function<void()>>> &tests() {
    static std::vector<std::pair<const char *, std::function<void()>>> all;
    return all;
}
struct Register {
    Register(const char *name, std::function<void()> body) { tests().push_back({name, body}); }
};
#define TEST(name)                                                                                                     \
    static void name();                                                                                                \
    static Register register_##name(#name, name);                                                                      \
    static void name()

// Never zero, so silence and signal cannot be confused.
static float rampValue(int64_t frame) { return float(frame % 65535 + 1); }

static std::vector<float> ramp(int64_t start, uint32_t frames) {
    std::vector<float> v(frames * 2);
    for (uint32_t i = 0; i < frames; ++i) {
        v[2 * i] = rampValue(start + i);
        v[2 * i + 1] = -rampValue(start + i);
    }
    return v;
}

// MARK: SeqLock

TEST(seqlock_never_hands_out_a_torn_value) {
    struct Pair {
        uint64_t a, b, c;
    };
    SeqLock<Pair> lock;
    Pair out{};
    CHECK(!lock.read(out));
    std::atomic<bool> done{false};
    std::thread writer([&] {
        for (uint64_t i = 1; i < 2000000; ++i) lock.publish({i, i * 2, i * 3});
        done = true;
    });
    uint64_t reads = 0, torn = 0, last = 0, backwards = 0;
    while (!done) {
        if (lock.read(out)) {
            ++reads;
            if (out.b != out.a * 2 || out.c != out.a * 3) ++torn;
            if (out.a < last) ++backwards;
            last = out.a;
        }
    }
    writer.join();
    CHECK(reads > 0);
    CHECK(torn == 0);
    CHECK(backwards == 0);
}

// MARK: FrameRing

TEST(ring_reads_back_what_was_written_across_the_wrap) {
    FrameRing ring(2, 1000, 16384);
    CHECK(ring.capacity() == 1024);
    int64_t t = 5000;
    for (int i = 0; i < 10; ++i, t += 300) CHECK(ring.write(ramp(t, 300).data(), 300, t) != FrameRing::Write::Restart);
    std::vector<float> out(2 * 400);
    FrameRing::Read r = ring.read(out.data(), 400, t - 700);
    CHECK(r.valid && r.underrun == 0 && r.overrun == 0 && r.missing == 0);
    bool same = true;
    for (int i = 0; i < 400; ++i) same = same && out[2 * i] == rampValue(t - 700 + i) && out[2 * i + 1] == -out[2 * i];
    CHECK(same);
}

TEST(ring_classifies_missing_underrun_and_overrun) {
    FrameRing ring(2, 1024, 16384);
    std::vector<float> out(2 * 100);
    CHECK(ring.read(out.data(), 100, 0).missing == 100);
    ring.write(ramp(1000, 100).data(), 100, 1000);
    FrameRing::Read before = ring.read(out.data(), 100, 950);
    CHECK(before.missing == 50 && before.underrun == 0);
    FrameRing::Read ahead = ring.read(out.data(), 100, 1050);
    CHECK(ahead.underrun == 50 && out[0] == rampValue(1050) && out[2 * 50] == 0.0f);
    for (int64_t t = 1100; t < 3000; t += 100) ring.write(ramp(t, 100).data(), 100, t);
    FrameRing::Read old = ring.read(out.data(), 100, 3000 - 1024 - 50);
    CHECK(old.overrun == 50 && old.underrun == 0);
}

TEST(ring_zero_fills_a_small_gap_and_restarts_on_a_jump) {
    FrameRing ring(2, 1024, 256);
    CHECK(ring.write(ramp(0, 100).data(), 100, 0) == FrameRing::Write::First);
    uint64_t firstEpoch = ring.epoch();
    CHECK(ring.write(ramp(150, 100).data(), 100, 150) == FrameRing::Write::Gap);
    std::vector<float> out(2 * 250);
    FrameRing::Read r = ring.read(out.data(), 250, 0);
    CHECK(r.underrun == 0 && out[2 * 120] == 0.0f && out[2 * 99] == rampValue(99) && out[2 * 150] == rampValue(150));
    CHECK(ring.write(ramp(10, 100).data(), 100, 10) == FrameRing::Write::Restart);
    CHECK(ring.epoch() == firstEpoch + 2);
    CHECK(ring.read(out.data(), 100, 0).missing == 10);
    CHECK(ring.write(ramp(10000, 100).data(), 100, 10000) == FrameRing::Write::Restart);
}

TEST(ring_spsc_stress_hands_out_only_correct_frames) {
    FrameRing ring(2, 4096, 16384);
    std::atomic<bool> done{false};
    std::thread writer([&] {
        int64_t t = 0;
        for (int i = 0; i < 200000; ++i, t += 64) ring.write(ramp(t, 64).data(), 64, t);
        done = true;
    });
    std::vector<float> out(2 * 256);
    uint64_t wrong = 0, served = 0;
    while (!done) {
        int64_t end = ring.end();
        int64_t start = end - 3000;
        if (start < 0) continue;
        FrameRing::Read r = ring.read(out.data(), 256, start);
        if (!r.valid) continue;
        for (int i = 0; i < 256; ++i) {
            if (out[2 * i] == 0.0f && out[2 * i + 1] == 0.0f) continue;
            ++served;
            if (out[2 * i] != rampValue(start + i) || out[2 * i + 1] != -out[2 * i]) ++wrong;
        }
    }
    writer.join();
    CHECK(served > 0);
    CHECK(wrong == 0);
}

// MARK: Timeline and clock

TEST(timeline_watch_flags_backward_and_large_forward_jumps) {
    TimelineWatch w;
    CHECK(!w.observe(1000, 512));
    CHECK(!w.observe(1512, 512));
    CHECK(!w.observe(2024 + 16384, 512));
    CHECK(w.observe(13688, 512));
    CHECK(!w.observe(14200, 512));
    CHECK(w.observe(14712 + 16385, 512));
}

TEST(clock_advances_by_every_elapsed_period) {
    const double tpf = 1e9 / 48000;
    VirtualClock c(tpf);
    c.anchor(1000);
    c.advance(1000 + uint64_t(tpf * VirtualClock::kPeriod * 3.5), nullptr);
    CHECK(c.zeroSample() == 3.0 * VirtualClock::kPeriod);
    CHECK_NEAR(double(c.zeroHost()), 1000 + tpf * VirtualClock::kPeriod * 3, 2);
    CHECK_NEAR(projectSample(c.snapshot(), c.zeroHost() + uint64_t(tpf * 100)), 3.0 * VirtualClock::kPeriod + 100, 0.01);
}

TEST(clock_correction_is_clamped) {
    const double tpf = 1e9 / 48000;
    VirtualClock c(tpf);
    c.anchor(0);
    ServoFeedback fb{1, 0, 0, 0, 0};
    uint64_t now = 0;
    for (int i = 1; i <= 50; ++i) {
        fb.phaseCount += 10;
        fb.phaseSum += 10 * 1e6;
        now += uint64_t(tpf * VirtualClock::kPeriod * 1.001);
        c.advance(now, &fb);
    }
    CHECK_NEAR(c.correctionPpm(), 500, 1e-6);
    for (int i = 1; i <= 500; ++i) {
        fb.phaseCount += 10;
        fb.phaseSum -= 10 * 1e6;
        now += uint64_t(tpf * VirtualClock::kPeriod * 1.001);
        c.advance(now, &fb);
    }
    CHECK_NEAR(c.correctionPpm(), -500, 1e-6);
}

TEST(clock_takes_the_rate_scalar_as_feed_forward) {
    const double tpf = 1e9 / 48000;
    VirtualClock c(tpf);
    c.anchor(0);
    ServoFeedback fb{7, 4, 0, 4 * 0.9997, 0};
    c.advance(uint64_t(tpf * VirtualClock::kPeriod * 1.2), &fb);
    CHECK_NEAR(c.rateRatio(), 0.9997, 1e-12);
    CHECK_NEAR(c.snapshot().ticksPerFrame, tpf * 0.9997, 1e-9);
}

// MARK: Latency

TEST(latency_is_the_target_chain_plus_the_cushion) {
    TargetTiming t;
    t.deviceLatency = 7938;
    t.streamLatency = 12;
    t.safetyOffset = 144;
    t.bufferFrames = 512;
    CHECK(cushionFrames(t) == 144 + 1024 + kCushionMarginFrames);
    CHECK(reportedLatency(t, cushionFrames(t)) == 7938 + 12 + 144 + 1024 + kCushionMarginFrames);
}

// MARK: Channel map

static AudioBufferList *bufferList(std::vector<std::vector<float>> &storage, const std::vector<uint32_t> &channels,
                                   uint32_t frames) {
    size_t size = offsetof(AudioBufferList, mBuffers) + channels.size() * sizeof(AudioBuffer);
    auto *list = static_cast<AudioBufferList *>(calloc(1, size));
    list->mNumberBuffers = uint32_t(channels.size());
    storage.resize(channels.size());
    for (size_t b = 0; b < channels.size(); ++b) {
        storage[b].assign(channels[b] * frames, 7.0f);
        list->mBuffers[b] = {channels[b], uint32_t(storage[b].size() * sizeof(float)), storage[b].data()};
    }
    return list;
}

TEST(channel_map_handles_interleaved_split_wide_and_mono_targets) {
    const float left[] = {1, 2, 3}, right[] = {-1, -2, -3};
    std::vector<std::vector<float>> s;

    AudioBufferList *inter = bufferList(s, {2}, 3);
    scatter(left, right, 3, makeChannelMap({2}, 1, 2), inter, 1, 1);
    CHECK(s[0] == (std::vector<float>{1, -1, 2, -2, 3, -3}));
    free(inter);

    AudioBufferList *split = bufferList(s, {1, 1}, 3);
    scatter(left, right, 3, makeChannelMap({1, 1}, 1, 2), split, 0.5f, 1);
    CHECK(s[0] == (std::vector<float>{0.5f, 1, 1.5f}) && s[1] == (std::vector<float>{-1, -2, -3}));
    free(split);

    AudioBufferList *wide = bufferList(s, {8}, 2);
    scatter(left, right, 2, makeChannelMap({8}, 3, 4), wide, 1, 1);
    CHECK(s[0][2] == 1 && s[0][3] == -1 && s[0][8 + 2] == 2 && s[0][8 + 3] == -2 && s[0][0] == 0 && s[0][7] == 0);
    free(wide);

    AudioBufferList *twoStreams = bufferList(s, {2, 6}, 1);
    ChannelMap m = makeChannelMap({2, 6}, 3, 4);
    CHECK(m.left.buffer == 1 && m.left.offset == 0 && m.right.offset == 1);
    scatter(left, right, 1, m, twoStreams, 1, 1);
    CHECK(s[0][0] == 0 && s[1][0] == 1 && s[1][1] == -1);
    free(twoStreams);

    AudioBufferList *mono = bufferList(s, {1}, 1);
    ChannelMap mm = makeChannelMap({1}, 1, 2);
    CHECK(mm.valid && mm.mono);
    scatter(left + 2, left, 1, mm, mono, 1, 1);
    CHECK(s[0][0] == 2);
    free(mono);

    ChannelMap fallback = makeChannelMap({2}, 0, 9);
    CHECK(fallback.valid && fallback.left.offset == 0 && fallback.right.offset == 1);
    CHECK(!makeChannelMap({}, 1, 2).valid);
}

// MARK: Device match

TEST(usb_uid_match_ignores_only_the_location) {
    std::string a = "AppleUSBAudioEngine:CalDigit:TS4 Audio:20200000:1";
    CHECK(sameDeviceIgnoringUSBLocation(a, "AppleUSBAudioEngine:CalDigit:TS4 Audio:21200000:1"));
    CHECK(!sameDeviceIgnoringUSBLocation(a, "AppleUSBAudioEngine:CalDigit:TS4 Audio:21200000:2"));
    CHECK(!sameDeviceIgnoringUSBLocation(a, "AppleUSBAudioEngine:Other:TS4 Audio:20200000:1"));
    CHECK(!sameDeviceIgnoringUSBLocation("40-72-18-5C-0F-2E:output", "40-72-18-5C-0F-2F:output"));
}

// MARK: Target machine

struct FakeTarget : TargetExecutor {
    std::vector<std::string> calls;
    bool buildOK = true;
    std::vector<bool> startResults;
    bool build(uint32_t id) override {
        calls.push_back("build " + std::to_string(id));
        return buildOK;
    }
    void teardown() override { calls.push_back("teardown"); }
    bool start() override {
        calls.push_back("start");
        if (startResults.empty()) return true;
        bool ok = startResults.front();
        startResults.erase(startResults.begin());
        return ok;
    }
    void stop() override { calls.push_back("stop"); }
    std::string take() {
        std::string all;
        for (auto &c : calls) all += (all.empty() ? "" : ", ") + c;
        calls.clear();
        return all;
    }
};

static TargetFacts facts(double now, bool found, uint32_t id = 42, bool clients = true) {
    TargetFacts f;
    f.now = now;
    f.found = found;
    f.deviceID = id;
    f.clientsActive = clients;
    f.lastCallbackAt = now;
    return f;
}

TEST(machine_keeps_looking_for_a_target_that_appears_late) {
    TargetMachine m(0);
    FakeTarget x;
    TargetOutcome o = m.step(facts(1.0, false), x);
    CHECK(x.take().empty() && !o.hidden);
    CHECK_NEAR(o.recheckIn, 0.1, 1e-9);
    o = m.step(facts(1.1, false), x);
    CHECK_NEAR(o.recheckIn, 0.5, 1e-9);
    o = m.step(facts(1.6, false), x);
    CHECK_NEAR(o.recheckIn, 2.0, 1e-9);
    o = m.step(facts(2.0, true), x);
    CHECK(x.take() == "build 42, start");
    CHECK(m.running() && m.builds() == 1);
    CHECK_NEAR(o.recheckIn, TargetMachine::kWatchdogEvery, 1e-9);
}

TEST(machine_retries_a_failed_start_with_backoff_then_rebuilds) {
    TargetMachine m(0);
    FakeTarget x;
    x.startResults = {false, false, false, true};
    TargetOutcome o = m.step(facts(0, true), x);
    CHECK(x.take() == "build 42, start");
    CHECK_NEAR(o.recheckIn, 0.1, 1e-9);
    o = m.step(facts(0.05, true), x);
    CHECK(x.take().empty());
    o = m.step(facts(0.1, true), x);
    CHECK(x.take() == "start");
    CHECK_NEAR(o.recheckIn, 0.5, 1e-9);
    o = m.step(facts(0.6, true), x);
    CHECK(x.take() == "start, teardown");
    CHECK_NEAR(o.recheckIn, 2.0, 1e-9);
    o = m.step(facts(2.6, true), x);
    CHECK(x.take() == "build 42, start");
    CHECK(m.running() && m.startFailures() == 3);
}

TEST(machine_rebuilds_a_stalled_ioproc) {
    TargetMachine m(0);
    FakeTarget x;
    m.step(facts(0, true), x);
    x.take();
    TargetFacts f = facts(0.9, true);
    f.lastCallbackAt = 0.5;
    m.step(f, x);
    CHECK(x.take().empty());
    f = facts(2.0, true);
    f.lastCallbackAt = 0.5;
    TargetOutcome o = m.step(f, x);
    CHECK(x.take() == "teardown");
    CHECK_NEAR(o.recheckIn, 0.1, 1e-9);
    f.now = 2.1;
    m.step(f, x);
    CHECK(x.take() == "build 42, start");
    CHECK(m.stalls() == 1);

    f.now = 3.2;
    o = m.step(f, x);
    CHECK(x.take() == "teardown");
    CHECK_NEAR(o.recheckIn, 0.5, 1e-9);
    f.now = 3.7;
    m.step(f, x);
    CHECK(x.take() == "build 42, start");
    f.now = 4.0;
    f.lastCallbackAt = 3.9;
    m.step(f, x);
    f.now = 5.5;
    o = m.step(f, x);
    CHECK(x.take() == "teardown");
    CHECK_NEAR(o.recheckIn, 0.1, 1e-9);
    CHECK(m.stalls() == 3);
}

TEST(machine_stops_the_target_after_an_idle_delay) {
    TargetMachine m(0);
    FakeTarget x;
    m.step(facts(0, true), x);
    x.take();
    TargetOutcome o = m.step(facts(5, true, 42, false), x);
    CHECK(x.take().empty());
    CHECK_NEAR(o.recheckIn, TargetMachine::kIdleStopAfter, 1e-9);
    m.step(facts(6, true, 42, true), x);
    m.step(facts(6.5, true, 42, false), x);
    m.step(facts(8.0, true, 42, false), x);
    CHECK(x.take().empty());
    m.step(facts(8.5, true, 42, false), x);
    CHECK(x.take() == "stop");
    m.step(facts(9, true, 42, true), x);
    CHECK(x.take() == "start");
}

TEST(machine_hides_only_after_the_target_is_gone_for_a_while) {
    TargetMachine m(0);
    FakeTarget x;
    CHECK(!m.step(facts(1, false), x).hidden);
    TargetOutcome o = m.step(facts(5, false), x);
    CHECK(!o.hidden);
    CHECK(o.recheckIn <= 5.0);
    CHECK(m.step(facts(10, false), x).hidden);
    CHECK(!m.step(facts(11, true), x).hidden);
    x.take();
    CHECK(!m.step(facts(20, false), x).hidden);
    CHECK(x.take() == "teardown");
    CHECK(!m.step(facts(22.9, false), x).hidden);
    CHECK(m.step(facts(23, false), x).hidden);
}

TEST(machine_follows_a_new_device_and_rebuilds_on_request) {
    TargetMachine m(0);
    FakeTarget x;
    m.step(facts(0, true, 7), x);
    x.take();
    m.step(facts(1, true, 9), x);
    CHECK(x.take() == "teardown, build 9, start");
    TargetFacts f = facts(2, true, 9);
    f.rebuild = true;
    m.step(f, x);
    CHECK(x.take() == "teardown, build 9, start");
    CHECK(m.requestedRebuilds() == 1 && m.builds() == 3);
}

TEST(machine_waits_for_the_rate_to_match_before_starting) {
    TargetMachine m(0);
    FakeTarget x;
    TargetFacts f = facts(0, true);
    f.rateMatches = false;
    TargetOutcome o = m.step(f, x);
    CHECK(x.take() == "build 42");
    CHECK_NEAR(o.recheckIn, TargetMachine::kRateRecheckEvery, 1e-9);
    f.now = 0.3;
    f.rateMatches = true;
    m.step(f, x);
    CHECK(x.take() == "start");
}

TEST(change_request_is_sent_once_until_answered) {
    ChangeRequest c;
    CHECK(c.recheckIn(0) == -1);
    CHECK(c.send(0));
    CHECK(c.pending(1) && !c.send(1));
    CHECK_NEAR(c.recheckIn(1), 2.0, 1e-9);
    c.performed();
    CHECK(!c.pending(1.5) && c.recheckIn(1.5) == -1);
    CHECK(c.send(1.5));
}

TEST(change_request_lost_or_refused_is_resent_with_backoff) {
    ChangeRequest c;
    CHECK(c.send(0));
    CHECK(!c.pending(ChangeRequest::kTimeout));
    CHECK_NEAR(c.recheckIn(3), 1.0, 1e-9);
    CHECK(!c.send(3.5));
    CHECK(c.send(4));
    c.failed(4.5);
    CHECK(!c.send(6) && c.send(6.5));
    c.failed(7);
    CHECK(!c.send(11.9) && c.send(12));
    c.failed(12);
    c.failed(12);
    CHECK(!c.send(21.9) && c.send(22));
    c.performed();
    c.failed(30);
    CHECK_NEAR(c.recheckIn(30), 1.0, 1e-9);
}

// MARK: Whole pipeline, simulated

struct SimResult {
    uint64_t underruns = 0, overruns = 0, resyncs = 0, breaks = 0, silentCycles = 0;
    int64_t worstPhase = 0;
    double correctionPpm = 0, rateRatio = 0;
};

// Our device's HAL writes frames just in time on its own clock; the target consumes on a clock
// `ppm` off nominal, a buffer plus a safety offset ahead of the hardware, with scheduling jitter on
// both sides. Counts audible breaks in a ramp after the warm-up.
static SimResult simulate(double seconds, double ppm, bool rateScalarValid, double jumpAt, double warmup) {
    const double ticks = 1e9, rate = 48000, nominal = ticks / rate;
    const uint32_t clientBuffer = 512, targetBuffer = 512, safety = 144;
    TargetTiming timing;
    timing.bufferFrames = targetBuffer;
    timing.safetyOffset = safety;
    Pipeline p;
    VirtualClock clock(nominal);
    Reader reader(p, cushionFrames(timing));
    std::mt19937 rng(1234);
    std::uniform_real_distribution<double> jitter(0, 150e-6 * ticks);

    const double targetTpf = nominal / (1.0 + ppm * 1e-6);
    const uint64_t t0 = 5'000'000'000ull;
    clock.anchor(t0);
    p.clock.publish(clock.snapshot());
    p.firstClientStarted();

    int64_t ourNext = 0;
    double writeAt = double(t0);
    double targetZeroHost = double(t0) + 0.2 * ticks, targetSample = 0;
    double readAt = targetZeroHost - (safety + targetBuffer) * targetTpf;
    bool jumped = false;
    std::vector<float> stereo(2 * targetBuffer);
    SimResult res;
    int64_t last = -1;
    const double end = double(t0) + seconds * ticks;

    while (writeAt < end || readAt < end) {
        if (writeAt <= readAt) {
            uint64_t now = uint64_t(writeAt);
            ServoFeedback fb;
            bool have = p.feedback.read(fb);
            clock.advance(now, have ? &fb : nullptr);
            p.clock.publish(clock.snapshot());
            p.write(ramp(ourNext, clientBuffer).data(), clientBuffer, ourNext);
            ourNext += clientBuffer;
            ClockSnapshot s = clock.snapshot();
            writeAt = double(s.zeroHost) + (double(ourNext) - s.zeroSample) * s.ticksPerFrame + jitter(rng);
        } else {
            bool warm = readAt > double(t0) + warmup * ticks;
            if (!jumped && jumpAt > 0 && readAt > double(t0) + jumpAt * ticks) {
                jumped = true;
                targetZeroHost += targetSample * targetTpf;
                targetSample = 13688;
                targetZeroHost -= targetSample * targetTpf;
                last = -1;
            }
            TargetCycle c;
            c.sampleTime = targetSample;
            c.hostTime = uint64_t(targetZeroHost + targetSample * targetTpf);
            c.hostValid = true;
            c.rateScalar = targetTpf / nominal;
            c.rateValid = rateScalarValid;
            c.frames = targetBuffer;
            uint64_t under = p.counters.underruns, over = p.counters.overruns;
            reader.render(c, stereo.data());
            if (!warm) {
                p.counters.underruns = under;
                p.counters.overruns = over;
            }
            bool silent = true;
            for (uint32_t i = 0; i < targetBuffer; ++i) {
                float v = stereo[2 * i];
                if (v == 0.0f && stereo[2 * i + 1] == 0.0f) continue;
                silent = false;
                int64_t now = int64_t(v);
                if (warm && last >= 0 && now != last % 65535 + 1) ++res.breaks;
                last = now;
            }
            if (warm && silent) ++res.silentCycles;
            if (warm) res.worstPhase = std::max(res.worstPhase, std::llabs(p.counters.phaseError.load()));
            targetSample += targetBuffer;
            readAt = targetZeroHost + targetSample * targetTpf - (safety + targetBuffer) * targetTpf + jitter(rng);
        }
    }
    res.underruns = p.counters.underruns;
    res.overruns = p.counters.overruns;
    res.resyncs = p.counters.resyncs;
    res.correctionPpm = clock.correctionPpm();
    res.rateRatio = clock.rateRatio();
    return res;
}

TEST(pipeline_holds_two_hours_against_a_fast_target_with_feed_forward) {
    SimResult r = simulate(2 * 3600, 300, true, -1, 1);
    std::printf("  2 h, +300 ppm, rate scalar: underruns %llu overruns %llu breaks %llu silent %llu "
                "worst phase %lld frames, correction %+.2f ppm, rate ratio %.6f\n",
                r.underruns, r.overruns, r.breaks, r.silentCycles, r.worstPhase, r.correctionPpm, r.rateRatio);
    CHECK(r.underruns == 0 && r.overruns == 0 && r.breaks == 0 && r.silentCycles == 0);
    CHECK(r.resyncs == 0);
    CHECK(r.worstPhase <= 16);
    CHECK_NEAR(r.rateRatio, 1.0 / 1.0003, 1e-6);
    CHECK(std::fabs(r.correctionPpm) < 5);
}

TEST(pipeline_locks_on_by_feedback_alone_when_the_rate_scalar_is_invalid) {
    SimResult r = simulate(2 * 3600, -250, false, -1, 120);
    std::printf("  2 h, -250 ppm, no rate scalar: underruns %llu overruns %llu breaks %llu silent %llu "
                "worst phase %lld frames, correction %+.2f ppm\n",
                r.underruns, r.overruns, r.breaks, r.silentCycles, r.worstPhase, r.correctionPpm);
    CHECK(r.underruns == 0 && r.overruns == 0 && r.breaks == 0 && r.silentCycles == 0);
    CHECK(r.resyncs == 0);
    CHECK(r.worstPhase <= 64);
    CHECK_NEAR(r.correctionPpm, 250, 10);
}

TEST(pipeline_reanchors_after_the_target_timeline_resets) {
    SimResult r = simulate(600, 100, true, 300, 1);
    std::printf("  10 min, target sample time reset at 5 min: resyncs %llu breaks %llu underruns %llu\n", r.resyncs,
                r.breaks, r.underruns);
    CHECK(r.resyncs == 1);
    CHECK(r.breaks <= 1);
    CHECK(r.underruns == 0 && r.overruns == 0);
}

TEST(pipeline_plays_to_the_last_frame_then_stays_silent_until_clients_return) {
    Pipeline p;
    const double tpf = 1e9 / 48000;
    VirtualClock clock(tpf);
    clock.anchor(0);
    p.clock.publish(clock.snapshot());
    Reader reader(p, 1000);
    p.firstClientStarted();
    for (int64_t t = 0; t < 4096; t += 512) p.write(ramp(t, 512).data(), 512, t);
    std::vector<float> out(2 * 512);
    TargetCycle c;
    c.hostValid = true;
    c.frames = 512;
    c.hostTime = uint64_t(tpf * 4096);
    reader.render(c, out.data());
    CHECK(std::fabs(out[0] - rampValue(4096 - 1000)) <= 1);
    p.lastClientStopped();
    uint64_t underruns = p.counters.underruns;
    for (int i = 1; i < 6; ++i) {
        c.sampleTime += 512;
        c.hostTime += uint64_t(512 * tpf);
        reader.render(c, out.data());
    }
    CHECK(p.counters.underruns == underruns);
    CHECK(out[0] == 0.0f && out[2 * 511] == 0.0f);
    clock.anchor(uint64_t(tpf * 10000));
    p.clock.publish(clock.snapshot());
    p.firstClientStarted();
    for (int64_t t = 0; t < 4096; t += 512) p.write(ramp(t, 512).data(), 512, t);
    c.sampleTime += 512;
    c.hostTime = uint64_t(tpf * (10000 + 4096));
    reader.render(c, out.data());
    CHECK(std::fabs(out[0] - rampValue(4096 - 1000)) <= 1);
}

// MARK: Settings record

static eqc_settings sampleSettings() {
    eqc_settings s{};
    s.bandCount = 3;
    s.bands[0] = {EQC_PEAK, 1000, 6, 1.41, true};
    s.bands[1] = {EQC_LOW_SHELF, 80, 4, 0.7, true};
    s.bands[2] = {EQC_HIGH_PASS, 20, 0, 0.5, false};
    s.preampDB = -6;
    s.limiterEnabled = true;
    s.limiterCeilingDB = -1;
    s.compressor = EQC_COMPRESSOR_GENTLE;
    s.colour = EQC_COLOUR_TUBE;
    s.colourAmount = 0.4;
    return s;
}

static std::vector<uint8_t> record(const eqc_settings &s, const char *uid, uint64_t serial) {
    eqc_blob blob;
    if (!eqc_blob_encode(&blob, &s, uid, serial)) return {};
    auto *raw = reinterpret_cast<const uint8_t *>(&blob);
    return std::vector<uint8_t>(raw, raw + sizeof(blob));
}

static eqc_blob_status decode(const std::vector<uint8_t> &bytes, eqc_settings *s = nullptr) {
    eqc_settings scratch;
    char uid[EQC_BLOB_UID_CAPACITY];
    uint64_t serial;
    return eqc_blob_decode(bytes.data(), bytes.size(), s ? s : &scratch, uid, &serial);
}

template <typename T>
static void poke(std::vector<uint8_t> &bytes, size_t offset, T value) {
    std::memcpy(bytes.data() + offset, &value, sizeof(T));
}

// Everything a decoded record may hold: what EQCore then designs filters from is never NaN, never
// infinite and never absurd.
static bool sane(const eqc_settings &s) {
    auto in = [](double x, double lo, double hi) { return std::isfinite(x) && x >= lo && x <= hi; };
    if (s.bandCount < 0 || s.bandCount > EQC_MAX_BANDS) return false;
    for (int i = 0; i < s.bandCount; ++i) {
        const eqc_band &b = s.bands[i];
        if (b.type < EQC_PEAK || b.type > EQC_BAND_PASS || !in(b.frequency, 1, 1e5) || !in(b.gainDB, -60, 60) ||
            !in(b.q, 0.01, 100))
            return false;
    }
    return in(s.preampDB, -60, 24) && in(s.outputGainDB, -60, 24) && in(s.limiterCeilingDB, -60, 0) &&
           in(s.colourAmount, 0, 1) && s.compressor >= EQC_COMPRESSOR_OFF && s.compressor <= EQC_COMPRESSOR_NIGHT &&
           s.colour >= EQC_COLOUR_OFF && s.colour <= EQC_COLOUR_TUBE && in(s.soloLow, 0, 1e5) && in(s.soloHigh, 0, 1e5);
}

TEST(settings_record_round_trips) {
    eqc_settings in = sampleSettings();
    std::vector<uint8_t> bytes = record(in, "BE-RCA:output", 42);
    CHECK(bytes.size() == sizeof(eqc_blob));
    eqc_settings out;
    char uid[EQC_BLOB_UID_CAPACITY];
    uint64_t serial = 0;
    CHECK(eqc_blob_decode(bytes.data(), bytes.size(), &out, uid, &serial) == EQC_BLOB_OK);
    CHECK(std::string(uid) == "BE-RCA:output" && serial == 42);
    CHECK(out.bandCount == 3 && out.bands[1].type == EQC_LOW_SHELF && out.bands[1].frequency == 80 &&
          out.bands[1].gainDB == 4 && out.bands[1].q == 0.7 && out.bands[1].enabled && !out.bands[2].enabled);
    CHECK(out.preampDB == -6 && out.limiterEnabled && out.limiterCeilingDB == -1 &&
          out.compressor == EQC_COMPRESSOR_GENTLE && out.colour == EQC_COLOUR_TUBE && out.colourAmount == 0.4 &&
          !out.solo && !out.bypassed);
    CHECK(record(out, uid, serial) == bytes);
    CHECK(!eqc_blob_encode(reinterpret_cast<eqc_blob *>(bytes.data()), &in, "", 1));
    CHECK(!eqc_blob_encode(reinterpret_cast<eqc_blob *>(bytes.data()), &in, std::string(256, 'x').c_str(), 1));
}

TEST(settings_record_refuses_wrong_sizes_magic_and_version) {
    std::vector<uint8_t> good = record(sampleSettings(), "uid", 1);
    for (size_t n : {size_t(0), size_t(1), size_t(4), sizeof(eqc_blob) / 2, sizeof(eqc_blob) - 1}) {
        std::vector<uint8_t> cut(good.begin(), good.begin() + long(n));
        CHECK(decode(cut) == EQC_BLOB_BAD_SIZE);
    }
    std::vector<uint8_t> longer = good;
    longer.push_back(0);
    CHECK(decode(longer) == EQC_BLOB_BAD_SIZE);
    std::vector<uint8_t> b = good;
    poke<uint32_t>(b, offsetof(eqc_blob, magic), 0x12345678);
    CHECK(decode(b) == EQC_BLOB_BAD_MAGIC);
    b = good;
    poke<uint16_t>(b, offsetof(eqc_blob, version), EQC_BLOB_VERSION + 1);
    CHECK(decode(b) == EQC_BLOB_BAD_VERSION);
    b = good;
    poke<uint32_t>(b, offsetof(eqc_blob, size), sizeof(eqc_blob) + 8);
    CHECK(decode(b) == EQC_BLOB_BAD_SIZE);
}

TEST(settings_record_refuses_a_bad_uid) {
    std::vector<uint8_t> good = record(sampleSettings(), "uid", 1);
    size_t at = offsetof(eqc_blob, targetUID);
    std::vector<uint8_t> b = good;
    b[at] = 0;
    CHECK(decode(b) == EQC_BLOB_BAD_UID);
    b = good;
    std::fill(b.begin() + long(at), b.begin() + long(at + EQC_BLOB_UID_CAPACITY), uint8_t('a'));
    CHECK(decode(b) == EQC_BLOB_BAD_UID);
    b = good;
    b[at + 1] = '\n';
    CHECK(decode(b) == EQC_BLOB_BAD_UID);
    b = good;
    b[at + 10] = 'x';
    CHECK(decode(b) == EQC_BLOB_BAD_UID);
}

TEST(settings_record_refuses_non_finite_and_out_of_range_values) {
    std::vector<uint8_t> good = record(sampleSettings(), "uid", 1);
    size_t doubles[] = {offsetof(eqc_blob, preampDB), offsetof(eqc_blob, outputGainDB), offsetof(eqc_blob, limiterCeilingDB),
                        offsetof(eqc_blob, colourAmount), offsetof(eqc_blob, soloLow), offsetof(eqc_blob, soloHigh),
                        offsetof(eqc_blob, bands) + offsetof(eqc_blob_band, frequency),
                        offsetof(eqc_blob, bands) + offsetof(eqc_blob_band, gainDB),
                        offsetof(eqc_blob, bands) + offsetof(eqc_blob_band, q),
                        offsetof(eqc_blob, bands) + 63 * sizeof(eqc_blob_band) + offsetof(eqc_blob_band, q)};
    for (size_t at : doubles)
        for (double bad : {double(NAN), double(INFINITY), -double(INFINITY)}) {
            std::vector<uint8_t> b = good;
            poke<double>(b, at, bad);
            CHECK(decode(b) == EQC_BLOB_NOT_FINITE);
        }

    struct Case { size_t at; double value; };
    size_t band = offsetof(eqc_blob, bands);
    for (Case c : {Case{offsetof(eqc_blob, preampDB), 25}, Case{offsetof(eqc_blob, preampDB), -61},
                   Case{offsetof(eqc_blob, outputGainDB), 30}, Case{offsetof(eqc_blob, limiterCeilingDB), 0.5},
                   Case{offsetof(eqc_blob, colourAmount), 1.01}, Case{offsetof(eqc_blob, colourAmount), -0.1},
                   Case{offsetof(eqc_blob, soloHigh), 2e5}, Case{band + offsetof(eqc_blob_band, frequency), 0.5},
                   Case{band + offsetof(eqc_blob_band, frequency), 2e5}, Case{band + offsetof(eqc_blob_band, gainDB), 61},
                   Case{band + offsetof(eqc_blob_band, q), 0.001}, Case{band + offsetof(eqc_blob_band, q), 101}}) {
        std::vector<uint8_t> b = good;
        poke<double>(b, c.at, c.value);
        CHECK(decode(b) == EQC_BLOB_OUT_OF_RANGE);
    }
    struct Flag { size_t at; uint32_t value; };
    for (Flag f : {Flag{offsetof(eqc_blob, bandCount), EQC_MAX_BANDS + 1}, Flag{offsetof(eqc_blob, limiterEnabled), 2},
                   Flag{offsetof(eqc_blob, bypassed), 7}, Flag{offsetof(eqc_blob, solo), 2},
                   Flag{offsetof(eqc_blob, compressor), 3}, Flag{offsetof(eqc_blob, colour), 3},
                   Flag{offsetof(eqc_blob, reserved2), 1}, Flag{band + offsetof(eqc_blob_band, type), 7},
                   Flag{band + offsetof(eqc_blob_band, enabled), 2},
                   Flag{band + 10 * sizeof(eqc_blob_band) + offsetof(eqc_blob_band, type), 1}}) {
        std::vector<uint8_t> b = good;
        poke<uint32_t>(b, f.at, f.value);
        CHECK(decode(b) == EQC_BLOB_OUT_OF_RANGE);
    }
    std::vector<uint8_t> b = good;
    poke<uint16_t>(b, offsetof(eqc_blob, reserved), 1);
    CHECK(decode(b) == EQC_BLOB_OUT_OF_RANGE);
}

// Random bytes and random corruption of a good record: the decoder never reads out of bounds
// (address sanitizer) and whatever it accepts is sane.
TEST(settings_record_survives_fuzzing) {
    std::mt19937_64 rng(7);
    std::vector<uint8_t> good = record(sampleSettings(), "BE-RCA", 3);
    int accepted = 0, rejected = 0;
    for (int i = 0; i < 200000; ++i) {
        std::vector<uint8_t> b;
        switch (i % 4) {
        case 0:
            b.resize(rng() % 2 ? sizeof(eqc_blob) : rng() % (2 * sizeof(eqc_blob)));
            for (auto &x : b) x = uint8_t(rng());
            break;
        case 1:
        case 2: {
            b = good;
            int flips = 1 + int(rng() % 4);
            for (int k = 0; k < flips; ++k) b[rng() % b.size()] ^= uint8_t(1u << (rng() % 8));
            break;
        }
        default: {
            b = good;
            size_t at = (rng() % (sizeof(eqc_blob) / 8)) * 8;
            double values[] = {NAN, INFINITY, 1e300, -1e300, 0, -0.0, 1e-320, 5, 1e5, 100};
            poke<double>(b, at, values[rng() % 10]);
            break;
        }
        }
        eqc_settings s;
        if (decode(b, &s) == EQC_BLOB_OK) {
            ++accepted;
            CHECK(sane(s));
        } else {
            ++rejected;
        }
    }
    std::printf("  %d accepted, %d refused\n", accepted, rejected);
    CHECK(accepted > 1000 && rejected > 100000);
}

// MARK: Settings per target

struct MapStorage : SettingsStorage {
    std::map<std::string, std::vector<uint8_t>> values;
    std::vector<uint8_t> read(const std::string &key) override {
        auto it = values.find(key);
        return it == values.end() ? std::vector<uint8_t>{} : it->second;
    }
    void write(const std::string &key, const std::vector<uint8_t> &bytes) override { values[key] = bytes; }
};

struct TestEngine {
    eqc_engine *engine;
    explicit TestEngine(double rate = 48000) {
        engine = static_cast<eqc_engine *>(std::aligned_alloc(16, (eqc_engine_size() + 15) / 16 * 16));
        const double meter[] = {32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000};
        eqc_engine_init(engine, meter, 10);
        eqc_configure(engine, rate, 2);
    }
    ~TestEngine() { std::free(engine); }
    TestEngine(const TestEngine &) = delete;
    TestEngine &operator=(const TestEngine &) = delete;
};

static std::vector<float> noise(uint32_t frames, uint64_t seed) {
    std::mt19937_64 rng(seed);
    std::uniform_real_distribution<float> d(-0.5f, 0.5f);
    std::vector<float> v(size_t(frames) * 2);
    for (auto &x : v) x = d(rng);
    return v;
}

// What the plug-in plays for `stereo` against EQCore called directly with `settings` (nullptr for
// none) on the same channels, `chunk` frames at a time.
static bool playsAs(eqc_engine *engine, const eqc_settings *settings, uint32_t frames, uint32_t chunk, uint64_t seed) {
    // What an earlier curve left in the limiter and the compressor is not what is compared here.
    eqc_reset_render_state(engine);
    std::vector<float> stereo = noise(frames, seed);
    std::vector<float> left(frames), right(frames);
    processStereo(engine, stereo.data(), left.data(), right.data(), frames, true);

    TestEngine reference;
    if (settings) eqc_update(reference.engine, settings, nullptr);
    eqc_set_metering(reference.engine, true);
    std::vector<float> l(frames), r(frames);
    for (uint32_t i = 0; i < frames; ++i) {
        l[i] = stereo[2 * i];
        r[i] = stereo[2 * i + 1];
    }
    for (uint32_t at = 0; at < frames; at += chunk) {
        float *channels[2] = {l.data() + at, r.data() + at};
        eqc_process(reference.engine, channels, 2, int32_t(std::min(chunk, frames - at)));
    }
    return std::memcmp(left.data(), l.data(), frames * sizeof(float)) == 0 &&
           std::memcmp(right.data(), r.data(), frames * sizeof(float)) == 0;
}

TEST(plugin_processing_is_eqcore_to_the_bit) {
    eqc_settings s = sampleSettings();
    for (uint32_t frames : {1u, 512u, 4096u}) {
        TestEngine e;
        eqc_update(e.engine, &s, nullptr);
        CHECK(playsAs(e.engine, &s, frames, frames, frames));
    }
    TestEngine e;
    eqc_update(e.engine, &s, nullptr);
    CHECK(playsAs(e.engine, &s, 8192, EQC_METER_CAPACITY, 9));
    eqc_meter_frame frame;
    const double meter[] = {32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000};
    eqc_meter_frame_read(&frame, e.engine, meter, 10);
    CHECK(frame.bandCount == 10 && frame.peakDB > -20 && frame.outputDB[5] > EQC_METER_FLOOR_DB);
    eqc_meter_frame decoded;
    CHECK(eqc_meter_frame_decode(&frame, sizeof(frame), &decoded) && decoded.peakDB == frame.peakDB);
    CHECK(!eqc_meter_frame_decode(&frame, sizeof(frame) - 1, &decoded));
    eqc_meter_frame_read(&frame, nullptr, meter, 10);
    CHECK(frame.peakDB == EQC_METER_FLOOR_DB && frame.inputDB[9] == EQC_METER_FLOOR_DB);
}

// What every eq before the spectrum does with a meter record: exactly 416 bytes, version 1.
static bool decodesBeforeSpectrum(const void *bytes, size_t size) {
    if (size != 416) return false;
    uint32_t magic;
    uint16_t version;
    std::memcpy(&magic, bytes, 4);
    std::memcpy(&version, static_cast<const uint8_t *>(bytes) + 4, 2);
    return magic == EQC_METER_MAGIC && version == 1;
}

TEST(meter_record_carries_the_spectrum_only_in_version_2) {
    TestEngine e;
    std::vector<float> stereo(2 * 4096), left(4096), right(4096);
    for (uint32_t i = 0; i < 4096; ++i) stereo[2 * i] = stereo[2 * i + 1] = 0.5f * std::sin(2 * M_PI * 1000 * i / 48000);
    const double meter[] = {32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000};
    eqc_meter_frame frame, decoded;

    processStereo(e.engine, stereo.data(), left.data(), right.data(), 4096, true);
    eqc_meter_frame_read(&frame, e.engine, meter, 10);
    CHECK(frame.version == EQC_METER_SPECTRUM_VERSION && frame.spectrumCount == EQC_SPECTRUM_BANDS);
    CHECK(frame.spectrumDB[17] == EQC_METER_FLOOR_DB);

    processStereo(e.engine, stereo.data(), left.data(), right.data(), 4096, true, true);
    processStereo(e.engine, stereo.data(), left.data(), right.data(), 4096, true, true);
    eqc_meter_frame_read(&frame, e.engine, meter, 10);
    CHECK_NEAR(frame.spectrumDB[17], -6, 1.5);
    CHECK(frame.spectrumDB[16] < frame.spectrumDB[17] - 6 && frame.spectrumDB[18] < frame.spectrumDB[17] - 6);
    CHECK(eqc_meter_frame_decode(&frame, sizeof(frame), &decoded) && decoded.spectrumCount == EQC_SPECTRUM_BANDS &&
          decoded.spectrumDB[17] == frame.spectrumDB[17] && decoded.outputDB[5] == frame.outputDB[5]);
    CHECK(!decodesBeforeSpectrum(&frame, sizeof(frame)));

    // `eqMt` from a new plug-in: the old eq reads it as before, the new one as a frame with no spectrum.
    eqc_meter_frame v1 = frame;
    v1.version = EQC_METER_VERSION;
    CHECK(decodesBeforeSpectrum(&v1, EQC_METER_V1_SIZE));
    CHECK(eqc_meter_frame_decode(&v1, EQC_METER_V1_SIZE, &decoded) && decoded.spectrumCount == 0 && decoded.bandCount == 10 &&
          decoded.outputDB[5] == frame.outputDB[5] && decoded.spectrumDB[17] == 0);

    CHECK(!eqc_meter_frame_decode(&v1, sizeof(v1), &decoded));
    CHECK(!eqc_meter_frame_decode(&frame, EQC_METER_V1_SIZE, &decoded));
    eqc_meter_frame odd = frame;
    odd.spectrumCount = 5;
    CHECK(!eqc_meter_frame_decode(&odd, sizeof(odd), &decoded));
    CHECK(!eqc_meter_frame_decode(&frame, sizeof(frame) - 8, &decoded));

    processStereo(e.engine, stereo.data(), left.data(), right.data(), 4096, true, false);
    processStereo(e.engine, stereo.data(), left.data(), right.data(), 4096, true, true);
    eqc_meter_frame_read(&frame, e.engine, meter, 10);
    CHECK(frame.spectrumDB[17] > -8);
}

TEST(each_target_keeps_its_own_curve) {
    MapStorage storage;
    TestEngine e;
    EngineSettings settings(e.engine);
    eqc_settings a = sampleSettings(), b = sampleSettings();
    b.bands[0].gainDB = -9;
    b.compressor = EQC_COMPRESSOR_NIGHT;
    b.solo = true;
    b.soloLow = 300;
    b.soloHigh = 3000;

    CHECK(settings.follow(storage, "speaker"));
    CHECK(!settings.active() && settings.record().empty());
    CHECK(playsAs(e.engine, nullptr, 512, 512, 1));

    CHECK(settings.accept(storage, {a, 1}, "speaker"));
    CHECK(settings.active() && settings.serial() == 1);
    CHECK(playsAs(e.engine, &a, 512, 512, 2));
    CHECK(!settings.accept(storage, {b, 2}, "headphones"));
    CHECK(settings.serial() == 1);

    CHECK(settings.follow(storage, "headphones"));
    CHECK(!settings.follow(storage, "headphones"));
    CHECK(settings.active() && settings.serial() == 2);
    eqc_settings stored = b;
    stored.solo = false;
    CHECK(playsAs(e.engine, &stored, 512, 512, 3));

    CHECK(settings.follow(storage, "hdmi"));
    CHECK(!settings.active());
    CHECK(playsAs(e.engine, nullptr, 512, 512, 4));

    TestEngine reloaded;
    EngineSettings again(reloaded.engine);
    again.follow(storage, "speaker");
    CHECK(again.active() && again.serial() == 1 && again.record() == record(a, "speaker", 1));
    CHECK(playsAs(reloaded.engine, &a, 512, 512, 5));

    CHECK(storage.values.size() == 2);
    storage.values[EngineSettings::key("speaker")][offsetof(eqc_blob, preampDB) + 7] = 0x7f;
    storage.values[EngineSettings::key("hdmi")] = storage.values[EngineSettings::key("headphones")];
    CHECK(!EngineSettings::recall(storage, "speaker"));
    CHECK(!EngineSettings::recall(storage, "hdmi"));
    CHECK(!EngineSettings::recall(storage, ""));
}

// MARK: Who may write the settings

static std::string selfIdentifier() {
    SecCodeRef self = nullptr;
    CFDictionaryRef info = nullptr;
    std::string id;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &self) == errSecSuccess) {
        SecStaticCodeRef code = nullptr;
        if (SecCodeCopyStaticCode(self, kSecCSDefaultFlags, &code) == errSecSuccess) {
            if (SecCodeCopySigningInformation(code, kSecCSDefaultFlags, &info) == errSecSuccess && info) {
                auto v = static_cast<CFStringRef>(CFDictionaryGetValue(info, kSecCodeInfoIdentifier));
                char buffer[256];
                if (v && CFStringGetCString(v, buffer, sizeof(buffer), kCFStringEncodingUTF8)) id = buffer;
                CFRelease(info);
            }
            CFRelease(code);
        }
        CFRelease(self);
    }
    return id;
}

TEST(only_a_process_meeting_the_requirement_may_write) {
    std::string me = selfIdentifier();
    CHECK(!me.empty());
    ClientCheck mine("identifier \"" + me + "\"");
    CHECK(mine.allowed(getpid()));
    CHECK(mine.allowed(getpid()));
    CHECK(!mine.allowed(0) && !mine.allowed(-1) && !mine.allowed(1) && !mine.allowed(99999999));
    CHECK(!ClientCheck("identifier \"com.servitola.eq\"").allowed(getpid()));
    CHECK(!ClientCheck("not a requirement (").allowed(getpid()));

    // Another user's process, as eq is to the helper running as _coreaudiod.
    pid_t other = 0;
    {
        int name[] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
        size_t size = 0;
        sysctl(name, 4, nullptr, &size, nullptr, 0);
        std::vector<kinfo_proc> all(size / sizeof(kinfo_proc) + 16);
        size = all.size() * sizeof(kinfo_proc);
        if (sysctl(name, 4, all.data(), &size, nullptr, 0) == 0)
            for (size_t i = 0; i < size / sizeof(kinfo_proc); ++i)
                if (std::string(all[i].kp_proc.p_comm) == "coreaudiod" && all[i].kp_eproc.e_ucred.cr_uid != getuid())
                    other = all[i].kp_proc.p_pid;
    }
    if (other) {
        CHECK(ClientCheck("identifier \"com.apple.audio.coreaudiod\" and anchor apple").allowed(other));
        CHECK(!ClientCheck("identifier \"com.servitola.eq\" and anchor apple").allowed(other));
    } else {
        std::printf("  no coreaudiod under another user; skipping the cross-user check\n");
    }

    // The real thing: EQ.app's eq, started suspended so it never runs, against the requirement a
    // Developer ID build of the plug-in compiles in.
    const char *eq = "/Applications/EQ.app/Contents/MacOS/eq";
    if (access(eq, X_OK) != 0) {
        std::printf("  no %s; skipping the Developer ID check\n", eq);
        return;
    }
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_START_SUSPENDED);
    pid_t pid = 0;
    char *argv[] = {const_cast<char *>(eq), const_cast<char *>("--version"), nullptr};
    CHECK(posix_spawn(&pid, eq, nullptr, &attr, argv, nullptr) == 0);
    posix_spawnattr_destroy(&attr);
    if (pid <= 0) return;
    CHECK(ClientCheck("identifier \"com.servitola.eq\" and anchor apple generic and certificate leaf[subject.OU] = "
                      "\"NZNV266K59\"")
              .allowed(pid));
    CHECK(!ClientCheck("identifier \"com.servitola.eq\" and anchor apple generic and certificate leaf[subject.OU] = "
                       "\"AAAAAAAAAA\"")
               .allowed(pid));
    kill(pid, SIGKILL);
    int status = 0;
    waitpid(pid, &status, 0);
}

int main() {
    for (auto &t : tests()) {
        int before = failures;
        std::printf("%s\n", t.first);
        t.second();
        if (failures != before) std::printf("  -> failed\n");
    }
    std::printf("\n%zu tests, %d checks, %d failures\n", tests().size(), checks, failures);
    return failures == 0 ? 0 : 1;
}
