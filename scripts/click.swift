// Plays short clicks on the default output from their own process, so eq's tap captures them,
// and prints the host-clock second at which each click's first sample was handed to the device.
// scripts/measure-latency.sh lines these up against eq's status `lastOnset`.
// Usage: click <count> [interval seconds]
import CoreAudio
import Foundation

let count = Int(CommandLine.arguments.dropFirst().first ?? "") ?? 3
let interval = Double(CommandLine.arguments.dropFirst(2).first ?? "") ?? 2

var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                         mScope: kAudioObjectPropertyScopeGlobal,
                                         mElement: kAudioObjectPropertyElementMain)
var device = AudioObjectID(0)
var size = UInt32(MemoryLayout<AudioObjectID>.size)
guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
    FileHandle.standardError.write("no default output\n".data(using: .utf8)!); exit(1)
}
address.mSelector = kAudioDevicePropertyNominalSampleRate
var rate = 0.0
size = UInt32(MemoryLayout<Double>.size)
AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
guard rate > 0 else { FileHandle.standardError.write("no sample rate\n".data(using: .utf8)!); exit(1) }

// Half a second of exact zeros first: eq counts a sound as an onset only after 100 ms of silence.
let burst = Int(rate / 50)
var firstClick = -1.0
let stamps = UnsafeMutablePointer<Double>.allocate(capacity: count)
var stamped = 0

var procID: AudioDeviceIOProcID?
AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, _, _, output, outputTime in
    let time = outputTime.pointee
    if firstClick < 0 { firstClick = time.mSampleTime + rate / 2 }
    for buffer in UnsafeMutableAudioBufferListPointer(output) {
        guard let data = buffer.mData else { continue }
        let channels = max(Int(buffer.mNumberChannels), 1)
        let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
        let samples = data.assumingMemoryBound(to: Float.self)
        for frame in 0..<frames {
            let sample = time.mSampleTime + Double(frame) - firstClick
            guard sample >= 0 else { continue }
            let period = (interval * rate).rounded()
            let click = Int(sample / period)
            let offset = Int(sample - Double(click) * period)
            guard click < count, offset < burst else { continue }
            // cos, not sin: the first sample of the burst must be non-zero, it is the one eq times.
            let value = Float(0.3 * cos(2 * Double.pi * 1000 * Double(offset) / rate))
            for ch in 0..<channels { samples[frame * channels + ch] = value }
            if offset == 0, click == stamped {
                stamps[click] = Double(AudioConvertHostTimeToNanos(time.mHostTime)) / 1e9 + Double(frame) / rate
                stamped += 1
            }
        }
    }
}
guard let procID, AudioDeviceStart(device, procID) == noErr else {
    FileHandle.standardError.write("cannot start output\n".data(using: .utf8)!); exit(1)
}
var printed = 0
let deadline = Date().addingTimeInterval(1 + Double(count) * interval + 2)
while printed < count, Date() < deadline {
    Thread.sleep(forTimeInterval: 0.05)
    while printed < stamped {
        print(String(format: "click %.6f", stamps[printed]))
        fflush(stdout)
        printed += 1
    }
}
AudioDeviceStop(device, procID)
AudioDeviceDestroyIOProcID(device, procID)
exit(printed == count ? 0 : 1)
