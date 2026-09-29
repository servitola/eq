// Real-time analysis inside an IOProc. Everything is preallocated; results are read only after
// AudioDeviceStop has returned, which the HAL guarantees ends the callbacks, so nothing is atomic.
import CoreAudio
import Foundation

final class Meter: @unchecked Sendable {
    let rate: Double
    let freqs: [Double]
    let nonInterleaved: Bool
    static let maxFrames = 16384
    let stereo = UnsafeMutablePointer<Float>.allocate(capacity: 2 * maxFrames)
    var stereoFrames = 0

    // Totals
    var callbacks = 0
    var emptyCallbacks = 0
    var frames = 0
    var firstCallbackHost = 0.0
    var firstInputHost = 0.0
    var lastInputEnd = 0.0
    var peak: Float = 0
    var sumSquares = 0.0

    /// The first sample above −80 dBFS: when the tap first carried sound.
    var firstSignal: (input: Double, output: Double, callback: Double)?

    // Onsets: first sample after ≥100 ms below −80 dBFS, the click method of scripts/measure-latency.sh.
    static let silence: Float = 1e-4
    var quiet = 0
    let onsetCapacity = 256
    let onsets: UnsafeMutablePointer<(input: Double, output: Double, callback: Double)>
    var onsetCount = 0

    // HAL-reported discontinuities: input sample time not following on from the previous callback.
    var expectedSampleTime = -1.0
    var sampleTimeGaps = 0
    var firstGaps: [Double] = []

    // Glitches: the signal through a cascade of FIR notches, one per tone frequency. A clean sum of
    // those sines leaves ~0; a dropped/inserted sample or a zero run leaves a spike.
    let notchCoeff: [Float]
    var notchState: [Float]
    let thresholds: [Float] = [5e-4, 2e-3, 1e-2]
    var residualCounts = [0, 0, 0]
    var residualHold = 0
    var residualPeak: Float = 0
    var residualEvents: [(time: Double, size: Float)] = []
    var armed = false

    // Dropouts: ≥32 samples of digital near-silence after the signal started.
    var zeroRun = 0
    var zeroRuns = 0
    var longestZeroRun = 0

    // Zero crossings on channel 0, for a frequency estimate independent of the rate we assume.
    var lastSample: Float = 0
    var crossings = 0
    var firstCrossing = -1
    var lastCrossing = -1

    // Timeline: 10 ms Hann-windowed Goertzel amplitude per frequency, plus RMS.
    let blockSize: Int
    let window: UnsafeMutablePointer<Float>
    let windowSum: Float
    let goertzelCoeff: [Float]
    var s1: [Float], s2: [Float]
    var blockPos = 0
    var blockSquares: Float = 0
    var blockStart = 0.0
    let blockCapacity = 30000
    let blockTimes: UnsafeMutablePointer<Double>
    let blockAmps: UnsafeMutablePointer<Float>
    let blockRMS: UnsafeMutablePointer<Float>
    var blockCount = 0

    init(rate: Double, freqs: [Double], nonInterleaved: Bool) {
        self.rate = rate
        self.freqs = freqs
        self.nonInterleaved = nonInterleaved
        onsets = .allocate(capacity: onsetCapacity)
        notchCoeff = freqs.map { Float(2 * cos(2 * Double.pi * $0 / rate)) }
        notchState = [Float](repeating: 0, count: 2 * freqs.count)
        blockSize = max(Int(rate / 100), 64)
        window = .allocate(capacity: blockSize)
        var sum: Float = 0
        for i in 0..<blockSize {
            let w = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(blockSize - 1)))
            window[i] = w
            sum += w
        }
        windowSum = sum
        goertzelCoeff = freqs.map { Float(2 * cos(2 * Double.pi * $0 / rate)) }
        s1 = [Float](repeating: 0, count: freqs.count)
        s2 = [Float](repeating: 0, count: freqs.count)
        blockTimes = .allocate(capacity: blockCapacity)
        blockAmps = .allocate(capacity: blockCapacity * max(freqs.count, 1))
        blockRMS = .allocate(capacity: blockCapacity)
        residualEvents.reserveCapacity(64)
        firstGaps.reserveCapacity(16)
    }

    static func zero(_ output: UnsafeMutablePointer<AudioBufferList>) {
        for buffer in UnsafeMutableAudioBufferListPointer(output) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
    }

    /// The tap is the aggregate's last input stream: a sub-device's own inputs, if any, come first.
    private func extract(_ input: UnsafePointer<AudioBufferList>) -> Int {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard list.count > 0 else { return 0 }
        if nonInterleaved {
            let right = list[list.count - 1]
            let left = list.count > 1 ? list[list.count - 2] : right
            guard let l = left.mData, let r = right.mData else { return 0 }
            let n = min(Int(left.mDataByteSize) / 4, Meter.maxFrames)
            let lp = l.assumingMemoryBound(to: Float.self), rp = r.assumingMemoryBound(to: Float.self)
            for f in 0..<n { stereo[2 * f] = lp[f]; stereo[2 * f + 1] = rp[f] }
            return n
        }
        let buffer = list[list.count - 1]
        guard let data = buffer.mData else { return 0 }
        let channels = max(Int(buffer.mNumberChannels), 1)
        let n = min(Int(buffer.mDataByteSize) / 4 / channels, Meter.maxFrames)
        let p = data.assumingMemoryBound(to: Float.self)
        for f in 0..<n {
            stereo[2 * f] = p[f * channels]
            stereo[2 * f + 1] = p[f * channels + (channels > 1 ? 1 : 0)]
        }
        return n
    }

    func process(_ input: UnsafePointer<AudioBufferList>, _ inputTime: AudioTimeStamp, _ outputTime: AudioTimeStamp?,
                 callbackHost: UInt64) {
        callbacks += 1
        let callback = seconds(callbackHost)
        if callbacks == 1 { firstCallbackHost = callback }
        let n = extract(input)
        stereoFrames = n
        guard n > 0 else { emptyCallbacks += 1; return }
        let inputHost = seconds(inputTime.mHostTime)
        let outputHost = outputTime.map { seconds($0.mHostTime) } ?? 0
        if firstInputHost == 0 { firstInputHost = inputHost }
        lastInputEnd = inputHost + Double(n) / rate

        if inputTime.mFlags.contains(.sampleTimeValid) {
            if expectedSampleTime >= 0, abs(inputTime.mSampleTime - expectedSampleTime) > 0.5 {
                sampleTimeGaps += 1
                if firstGaps.count < 16 { firstGaps.append(inputTime.mSampleTime - expectedSampleTime) }
            }
            expectedSampleTime = inputTime.mSampleTime + Double(n)
        }

        let limit = Int(0.1 * rate)
        for f in 0..<n {
            let x = stereo[2 * f]
            let magnitude = abs(x)
            let t = inputHost + Double(f) / rate
            peak = max(peak, magnitude)
            sumSquares += Double(x * x)

            if magnitude > Meter.silence {
                if firstSignal == nil {
                    firstSignal = (t, outputTime == nil ? 0 : outputHost + Double(f) / rate, callback)
                }
                if quiet >= limit, onsetCount < onsetCapacity {
                    onsets[onsetCount] = (t, outputTime == nil ? 0 : outputHost + Double(f) / rate, callback)
                    onsetCount += 1
                }
                quiet = 0
                armed = true
            } else {
                quiet = min(quiet + 1, limit)
            }

            if armed {
                if magnitude < 1e-6 { zeroRun += 1 } else {
                    if zeroRun >= 32 { zeroRuns += 1 }
                    longestZeroRun = max(longestZeroRun, zeroRun)
                    zeroRun = 0
                }
            }

            var y = x
            for k in 0..<notchCoeff.count {
                let a = notchState[2 * k], b = notchState[2 * k + 1]
                let out = y - notchCoeff[k] * a + b
                notchState[2 * k + 1] = a
                notchState[2 * k] = y
                y = out
            }
            if armed, !notchCoeff.isEmpty {
                let r = abs(y)
                residualPeak = max(residualPeak, r)
                if residualHold > 0 { residualHold -= 1 } else if r > thresholds[0] {
                    for i in 0..<thresholds.count where r > thresholds[i] { residualCounts[i] += 1 }
                    if residualEvents.count < 64 { residualEvents.append((t, r)) }
                    residualHold = 64
                }
            }

            if lastSample <= 0, x > 0 {
                crossings += 1
                if firstCrossing < 0 { firstCrossing = frames + f }
                lastCrossing = frames + f
            }
            lastSample = x

            if blockPos == 0 { blockStart = t }
            let w = window[blockPos]
            for k in 0..<goertzelCoeff.count {
                let s = x * w + goertzelCoeff[k] * s1[k] - s2[k]
                s2[k] = s1[k]
                s1[k] = s
            }
            blockSquares += x * x
            blockPos += 1
            if blockPos == blockSize {
                if blockCount < blockCapacity {
                    blockTimes[blockCount] = blockStart
                    for k in 0..<goertzelCoeff.count {
                        let power = s1[k] * s1[k] + s2[k] * s2[k] - goertzelCoeff[k] * s1[k] * s2[k]
                        blockAmps[blockCount * freqs.count + k] = 2 * sqrt(max(power, 0)) / windowSum
                    }
                    blockRMS[blockCount] = sqrt(blockSquares / Float(blockSize))
                    blockCount += 1
                }
                for k in 0..<goertzelCoeff.count { s1[k] = 0; s2[k] = 0 }
                blockSquares = 0
                blockPos = 0
            }
        }
        frames += n
    }

    func write(to output: UnsafeMutablePointer<AudioBufferList>) {
        let n = stereoFrames
        for buffer in UnsafeMutableAudioBufferListPointer(output) {
            guard let data = buffer.mData else { continue }
            let channels = max(Int(buffer.mNumberChannels), 1)
            let capacity = Int(buffer.mDataByteSize) / 4 / channels
            let out = data.assumingMemoryBound(to: Float.self)
            for f in 0..<capacity {
                for c in 0..<channels { out[f * channels + c] = f < n ? stereo[2 * f + (c & 1)] : 0 }
            }
        }
    }

    // MARK: - Reading results (after stop)

    var rms: Double { frames > 0 ? sqrt(sumSquares / Double(frames)) : 0 }

    /// Rate the tap actually delivered, from host time: catches a format that lies about its rate.
    var measuredRate: Double {
        lastInputEnd > firstInputHost ? Double(frames) / (lastInputEnd - firstInputHost) : 0
    }

    var estimatedFrequency: Double {
        guard crossings > 2, lastCrossing > firstCrossing else { return 0 }
        return Double(crossings - 1) / (Double(lastCrossing - firstCrossing) / rate)
    }

    func amp(_ block: Int, _ k: Int) -> Float { blockAmps[block * freqs.count + k] }

    /// Median amplitude of frequency k over blocks whose start lies in [from, to).
    func level(_ k: Int, from: Double, to: Double) -> Float {
        var values: [Float] = []
        for b in 0..<blockCount where blockTimes[b] >= from && blockTimes[b] < to { values.append(amp(b, k)) }
        guard !values.isEmpty else { return -1 }
        values.sort()
        return values[values.count / 2]
    }

    func maxLevel(_ k: Int, from: Double, to: Double) -> Float {
        var result: Float = -1
        for b in 0..<blockCount where blockTimes[b] >= from && blockTimes[b] < to { result = max(result, amp(b, k)) }
        return result
    }

    /// First block at or after `from` whose amplitude at k crosses `threshold` in the given direction.
    func firstBlock(_ k: Int, from: Double, above threshold: Float) -> Double? {
        for b in 0..<blockCount where blockTimes[b] >= from && amp(b, k) > threshold { return blockTimes[b] }
        return nil
    }

    func firstBlock(_ k: Int, from: Double, below threshold: Float) -> Double? {
        for b in 0..<blockCount where blockTimes[b] >= from && amp(b, k) < threshold { return blockTimes[b] }
        return nil
    }

    var silentBlockFraction: Double {
        guard blockCount > 0 else { return 1 }
        var silent = 0
        for b in 0..<blockCount where blockRMS[b] < 1e-6 { silent += 1 }
        return Double(silent) / Double(blockCount)
    }

    func quality() -> String {
        let events = residualEvents.prefix(8).map { String(format: "%.3fs/%.4f", $0.time - firstInputHost, $0.size) }
        return """
        callbacks \(callbacks) (\(emptyCallbacks) empty), frames \(frames), measured rate \(String(format: "%.1f", measuredRate)) Hz, \
        HAL sample-time gaps \(sampleTimeGaps)\(firstGaps.isEmpty ? "" : " \(firstGaps.prefix(4))"), \
        glitches >5e-4/>2e-3/>1e-2: \(residualCounts[0])/\(residualCounts[1])/\(residualCounts[2]) (residual peak \(String(format: "%.5f", residualPeak))), \
        dropouts ≥32 samples: \(zeroRuns) (longest \(longestZeroRun)), peak \(db(Double(peak))), rms \(db(rms))\
        \(events.isEmpty ? "" : "\n    first glitches (s from first input / size): \(events.joined(separator: " "))")
        """
    }
}
