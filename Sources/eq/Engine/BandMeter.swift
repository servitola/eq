import Foundation

/// Per-band peak meter on the mono sum of the chain's input and output.
final class BandMeter {
    static let floorDB = -60.0
    private static let floorLinear: Float = 1e-3

    let bandCount: Int
    private let frequencies: [Double]
    private let coefficients: UnsafeMutablePointer<BiquadCoefficients>
    // [input bands | output bands]
    private let states: UnsafeMutablePointer<BiquadState>
    private let envelopes: UnsafeMutablePointer<Float>
    private var peakEnvelope: Float = 0
    private var attack: Float = 0
    private var release: Float = 0

    // Readers on the main queue copy these while the audio thread writes them, without a lock:
    // an aligned 8-byte store is atomic on arm64, so a reader sees an old or a new value per band,
    // never a torn one, and a frame mixing two callbacks is invisible at 30 Hz. Raw storage, not
    // [Double], because a reader holding the array would make the audio thread's next element
    // write copy-on-write, which allocates.
    private let levels: UnsafeMutablePointer<Double>
    private var peakLevel: Double = BandMeter.floorDB

    var inputDB: [Double] { Array(UnsafeBufferPointer(start: levels, count: bandCount)) }
    var outputDB: [Double] { Array(UnsafeBufferPointer(start: levels + bandCount, count: bandCount)) }
    var peakDB: Double { peakLevel }

    init(frequencies: [Double]) {
        self.frequencies = frequencies
        bandCount = frequencies.count
        coefficients = .allocate(capacity: bandCount)
        coefficients.initialize(repeating: BiquadCoefficients(), count: bandCount)
        states = .allocate(capacity: 2 * bandCount)
        states.initialize(repeating: BiquadState(), count: 2 * bandCount)
        envelopes = .allocate(capacity: 2 * bandCount)
        envelopes.initialize(repeating: 0, count: 2 * bandCount)
        levels = .allocate(capacity: 2 * bandCount)
        levels.initialize(repeating: BandMeter.floorDB, count: 2 * bandCount)
        configure(sampleRate: 48000)
    }

    deinit {
        coefficients.deallocate()
        states.deallocate()
        envelopes.deallocate()
        levels.deallocate()
    }

    func configure(sampleRate: Double) {
        for band in 0..<bandCount {
            coefficients[band] = BiquadCoefficients.make(
                type: .bandPass, frequency: frequencies[band], gainDB: 0, q: 1.41, sampleRate: sampleRate)
        }
        attack = Float(exp(-1 / (0.010 * sampleRate)))
        release = Float(exp(-1 / (0.300 * sampleRate)))
        reset()
    }

    func reset() {
        states.update(repeating: BiquadState(), count: 2 * bandCount)
        envelopes.update(repeating: 0, count: 2 * bandCount)
        levels.update(repeating: BandMeter.floorDB, count: 2 * bandCount)
        peakEnvelope = 0
        peakLevel = BandMeter.floorDB
    }

    /// Races the audio thread; call only while nothing is rendering.
    func stateForTesting() -> [Float] {
        (0..<(2 * bandCount)).flatMap { [states[$0].z1, states[$0].z2, envelopes[$0]] } + [peakEnvelope]
    }

    /// Audio thread. `input`/`output` are the deinterleaved channels; mono = 0.5*(L+R).
    func feed(input: [UnsafeMutablePointer<Float>], output: [UnsafeMutablePointer<Float>], frameCount: Int) {
        run(channels: input, offset: 0, frameCount: frameCount, trackPeak: false)
        run(channels: output, offset: bandCount, frameCount: frameCount, trackPeak: true)
        for index in 0..<(2 * bandCount) { levels[index] = Self.decibels(envelopes[index]) }
        peakLevel = Self.decibels(peakEnvelope)
        for index in 0..<(2 * bandCount)
            where !envelopes[index].isFinite || !states[index].z1.isFinite || !states[index].z2.isFinite {
            envelopes[index] = 0
            states[index] = BiquadState()
            levels[index] = Self.floorDB
        }
        if !peakEnvelope.isFinite { peakEnvelope = 0; peakLevel = Self.floorDB }
        for index in 0..<(2 * bandCount) {
            states[index].flushDenormals()
            if envelopes[index] < Float.leastNormalMagnitude { envelopes[index] = 0 }
        }
        if peakEnvelope < Float.leastNormalMagnitude { peakEnvelope = 0 }
    }

    private func run(channels: [UnsafeMutablePointer<Float>], offset: Int, frameCount: Int, trackPeak: Bool) {
        guard let first = channels.first else { return }
        let second = channels.count > 1 ? channels[1] : first
        let bandStates = states + offset
        let bandEnvelopes = envelopes + offset
        let attack = attack, release = release
        for frame in 0..<frameCount {
            let mono = 0.5 * (first[frame] + second[frame])
            if trackPeak {
                peakEnvelope = Self.follow(peakEnvelope, max(abs(first[frame]), abs(second[frame])), attack, release)
            }
            for band in 0..<bandCount {
                let y = abs(bandStates[band].process(mono, coefficients[band]))
                bandEnvelopes[band] = Self.follow(bandEnvelopes[band], y, attack, release)
            }
        }
    }

    @inline(__always)
    private static func follow(_ env: Float, _ x: Float, _ attack: Float, _ release: Float) -> Float {
        x > env ? attack * env + (1 - attack) * x : release * env + (1 - release) * x
    }

    private static func decibels(_ envelope: Float) -> Double {
        envelope > floorLinear ? 20 * log10(Double(envelope)) : floorDB
    }
}
