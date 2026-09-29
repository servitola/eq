// The "app" the M0 tests route: plays a sine or clicks on one named device from its own process and
// prints host-clock stamps. Built into SpikeTone.app (com.servitola.eq.spike.tone) and a nested
// SpikeToneHelper.app (com.servitola.eq.spike.tone.helper), which stands in for a Chrome helper.
//   spiketone --device UID [--freq Hz] [--amp A] [--seconds S] [--mode sine|clicks]
//             [--count N --interval S --lead S] [--engine ioproc|queue --rate Hz] [--delay S]
//             [--spawn-helper-after S --helper-freq Hz --helper-seconds S]
// Prints: "pid <pid> bundle <id>", "ready <host s>" once its HAL client exists, "start <host s>" at
// the first sample handed to the device, "click <host s>" per click. Exits on --seconds, SIGTERM,
// or when its parent dies, so a killed spike never leaves a tone playing.
import AudioToolbox
import CoreAudio
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("spiketone: " + message + "\n").data(using: .utf8)!)
    exit(1)
}
func out(_ line: String) { print(line); fflush(stdout) }
func hostSeconds(_ host: UInt64) -> Double { Double(AudioConvertHostTimeToNanos(host)) / 1e9 }

let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func number(_ name: String, _ fallback: Double) -> Double { option(name).flatMap(Double.init) ?? fallback }

guard let uid = option("--device") else { fail("--device UID is required") }
guard !uid.hasPrefix("com.servitola.eq") else { fail("refusing eq's own device \(uid)") }
let freq = number("--freq", 1000)
let amp = number("--amp", 0.1)
let duration = number("--seconds", 30)
let mode = option("--mode") ?? "sine"
let clicksMode = mode == "clicks"
let engine = option("--engine") ?? "ioproc"
let clickCount = Int(number("--count", 5))
let clickInterval = number("--interval", 1.5)
let lead = number("--lead", 1.5)
let delay = number("--delay", 0)

var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var device = AudioObjectID(0)
var size = UInt32(MemoryLayout<AudioObjectID>.size)
var cfUID = uid as CFString
let lookup = withUnsafeMutablePointer(to: &cfUID) {
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                               UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
}
guard lookup == noErr, device != 0 else { fail("no device with UID \(uid)") }
addr.mSelector = kAudioDevicePropertyNominalSampleRate
var deviceRate = 0.0
size = UInt32(MemoryLayout<Double>.size)
AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &deviceRate)
guard deviceRate > 0 else { fail("device has no rate") }

out("pid \(getpid()) bundle \(Bundle.main.bundleIdentifier ?? "-")")

var helper: Process?
func stopAll() -> Never {
    if let helper, helper.isRunning { kill(helper.processIdentifier, SIGTERM) }
    exit(0)
}
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler { stopAll() }
term.resume()
let int = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
int.setEventHandler { stopAll() }
int.resume()

let stamps = UnsafeMutablePointer<Double>.allocate(capacity: 4096)
var stamped = 0
var startStamp = 0.0

final class Phase: @unchecked Sendable { var sample = 0.0 }
let phase = Phase()

func render(_ samples: UnsafeMutablePointer<Float>, frames: Int, channels: Int, rate: Double, firstSample: Double,
            host: Double) {
    for frame in 0..<frames {
        var value: Float = 0
        if clicksMode {
            let sample = firstSample + Double(frame) - lead * rate
            if sample >= 0 {
                let period = (clickInterval * rate).rounded()
                let click = Int(sample / period)
                let offset = Int(sample - Double(click) * period)
                if click < clickCount, offset < Int(rate / 50) {
                    // cos: the first sample of a burst must be non-zero, it is the one timed.
                    value = Float(amp * cos(2 * Double.pi * freq * Double(offset) / rate))
                    if offset == 0, click == stamped, stamped < 4096 {
                        stamps[stamped] = host + Double(frame) / rate
                        stamped += 1
                    }
                }
            }
        } else {
            value = Float(amp * sin(2 * Double.pi * freq * (firstSample + Double(frame)) / rate))
        }
        for c in 0..<channels { samples[frame * channels + c] = value }
    }
}

if engine == "queue" {
    let rate = number("--rate", 48000)
    var format = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                             mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                             mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                             mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    var queue: AudioQueueRef?
    let status = AudioQueueNewOutputWithDispatchQueue(&queue, &format, 0, DispatchQueue(label: "tone")) { queue, buffer in
        let frames = Int(buffer.pointee.mAudioDataBytesCapacity) / 8
        render(buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self), frames: frames, channels: 2, rate: rate,
               firstSample: phase.sample, host: 0)
        phase.sample += Double(frames)
        buffer.pointee.mAudioDataByteSize = UInt32(frames * 8)
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }
    guard status == noErr, let queue else { fail("AudioQueueNewOutput failed \(status)") }
    var deviceUID = uid as CFString
    let set = AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, &deviceUID, UInt32(MemoryLayout<CFString>.size))
    guard set == noErr else { fail("cannot put the queue on \(uid): \(set)") }
    for _ in 0..<3 {
        var buffer: AudioQueueBufferRef?
        AudioQueueAllocateBuffer(queue, 1024 * 8, &buffer)
        guard let buffer else { fail("buffer allocation failed") }
        let frames = 1024
        render(buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self), frames: frames, channels: 2, rate: rate,
               firstSample: phase.sample, host: 0)
        phase.sample += Double(frames)
        buffer.pointee.mAudioDataByteSize = UInt32(frames * 8)
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }
    out(String(format: "ready %.6f", hostSeconds(mach_absolute_time())))
    if delay > 0 { Thread.sleep(forTimeInterval: delay) }
    guard AudioQueueStart(queue, nil) == noErr else { fail("AudioQueueStart failed") }
    out(String(format: "start %.6f", hostSeconds(mach_absolute_time())))
    out("queue rate \(rate) device rate \(deviceRate)")
} else {
    var procID: AudioDeviceIOProcID?
    AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, _, _, output, outputTime in
        let host = hostSeconds(outputTime.pointee.mHostTime)
        if startStamp == 0 { startStamp = host }
        var frames = 0
        for buffer in UnsafeMutableAudioBufferListPointer(output) {
            guard let data = buffer.mData else { continue }
            let channels = max(Int(buffer.mNumberChannels), 1)
            frames = Int(buffer.mDataByteSize) / 4 / channels
            render(data.assumingMemoryBound(to: Float.self), frames: frames, channels: channels, rate: deviceRate,
                   firstSample: phase.sample, host: host)
        }
        phase.sample += Double(frames)
    }
    guard let procID else { fail("IOProc creation failed") }
    out(String(format: "ready %.6f", hostSeconds(mach_absolute_time())))
    if delay > 0 { Thread.sleep(forTimeInterval: delay) }
    guard AudioDeviceStart(device, procID) == noErr else { fail("cannot start \(uid)") }
}

if let after = option("--spawn-helper-after").flatMap(Double.init) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay + after) {
        let path = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Frameworks/SpikeToneHelper.app/Contents/MacOS/spiketone").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["--device", uid, "--freq", option("--helper-freq") ?? "2000", "--amp", String(amp),
                       "--seconds", option("--helper-seconds") ?? "2"]
        do { try p.run(); helper = p } catch { FileHandle.standardError.write("helper: \(error)\n".data(using: .utf8)!) }
    }
}

let begin = Date()
var printedClicks = 0
let parent = getppid()
Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
    if engine != "queue", startStamp > 0 {
        out(String(format: "start %.6f", startStamp))
        startStamp = -1
    }
    while printedClicks < stamped { out(String(format: "click %.6f", stamps[printedClicks])); printedClicks += 1 }
    if getppid() != parent || Date().timeIntervalSince(begin) > duration + delay { stopAll() }
}
RunLoop.main.run()
