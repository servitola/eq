// The eight M0 tests of docs/superpowers/specs/2026-09-29-eq-app-routing.md, one function each.
import CoreAudio
import Foundation

func mixdown(_ processes: [AudioObjectID], _ mute: CATapMuteBehavior) -> CATapDescription {
    let d = CATapDescription(stereoMixdownOfProcesses: processes)
    d.muteBehavior = mute
    return d
}

func muteName(_ m: CATapMuteBehavior) -> String {
    switch m {
    case .muted: return "muted"
    case .mutedWhenTapped: return "mutedWhenTapped"
    default: return "unmuted"
    }
}

func parseMute(_ s: String?) -> CATapMuteBehavior {
    switch s ?? "muted" {
    case "muted": return .muted
    case "mwt", "mutedWhenTapped": return .mutedWhenTapped
    default: fail("--mute muted|mwt")
    }
}

func observer(on device: Device, freqs: [Double] = [1000]) -> Engine {
    let excluded = processObject(pid: getpid()).map { [$0] } ?? []
    let d = CATapDescription(excludingProcesses: excluded, deviceUID: device.uid, stream: 0)
    d.muteBehavior = .unmuted
    let e = Engine(label: "observer", description: d, target: nil, drift: true, autoStart: false, freqs: freqs,
                   deviceRate: device.rate)
    e.run()
    return e
}

func level(_ x: Float) -> String { x < 0 ? "n/a" : db(Double(x)) }

// MARK: 0. check

func testCheck(_ source: Device) {
    say("== check: can this binary capture? 1 s quiet beep on \(source.name)")
    let tone = Tone(device: source, freq: 1000, amp: 0.03, seconds: 3)
    _ = tone.wait("start")
    let object = waitProcessObject(pid: tone.pid)
    say("  tone pid \(tone.pid), HAL bundle ID '\(bundleID(ofProcessObject: object))'")
    let e = Engine(label: "check", description: mixdown([object], .unmuted), target: nil, drift: true, autoStart: false,
                   freqs: [1000])
    e.run()
    nap(1.5)
    e.stop()
    tone.stop()
    let ok = e.meter.peak > 1e-3
    say("  captured peak \(db(Double(e.meter.peak))), 1 kHz \(level(e.meter.level(0, from: 0, to: .infinity)))")
    say("RESULT check capture=\(ok ? "ok" : "SILENT") peak=\(db(Double(e.meter.peak)))")
    e.destroy()
    if !ok { fail("the tap delivered silence: is System Audio Recording granted to EQ, and is this build signed as com.servitola.eq?") }
}

// MARK: 1. L1 latency and quality

func testL1(source: Device, target: Device, drift: Bool, clicks: Int, sineSeconds: Double) {
    say("== 1. L1 route \(source.name) → \(target.name), sub-tap drift compensation \(drift ? "on" : "off")")
    say("  source: \(source.describe())")
    say("  target: \(target.describe())")

    let interval = 1.5
    let clickTone = Tone(device: source, freq: 1000, amp: 0.2, seconds: 1.5 + Double(clicks) * interval + 4,
                         extra: ["--mode", "clicks", "--count", String(clicks), "--interval", String(interval), "--lead", "1.5"])
    _ = clickTone.wait("start")
    let clickObject = waitProcessObject(pid: clickTone.pid)
    let route = Engine(label: "l1-clicks", description: mixdown([clickObject], .muted), target: target, drift: drift,
                       autoStart: true, freqs: [1000])
    say("  \(route.info())")
    route.run()
    say("  route up \(ms(now() - route.created.tapBegan)) ms after tap creation began (AudioDeviceStart \(ms(route.startResult.seconds)) ms)")
    let deadline = now() + 1.5 + Double(clicks) * interval + 3
    while clickTone.values("click").count < clicks, now() < deadline { nap(0.05) }
    nap(1.2)
    route.stop()
    clickTone.stop()
    var added: [Double] = []
    let onsets = (0..<route.meter.onsetCount).map { route.meter.onsets[$0] }
    say("  per click (ms): tap−click   out−click (= added over the target's own output latency)")
    for click in clickTone.values("click") {
        guard let onset = onsets.first(where: { $0.input > click - 0.05 && $0.input - click < 1.0 }) else {
            say("    click at \(String(format: "%.3f", click)): no onset in the route")
            continue
        }
        say("    \(ms(onset.input - click).padding(toLength: 10, withPad: " ", startingAt: 0))  \(ms(onset.output - click))")
        added.append(onset.output - click)
    }
    let median = added.isEmpty ? nil : added.sorted()[added.count / 2]
    say("  median added \(median.map(ms) ?? "-") ms over \(added.count)/\(clicks) clicks; min \(added.min().map(ms) ?? "-"), max \(added.max().map(ms) ?? "-")")
    route.destroy()

    say("  quality: \(Int(sineSeconds)) s of a 1 kHz sine at −20 dBFS on \(source.name), routed to \(target.name)")
    let sine = Tone(device: source, freq: 1000, amp: 0.1, seconds: sineSeconds + 5)
    _ = sine.wait("start")
    let sineObject = waitProcessObject(pid: sine.pid)
    let q = Engine(label: "l1-sine", description: mixdown([sineObject], .muted), target: target, drift: drift,
                   autoStart: true, freqs: [1000])
    q.run()
    nap(sineSeconds)
    q.stop()
    sine.stop()
    let heard = ask("Was the tone clean on \(target.name) and silent on \(source.name)? c=clean k=crackle/dropouts s=also on \(source.name)", "c/k/s")
    let m = q.meter
    say("  \(m.quality())")
    say("  1 kHz level \(level(m.level(0, from: 0, to: .infinity))), estimated frequency \(String(format: "%.2f", m.estimatedFrequency)) Hz, overloads \(q.overloads.count.get())")
    say("RESULT l1 src=\(source.name) dst=\(target.name) drift=\(drift ? 1 : 0) added_ms=\(median.map(ms) ?? "-") clicks=\(added.count)/\(clicks) glitches=\(m.residualCounts[1]) dropouts=\(m.zeroRuns) gaps=\(m.sampleTimeGaps) overloads=\(q.overloads.count.get()) heard=\(heard)")
    q.destroy()
}

// MARK: 2. Live exclusion edit

func testExcludeLive(device: Device, mute: Bool) {
    say("== 2. live kAudioTapPropertyDescription edit on a main-style device tap on \(device.name) (\(mute ? "mutedWhenTapped, no replay" : "unmuted, capture only"))")
    let a = Tone(device: device, freq: 1000, amp: 0.1, seconds: 16)
    let b = Tone(device: device, freq: 2000, amp: 0.1, seconds: 16)
    _ = a.wait("start"); _ = b.wait("start")
    let objectA = waitProcessObject(pid: a.pid)
    _ = waitProcessObject(pid: b.pid)
    let base = mute ? protectedProcesses() : (processObject(pid: getpid()).map { [$0] } ?? [])
    say("  always excluded: \(base) (\(base.map(bundleID(ofProcessObject:))))")
    let d = CATapDescription(excludingProcesses: base, deviceUID: device.uid, stream: 0)
    d.muteBehavior = mute ? .mutedWhenTapped : .unmuted
    let e = Engine(label: "main", description: d, target: nil, drift: true, autoStart: false, freqs: [1000, 2000],
                   deviceRate: device.rate)
    say("  \(e.info())")
    e.run()
    let t0 = now()
    nap(3)
    d.processes = base + [objectA]
    let exclude = now()
    let s1 = writeDescription(e.tap, d)
    let excludeDone = now()
    say("  t+3 s: exclude 1 kHz tone → status \(s1) in \(ms(excludeDone - exclude)) ms; read back processes \(readDescription(e.tap)?.processes ?? [])")
    nap(3)
    d.processes = base
    let include = now()
    let s2 = writeDescription(e.tap, d)
    let includeDone = now()
    say("  t+6 s: include it again → status \(s2) in \(ms(includeDone - include)) ms; read back processes \(readDescription(e.tap)?.processes ?? [])")
    nap(3)
    e.stop()
    a.stop(); b.stop()
    let heard = mute ? ask("Did the 1 kHz tone play only between ~3 s and ~6 s, and the 2 kHz tone never?") : "-"

    let m = e.meter
    let preA = m.level(0, from: t0 + 0.5, to: exclude - 0.1)
    let preB = m.level(1, from: t0 + 0.5, to: exclude - 0.1)
    let gone = preA > 0 ? m.firstBlock(0, from: exclude - 0.3, below: preA * 0.1) : nil
    let during = m.level(0, from: excludeDone + 0.3, to: include - 0.1)
    let back = preA > 0 ? m.firstBlock(0, from: include - 0.3, above: preA * 0.5) : nil
    let after = m.level(0, from: includeDone + 0.3, to: includeDone + 2.5)
    let bDip = preB > 0 ? m.firstBlock(1, from: t0 + 0.5, below: preB * 0.5) : nil
    say("  1 kHz (edited): before \(level(preA)), excluded \(level(during)), re-included \(level(after))")
    say("  1 kHz left the tap \(gone.map { ms($0 - exclude) + " ms" } ?? "never") after the exclude call; came back \(back.map { ms($0 - include) + " ms" } ?? "never") after the include call (audio timestamps)")
    say("  2 kHz (untouched): \(level(preB)); \(bDip.map { "DIPPED at \(ms($0 - t0)) ms from start" } ?? "no dip below −6 dB")")
    say("  edits at \(String(format: "%.3f", exclude - m.firstInputHost)) s and \(String(format: "%.3f", include - m.firstInputHost)) s on the glitch clock below; expect one glitch at each (the 1 kHz stopping/starting)")
    say("  \(m.quality())")
    say("RESULT exclude-live mute=\(mute ? 1 : 0) status=\(s1)/\(s2) gone_ms=\(gone.map { ms($0 - exclude) } ?? "never") back_ms=\(back.map { ms($0 - include) } ?? "never") excluded_level=\(level(during)) b_dip=\(bDip == nil ? "no" : "YES") glitches=\(m.residualCounts[1]) gaps=\(m.sampleTimeGaps) heard=\(heard)")
    e.destroy()
}

// MARK: 3. bundleIDs taps

func testBundle(device: Device, restore: Bool, pre: Bool) {
    say("== 3. bundleIDs tap [\(toneBundleID)], processRestoreEnabled \(restore), \(pre ? "a tone already running at creation" : "nothing running at creation")")
    var early: Tone?
    var earlyStart = 0.0
    if pre {
        early = Tone(device: device, freq: 1000, amp: 0.08, seconds: 1.5)
        earlyStart = early!.wait("start")
        say("  early tone pid \(early!.pid), HAL bundle '\(bundleID(ofProcessObject: waitProcessObject(pid: early!.pid)))'")
        nap(0.3)
    }
    let d = CATapDescription(stereoMixdownOfProcesses: [])
    d.bundleIDs = [toneBundleID]
    d.isProcessRestoreEnabled = restore
    d.muteBehavior = .muted
    let e = Engine(label: "bundle", description: d, target: nil, drift: true, autoStart: false,
                   freqs: [1000, 2000, 3000])
    e.run()
    let t0 = now()
    if let r = readDescription(e.tap) { say("  after creation: processes \(r.processes), bundleIDs \(r.bundleIDs)") }
    while now() < t0 + 2 { nap(0.05) }

    let late = Tone(device: device, freq: 1000, amp: 0.08, seconds: 5,
                    extra: ["--spawn-helper-after", "2", "--helper-freq", "2000", "--helper-seconds", "2"])
    let lateStart = late.wait("start")
    say("  t+2 s: new tone pid \(late.pid), HAL bundle '\(bundleID(ofProcessObject: waitProcessObject(pid: late.pid)))'")
    nap(2.5)
    let helperLine = late.lines.get().filter { $0.hasPrefix("pid ") }.dropFirst().first ?? "none"
    let helperStart = late.values("start").dropFirst().first
    if let pid = helperLine.split(separator: " ").dropFirst().first.flatMap({ pid_t($0) }) {
        say("  t+4 s: nested helper spawned by the tone: \(helperLine), HAL bundle '\(bundleID(ofProcessObject: waitProcessObject(pid: pid)))'")
    } else {
        say("  t+4 s: nested helper did not report: \(late.lines.get())")
    }
    if let r = readDescription(e.tap) { say("  now: processes \(r.processes), bundleIDs \(r.bundleIDs)") }
    while now() < t0 + 7.5 { nap(0.05) }

    let direct = Tone(device: device, freq: 3000, amp: 0.08, seconds: 1.5, path: nestedHelperPath)
    let directStart = direct.wait("start")
    say("  t+7.5 s: helper bundle started directly by the spike, pid \(direct.pid), HAL bundle '\(bundleID(ofProcessObject: waitProcessObject(pid: direct.pid)))'")
    nap(2)
    e.stop()
    late.stop(); direct.stop(); early?.stop()

    let m = e.meter
    func report(_ name: String, _ k: Int, _ start: Double?, _ length: Double) -> String {
        guard let start else { return "\(name): never started" }
        let caught = m.level(k, from: start + 0.3, to: start + length - 0.2)
        let first = m.firstBlock(k, from: start - 0.05, above: 0.02)
        let yes = caught > 0.02
        say("  \(name): level while playing \(level(caught)) → \(yes ? "CAUGHT" : "not caught")\(yes ? ", first captured \(first.map { ms($0 - start) } ?? "-") ms after its first sample" : "")")
        return yes ? "yes" : "no"
    }
    let r0 = pre ? report("tone running at creation", 0, earlyStart, 1.2) : "-"
    let r1 = report("tone started after the tap", 0, lateStart, 4.5)
    let r2 = report("nested helper (…tone.helper) started by the tone", 1, helperStart, 2)
    let r3 = report("same helper started by the spike", 2, directStart, 1.5)
    say("  \(m.quality())")
    say("RESULT bundle restore=\(restore ? 1 : 0) pre=\(pre ? 1 : 0) running_at_creation=\(r0) started_later=\(r1) helper_by_app=\(r2) helper_standalone=\(r3)")
    e.destroy()
}

// MARK: 4. Route tap and main tap together

func testDual(source: Device, target: Device, routeFirst: Bool) {
    say("== 4. route tap + main tap on \(source.name) in one process, \(routeFirst ? "route" : "main") started first")
    let a = Tone(device: source, freq: 1000, amp: 0.1, seconds: 600)
    let b = Tone(device: source, freq: 2000, amp: 0.1, seconds: 600)
    _ = a.wait("start"); _ = b.wait("start")
    let objectA = waitProcessObject(pid: a.pid)
    _ = waitProcessObject(pid: b.pid)
    let mainDescription = CATapDescription(excludingProcesses: protectedProcesses() + [objectA], deviceUID: source.uid, stream: 0)
    mainDescription.muteBehavior = .mutedWhenTapped
    func makeMain() -> Engine {
        let e = Engine(label: "main", description: mainDescription, target: nil, drift: true, autoStart: false,
                       freqs: [1000, 2000], deviceRate: source.rate)
        e.run()
        return e
    }
    func makeRoute() -> Engine {
        let e = Engine(label: "route", description: mixdown([objectA], .muted), target: target, drift: true,
                       autoStart: true, freqs: [1000, 2000])
        e.run()
        return e
    }
    let first = routeFirst ? makeRoute() : makeMain()
    let second = routeFirst ? makeMain() : makeRoute()
    let (main, route) = routeFirst ? (second, first) : (first, second)
    for e in [first, second] {
        say("  \(e.label): AudioDeviceStart \(e.startResult.status == nil ? "BLOCKED" : "status \(e.startResult.status!)") in \(ms(e.startResult.seconds)) ms")
    }
    let t0 = now()
    nap(6)
    let heard = ask("1 kHz should play on \(target.name) only; \(source.name) silent (the main-style tap mutes it and does not replay). Heard 1 kHz on \(source.name)?")
    main.stop(); route.stop()
    a.stop(); b.stop()
    let mainA = main.meter.level(0, from: t0 + 0.5, to: t0 + 5.5)
    let mainB = main.meter.level(1, from: t0 + 0.5, to: t0 + 5.5)
    let routeA = route.meter.level(0, from: t0 + 0.5, to: t0 + 5.5)
    let routeB = route.meter.level(1, from: t0 + 0.5, to: t0 + 5.5)
    let doubled = mainA > 0.001
    say("  main tap: 1 kHz (routed app) \(level(mainA)), 2 kHz (other app) \(level(mainB)), callbacks \(main.meter.callbacks)")
    say("  route tap: 1 kHz \(level(routeA)), 2 kHz \(level(routeB)), callbacks \(route.meter.callbacks)")
    say("  route \(route.meter.quality())")
    say("RESULT dual first=\(routeFirst ? "route" : "main") start_ms=\(ms(first.startResult.seconds))/\(ms(second.startResult.seconds)) blocked=\(first.startResult.status == nil || second.startResult.status == nil ? "YES" : "no") doubled=\(doubled ? "YES" : "no") main_1k=\(level(mainA)) route_1k=\(level(routeA)) route_2k=\(level(routeB)) heard=\(heard)")
    main.destroy(); route.destroy()
}

// MARK: 5. Start loss/leak

func testStart(source: Device, target: Device, mute: CATapMuteBehavior, tapFirst: Bool) {
    say("== 5. start of a route, \(muteName(mute)), \(tapFirst ? "route running before the app plays" : "app already playing when the route is made")")
    let obs = observer(on: source)
    let tone: Tone
    let object: AudioObjectID
    let route: Engine
    var toneStart: Double
    if tapFirst {
        tone = Tone(device: source, freq: 1000, amp: 0.1, seconds: 600, extra: ["--delay", "1.5"])
        _ = tone.wait("ready")
        object = waitProcessObject(pid: tone.pid)
        route = Engine(label: "start", description: mixdown([object], mute), target: target, drift: true,
                       autoStart: false, freqs: [1000])
        route.run()
        toneStart = tone.wait("start", timeout: 5)
        nap(2)
    } else {
        tone = Tone(device: source, freq: 1000, amp: 0.1, seconds: 600)
        toneStart = tone.wait("start")
        object = waitProcessObject(pid: tone.pid)
        nap(1)
        route = Engine(label: "start", description: mixdown([object], mute), target: target, drift: true,
                       autoStart: true, freqs: [1000])
        route.run()
        nap(2)
    }
    let end = now()
    let heard = ask("Did you hear the 1 kHz tone on \(source.name) at any moment (a blip when the route started)?")
    route.stop()
    nap(0.3)
    obs.stop()
    tone.stop()

    let c = route.created
    let origin = tapFirst ? toneStart : c.tapBegan
    let rel: (Double) -> String = { ms($0 - origin) }
    say("  timeline (ms from \(tapFirst ? "the tone's first sample" : "tap creation")): tap made +\(rel(c.tapDone)), aggregate +\(rel(c.aggregateDone)), start called +\(rel(route.runBegan)), start returned +\(rel(route.runBegan + route.startResult.seconds))")
    say("  route: first callback +\(route.meter.callbacks > 0 ? rel(route.meter.firstCallbackHost) : "-"), first captured sound (audio time) +\(route.meter.firstSignal.map { rel($0.input) } ?? "-"), it arrived at +\(route.meter.firstSignal.map { rel($0.callback) } ?? "-")")
    let window = route.meter.firstSignal.map { $0.input - origin }
    let meaning = mute == .muted ? "lost (muted, nowhere)" : "leaked to \(source.name) (heard un-routed)"
    let preLevel = obs.meter.level(0, from: tapFirst ? toneStart + 0.2 : toneStart + 0.3, to: tapFirst ? toneStart + 1 : c.tapBegan - 0.05)
    let steady = obs.meter.level(0, from: route.runBegan + 1, to: end - 0.1)
    let calibrated = !tapFirst && preLevel > 0.01 && steady >= 0 && steady < preLevel * 0.05
    if tapFirst {
        let leak = obs.meter.maxLevel(0, from: toneStart - 0.05, to: toneStart + 0.5)
        say("  observer tap on \(source.name): max 1 kHz in the tone's first 500 ms \(level(leak)), steady \(level(steady)) (the observer may see muted audio too; see RESULT of the tone-first runs)")
    } else {
        let left = obs.meter.firstBlock(0, from: c.tapBegan - 0.3, below: preLevel * 0.1)
        say("  observer tap on \(source.name): before \(level(preLevel)), steady with the route \(level(steady)) → \(calibrated ? "calibrated: the tone left \(source.name) at +\(left.map(rel) ?? "-") ms" : "NOT calibrated (it still hears muted audio); rely on ears")")
    }
    say("  window between \(tapFirst ? "the tone's first sample" : "tap creation") and the first captured sample: \(window.map(ms) ?? "-") ms, \(meaning)")
    say("RESULT start mute=\(muteName(mute)) order=\(tapFirst ? "tap-first" : "tone-first") window_ms=\(window.map(ms) ?? "-") observer=\(tapFirst ? "-" : (calibrated ? "calibrated" : "uncalibrated")) heard=\(heard)")
    route.destroy(); obs.destroy()
}

// MARK: 6. kill -9 of the owner

func hold(pid: pid_t, source: Device, target: Device, mute: CATapMuteBehavior, isPublic: Bool) -> Never {
    let object = waitProcessObject(pid: pid)
    let e = Engine(label: "hold", description: mixdown([object], mute), target: target, drift: true, autoStart: true,
                   freqs: [1000], isPrivate: !isPublic)
    e.run()
    say("ready \(getpid())")
    while true { nap(1) }
}

func testKill(source: Device, target: Device, mute: CATapMuteBehavior, isPublic: Bool) {
    say("== 6. kill -9 of a route's owner: \(muteName(mute)), \(isPublic ? "public" : "private") tap and aggregate")
    let obs = observer(on: source)
    let tone = Tone(device: source, freq: 1000, amp: 0.1, seconds: 600)
    _ = tone.wait("start")
    nap(2)
    let phase0 = (now() - 1.7, now())
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    child.arguments = ["hold", "--pid", String(tone.pid), "--source", source.uid, "--target", target.uid,
                       "--mute", mute == .muted ? "muted" : "mwt"] + (isPublic ? ["--public"] : [])
    let pipe = Pipe()
    child.standardOutput = pipe
    try? child.run()
    registry.add(child: child)
    let ready = LockedBox(false)
    pipe.fileHandleForReading.readabilityHandler = { h in
        if String(decoding: h.availableData, as: UTF8.self).contains("ready") { ready.set(true) }
    }
    let deadline = now() + 5
    while !ready.get(), now() < deadline { nap(0.02) }
    guard ready.get() else { fail("the owner child never became ready") }
    nap(3)
    let phase1 = (now() - 2.5, now())
    let a1 = ask("Tone on \(target.name) and NOT on \(source.name)?")
    let whileHeld = listLeftovers()
    kill(child.processIdentifier, SIGKILL)
    child.waitUntilExit()
    let killed = now()
    nap(3)
    let phase2 = (killed + 0.5, now())
    let a2 = ask("After the kill: do you hear the 1 kHz tone on \(source.name) again?")
    let left = listLeftovers()
    say("  visible to the parent while held: aggregates \(whileHeld.aggregates), taps \(whileHeld.taps)")
    say("  left after kill -9: aggregates \(left.aggregates), taps \(left.taps)")
    var phase3: (Double, Double)?
    var a3 = "-"
    if !left.aggregates.isEmpty || !left.taps.isEmpty {
        destroyLeftovers(verbose: true)
        let destroyed = now()
        nap(2)
        phase3 = (destroyed + 0.3, now())
        a3 = ask("After destroying the leftovers: tone on \(source.name)?")
    }
    obs.stop()
    tone.stop()
    let m = obs.meter
    let l0 = m.level(0, from: phase0.0, to: phase0.1)
    let l1 = m.level(0, from: phase1.0, to: phase1.1)
    let l2 = m.level(0, from: phase2.0, to: phase2.1)
    let l3 = phase3.map { m.level(0, from: $0.0, to: $0.1) }
    let calibrated = l0 > 0.01 && l1 >= 0 && l1 < l0 * 0.05
    say("  observer on \(source.name): before \(level(l0)), held \(level(l1)), after kill \(level(l2))\(l3.map { ", after destroy \(level($0))" } ?? "") → \(calibrated ? "calibrated" : "NOT calibrated: it hears muted audio, so only the answers count")")
    let back = calibrated ? (l2 > l0 * 0.5 ? "yes" : "NO") : "?"
    say("RESULT kill mute=\(muteName(mute)) public=\(isPublic ? 1 : 0) audible_after_kill=\(back) leftovers=\(left.aggregates.count)+\(left.taps.count) observer=\(calibrated ? "calibrated" : "uncalibrated") heard_held=\(a1) heard_after=\(a2) heard_after_destroy=\(a3)")
    obs.destroy()
}

// MARK: 7. Tap format across rates

func testFormat(device: Device, target: Device, processRate: Double?) {
    let rate = processRate ?? (device.rate == 48000 ? 44100 : 48000)
    say("== 7. tap format: a process rendering at \(Int(rate)) Hz to \(device.name) at \(Int(device.rate)) Hz")
    let tone = Tone(device: device, freq: 1000, amp: 0.05, seconds: 12, extra: ["--engine", "queue", "--rate", String(rate)])
    _ = tone.wait("start")
    let object = waitProcessObject(pid: tone.pid)
    nap(0.3)
    say("  tone: \(tone.lines.get().filter { $0.hasPrefix("queue") }.first ?? "?")")
    func probe(_ label: String, _ d: CATapDescription, main: Device?) -> String {
        d.muteBehavior = .unmuted
        let e = Engine(label: label, description: d, target: main, drift: true, autoStart: false, freqs: [1000], play: false)
        let afterAggregate = tapFormat(e.tap)
        e.run()
        nap(2)
        e.stop()
        let m = e.meter
        say("  \(label): at creation \(describe(e.formatAtCreation)); in the aggregate \(describe(afterAggregate)); aggregate input stream \(describe(inputStreamFormat(e.aggregate)))")
        say("    \(describeAggregate(e.aggregate)); delivered \(String(format: "%.1f", m.measuredRate)) frames/s, tone measured at \(String(format: "%.2f", m.estimatedFrequency)) Hz (1000 if the format is honest), level \(level(m.level(0, from: 0, to: .infinity)))")
        let summary = "\(Int(e.formatAtCreation?.mSampleRate ?? 0))/\(Int(afterAggregate?.mSampleRate ?? 0))/\(Int(m.measuredRate.rounded()))"
        e.destroy()
        return summary
    }
    let a = probe("mixdown, tap-only aggregate", CATapDescription(stereoMixdownOfProcesses: [object]), main: nil)
    let b = probe("mixdown, L1 aggregate on \(target.name)", CATapDescription(stereoMixdownOfProcesses: [object]), main: target)
    let c = probe("device-stream tap, tap-only aggregate", CATapDescription(processes: [object], deviceUID: device.uid, stream: 0), main: nil)
    tone.stop()
    say("RESULT format device=\(device.name)@\(Int(device.rate)) process=\(Int(rate)) mixdown=\(a) mixdown_l1=\(b) device_stream=\(c) (creation/aggregate/delivered Hz)")
}

// MARK: 8. Apple Music

func testMusic() {
    say("== 8. Apple Music through a tap")
    func musicProcesses() -> [AudioProcess] { audioProcesses().filter { $0.bundleID.hasPrefix("com.apple.Music") } }
    var procs = musicProcesses()
    if !procs.contains(where: \.runningOutput) {
        _ = ask("Start a track in Music now (an Apple Music catalogue track, not your own file), then press Enter", "Enter")
        nap(1)
        procs = musicProcesses()
    }
    for p in audioProcesses() where p.bundleID.localizedCaseInsensitiveContains("music") {
        say("  process \(p.object) pid \(p.pid) '\(p.bundleID)' running output \(p.runningOutput)")
    }
    guard procs.contains(where: \.runningOutput) else {
        say("RESULT music skipped=Music is not playing")
        return
    }
    func measure(_ label: String, _ d: CATapDescription) -> String {
        d.muteBehavior = .unmuted
        let e = Engine(label: label, description: d, target: nil, drift: true, autoStart: false, freqs: [])
        e.run()
        nap(8)
        e.stop()
        let m = e.meter
        say("  \(label): rms \(db(m.rms)), peak \(db(Double(m.peak))), silent 10 ms blocks \(String(format: "%.0f", m.silentBlockFraction * 100)) %, callbacks \(m.callbacks)")
        e.destroy()
        return m.peak > 1e-4 ? "audio(\(db(m.rms)))" : "SILENT"
    }
    let byPID = measure("pid tap on \(procs.map(\.object))", mixdown(procs.map(\.object), .unmuted))
    let byBundle: String
    let d = CATapDescription(stereoMixdownOfProcesses: [])
    d.bundleIDs = ["com.apple.Music"]
    byBundle = measure("bundleIDs tap [com.apple.Music]", d)
    let kind = ask("Was it an Apple Music catalogue (DRM) track? y=catalogue n=own file", "y/n")
    say("RESULT music pid_tap=\(byPID) bundle_tap=\(byBundle) catalogue=\(kind)")
}
