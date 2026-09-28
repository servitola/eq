#include "../Source/Core/ChangeRequest.h"
#include "../Source/Core/ChannelMap.h"
#include "../Source/Core/Clock.h"
#include "../Source/Core/DeviceMatch.h"
#include "../Source/Core/FrameRing.h"
#include "../Source/Core/Latency.h"
#include "../Source/Core/Pipeline.h"
#include "../Source/Core/SeqLock.h"
#include "../Source/Core/TargetMachine.h"

#include <cmath>
#include <cstdio>
#include <functional>
#include <random>
#include <string>
#include <thread>
#include <vector>

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
    const float stereo[] = {1, -1, 2, -2, 3, -3};
    std::vector<std::vector<float>> s;

    AudioBufferList *inter = bufferList(s, {2}, 3);
    scatter(stereo, 3, makeChannelMap({2}, 1, 2), inter, 1, 1);
    CHECK(s[0] == (std::vector<float>{1, -1, 2, -2, 3, -3}));
    free(inter);

    AudioBufferList *split = bufferList(s, {1, 1}, 3);
    scatter(stereo, 3, makeChannelMap({1, 1}, 1, 2), split, 0.5f, 1);
    CHECK(s[0] == (std::vector<float>{0.5f, 1, 1.5f}) && s[1] == (std::vector<float>{-1, -2, -3}));
    free(split);

    AudioBufferList *wide = bufferList(s, {8}, 2);
    scatter(stereo, 2, makeChannelMap({8}, 3, 4), wide, 1, 1);
    CHECK(s[0][2] == 1 && s[0][3] == -1 && s[0][8 + 2] == 2 && s[0][8 + 3] == -2 && s[0][0] == 0 && s[0][7] == 0);
    free(wide);

    AudioBufferList *twoStreams = bufferList(s, {2, 6}, 1);
    ChannelMap m = makeChannelMap({2, 6}, 3, 4);
    CHECK(m.left.buffer == 1 && m.left.offset == 0 && m.right.offset == 1);
    scatter(stereo, 1, m, twoStreams, 1, 1);
    CHECK(s[0][0] == 0 && s[1][0] == 1 && s[1][1] == -1);
    free(twoStreams);

    const float lr[] = {1, 3};
    AudioBufferList *mono = bufferList(s, {1}, 1);
    ChannelMap mm = makeChannelMap({1}, 1, 2);
    CHECK(mm.valid && mm.mono);
    scatter(lr, 1, mm, mono, 1, 1);
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
