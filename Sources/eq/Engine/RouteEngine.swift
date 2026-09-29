import Foundation
import CoreAudio
import AudioToolbox
import Accelerate
import EQAtomics
import EQCore

/// Plays some apps on one target device, whatever the default output is: a muted private tap on
/// their processes in a tap-only aggregate → a ring → an output IOProc on the target that resamples
/// the tap's rate onto the target's clock, runs the target's curve and plays it.
///
/// Not L1 (tap and target in one aggregate): M0 measured it adding 187 ms on the way to Bluetooth.
/// The tap is private and muted: after a `kill -9` a private muted tap gave the app its sound back
/// (M0), and while nothing reads it, what the app plays is lost rather than heard on the wrong device.
final class RouteEngine {
    enum State: Equatable {
        case stopped
        case running
        case failed(String)
    }

    static let aggregateUIDPrefix = AudioDeviceManager.aggregateUIDPrefix + "route-"
    static let maxOutputFrames = 4096

    let targetUID: String
    let processor = EQProcessor()
    private let core: OpaquePointer

    private(set) var state: State = .stopped
    private(set) var targetDeviceID: AudioObjectID = 0
    private(set) var processes: [AudioObjectID] = []
    var requestedIOBufferFrames = 128

    private(set) var tapRate: Double = 0
    private(set) var outputRate: Double = 0
    private(set) var tapChannels = 2
    private(set) var tapBufferFrames = 128
    private(set) var outputBufferFrames = 128

    // Written on the audio threads, read racily by the daemon; a torn read is harmless.
    private(set) var callbacks: UInt64 = 0
    private(set) var tapCallbacks: UInt64 = 0
    private(set) var signalCallbacks: UInt64 = 0
    private(set) var framesProcessed: UInt64 = 0
    private(set) var underruns: UInt64 = 0
    private(set) var overruns: UInt64 = 0
    private var tapDropouts: UInt64 = 0
    private var outputDropouts: UInt64 = 0
    var dropouts: UInt64 { tapDropouts &+ outputDropouts }
    private var delayTicks: Double = 0
    private var onsets: UInt64 = 0
    private var onsetTapHost: UInt64 = 0
    private var onsetOutputHost: UInt64 = 0
    private(set) var servo = DriftServo()
    private(set) var deviceLatencyMs: Double?
    private var estimatedAddedMs: Double?

    /// From a tap frame's capture to its output, as the servo last measured it.
    var addedLatencyMs: Double? {
        let ticks = delayTicks
        return ticks > 0 ? ticks / ticksPerSecond * 1000 : estimatedAddedMs
    }

    var correctionPpm: Double { servo.correction * 1e6 }

    var lastOnset: Status.Onset? {
        guard onsets > 0 else { return nil }
        return Status.Onset(tapHostSeconds: IODelay.seconds(host: onsetTapHost, frame: 0, sampleRate: 0),
                            outputHostSeconds: IODelay.seconds(host: onsetOutputHost, frame: 0, sampleRate: 0),
                            count: onsets)
    }

    /// On the main queue: the target's rate or the tap's format changed, so the engine plays at the
    /// wrong pitch until it is built again.
    var onInvalidated: (() -> Void)?

    private var tapID: AudioObjectID = 0
    private var tapDescription: CATapDescription?
    private var aggregateID: AudioObjectID = 0
    private var tapProcID: AudioDeviceIOProcID?
    private var outputProcID: AudioDeviceIOProcID?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var stranded = StrandedIOProcs()

    // Render state, sized by `prepare` while neither IOProc runs and never freed under them.
    private let ring = AudioRing(channels: 2, minimumCapacity: 8192)
    private var resamplerStorage: UnsafeMutableRawPointer?
    private var resampler: OpaquePointer?
    private let tapSources = UnsafeMutablePointer<AudioRing.Source>.allocate(capacity: TapFormat.maxChannels)
    private let channelPointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: TapFormat.maxChannels)
    private let inputPointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: TapFormat.maxChannels)
    private var scratch: [UnsafeMutablePointer<Float>] = []
    private var scratchCapacity = 0
    // Sequence-locked (position, host) stamps from the tap: [0...2] its latest buffer, [8...10] its
    // latest onset; [4] its latest buffer size.
    private let sharedCells = UnsafeMutablePointer<Int64>.allocate(capacity: 16)
    private static let onsetStamp = 8
    private static let tapFramesCell = 4
    private var handledOnset: Int64 = 0
    private var readPosition: Int64 = 0
    /// The ring position of the resampler's input frame 0.
    private var origin: Int64 = 0
    private var primed = false
    private var nominalStep = 1.0
    private var lookAhead = 0
    private var ringLimit = 0
    private var ticksPerSecond = Double(AudioConvertNanosToHostTime(1_000_000_000))
    private var tapTicksPerFrame: Double = 0
    private var oneSecondFrames = 48000
    private var tapSilentFrames = 0
    private var silentFrames = 0
    private var isSilenceGated = false

    init(targetUID: String) {
        self.targetUID = targetUID
        core = processor.core
        sharedCells.initialize(repeating: 0, count: 16)
        processor.configure(sampleRate: 48000, channels: 2)
        prepare(channels: 2, tapRate: 48000, outputRate: 48000, tapFrames: 128, outputFrames: 128)
    }

    deinit {
        stop()
        for pointer in scratch { pointer.deallocate() }
        resamplerStorage?.deallocate()
        tapSources.deallocate()
        channelPointers.deallocate()
        inputPointers.deallocate()
        sharedCells.deallocate()
    }

    var aggregateUID: String { Self.aggregateUIDPrefix + targetUID }

    // MARK: - Lifecycle

    /// Builds the whole route for `processes`. The output IOProc starts before the tap's, so the
    /// first tap buffer already has a reader; the tap mutes the apps from its creation, some tens of
    /// ms before that, which is why the daemon taps an app when it opens audio, not when it plays.
    func start(processes: [AudioObjectID]) {
        stop()
        stranded.retry()
        guard stranded.isEmpty else {
            transition(to: .failed("Core Audio would not remove an earlier IO proc on device \(stranded.devices.map(String.init).joined(separator: ", "))."))
            return
        }
        guard !processes.isEmpty else {
            transition(to: .failed("No process to route."))
            return
        }
        guard let deviceID = AudioDeviceManager.deviceID(uid: targetUID) else {
            transition(to: .failed("Route target \(targetUID) is not there."))
            return
        }
        let outputRate = AudioDeviceManager.nominalSampleRate(deviceID)
        guard outputRate > 0 else {
            transition(to: .failed("Route target has no sample rate yet."))
            return
        }
        targetDeviceID = deviceID
        self.processes = processes

        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.name = "eq route tap"
        description.isPrivate = true
        description.muteBehavior = .muted
        var newTapID = AudioObjectID(0)
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr, newTapID != 0 else {
            transition(to: .failed("Couldn’t create audio tap (error \(status))."))
            return
        }
        tapID = newTapID
        tapDescription = description

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "eq route",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        var newAggregateID = AudioObjectID(0)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard status == noErr, newAggregateID != 0 else {
            cleanup()
            transition(to: .failed("Couldn’t create aggregate device (error \(status))."))
            return
        }
        aggregateID = newAggregateID

        // The tap's own format, not the aggregate's: M0 found a mixdown tap labelled 48 kHz inside an
        // aggregate that delivered 44.1 kHz. Alone in its aggregate it tells the truth, and the
        // aggregate is set to match.
        guard let format = AudioDeviceManager.tapFormat(tapID), format.mSampleRate > 0,
              format.mSampleRate <= AudioDeviceManager.maxSampleRate else {
            cleanup()
            transition(to: .failed("Unsupported tap format or rate."))
            return
        }
        let tapRate = format.mSampleRate
        if AudioDeviceManager.nominalSampleRate(aggregateID) != tapRate {
            _ = AudioDeviceManager.setNominalSampleRate(aggregateID, tapRate)
            for _ in 0..<30 where AudioDeviceManager.nominalSampleRate(aggregateID) != tapRate { usleep(10_000) }
        }
        guard let inputChannels = AudioDeviceManager.inputStreamChannelCounts(aggregateID),
              let channels = TapFormat.channels(tap: format, deviceRate: tapRate,
                                                aggregateRate: AudioDeviceManager.nominalSampleRate(aggregateID),
                                                aggregateInputChannels: inputChannels),
              eqc_resampler_size(tapRate, outputRate, Int32(channels), Int32(Self.maxOutputFrames)) > 0 else {
            cleanup()
            transition(to: .failed("Unsupported tap format or rate."))
            return
        }
        processor.configure(sampleRate: outputRate, channels: channels)
        AudioDeviceManager.requestBufferFrameSize(aggregateID, requestedIOBufferFrames)
        AudioDeviceManager.requestBufferFrameSize(deviceID, requestedIOBufferFrames)
        prepare(channels: channels, tapRate: tapRate, outputRate: outputRate,
                tapFrames: AudioDeviceManager.bufferFrameSize(aggregateID) ?? requestedIOBufferFrames,
                outputFrames: AudioDeviceManager.bufferFrameSize(deviceID) ?? requestedIOBufferFrames)

        // Plain C functions handed the engine unretained, as ProcessTapEngine's: a block IOProc would
        // retain and release its context on every callback. cleanup() destroys both first.
        let engine = Unmanaged.passUnretained(self).toOpaque()
        status = AudioDeviceCreateIOProcID(aggregateID, { _, _, input, inputTime, _, _, engine in
            Unmanaged<RouteEngine>.fromOpaque(engine!)._withUnsafeGuaranteedRef {
                $0.renderTap(input: input, inputTime: inputTime.pointee)
            }
            return noErr
        }, engine, &tapProcID)
        guard status == noErr, tapProcID != nil else {
            cleanup()
            transition(to: .failed("Couldn’t create audio IO proc (error \(status))."))
            return
        }
        status = AudioDeviceCreateIOProcID(deviceID, { _, _, _, _, output, outputTime, engine in
            Unmanaged<RouteEngine>.fromOpaque(engine!)._withUnsafeGuaranteedRef {
                $0.renderOutput(output: output, outputTime: outputTime.pointee)
            }
            return noErr
        }, engine, &outputProcID)
        guard status == noErr, let outputProcID else {
            cleanup()
            transition(to: .failed("Couldn’t create audio IO proc (error \(status))."))
            return
        }
        guard StreamUsage.restrict(outputProcID, on: deviceID) else {
            cleanup()
            transition(to: .failed("Couldn’t keep the route target’s microphone closed; not starting."))
            return
        }
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
            outputBuffer: UInt32(outputBufferFrames),
            tapInput: 0,
            ringTarget: 0)
        deviceLatencyMs = path.deviceMilliseconds(sampleRate: outputRate)
        let tapInput = Double(AudioDeviceManager.latencyFrames(device: aggregateID, scope: kAudioDevicePropertyScopeInput))
        estimatedAddedMs = (tapInput + Double(cushion(outputFrames: outputBufferFrames, tapFrames: tapBufferFrames).target)) / tapRate * 1000
            + Double(outputBufferFrames) / outputRate * 1000
        Log.write("route \(targetUID): tap \(Int(tapRate)) Hz \(channels) ch, buffer \(tapBufferFrames); target \(Int(outputRate)) Hz, buffer \(outputBufferFrames); \(processes.count) process(es)")
        listen(deviceID, kAudioDevicePropertyNominalSampleRate) { [weak self] in
            guard let self else { return false }
            return AudioDeviceManager.nominalSampleRate(self.targetDeviceID) != self.outputRate
        }
        listen(tapID, kAudioTapPropertyFormat) { [weak self] in
            guard let self else { return false }
            return AudioDeviceManager.tapFormat(self.tapID).map { $0.mSampleRate != self.tapRate || Int($0.mChannelsPerFrame) != self.tapChannels } ?? true
        }
        transition(to: .running)
    }

    /// Both IOProcs stopped while the tap stays, so its apps stay muted and the target's stream may
    /// sleep; the first moment of sound after `setIdle(false)` is lost (the spec's answer 3).
    private(set) var idle = false

    /// False when an IOProc would not start again; the engine is then failed.
    @discardableResult
    func setIdle(_ idle: Bool) -> Bool {
        guard state == .running, idle != self.idle, let outputProcID, let tapProcID else { return state == .running }
        if idle {
            AudioDeviceStop(targetDeviceID, outputProcID)
            AudioDeviceStop(aggregateID, tapProcID)
            // Both callbacks have ended: the output primes again from whatever the tap writes next.
            primed = false
            self.idle = true
            return true
        }
        var status = AudioDeviceStart(targetDeviceID, outputProcID)
        if status == noErr { status = AudioDeviceStart(aggregateID, tapProcID) }
        self.idle = false
        guard status == noErr else {
            transition(to: .failed("Couldn’t start the route again (error \(status))."))
            return false
        }
        return true
    }

    /// The tap's processes, changed on the live tap: M0 found the edit takes within some 30 ms.
    /// False when Core Audio refused it; the engine then needs building again.
    func setProcesses(_ processes: [AudioObjectID]) -> Bool {
        guard state == .running, tapID != 0, let tapDescription else { return false }
        guard processes != self.processes else { return true }
        tapDescription.processes = processes
        let status = AudioDeviceManager.setTapDescription(tapID, tapDescription)
        guard status == noErr else {
            Log.write("route \(targetUID): could not change the tap's processes (error \(status))")
            return false
        }
        self.processes = processes
        return true
    }

    func stop() {
        for (object, address, block) in listeners {
            var addr = address
            AudioObjectRemovePropertyListenerBlock(object, &addr, .main, block)
        }
        listeners = []
        cleanup()
        targetDeviceID = 0
        processes = []
        callbacks = 0
        tapCallbacks = 0
        signalCallbacks = 0
        framesProcessed = 0
        underruns = 0
        overruns = 0
        tapDropouts = 0
        outputDropouts = 0
        delayTicks = 0
        onsets = 0
        deviceLatencyMs = nil
        estimatedAddedMs = nil
        servo = DriftServo()
        idle = false
        if state != .stopped { transition(to: .stopped) }
    }

    /// Sizes every render buffer and clears all render state. Only while neither IOProc runs; tests
    /// drive the two render functions through it without Core Audio.
    func prepare(channels: Int, tapRate: Double, outputRate: Double, tapFrames: Int, outputFrames: Int) {
        let channels = min(max(channels, 1), TapFormat.maxChannels)
        tapChannels = channels
        self.tapRate = tapRate
        self.outputRate = outputRate
        tapBufferFrames = tapFrames
        outputBufferFrames = outputFrames
        nominalStep = tapRate / outputRate
        let maxOutput = max(outputFrames, Self.maxOutputFrames)
        resamplerStorage?.deallocate()
        let size = eqc_resampler_size(tapRate, outputRate, Int32(channels), Int32(maxOutput))
        precondition(size > 0, "no resampler from \(tapRate) to \(outputRate) Hz")
        let storage = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        resamplerStorage = storage
        resampler = OpaquePointer(storage)
        eqc_resampler_init(resampler!, tapRate, outputRate, Int32(channels), Int32(maxOutput))
        lookAhead = Int(eqc_resampler_latency(resampler!))
        // Room for both sides to grow to their largest buffers without a rebuild.
        let roomy = cushion(outputFrames: maxOutput, tapFrames: max(tapFrames, Self.maxOutputFrames))
        ring.reset(channels: channels, minimumCapacity: 4 * roomy.ceiling)
        ringLimit = ring.capacity / 4
        if scratch.count < channels || scratchCapacity < maxOutput {
            for pointer in scratch { pointer.deallocate() }
            scratchCapacity = maxOutput
            scratch = (0..<max(channels, 2)).map { _ in
                let pointer = UnsafeMutablePointer<Float>.allocate(capacity: maxOutput)
                pointer.initialize(repeating: 0, count: maxOutput)
                return pointer
            }
        }
        for (index, pointer) in scratch.prefix(channels).enumerated() { channelPointers[index] = pointer }
        ticksPerSecond = Double(AudioConvertNanosToHostTime(1_000_000_000))
        tapTicksPerFrame = tapRate > 0 ? ticksPerSecond / tapRate : 0
        oneSecondFrames = max(Int(outputRate), 1)
        for index in 0..<16 { eq_store_relaxed(sharedCells + index, 0) }
        handledOnset = 0
        readPosition = 0
        origin = 0
        primed = false
        tapSilentFrames = 0
        silentFrames = 0
        isSilenceGated = false
        servo = DriftServo()
    }

    /// In tap frames: what the output reads in one cycle through the resampler, its look-ahead, a
    /// tap buffer of phase slack and 64 frames of scheduling jitter, as ProcessTapEngine's cushion.
    /// Four buffers above it snap back.
    private func cushion(outputFrames: Int, tapFrames: Int) -> (target: Int, ceiling: Int) {
        let reads = Int((Double(outputFrames) * nominalStep * (1 + EQC_RESAMPLER_MAX_CORRECTION)).rounded(.up)) + 1
        let target = reads + lookAhead + tapFrames + 64
        return (target, target + 4 * max(reads, tapFrames))
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, changed: @escaping () -> Bool) {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.state == .running, changed() else { return }
            Log.write("route \(self.targetUID): the target's rate or the tap's format changed")
            self.onInvalidated?()
        }
        if AudioObjectAddPropertyListenerBlock(object, &addr, .main, block) == noErr {
            listeners.append((object, addr, block))
        }
    }

    private func cleanup() {
        if let outputProcID, targetDeviceID != 0 { destroy(outputProcID, on: targetDeviceID, "output") }
        outputProcID = nil
        if let tapProcID, aggregateID != 0 { destroy(tapProcID, on: aggregateID, "tap") }
        tapProcID = nil
        if aggregateID != 0 {
            let status = AudioHardwareDestroyAggregateDevice(aggregateID)
            if status == noErr {
                stranded.forget(device: aggregateID)
            } else {
                Log.write("AudioHardwareDestroyAggregateDevice(\(aggregateID)) failed: \(status)")
            }
            aggregateID = 0
        }
        if tapID != 0 {
            let status = AudioHardwareDestroyProcessTap(tapID)
            if status != noErr { Log.write("AudioHardwareDestroyProcessTap(\(tapID)) failed: \(status)") }
            tapID = 0
        }
        tapDescription = nil
    }

    private func destroy(_ proc: AudioDeviceIOProcID, on device: AudioObjectID, _ role: String) {
        let stopped = AudioDeviceStop(device, proc)
        if stopped != noErr { Log.write("AudioDeviceStop(\(device)) for the route's \(role) IO proc failed: \(stopped)") }
        let destroyed = AudioDeviceDestroyIOProcID(device, proc)
        guard destroyed != noErr else { return }
        Log.write("AudioDeviceDestroyIOProcID(\(device)) for the route's \(role) IO proc failed: \(destroyed)")
        if !StrandedIOProcs.gone(afterDestroy: destroyed) { stranded.add(device: device, proc: proc) }
    }

    private func transition(to newState: State) {
        state = newState
        Log.write("route \(targetUID): \(newState)")
    }

    // MARK: - Tap side (the aggregate's IO thread)

    func renderTap(input: UnsafePointer<AudioBufferList>, inputTime: AudioTimeStamp) {
        tapCallbacks &+= 1
        let inputBuffers = audioBuffers(input)
        var channel = 0
        var frameCount = -1
        for index in 0..<inputBuffers.count {
            let buffer = inputBuffers[index]
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
        if hostValid { eq_stamp_publish(sharedCells, start, Int64(bitPattern: inputTime.mHostTime)) }
        if firstSignalFrame >= 0 {
            if hostValid, tapSilentFrames + firstSignalFrame >= Int(tapRate) / 10 {
                let host = inputTime.mHostTime &+ UInt64(Double(firstSignalFrame) * tapTicksPerFrame)
                eq_stamp_publish(sharedCells + Self.onsetStamp, start + Int64(firstSignalFrame), Int64(bitPattern: host))
            }
            signalCallbacks &+= 1
            tapSilentFrames = 0
        } else {
            tapSilentFrames = min(tapSilentFrames + frameCount, Int(tapRate))
        }
    }

    // MARK: - Output side (the target's IO thread)

    func renderOutput(output: UnsafeMutablePointer<AudioBufferList>, outputTime: AudioTimeStamp) {
        callbacks &+= 1
        let outputList = audioBuffers(output)
        var frameCount = 0
        for index in 0..<outputList.count where outputList[index].mData != nil {
            frameCount = Int(outputList[index].mDataByteSize) / MemoryLayout<Float>.size / max(Int(outputList[index].mNumberChannels), 1)
            break
        }
        guard frameCount > 0, frameCount <= scratchCapacity, let resampler else {
            if frameCount > 0 { outputDropouts &+= 1 }
            zero(outputList)
            return
        }

        let written = ring.written
        let tapFrames = Int(eq_load_relaxed(sharedCells + Self.tapFramesCell))
        var sizes = cushion(outputFrames: frameCount, tapFrames: max(tapFrames, tapBufferFrames))
        sizes = (min(sizes.target, ringLimit), min(sizes.ceiling, ringLimit))
        if !primed {
            guard written - readPosition >= Int64(sizes.target) else {
                zero(outputList)
                return
            }
            restart(at: written - Int64(sizes.target))
        } else if written - readPosition > Int64(sizes.ceiling) {
            overruns &+= 1
            restart(at: written - Int64(sizes.target))
        }

        let needed = Int(eqc_resampler_needed(resampler, Int32(frameCount)))
        let available = Int(max(written - readPosition, 0))
        let count = min(needed, available)
        for channel in 0..<tapChannels { inputPointers[channel] = eqc_resampler_input(resampler, Int32(channel)) }
        ring.copy(from: readPosition, frames: count, into: UnsafeBufferPointer(start: inputPointers, count: tapChannels))
        if count < needed {
            underruns &+= 1
            primed = false
        }
        let position = eqc_resampler_position(resampler)
        let step = eqc_resampler_step(resampler)
        eqc_resampler_produce(resampler, Int32(count), channelPointers, Int32(frameCount))
        readPosition += Int64(count)
        ring.consume(through: readPosition)
        if outputTime.mFlags.contains(.hostTimeValid) {
            steer(position: position, step: step, frames: frameCount, outputHost: outputTime.mHostTime)
        }

        var peak: Float = 0
        for channel in 0..<tapChannels {
            var channelPeak: Float = 0
            vDSP_maxmgv(channelPointers[channel], 1, &channelPeak, vDSP_Length(frameCount))
            peak = max(peak, channelPeak)
        }
        if peak > 0 {
            silentFrames = 0
            isSilenceGated = false
        } else {
            silentFrames = min(silentFrames + frameCount, oneSecondFrames)
            if silentFrames == oneSecondFrames {
                if !isSilenceGated {
                    eqc_reset_render_state(core)
                    isSilenceGated = true
                }
                zero(outputList)
                return
            }
        }
        eqc_process(core, channelPointers, Int32(tapChannels), Int32(frameCount))
        framesProcessed &+= UInt64(frameCount)
        write(outputList, frames: frameCount)
    }

    /// The ring read from `position` on, the resampler from its frame 0, the servo from a new setpoint.
    private func restart(at position: Int64) {
        readPosition = position
        ring.consume(through: position)
        origin = position
        eqc_resampler_reset(resampler!)
        servo.restart()
        eqc_resampler_set_correction(resampler!, servo.correction)
        primed = true
    }

    /// The first output frame of this cycle is ring frame `origin + position`; the tap stamped a
    /// nearby frame's capture, so the gap to `outputHost` is how long eq holds the sound.
    private func steer(position: Double, step: Double, frames: Int, outputHost: UInt64) {
        var stampPosition: Int64 = 0
        var stampHost: Int64 = 0
        if eq_stamp_read(sharedCells, &stampPosition, &stampHost) != 0 {
            let captured = Double(UInt64(bitPattern: stampHost)) + (Double(origin - stampPosition) + position) * tapTicksPerFrame
            let ticks = Double(outputHost) - captured
            if ticks.isFinite, ticks > 0 {
                delayTicks = ticks
                let correction = servo.update(delay: ticks / ticksPerSecond, interval: Double(frames) / outputRate)
                eqc_resampler_set_correction(resampler!, correction)
            }
        }
        let sequence = eq_stamp_read(sharedCells + Self.onsetStamp, &stampPosition, &stampHost)
        guard sequence != 0, sequence != handledOnset else { return }
        let offset = (Double(stampPosition - origin) - position) / step
        guard offset < Double(frames) else { return }
        handledOnset = sequence
        // Before this cycle's first frame: skipped while the ring primed, so it never played.
        guard offset >= 0 else { return }
        onsetTapHost = UInt64(bitPattern: stampHost)
        onsetOutputHost = outputHost &+ UInt64(offset / outputRate * ticksPerSecond)
        onsets &+= 1
    }

    /// Tap channel n to device channel n across the output buffers; silence past the tap's. A mono
    /// device gets the average of the tap's channels.
    private func write(_ outputList: UnsafeMutableBufferPointer<AudioBuffer>, frames frameCount: Int) {
        var zero: Float = 0
        if outputList.count == 1, outputList[0].mNumberChannels == 1, tapChannels > 1, let data = outputList[0].mData {
            let samples = data.assumingMemoryBound(to: Float.self)
            let n = min(Int(outputList[0].mDataByteSize) / MemoryLayout<Float>.size, frameCount)
            vDSP_vclr(samples, 1, vDSP_Length(n))
            var share = 1 / Float(tapChannels)
            for channel in 0..<tapChannels {
                vDSP_vsma(channelPointers[channel], 1, &share, samples, 1, samples, 1, vDSP_Length(n))
            }
            return
        }
        var deviceChannel = 0
        for index in 0..<outputList.count {
            let buffer = outputList[index]
            guard let data = buffer.mData else { continue }
            let channelCount = max(Int(buffer.mNumberChannels), 1)
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channelCount
            let samples = data.assumingMemoryBound(to: Float.self)
            let n = min(frames, frameCount)
            for offset in 0..<channelCount {
                if deviceChannel < tapChannels {
                    vDSP_vsadd(channelPointers[deviceChannel], 1, &zero, samples + offset, vDSP_Stride(channelCount), vDSP_Length(n))
                } else {
                    vDSP_vclr(samples + offset, vDSP_Stride(channelCount), vDSP_Length(n))
                }
                deviceChannel += 1
            }
            if frames > n { vDSP_vclr(samples + n * channelCount, 1, vDSP_Length((frames - n) * channelCount)) }
        }
    }

    private func zero(_ outputList: UnsafeMutableBufferPointer<AudioBuffer>) {
        for index in 0..<outputList.count {
            let buffer = outputList[index]
            guard let data = buffer.mData else { continue }
            vDSP_vclr(data.assumingMemoryBound(to: Float.self), 1, vDSP_Length(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size))
        }
    }
}
