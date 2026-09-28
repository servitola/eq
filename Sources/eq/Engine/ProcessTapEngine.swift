// Vendored from zollans/OnlyEQ @ 6569655 (Unlicense), trimmed for eq; the split tap/output path is eq's own.
import Foundation
import CoreAudio
import AudioToolbox
import Accelerate
import EQAtomics

/// What the tap delivers, checked once before either IOProc runs so neither has to guess.
enum TapFormat {
    static let maxChannels = 16

    /// The tap's channel count, or nil for a format the ring cannot carry. A device-targeted tap
    /// takes the format of the device stream it taps; the aggregate around it holds nothing else,
    /// so its input channels must add up to exactly the tap's.
    static func channels(tap: AudioStreamBasicDescription, deviceRate: Double, aggregateRate: Double,
                         aggregateInputChannels: [UInt32]) -> Int? {
        let channels = Int(tap.mChannelsPerFrame)
        guard tap.mFormatID == kAudioFormatLinearPCM,
              tap.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              tap.mBitsPerChannel == 32,
              (1...maxChannels).contains(channels),
              deviceRate > 0, tap.mSampleRate == deviceRate, aggregateRate == deviceRate,
              aggregateInputChannels.reduce(0, { $0 + Int($1) }) == channels else { return nil }
        return channels
    }
}

/// One pass through the tap path, in frames at the device's nominal rate.
struct PathLatency: Equatable {
    /// Output device latency plus its safety offset.
    var outputDevice: UInt32
    var outputStream: UInt32
    /// The output IOProc's buffer on the device: it waits a full cycle before the device plays it.
    var outputBuffer: UInt32
    /// The tap aggregate's input side: latency plus safety offset.
    var tapInput: UInt32
    /// Frames the ring holds between the two IOProcs.
    var ringTarget: UInt32

    func milliseconds(sampleRate: Double) -> Double? {
        guard let device = deviceMilliseconds(sampleRate: sampleRate), let added = addedMilliseconds(sampleRate: sampleRate) else { return nil }
        return device + added
    }

    /// What a player sees on the device and compensates for without eq.
    func deviceMilliseconds(sampleRate: Double) -> Double? {
        guard sampleRate > 0 else { return nil }
        return (Double(outputDevice) + Double(outputStream)) / sampleRate * 1000
    }

    /// eq's share before anything is measured: tap hold, ring cushion, output buffer.
    func addedMilliseconds(sampleRate: Double) -> Double? {
        guard sampleRate > 0 else { return nil }
        return (Double(tapInput) + Double(ringTarget) + Double(outputBuffer)) / sampleRate * 1000
    }
}

/// How long eq holds a sample: from the host time the tap stamped it to the host time the output
/// IOProc hands it to the device. The two IOProcs run on different threads but share host time.
struct IODelay: Equatable {
    var hostTicks: UInt64
    var frames: Double

    /// The tap stamped ring position `tapPosition` at `tapHost`; the output sends `outputPosition`
    /// at `outputHost`. Both sides run on the device's clock, so the tap's time for
    /// `outputPosition` is its stamp plus the frames in between.
    static func between(tapPosition: Int64, tapHost: UInt64, outputPosition: Int64, outputHost: UInt64,
                        ticksPerFrame: Double) -> IODelay? {
        guard ticksPerFrame > 0, tapHost > 0, outputHost > 0 else { return nil }
        let tapped = Double(tapHost) + Double(outputPosition - tapPosition) * ticksPerFrame
        let ticks = Double(outputHost) - tapped
        guard ticks.isFinite, ticks > 0 else { return nil }
        return IODelay(hostTicks: UInt64(ticks), frames: ticks / ticksPerFrame)
    }

    func milliseconds(nanos: (UInt64) -> UInt64 = AudioConvertHostTimeToNanos) -> Double {
        Double(nanos(hostTicks)) / 1_000_000
    }

    /// Host time as seconds on the clock every process shares, `frame` samples after `host`.
    static func seconds(host: UInt64, frame: Int, sampleRate: Double,
                        nanos: (UInt64) -> UInt64 = AudioConvertHostTimeToNanos) -> Double {
        Double(nanos(host)) / 1_000_000_000 + (sampleRate > 0 ? Double(frame) / sampleRate : 0)
    }
}

/// System-wide EQ engine built on Core Audio process taps (macOS 14.4+).
///
/// Signal path: a muted tap on the output device's first stream (silences the original output)
/// → a private aggregate holding only that tap → its IOProc writes into a ring → a second IOProc,
/// on the real output device, reads the ring, runs the EQ chain and plays the result. No drivers,
/// no BlackHole.
final class ProcessTapEngine {

    enum State: Equatable {
        case stopped
        case running
        case failed(String)
    }

    let processor = EQProcessor()

    private(set) var state: State = .stopped
    private(set) var targetDeviceID: AudioObjectID = 0
    /// The output IOProc's buffer on the device, as granted.
    private(set) var ioBufferFrames: Int = 128
    private(set) var tapBufferFrames: Int = 128
    var requestedIOBufferFrames: Int = 128

    /// Written on the audio threads, read racily by the status writer; a torn read is harmless.
    private(set) var framesProcessed: UInt64 = 0
    /// Output IOProc cycles.
    private(set) var callbacks: UInt64 = 0
    /// Tap IOProc cycles.
    private(set) var tapCallbacks: UInt64 = 0
    /// Tap cycles that carried a non-zero sample; stops advancing when nothing reaches the tap.
    private(set) var signalCallbacks: UInt64 = 0
    /// Output cycles that found the ring short (silence filled the gap) or overfull (oldest dropped).
    private(set) var underruns: UInt64 = 0
    private(set) var overruns: UInt64 = 0
    /// Buffers dropped whole: a tap buffer the ring cannot take, an output buffer past the scratch.
    /// One counter per thread, so each has a single writer.
    private var tapDropouts: UInt64 = 0
    private var outputDropouts: UInt64 = 0
    var dropouts: UInt64 { tapDropouts &+ outputDropouts }
    private(set) var deviceLatencyMs: Double?
    private var estimatedAddedMs: Double?
    /// Passed to the aggregate for its one sub-tap. With no sub-device beside it there is no other
    /// clock to follow, so it should change nothing; kept for `EQ_DRIFT_COMPENSATION` measurements.
    var driftCompensation = true
    private var ioDelayTicks: UInt64 = 0
    private var ioDelayFrames: Double = 0
    /// The first sample after silence, as the tap stamped it and as eq sends it on: a click played
    /// by another process lines up against these to measure what the whole tap path adds.
    private var onsets: UInt64 = 0
    private var onsetTapHost: UInt64 = 0
    private var onsetOutputHost: UInt64 = 0
    private var onsetOutputFrame = 0

    var addedLatency: IODelay? {
        let ticks = ioDelayTicks
        return ticks == 0 ? nil : IODelay(hostTicks: ticks, frames: ioDelayFrames)
    }

    /// The device's share plus eq's, measured once audio has flowed, estimated before.
    var latencyMs: Double? {
        guard let device = deviceLatencyMs else { return nil }
        guard let added = addedLatency?.milliseconds() ?? estimatedAddedMs else { return nil }
        return device + added
    }

    var lastOnset: Status.Onset? {
        guard onsets > 0 else { return nil }
        let rate = processor.sampleRate
        return Status.Onset(tapHostSeconds: IODelay.seconds(host: onsetTapHost, frame: 0, sampleRate: rate),
                            outputHostSeconds: IODelay.seconds(host: onsetOutputHost, frame: onsetOutputFrame, sampleRate: rate),
                            count: onsets)
    }

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var tapProcID: AudioDeviceIOProcID?
    private var outputProcID: AudioDeviceIOProcID?
    private var sampleRateListener: AudioObjectPropertyListenerBlock?

    // Render state. `ring` and `sharedCells` live as long as the engine, so the IOProcs never
    // take a reference to anything that could go away under them.
    private let ring = AudioRing(channels: 2, minimumCapacity: 8192)
    private var pacer = RingPacer.forBuffers(output: 128, tap: 128)
    private var tapChannels = 2
    private let tapSources = UnsafeMutablePointer<AudioRing.Source>.allocate(capacity: TapFormat.maxChannels)
    private var channelScratch: [UnsafeMutablePointer<Float>] = []
    private var scratchCapacity = 0
    /// `channelScratch` cut to the tap's channel count, built off the audio thread: the array for
    /// the processor, the raw copy for every loop the render thread runs itself.
    private var activeChannels: [UnsafeMutablePointer<Float>] = []
    private let channelPointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: TapFormat.maxChannels)
    // Two sequence-locked (position, host) stamps the tap publishes for the output IOProc:
    // [0...2] the latest tap buffer, [8...10] the latest onset; [4] the tap's latest buffer size.
    private let sharedCells = UnsafeMutablePointer<Int64>.allocate(capacity: 16)
    private static let onsetStamp = 8
    private static let tapFramesCell = 4
    private var handledOnset: Int64 = 0
    private var ticksPerFrame: Double = 0
    private var oneSecondFrames = 48000
    /// Consecutive all-zero frames on each side, saturated at one second's worth.
    private var silentFrames = 0
    private var tapSilentFrames = 0
    private var isSilenceGated = false

    /// Fired (on the main queue) when the tapped device's nominal sample rate
    /// changes while running. Biquad coefficients are baked for one rate, so
    /// the owner must restart the engine to stay on pitch.
    var onSampleRateChange: (() -> Void)?

    init() {
        sharedCells.initialize(repeating: 0, count: 16)
        prepare(channels: 2, tapFrames: ioBufferFrames, outputFrames: ioBufferFrames)
    }

    // MARK: - Lifecycle

    /// Start (or restart) tapping the given output device — pass nil for the
    /// current system default output.
    func start(outputDeviceID explicitDevice: AudioObjectID? = nil) {
        stop()

        guard let deviceID = explicitDevice ?? AudioDeviceManager.defaultOutputDeviceID(),
              let deviceUID = AudioDeviceManager.stringProperty(deviceID, kAudioDevicePropertyDeviceUID) else {
            transition(to: .failed("No output device found."))
            return
        }
        targetDeviceID = deviceID
        let sampleRate = AudioDeviceManager.nominalSampleRate(deviceID)
        processor.configure(sampleRate: sampleRate, channels: tapChannels)
        // The owner sees the 0 Hz rate and retries once the device settles; no tap until then.
        guard sampleRate > 0 else { return }

        // 1. Muted tap on the device's first output stream, excluding ourselves: re-rendered
        //    audio must not be re-captured.
        let excluded = AudioDeviceManager.processObject(forPID: getpid()).map { [$0] } ?? []
        let description = CATapDescription(excludingProcesses: excluded, deviceUID: deviceUID, stream: 0)
        description.name = "eq tap"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true

        var newTapID = AudioObjectID(0)
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr, newTapID != 0 else {
            transition(to: .failed("Couldn’t create audio tap (error \(status))."))
            return
        }
        tapID = newTapID

        // 2. A private aggregate holding the tap and nothing else. An Apple engineer (developer
        //    forums thread 770218): a Bluetooth device in the same aggregate as the tap is
        //    expected to raise the tap's latency. Measured on a Bluetooth speaker: tap plus device
        //    in one aggregate added 280 ms; a device-targeted tap alone, with a second IOProc on
        //    the device, 12.8 ms. No sub-device also means no microphone in any aggregate.
        //    Auto-start stays off: it would hold AudioDeviceStart until something plays, and the
        //    daemon's watchdog needs the callbacks to run through silence.
        let aggregateUID = "\(AudioDeviceManager.aggregateUIDPrefix)\(deviceUID)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "eq",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: driftCompensation,
                ]
            ],
        ]

        var newAggregateID = AudioObjectID(0)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard status == noErr, newAggregateID != 0 else {
            cleanupTap()
            transition(to: .failed("Couldn’t create aggregate device (error \(status))."))
            return
        }
        aggregateID = newAggregateID

        if AudioDeviceManager.nominalSampleRate(aggregateID) != sampleRate {
            _ = AudioDeviceManager.setNominalSampleRate(aggregateID, sampleRate)
            for _ in 0..<30 where AudioDeviceManager.nominalSampleRate(aggregateID) != sampleRate {
                usleep(10_000)
            }
        }
        guard let tapFormat = AudioDeviceManager.tapFormat(tapID),
              let inputChannels = AudioDeviceManager.inputStreamChannelCounts(aggregateID),
              let channels = TapFormat.channels(tap: tapFormat, deviceRate: sampleRate,
                                                aggregateRate: AudioDeviceManager.nominalSampleRate(aggregateID),
                                                aggregateInputChannels: inputChannels) else {
            cleanup()
            transition(to: .failed("Unsupported tap format or rate."))
            return
        }
        processor.configure(sampleRate: sampleRate, channels: channels)

        AudioDeviceManager.requestBufferFrameSize(aggregateID, requestedIOBufferFrames)
        AudioDeviceManager.requestBufferFrameSize(deviceID, requestedIOBufferFrames)
        prepare(channels: channels,
                tapFrames: AudioDeviceManager.bufferFrameSize(aggregateID) ?? requestedIOBufferFrames,
                outputFrames: AudioDeviceManager.bufferFrameSize(deviceID) ?? requestedIOBufferFrames)

        // 3. Two IOProcs. unowned(unsafe): cleanup() destroys both before the engine can go, and
        //    the render threads must not touch reference counts.
        status = AudioDeviceCreateIOProcIDWithBlock(&tapProcID, aggregateID, nil) { [unowned(unsafe) self] _, input, inputTime, _, _ in
            self.renderTap(input: input, inputTime: inputTime.pointee)
        }
        guard status == noErr, tapProcID != nil else {
            cleanup()
            transition(to: .failed("Couldn’t create audio IO proc (error \(status))."))
            return
        }
        status = AudioDeviceCreateIOProcIDWithBlock(&outputProcID, deviceID, nil) { [unowned(unsafe) self] _, _, _, output, outputTime in
            self.renderOutput(output: output, outputTime: outputTime.pointee)
        }
        guard status == noErr, let outputProcID else {
            cleanup()
            transition(to: .failed("Couldn’t create audio IO proc (error \(status))."))
            return
        }
        if !AudioDeviceManager.disableInput(deviceID, for: outputProcID) {
            Log.write("cannot switch the device's input streams off for eq's IO proc; macOS may count it as microphone use")
        }

        // Output first: it plays silence until the tap has filled the ring to its target.
        status = AudioDeviceStart(deviceID, outputProcID)
        if status == noErr { status = AudioDeviceStart(aggregateID, tapProcID) }
        guard status == noErr else {
            cleanup()
            transition(to: .failed("Couldn’t start audio device (error \(status))."))
            return
        }

        let path = PathLatency(
            outputDevice: AudioDeviceManager.latencyFrames(device: deviceID, scope: kAudioDevicePropertyScopeOutput),
            outputStream: AudioDeviceManager.firstOutputStreamLatencyFrames(deviceID),
            outputBuffer: UInt32(ioBufferFrames),
            tapInput: AudioDeviceManager.latencyFrames(device: aggregateID, scope: kAudioDevicePropertyScopeInput),
            ringTarget: UInt32(pacer.target)
        )
        deviceLatencyMs = path.deviceMilliseconds(sampleRate: sampleRate)
        estimatedAddedMs = path.addedMilliseconds(sampleRate: sampleRate)
        Log.write("IO buffer: tap \(tapBufferFrames), output \(ioBufferFrames) frames, ring target \(pacer.target), \(channels) ch")
        Log.write("path latency frames: \(path), drift compensation \(driftCompensation)")
        installSampleRateListener(on: deviceID)
        transition(to: .running)
    }

    func stop() {
        removeSampleRateListener()
        cleanup()
        targetDeviceID = 0
        framesProcessed = 0
        callbacks = 0
        tapCallbacks = 0
        signalCallbacks = 0
        underruns = 0
        overruns = 0
        tapDropouts = 0
        outputDropouts = 0
        deviceLatencyMs = nil
        estimatedAddedMs = nil
        ioDelayTicks = 0
        ioDelayFrames = 0
        onsets = 0
        processor.solo = nil
        if state != .stopped { transition(to: .stopped) }
    }

    deinit {
        stop()
        for pointer in channelScratch { pointer.deallocate() }
        tapSources.deallocate()
        channelPointers.deallocate()
        sharedCells.deallocate()
    }

    /// Sizes every render buffer and clears all render state. Only while neither IOProc runs;
    /// `start` calls it, and tests drive the two render functions through it without Core Audio.
    func prepare(channels: Int, tapFrames: Int, outputFrames: Int) {
        let channels = min(max(channels, 1), TapFormat.maxChannels)
        tapChannels = channels
        tapBufferFrames = tapFrames
        ioBufferFrames = outputFrames
        // Room for both buffers to grow to 4096 frames, the most EQ_IO_FRAMES asks for, without a
        // rebuild: the pacer follows them up to a quarter of the ring, and the tap may write up to half.
        let roomy = RingPacer.cushion(output: max(outputFrames, 4096), tap: max(tapFrames, 4096))
        ring.reset(channels: channels, minimumCapacity: 4 * roomy.ceiling)
        pacer = RingPacer.forBuffers(output: outputFrames, tap: tapFrames, limit: ring.capacity / 4)
        let frames = max(outputFrames, EQProcessor.meterCapacity)
        if channelScratch.count < channels || scratchCapacity < frames {
            for pointer in channelScratch { pointer.deallocate() }
            scratchCapacity = frames
            channelScratch = (0..<max(channels, 2)).map { _ in
                let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
                pointer.initialize(repeating: 0, count: frames)
                return pointer
            }
        }
        activeChannels = Array(channelScratch.prefix(channels))
        for (index, pointer) in activeChannels.enumerated() { channelPointers[index] = pointer }
        let rate = processor.sampleRate
        ticksPerFrame = rate > 0 ? Double(AudioConvertNanosToHostTime(1_000_000_000)) / rate : 0
        oneSecondFrames = max(Int(rate), 1)
        for index in 0..<16 { eq_store_relaxed(sharedCells + index, 0) }
        handledOnset = 0
        silentFrames = 0
        tapSilentFrames = 0
        isSilenceGated = false
    }

    private func cleanup() {
        if let outputProcID, targetDeviceID != 0 {
            AudioDeviceStop(targetDeviceID, outputProcID)
            AudioDeviceDestroyIOProcID(targetDeviceID, outputProcID)
        }
        outputProcID = nil
        if let tapProcID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, tapProcID)
            AudioDeviceDestroyIOProcID(aggregateID, tapProcID)
        }
        tapProcID = nil
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        cleanupTap()
    }

    private func cleanupTap() {
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }

    private func transition(to newState: State) {
        state = newState
        Log.write("engine: \(newState)")
    }

    private static let sampleRateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private func installSampleRateListener(on deviceID: AudioObjectID) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self,
                  AudioDeviceManager.nominalSampleRate(deviceID) != self.processor.sampleRate else { return }
            self.onSampleRateChange?()
        }
        var addr = Self.sampleRateAddress
        if AudioObjectAddPropertyListenerBlock(deviceID, &addr, .main, block) == noErr {
            sampleRateListener = block
            // Close the small gap between the initial rate read and listener
            // installation: a device can renegotiate while the aggregate starts.
            if AudioDeviceManager.nominalSampleRate(deviceID) != processor.sampleRate {
                onSampleRateChange?()
            }
        }
    }

    private func removeSampleRateListener() {
        guard let sampleRateListener, targetDeviceID != 0 else { return }
        var addr = Self.sampleRateAddress
        AudioObjectRemovePropertyListenerBlock(targetDeviceID, &addr, .main, sampleRateListener)
        self.sampleRateListener = nil
    }

    // MARK: - Tap side (tap aggregate's IO thread)

    func renderTap(input: UnsafePointer<AudioBufferList>, inputTime: AudioTimeStamp) {
        tapCallbacks &+= 1
        let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var channel = 0
        var frameCount = -1
        for buffer in inputList {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0 else { continue }
            guard let data = buffer.mData else {
                tapDropouts &+= 1
                return
            }
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
            if frameCount < 0 { frameCount = frames } else if frames != frameCount {
                tapDropouts &+= 1
                return
            }
            let samples = UnsafePointer(data.assumingMemoryBound(to: Float.self))
            for offset in 0..<channels where channel < tapChannels {
                tapSources[channel] = AudioRing.Source(pointer: samples + offset, stride: channels)
                channel += 1
            }
        }
        // Half the ring at most: the consumer must always find the frames it snaps back to intact.
        guard channel == tapChannels, frameCount > 0, frameCount <= ring.capacity / 2 else {
            tapDropouts &+= 1
            return
        }

        var firstSignalFrame = -1
        signalSearch: for frame in 0..<frameCount {
            for index in 0..<tapChannels where tapSources[index].pointer[frame * tapSources[index].stride] != 0 {
                firstSignalFrame = frame
                break signalSearch
            }
        }
        eq_store_relaxed(sharedCells + Self.tapFramesCell, Int64(frameCount))
        let start = ring.write(UnsafeBufferPointer(start: tapSources, count: tapChannels), frames: frameCount)
        let hostValid = inputTime.mFlags.contains(.hostTimeValid)
        if hostValid {
            eq_stamp_publish(sharedCells, start, Int64(bitPattern: inputTime.mHostTime))
        }
        if firstSignalFrame >= 0 {
            if hostValid, tapSilentFrames + firstSignalFrame >= oneSecondFrames / 10 {
                let host = inputTime.mHostTime &+ UInt64(Double(firstSignalFrame) * ticksPerFrame)
                eq_stamp_publish(sharedCells + Self.onsetStamp, start + Int64(firstSignalFrame), Int64(bitPattern: host))
            }
            signalCallbacks &+= 1
            tapSilentFrames = 0
        } else {
            tapSilentFrames = min(tapSilentFrames + frameCount, oneSecondFrames)
        }
    }

    // MARK: - Output side (output device's IO thread)

    func renderOutput(output: UnsafeMutablePointer<AudioBufferList>, outputTime: AudioTimeStamp) {
        callbacks &+= 1
        let outputList = UnsafeMutableAudioBufferListPointer(output)
        var frameCount = 0
        for buffer in outputList where buffer.mData != nil {
            frameCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / max(Int(buffer.mNumberChannels), 1)
            break
        }
        guard frameCount > 0, frameCount <= scratchCapacity else {
            if frameCount > 0 { outputDropouts &+= 1 }
            zero(outputList)
            return
        }

        let plan = pacer.plan(written: ring.written, read: ring.read, frames: frameCount,
                              tapFrames: Int(eq_load_relaxed(sharedCells + Self.tapFramesCell)))
        switch plan.event {
        case .underrun: underruns &+= 1
        case .overrun: overruns &+= 1
        case .none, .primed: break
        }
        let channels = UnsafeBufferPointer(start: channelPointers, count: tapChannels)
        ring.copy(from: plan.start, frames: plan.count, into: channels)
        if plan.count < frameCount {
            for channel in channels {
                vDSP_vclr(channel + plan.count, 1, vDSP_Length(frameCount - plan.count))
            }
        }
        if plan.count > 0 {
            ring.consume(through: plan.start + Int64(plan.count))
            if outputTime.mFlags.contains(.hostTimeValid) {
                noteTiming(start: plan.start, count: plan.count, outputHost: outputTime.mHostTime)
            }
        }

        var peak: Float = 0
        for channel in channels {
            var channelPeak: Float = 0
            vDSP_maxmgv(channel, 1, &channelPeak, vDSP_Length(frameCount))
            peak = max(peak, channelPeak)
        }
        if peak > 0 {
            silentFrames = 0
            isSilenceGated = false
        } else {
            silentFrames = min(silentFrames + frameCount, oneSecondFrames)
            if silentFrames == oneSecondFrames {
                if !isSilenceGated {
                    processor.resetRenderState()
                    isSilenceGated = true
                }
                zero(outputList)
                return
            }
        }

        processor.process(channels: activeChannels, frameCount: frameCount)
        framesProcessed &+= UInt64(frameCount)

        // Tap channel n goes to device channel n, counted across the output buffers: the tap has
        // the format of the device's first stream. Channels beyond the tap's get silence.
        var zero: Float = 0
        var deviceChannel = 0
        for buffer in outputList {
            guard let data = buffer.mData else { continue }
            let channelCount = max(Int(buffer.mNumberChannels), 1)
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channelCount
            let samples = data.assumingMemoryBound(to: Float.self)
            let n = min(frames, frameCount)
            for offset in 0..<channelCount {
                if deviceChannel < channels.count {
                    vDSP_vsadd(channels[deviceChannel], 1, &zero, samples + offset,
                               vDSP_Stride(channelCount), vDSP_Length(n))
                } else {
                    vDSP_vclr(samples + offset, vDSP_Stride(channelCount), vDSP_Length(n))
                }
                deviceChannel += 1
            }
            if frames > n {
                vDSP_vclr(samples + n * channelCount, 1, vDSP_Length((frames - n) * channelCount))
            }
        }
    }

    /// The ring frames at `start` leave at `outputHost`: how long eq held them, and whether they
    /// carry the onset the tap last stamped.
    private func noteTiming(start: Int64, count: Int, outputHost: UInt64) {
        var position: Int64 = 0
        var host: Int64 = 0
        if eq_stamp_read(sharedCells, &position, &host) != 0,
           let delay = IODelay.between(tapPosition: position, tapHost: UInt64(bitPattern: host),
                                       outputPosition: start, outputHost: outputHost, ticksPerFrame: ticksPerFrame) {
            ioDelayFrames = delay.frames
            ioDelayTicks = delay.hostTicks
        }
        let sequence = eq_stamp_read(sharedCells + Self.onsetStamp, &position, &host)
        guard sequence != 0, sequence != handledOnset, position < start + Int64(count) else { return }
        handledOnset = sequence
        // An onset before `start` was dropped or skipped while the ring primed; it never played.
        guard position >= start else { return }
        onsetTapHost = UInt64(bitPattern: host)
        onsetOutputHost = outputHost
        onsetOutputFrame = Int(position - start)
        onsets &+= 1
    }

    private func zero(_ outputList: UnsafeMutableAudioBufferListPointer) {
        for buffer in outputList {
            guard let data = buffer.mData else { continue }
            vDSP_vclr(data.assumingMemoryBound(to: Float.self), 1,
                      vDSP_Length(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size))
        }
    }
}
