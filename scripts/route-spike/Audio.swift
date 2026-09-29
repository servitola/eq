// HAL helpers, the teardown registry and the route/capture builders shared by every M0 test.
import AudioToolbox
import CoreAudio
import Foundation

// Distinct from eq's "com.servitola.eq.aggregate-": the daemon's stale sweep must not eat a running
// spike, and `routespike cleanup` must never touch eq's own aggregate.
let spikeUIDPrefix = "com.servitola.eq.spike-"
let spikeTapName = "eq-route-spike"
let toneBundleID = "com.servitola.eq.spike.tone"

func say(_ line: String) {
    print(line)
    fflush(stdout)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("error: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

func seconds(_ host: UInt64) -> Double { Double(AudioConvertHostTimeToNanos(host)) / 1e9 }
func now() -> Double { seconds(mach_absolute_time()) }
func ms(_ x: Double) -> String { String(format: "%.1f", x * 1000) }
func db(_ amplitude: Double) -> String { amplitude > 0 ? String(format: "%.1f dBFS", 20 * log10(amplitude)) : "-inf dBFS" }
func nap(_ s: Double) { Thread.sleep(forTimeInterval: s) }

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func prop<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
            _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ initial: T) -> T? {
    var addr = address(selector, scope)
    guard AudioObjectHasProperty(id, &addr) else { return nil }
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    guard AudioObjectHasProperty(id, &addr) else { return nil }
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
    return value?.takeRetainedValue() as String?
}

func ids(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var addr = address(selector, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &list) == noErr else { return [] }
    return list
}

let system = AudioObjectID(kAudioObjectSystemObject)

// MARK: - Devices

struct Device {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32

    var rate: Double { prop(id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 0.0) ?? 0 }
    var outputStreams: Int { ids(id, kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput).count }
    var alive: Bool { (prop(id, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0) == 1 }
    var transportName: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        case kAudioDeviceTransportTypeHDMI: return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: return "displayport"
        default: return String(format: "0x%08x", transport)
        }
    }
    /// eq's own device and aggregates, the spike's aggregates, and the classes the spec refuses.
    var refusal: String? {
        if uid.hasPrefix("com.servitola.eq") { return "belongs to eq (driver device or aggregate)" }
        switch transport {
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return "is an aggregate"
        case kAudioDeviceTransportTypeVirtual: return "is virtual"
        case kAudioDeviceTransportTypeAirPlay: return "is AirPlay"
        default: return nil
        }
    }
    func describe() -> String {
        let latency = prop(id, kAudioDevicePropertyLatency, kAudioDevicePropertyScopeOutput, UInt32(0)) ?? 0
        let safety = prop(id, kAudioDevicePropertySafetyOffset, kAudioDevicePropertyScopeOutput, UInt32(0)) ?? 0
        let buffer = prop(id, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0
        let r = rate
        let totalMs = r > 0 ? Double(latency + safety) / r * 1000 : 0
        return "'\(name)' [\(uid)] \(transportName) \(Int(r)) Hz, out latency \(latency) + safety \(safety) frames (\(String(format: "%.1f", totalMs)) ms), buffer \(buffer)"
    }
}

func device(_ id: AudioObjectID) -> Device? {
    guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
    let transport = prop(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0
    return Device(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? "?", transport: transport)
}

func allDevices() -> [Device] { ids(system, kAudioHardwarePropertyDevices).compactMap(device) }

func defaultOutputUID() -> String? {
    guard let id = prop(system, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, AudioObjectID(0)),
          id != 0 else { return nil }
    return string(id, kAudioDevicePropertyDeviceUID)
}

/// "builtin", an exact UID, or a piece of the name; only real output devices qualify.
func resolveDevice(_ spec: String) -> Device {
    let outputs = allDevices().filter { $0.outputStreams > 0 }
    if let exact = outputs.first(where: { $0.uid == spec }) {
        if let why = exact.refusal { fail("\(exact.name) \(why); the spike never plays on or taps it") }
        return exact
    }
    let usable = outputs.filter { $0.refusal == nil }
    let matches = spec == "builtin"
        ? usable.filter { $0.transport == kAudioDeviceTransportTypeBuiltIn }
        : usable.filter { $0.name.localizedCaseInsensitiveContains(spec) }
    guard matches.count == 1 else {
        fail("device '\(spec)' matches \(matches.count) usable outputs: \(matches.map(\.name)); pass the UID")
    }
    guard matches[0].alive, matches[0].rate > 0 else { fail("\(matches[0].name) is not alive or has no rate") }
    return matches[0]
}

// MARK: - Process objects

func processObject(pid: pid_t) -> AudioObjectID? {
    var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var object = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var value = pid
    let status = AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &value, &size, &object)
    return status == noErr && object != 0 ? object : nil
}

func waitProcessObject(pid: pid_t, timeout: Double = 3) -> AudioObjectID {
    let deadline = now() + timeout
    while now() < deadline {
        if let object = processObject(pid: pid) { return object }
        nap(0.02)
    }
    fail("pid \(pid) never got a Core Audio process object")
}

struct AudioProcess {
    let object: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let runningOutput: Bool
}

func audioProcesses() -> [AudioProcess] {
    ids(system, kAudioHardwarePropertyProcessObjectList).map { object in
        AudioProcess(object: object,
                     pid: prop(object, kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal, pid_t(0)) ?? 0,
                     bundleID: string(object, kAudioProcessPropertyBundleID) ?? "",
                     runningOutput: (prop(object, kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0) != 0)
    }
}

func bundleID(ofProcessObject object: AudioObjectID) -> String { string(object, kAudioProcessPropertyBundleID) ?? "?" }

/// Excluded from every muting device tap: ourselves, and whatever hosts the EQ driver's playback
/// (coreaudiod and the Core Audio driver service), so a muted main-style tap never silences driver mode.
func protectedProcesses() -> [AudioObjectID] {
    var result: [AudioObjectID] = processObject(pid: getpid()).map { [$0] } ?? []
    let coreaudiod = Set(pids(named: "coreaudiod"))
    for p in audioProcesses() where p.bundleID.hasPrefix("com.apple.audio.") || coreaudiod.contains(p.pid) {
        result.append(p.object)
    }
    return result
}

func pids(named name: String) -> [pid_t] {
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-x", name]
    let pipe = Pipe()
    pgrep.standardOutput = pipe
    guard (try? pgrep.run()) != nil else { return [] }
    pgrep.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").compactMap { pid_t($0) }
}

// MARK: - Teardown registry

final class Registry: @unchecked Sendable {
    private let lock = NSLock()
    private var procs: [(AudioObjectID, AudioDeviceIOProcID)] = []
    private var aggregates: [AudioObjectID] = []
    private var taps: [AudioObjectID] = []
    private var children: [Process] = []

    func add(proc: AudioDeviceIOProcID, on device: AudioObjectID) { lock.withLock { procs.append((device, proc)) } }
    func add(aggregate: AudioObjectID) { lock.withLock { aggregates.append(aggregate) } }
    func add(tap: AudioObjectID) { lock.withLock { taps.append(tap) } }
    func add(child: Process) { lock.withLock { children.append(child) } }

    func remove(proc: AudioDeviceIOProcID) { lock.withLock { procs.removeAll { unsafeBitCast($0.1, to: UnsafeRawPointer.self) == unsafeBitCast(proc, to: UnsafeRawPointer.self) } } }
    func remove(aggregate: AudioObjectID) { lock.withLock { aggregates.removeAll { $0 == aggregate } } }
    func remove(tap: AudioObjectID) { lock.withLock { taps.removeAll { $0 == tap } } }

    /// Order matters: IOProcs before their aggregate, the aggregate before the tap it holds.
    func teardown() {
        lock.withLock {
            for (device, proc) in procs {
                AudioDeviceStop(device, proc)
                AudioDeviceDestroyIOProcID(device, proc)
            }
            for id in aggregates { AudioHardwareDestroyAggregateDevice(id) }
            for id in taps { AudioHardwareDestroyProcessTap(id) }
            for child in children where child.isRunning { kill(child.processIdentifier, SIGKILL) }
            procs = []; aggregates = []; taps = []; children = []
        }
    }
}

let registry = Registry()
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []

func installTeardown() {
    atexit { registry.teardown() }
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler {
            FileHandle.standardError.write("\nsignal \(sig): destroying the spike's taps and aggregates\n".data(using: .utf8)!)
            registry.teardown()
            _exit(128 + sig)
        }
        source.resume()
        signalSources.append(source)
    }
}

// MARK: - Taps and aggregates

func makeTap(_ description: CATapDescription) -> AudioObjectID {
    if description.name.isEmpty { description.name = spikeTapName }
    var tap = AudioObjectID(0)
    let status = AudioHardwareCreateProcessTap(description, &tap)
    guard status == noErr, tap != 0 else { fail("tap creation failed (\(status)); System Audio Recording granted to EQ?") }
    registry.add(tap: tap)
    return tap
}

func destroyTap(_ tap: AudioObjectID) {
    AudioHardwareDestroyProcessTap(tap)
    registry.remove(tap: tap)
}

func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
    prop(tap, kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal, AudioStreamBasicDescription())
}

func describe(_ f: AudioStreamBasicDescription?) -> String {
    guard let f else { return "?" }
    let interleaved = f.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 ? "interleaved" : "non-interleaved"
    let kind = f.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "float\(f.mBitsPerChannel)" : "int\(f.mBitsPerChannel)"
    return "\(f.mSampleRate) Hz \(f.mChannelsPerFrame) ch \(kind) \(interleaved)"
}

func readDescription(_ tap: AudioObjectID) -> CATapDescription? {
    var addr = address(kAudioTapPropertyDescription)
    var ref: Unmanaged<CATapDescription>?
    var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
    guard AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &ref) == noErr else { return nil }
    // Unretained on purpose: the header does not say who owns it, and a leak in a spike is harmless.
    return ref?.takeUnretainedValue()
}

func writeDescription(_ tap: AudioObjectID, _ description: CATapDescription) -> OSStatus {
    var addr = address(kAudioTapPropertyDescription)
    var ref = description
    return withUnsafeMutablePointer(to: &ref) {
        AudioObjectSetPropertyData(tap, &addr, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
    }
}

func makeAggregate(label: String, tap: CATapDescription, drift: Bool, main: Device?, autoStart: Bool,
                   isPrivate: Bool = true) -> AudioObjectID {
    var composition: [String: Any] = [
        kAudioAggregateDeviceNameKey: "\(spikeTapName) \(label)",
        kAudioAggregateDeviceUIDKey: "\(spikeUIDPrefix)\(label)-\(UUID().uuidString.prefix(8))",
        kAudioAggregateDeviceIsPrivateKey: isPrivate,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: autoStart,
        kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tap.uuid.uuidString,
                                           kAudioSubTapDriftCompensationKey: drift]],
    ]
    if let main {
        composition[kAudioAggregateDeviceMainSubDeviceKey] = main.uid
        composition[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: main.uid]]
    }
    var aggregate = AudioObjectID(0)
    let status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate)
    guard status == noErr, aggregate != 0 else { fail("aggregate creation failed (\(status))") }
    registry.add(aggregate: aggregate)
    return aggregate
}

func destroyAggregate(_ aggregate: AudioObjectID) {
    AudioHardwareDestroyAggregateDevice(aggregate)
    registry.remove(aggregate: aggregate)
}

func describeAggregate(_ aggregate: AudioObjectID) -> String {
    func frames(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> String {
        prop(aggregate, selector, scope, UInt32(0)).map(String.init) ?? "-"
    }
    let rate = prop(aggregate, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 0.0) ?? 0
    return "aggregate \(Int(rate)) Hz, in latency \(frames(kAudioDevicePropertyLatency, kAudioDevicePropertyScopeInput)) + safety \(frames(kAudioDevicePropertySafetyOffset, kAudioDevicePropertyScopeInput)), out latency \(frames(kAudioDevicePropertyLatency, kAudioDevicePropertyScopeOutput)) + safety \(frames(kAudioDevicePropertySafetyOffset, kAudioDevicePropertyScopeOutput)), buffer \(frames(kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal))"
}

/// Destroys leftovers from this or an earlier spike: aggregates by UID prefix, public taps by name.
/// Private ones are invisible to other processes and cannot be reached from here.
@discardableResult
func destroyLeftovers(verbose: Bool) -> (aggregates: Int, taps: Int) {
    var found = (aggregates: 0, taps: 0)
    for d in allDevices() where d.uid.hasPrefix(spikeUIDPrefix) {
        let status = AudioHardwareDestroyAggregateDevice(d.id)
        if verbose { say("  aggregate \(d.uid): destroy → \(status)") }
        found.aggregates += 1
    }
    for tap in ids(system, kAudioHardwarePropertyTapList) {
        guard let d = readDescription(tap), d.name.hasPrefix(spikeTapName) else { continue }
        let status = AudioHardwareDestroyProcessTap(tap)
        if verbose { say("  tap \(tap) '\(d.name)': destroy → \(status)") }
        found.taps += 1
    }
    return found
}

func listLeftovers() -> (aggregates: [String], taps: [String]) {
    let aggregates = allDevices().filter { $0.uid.hasPrefix(spikeUIDPrefix) }.map(\.uid)
    let taps = ids(system, kAudioHardwarePropertyTapList).compactMap { tap -> String? in
        guard let d = readDescription(tap), d.name.hasPrefix(spikeTapName) else { return nil }
        return "\(tap) '\(d.name)' mute \(d.muteBehavior.rawValue) processes \(d.processes)"
    }
    return (aggregates, taps)
}

// MARK: - IOProcs

/// Starts on a helper thread so a start that blocks (forum thread 848578) is reported, not hung on.
func start(_ device: AudioObjectID, _ proc: AudioDeviceIOProcID, timeout: Double = 4) -> (status: OSStatus?, seconds: Double) {
    let done = DispatchSemaphore(value: 0)
    let result = LockedBox<OSStatus?>(nil)
    let began = now()
    Thread { result.set(AudioDeviceStart(device, proc)); done.signal() }.start()
    if done.wait(timeout: .now() + timeout) == .timedOut { return (nil, now() - began) }
    return (result.get(), now() - began)
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    func set(_ v: T) { lock.withLock { value = v } }
    func mutate(_ body: (inout T) -> Void) { lock.withLock { body(&value) } }
}

final class OverloadCounter: @unchecked Sendable {
    let count = LockedBox(0)
    func listen(_ device: AudioObjectID) {
        var addr = address(kAudioDeviceProcessorOverload)
        AudioObjectAddPropertyListenerBlock(device, &addr, DispatchQueue.global()) { [count] _, _ in
            count.mutate { $0 += 1 }
        }
    }
}

/// A tap in its own aggregate (plus, for a route, the target as main sub-device) read by one IOProc.
/// Route mode copies the tap to the target; capture mode only measures.
final class Engine {
    let label: String
    let description: CATapDescription
    let tap: AudioObjectID
    let aggregate: AudioObjectID
    let meter: Meter
    let target: Device?
    let play: Bool
    let formatAtCreation: AudioStreamBasicDescription?
    let overloads = OverloadCounter()
    var runBegan = 0.0
    var proc: AudioDeviceIOProcID?
    var startResult: (status: OSStatus?, seconds: Double) = (nil, 0)
    var created: (tapBegan: Double, tapDone: Double, aggregateDone: Double) = (0, 0, 0)

    init(label: String, description: CATapDescription, target: Device?, drift: Bool, autoStart: Bool,
         freqs: [Double], isPrivate: Bool = true, deviceRate: Double? = nil, play: Bool = true) {
        self.label = label
        self.description = description
        self.target = target
        self.play = play
        description.isPrivate = isPrivate
        if description.name.isEmpty { description.name = "\(spikeTapName) \(label)" }
        let began = now()
        tap = makeTap(description)
        let tapDone = now()
        formatAtCreation = tapFormat(tap)
        aggregate = makeAggregate(label: label, tap: description, drift: drift, main: target, autoStart: autoStart,
                                  isPrivate: isPrivate)
        created = (began, tapDone, now())
        // Only a tap-only aggregate gets a rate set: with a sub-device it would change the real device.
        if target == nil, let deviceRate, deviceRate > 0,
           prop(aggregate, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 0.0) != deviceRate {
            var addr = address(kAudioDevicePropertyNominalSampleRate)
            var value = deviceRate
            AudioObjectSetPropertyData(aggregate, &addr, 0, nil, UInt32(MemoryLayout<Double>.size), &value)
            for _ in 0..<30 where prop(aggregate, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 0.0) != deviceRate {
                nap(0.01)
            }
        }
        let rate = prop(aggregate, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 0.0) ?? 0
        guard rate > 0 else { fail("\(label): aggregate has no rate") }
        let format = tapFormat(tap)
        meter = Meter(rate: rate, freqs: freqs,
                      nonInterleaved: (format?.mFormatFlags ?? 0) & kAudioFormatFlagIsNonInterleaved != 0)
        overloads.listen(aggregate)
    }

    func info() -> String {
        "\(label): tap \(describe(tapFormat(tap))); \(describeAggregate(aggregate))"
    }

    func run() {
        let meter = self.meter
        let routing = target != nil && play
        let hasOutput = target != nil
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil) { _, input, inputTime, output, outputTime in
            let callbackHost = mach_absolute_time()
            meter.process(input, inputTime.pointee, hasOutput ? outputTime.pointee : nil, callbackHost: callbackHost)
            if routing { meter.write(to: output) } else { Meter.zero(output) }
        }
        guard status == noErr, let procID else { fail("\(label): IOProc creation failed (\(status))") }
        registry.add(proc: procID, on: aggregate)
        proc = procID
        runBegan = now()
        startResult = start(aggregate, procID)
        switch startResult.status {
        case nil: say("  \(label): AudioDeviceStart BLOCKED > \(ms(startResult.seconds)) ms")
        case noErr?: break
        case let s?: fail("\(label): AudioDeviceStart failed (\(s))")
        }
    }

    func stop() {
        guard let proc else { return }
        AudioDeviceStop(aggregate, proc)
        AudioDeviceDestroyIOProcID(aggregate, proc)
        registry.remove(proc: proc)
        self.proc = nil
    }

    func destroy() {
        stop()
        destroyAggregate(aggregate)
        destroyTap(tap)
    }
}

// MARK: - Tone children

let toneAppPath: String = {
    let dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    return dir.appendingPathComponent("SpikeTone.app/Contents/MacOS/spiketone").path
}()
let nestedHelperPath: String = {
    let dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    return dir.appendingPathComponent("SpikeTone.app/Contents/Frameworks/SpikeToneHelper.app/Contents/MacOS/spiketone").path
}()

/// A SpikeTone process (bundle com.servitola.eq.spike.tone), never the spike itself: a bundle-ID tap
/// on com.servitola.eq would also catch the spike and the eq daemon.
final class Tone {
    let process = Process()
    let lines = LockedBox<[String]>([])
    let spawned: Double
    var pid: pid_t { process.processIdentifier }

    init(device: Device, freq: Double = 1000, amp: Double = 0.1, seconds: Double = 30, extra: [String] = [],
         path: String = toneAppPath) {
        guard FileManager.default.isExecutableFile(atPath: path) else { fail("no tone app at \(path); run build.sh") }
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--device", device.uid, "--freq", String(freq), "--amp", String(amp),
                             "--seconds", String(seconds)] + extra
        let pipe = Pipe()
        process.standardOutput = pipe
        let lines = self.lines
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            lines.mutate { $0 += text.split(separator: "\n").map(String.init) }
        }
        spawned = now()
        do { try process.run() } catch { fail("cannot start tone: \(error)") }
        registry.add(child: process)
    }

    /// Host-clock seconds of the first line starting with `prefix` (for "start", "ready"), waiting for it.
    func wait(_ prefix: String, timeout: Double = 4) -> Double {
        let deadline = now() + timeout
        while now() < deadline {
            if let line = lines.get().first(where: { $0.hasPrefix(prefix + " ") }),
               let value = Double(line.split(separator: " ").last ?? "") { return value }
            nap(0.01)
        }
        fail("tone \(pid) never printed '\(prefix)'; its output: \(lines.get())")
    }

    func values(_ prefix: String) -> [Double] {
        lines.get().filter { $0.hasPrefix(prefix + " ") }.compactMap { Double($0.split(separator: " ").last ?? "") }
    }

    func stop() {
        if process.isRunning { kill(pid, SIGTERM) }
        let deadline = now() + 1
        while process.isRunning, now() < deadline { nap(0.01) }
        if process.isRunning { kill(pid, SIGKILL) }
    }
}

// MARK: - Asking the user

nonisolated(unsafe) var askUser = false
nonisolated(unsafe) var askCount = 0

/// On a terminal the question goes to /dev/tty (so the wrapper can tee stdout). Without one (an
/// agent runs the wrapper) it is printed as "ASK <n> …" and the answer is read from the file named by
/// ROUTESPIKE_ANSWERS as a line "<n> <answer>"; the test holds its state, sound included, until then.
func ask(_ question: String, _ choices: String = "y/n") -> String {
    guard askUser else { return "-" }
    askCount += 1
    var answer = "(no terminal and no ROUTESPIKE_ANSWERS)"
    if let tty = fopen("/dev/tty", "r+") {
        defer { fclose(tty) }
        fputs("\u{7}  >>> \(question) [\(choices)] ", tty)
        fflush(tty)
        var buffer = [CChar](repeating: 0, count: 256)
        answer = fgets(&buffer, 256, tty).map { _ in
            String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""
    } else if let path = ProcessInfo.processInfo.environment["ROUTESPIKE_ANSWERS"] {
        say("ASK \(askCount) \(question) [\(choices)]  (reply: echo '\(askCount) <answer>' >> \(path))")
        answer = "(timeout)"
        let deadline = now() + 600
        poll: while now() < deadline {
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n") where line.hasPrefix("\(askCount) ") {
                answer = String(line.dropFirst("\(askCount) ".count)).trimmingCharacters(in: .whitespaces)
                break poll
            }
            nap(0.2)
        }
    }
    say("  ANSWER \(question) → \(answer.isEmpty ? "(none)" : answer)")
    return answer
}

func inputStreamFormat(_ device: AudioObjectID) -> AudioStreamBasicDescription? {
    guard let stream = ids(device, kAudioDevicePropertyStreams, kAudioDevicePropertyScopeInput).last else { return nil }
    return prop(stream, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, AudioStreamBasicDescription())
}
