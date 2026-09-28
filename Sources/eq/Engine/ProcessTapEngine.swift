// Vendored from zollans/OnlyEQ @ 6569655 (Unlicense), trimmed for eq.
import Foundation
import CoreAudio
import AudioToolbox
import Accelerate

struct TapInputSelection: Equatable {
    let bufferIndex: Int
    let channels: Int

    init(bufferIndex: Int, channels: Int) {
        self.bufferIndex = bufferIndex
        self.channels = channels
    }

    static func select(tapFormat: AudioStreamBasicDescription,
                       aggregateInputFormats: [AudioStreamBasicDescription],
                       aggregateInputChannels: [UInt32],
                       aggregateInputStartingChannels: [UInt32] = [],
                       physicalInputChannelCount: UInt32? = nil) -> TapInputSelection? {
        guard tapFormat.mFormatID == kAudioFormatLinearPCM,
              tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
              tapFormat.mBitsPerChannel == 32,
              tapFormat.mChannelsPerFrame == 2,
              aggregateInputFormats.count == aggregateInputChannels.count else { return nil }
        var matches: [TapInputSelection] = []
        for (index, format) in aggregateInputFormats.enumerated()
            where aggregateInputChannels[index] == 2 && compatible(format, tapFormat) {
            matches.append(TapInputSelection(bufferIndex: index, channels: 2))
        }
        if matches.count == 1 { return matches[0] }

        // Some interfaces expose a physical stereo input with the exact same
        // format as the stereo process tap. In the aggregate's input channel
        // space, the tap starts immediately after the physical device inputs.
        // Use that channel boundary to establish provenance without assuming
        // that Core Audio returns the streams in a particular array order.
        guard aggregateInputStartingChannels.count == aggregateInputFormats.count,
              let physicalInputChannelCount,
              physicalInputChannelCount < UInt32.max else { return nil }
        let tapStartingChannel = physicalInputChannelCount + 1
        let boundaryMatches = matches.filter {
            aggregateInputStartingChannels[$0.bufferIndex] == tapStartingChannel
        }
        guard boundaryMatches.count == 1 else { return nil }
        return boundaryMatches[0]
    }

    private static func compatible(_ lhs: AudioStreamBasicDescription, _ rhs: AudioStreamBasicDescription) -> Bool {
        lhs.mSampleRate == rhs.mSampleRate && lhs.mFormatID == rhs.mFormatID && lhs.mFormatFlags == rhs.mFormatFlags
            && lhs.mBytesPerPacket == rhs.mBytesPerPacket && lhs.mFramesPerPacket == rhs.mFramesPerPacket
            && lhs.mBytesPerFrame == rhs.mBytesPerFrame && lhs.mChannelsPerFrame == rhs.mChannelsPerFrame
            && lhs.mBitsPerChannel == rhs.mBitsPerChannel
    }
}

/// System-wide EQ engine built on Core Audio process taps (macOS 14.4+).
///
/// One pass through the tap path, in frames at the device's nominal rate.
struct PathLatency: Equatable {
    /// Output device latency plus its safety offset.
    var outputDevice: UInt32
    var outputStream: UInt32
    var buffer: UInt32
    /// The aggregate's input side (the tap): device latency plus safety offset.
    var tapInput: UInt32

    func milliseconds(sampleRate: Double) -> Double? {
        guard sampleRate > 0 else { return nil }
        // Twice: the IOProc gets a full input buffer from the tap before it runs, then its output
        // buffer waits a full cycle before the device plays it.
        let frames = Double(outputDevice) + Double(outputStream) + 2 * Double(buffer) + Double(tapInput)
        return frames / sampleRate * 1000
    }

    /// What a player sees on the device and compensates for without eq.
    func deviceMilliseconds(sampleRate: Double) -> Double? {
        guard sampleRate > 0 else { return nil }
        return (Double(outputDevice) + Double(outputStream)) / sampleRate * 1000
    }
}

/// How long one IO cycle holds a sample: from the time the tap delivered it to the time eq hands it
/// to the output, both read from the aggregate's own timestamps.
struct IODelay: Equatable {
    var hostTicks: UInt64
    var frames: Double

    static func measure(input: AudioTimeStamp, output: AudioTimeStamp) -> IODelay? {
        let valid: AudioTimeStampFlags = [.hostTimeValid, .sampleTimeValid]
        guard input.mFlags.contains(valid), output.mFlags.contains(valid),
              output.mHostTime > input.mHostTime else { return nil }
        return IODelay(hostTicks: output.mHostTime - input.mHostTime, frames: output.mSampleTime - input.mSampleTime)
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

/// Signal path: muted global tap (silences original output) → aggregate device
/// wrapping the real output + tap → IOProc reads tapped audio, runs the EQ
/// chain, and re-renders to the real output. No drivers, no BlackHole.
final class ProcessTapEngine {

    enum State: Equatable {
        case stopped
        case running
        case failed(String)
    }

    let processor = EQProcessor()

    private(set) var state: State = .stopped
    private(set) var targetDeviceID: AudioObjectID = 0
    private(set) var ioBufferFrames: Int = 256
    var requestedIOBufferFrames: Int = 256

    /// Written on the audio thread, read racily by the status writer; a torn read is harmless.
    private(set) var framesProcessed: UInt64 = 0
    private(set) var callbacks: UInt64 = 0
    /// Callbacks whose tap input carried a non-zero sample; stops advancing when nothing reaches the tap.
    private(set) var signalCallbacks: UInt64 = 0
    private(set) var latencyMs: Double?
    private(set) var deviceLatencyMs: Double?
    var driftCompensation = true
    private var ioDelayTicks: UInt64 = 0
    private var ioDelayFrames: Double = 0
    /// The first sample after silence, as the tap stamped it and as eq sends it on: a click played
    /// by another process lines up against these to measure what the whole tap path adds.
    private var onsets: UInt64 = 0
    private var onsetInputHost: UInt64 = 0
    private var onsetOutputHost: UInt64 = 0
    private var onsetFrame = 0

    var addedLatency: IODelay? {
        let ticks = ioDelayTicks
        return ticks == 0 ? nil : IODelay(hostTicks: ticks, frames: ioDelayFrames)
    }

    var lastOnset: Status.Onset? {
        guard onsets > 0 else { return nil }
        let rate = processor.sampleRate
        return Status.Onset(tapHostSeconds: IODelay.seconds(host: onsetInputHost, frame: onsetFrame, sampleRate: rate),
                            outputHostSeconds: IODelay.seconds(host: onsetOutputHost, frame: onsetFrame, sampleRate: rate),
                            count: onsets)
    }

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var sampleRateListener: AudioObjectPropertyListenerBlock?
    private var channelScratch: [UnsafeMutablePointer<Float>] = []
    private struct InputChannel {
        var pointer: UnsafeMutablePointer<Float>
        var stride: Int
    }
    private var inputChannels: [InputChannel] = []
    private var activeChannels: [UnsafeMutablePointer<Float>] = []
    /// Consecutive all-zero input frames, saturated at one second's worth.
    private var silentFrames = 0
    private var isSilenceGated = false
    private var preparedInput: TapInputSelection

    /// Fired (on the main queue) when the tapped device's nominal sample rate
    /// changes while running. Biquad coefficients are baked for one rate, so
    /// the owner must restart the engine to stay on pitch.
    var onSampleRateChange: (() -> Void)?

    init(preparedInput: TapInputSelection = TapInputSelection(bufferIndex: 0, channels: 2)) {
        self.preparedInput = preparedInput
        inputChannels.reserveCapacity(8)
        activeChannels.reserveCapacity(8)
        channelScratch.reserveCapacity(8)
        prepareScratch(channels: preparedInput.channels, frames: ioBufferFrames)
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

        // 1. Create the muted global tap, excluding ourselves — re-rendered audio
        //    must not be re-captured.
        let excluded = AudioDeviceManager.processObject(forPID: getpid()).map { [$0] } ?? []

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
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

        let sampleRate = AudioDeviceManager.nominalSampleRate(deviceID)
        processor.configure(sampleRate: sampleRate)

        // 2. Wrap the real output device + tap in a private aggregate.
        let aggregateUID = "\(AudioDeviceManager.aggregateUIDPrefix)\(deviceUID)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "eq",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: deviceUID,
                    // Exclude the device's input side (e.g. a Bluetooth
                    // headset's mic) from the aggregate — otherwise running
                    // our IOProc counts as microphone access and macOS shows
                    // a mic permission prompt when such a device connects.
                    kAudioSubDeviceInputChannelsKey: 0,
                ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: driftCompensation,
                ]
            ],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]

        var newAggregateID = AudioObjectID(0)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard status == noErr, newAggregateID != 0 else {
            cleanupTap()
            transition(to: .failed("Couldn’t create aggregate device (error \(status))."))
            return
        }
        aggregateID = newAggregateID

        // Prefer a unique format match. If a physical stereo input has the
        // same format as the tap, use aggregate channel numbering to identify
        // the tap without relying on stream-array order.
        guard let tapFormat = AudioDeviceManager.tapFormat(tapID),
              let inputFormats = AudioDeviceManager.inputStreamFormats(aggregateID),
              let inputChannels = AudioDeviceManager.inputStreamChannelCounts(aggregateID) else {
            cleanup()
            transition(to: .failed("Unsupported aggregate input topology: no unique tap stream."))
            return
        }
        let selection = TapInputSelection.select(
            tapFormat: tapFormat,
            aggregateInputFormats: inputFormats,
            aggregateInputChannels: inputChannels,
            aggregateInputStartingChannels: AudioDeviceManager.inputStreamStartingChannels(aggregateID) ?? [],
            physicalInputChannelCount: AudioDeviceManager.inputChannelCount(deviceID)
        )
        guard let selection else {
            cleanup()
            transition(to: .failed("Unsupported aggregate input topology: no unique tap stream."))
            return
        }
        preparedInput = selection

        requestIOBufferSize()

        // 3. IOProc: tapped audio arrives as input, processed audio leaves as output.
        silentFrames = 0
        isSilenceGated = false
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { [weak self] _, inInputData, inInputTime, outOutputData, inOutputTime in
            self?.render(input: inInputData, output: outOutputData, inputTime: inInputTime.pointee, outputTime: inOutputTime.pointee)
        }
        guard status == noErr, let ioProcID else {
            cleanup()
            transition(to: .failed("Couldn’t create audio IO proc (error \(status))."))
            return
        }

        // Allocate the normal stereo scratch path before the realtime callback
        // starts. prepareScratch still handles unusual topologies defensively.
        readIOBufferSize()
        prepareScratch(channels: 2, frames: ioBufferFrames)

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            cleanup()
            transition(to: .failed("Couldn’t start audio device (error \(status))."))
            return
        }

        let path = PathLatency(
            outputDevice: AudioDeviceManager.latencyFrames(device: deviceID, scope: kAudioDevicePropertyScopeOutput),
            outputStream: AudioDeviceManager.firstOutputStreamLatencyFrames(deviceID),
            buffer: UInt32(ioBufferFrames),
            tapInput: AudioDeviceManager.latencyFrames(device: aggregateID, scope: kAudioDevicePropertyScopeInput)
        )
        latencyMs = path.milliseconds(sampleRate: sampleRate)
        deviceLatencyMs = path.deviceMilliseconds(sampleRate: sampleRate)
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
        signalCallbacks = 0
        latencyMs = nil
        deviceLatencyMs = nil
        ioDelayTicks = 0
        ioDelayFrames = 0
        onsets = 0
        processor.solo = nil
        if state != .stopped { transition(to: .stopped) }
    }

    deinit {
        stop()
        for pointer in channelScratch { pointer.deallocate() }
    }

    private func cleanup() {
        if let ioProcID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
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

    private func readIOBufferSize() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(aggregateID, &addr, 0, nil, &size, &frames) == noErr, frames > 0 {
            ioBufferFrames = Int(frames)
        }
    }

    private func requestIOBufferSize() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var frames = UInt32(requestedIOBufferFrames)
        // Some devices refuse or clamp the request; readIOBufferSize() then reports what was granted.
        _ = AudioObjectSetPropertyData(aggregateID, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
    }

    // MARK: - Render path (audio thread)

    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>,
                inputTime: AudioTimeStamp, outputTime: AudioTimeStamp) {
        callbacks &+= 1
        if let delay = IODelay.measure(input: inputTime, output: outputTime) {
            ioDelayFrames = delay.frames
            ioDelayTicks = delay.hostTicks
        }
        let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputList = UnsafeMutableAudioBufferListPointer(output)
        guard inputList.count > 0, outputList.count > 0 else {
            zero(outputList)
            return
        }
        // Consume only the prepared tap stream; other aggregate inputs can be
        // physical streams and must never influence output.
        inputChannels.removeAll(keepingCapacity: true)
        guard preparedInput.bufferIndex < inputList.count else { zero(outputList); return }
        let selectedBuffer = inputList[preparedInput.bufferIndex]
        let channels = preparedInput.channels
        guard channels == 2, let data = selectedBuffer.mData, Int(selectedBuffer.mNumberChannels) == channels,
              selectedBuffer.mDataByteSize % UInt32(MemoryLayout<Float>.size * channels) == 0 else { zero(outputList); return }
        let frameCount = Int(selectedBuffer.mDataByteSize) / MemoryLayout<Float>.size / channels
        guard frameCount > 0 else {
            zero(outputList)
            return
        }
        let floatPtr = data.assumingMemoryBound(to: Float.self)
        for ch in 0..<channels {
            inputChannels.append(InputChannel(pointer: floatPtr + ch, stride: channels))
        }
        guard inputChannels.count <= channelScratch.count, frameCount <= scratchCapacity else {
            zero(outputList)
            return
        }

        // Inspect the exact frames/channels the renderer consumes. Scanning the
        // raw AudioBuffer storage as one contiguous vDSP vector is incorrect for
        // layouts with padding or a channel stride and can leave the engine
        // permanently gated after playback resumes.
        var firstSignalFrame = -1
        signalSearch: for frame in 0..<frameCount {
            for channel in inputChannels where channel.pointer[frame * channel.stride] != 0 {
                firstSignalFrame = frame
                break signalSearch
            }
        }
        if firstSignalFrame >= 0 {
            if silentFrames + firstSignalFrame >= Int(processor.sampleRate) / 10 {
                onsetInputHost = inputTime.mHostTime
                onsetOutputHost = outputTime.mHostTime
                onsetFrame = firstSignalFrame
                onsets &+= 1
            }
            signalCallbacks &+= 1
            silentFrames = 0
            isSilenceGated = false
        } else {
            let ringOutFrames = Int(processor.sampleRate)
            silentFrames = min(silentFrames + frameCount, ringOutFrames)
            if silentFrames == ringOutFrames {
                if !isSilenceGated {
                    processor.resetRenderState()
                    isSilenceGated = true
                }
                zero(outputList)
                return
            }
        }

        // De-interleave into scratch, process, then write to the output buffers.
        activeChannels.removeAll(keepingCapacity: true)
        var zero: Float = 0
        for (index, channel) in inputChannels.enumerated() {
            let scratch = channelScratch[index]
            if channel.stride == 1 {
                scratch.update(from: channel.pointer, count: frameCount)
            } else {
                vDSP_vsadd(channel.pointer, vDSP_Stride(channel.stride), &zero,
                           scratch, 1, vDSP_Length(frameCount))
            }
            activeChannels.append(scratch)
        }
        processor.process(channels: activeChannels, frameCount: frameCount)
        framesProcessed &+= UInt64(frameCount)

        // Write processed audio out, cycling tap channels across device channels.
        var sourceIndex = 0
        for buffer in outputList {
            guard let data = buffer.mData else { continue }
            let channelCount = max(Int(buffer.mNumberChannels), 1)
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channelCount
            let floatPtr = data.assumingMemoryBound(to: Float.self)
            let n = min(frames, frameCount)
            for ch in 0..<channelCount {
                let source = activeChannels[sourceIndex % activeChannels.count]
                if channelCount == 1 {
                    floatPtr.update(from: source, count: n)
                } else {
                    vDSP_vsadd(source, 1, &zero, floatPtr + ch,
                               vDSP_Stride(channelCount), vDSP_Length(n))
                }
                sourceIndex += 1
            }
            if frames > n {
                vDSP_vclr(floatPtr + n * channelCount, 1, vDSP_Length((frames - n) * channelCount))
            }
        }
    }

    private func prepareScratch(channels: Int, frames: Int) {
        let needed = channels
        if channelScratch.count < needed || (channelScratch.first != nil && scratchCapacity < frames) {
            for ptr in channelScratch { ptr.deallocate() }
            scratchCapacity = max(frames, 4096)
            channelScratch = (0..<needed).map { _ in
                UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
            }
        }
    }

    private var scratchCapacity = 0

    private func zero(_ outputList: UnsafeMutableAudioBufferListPointer) {
        for buffer in outputList {
            guard let data = buffer.mData else { continue }
            vDSP_vclr(data.assumingMemoryBound(to: Float.self), 1,
                      vDSP_Length(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size))
        }
    }
}
