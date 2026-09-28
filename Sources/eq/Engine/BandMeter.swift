import EQCore
import Foundation

/// Per-band peak meter on the mono sum of the chain's input and output, run by EQCore.
final class BandMeter {
    static let floorDB = EQC_METER_FLOOR_DB

    let bandCount: Int
    private let meter: OpaquePointer
    // The memory the meter lives in: its own, or the engine's it belongs to.
    private let storage: CoreStorage

    init(frequencies: [Double]) {
        storage = CoreStorage(size: eqc_meter_size())
        meter = OpaquePointer(storage.pointer)
        eqc_meter_init(meter, frequencies, Int32(frequencies.count))
        bandCount = Int(eqc_meter_band_count(meter))
    }

    init(_ meter: OpaquePointer, in storage: CoreStorage) {
        self.meter = meter
        self.storage = storage
        bandCount = Int(eqc_meter_band_count(meter))
    }

    private func levels() -> (input: [Double], output: [Double], peak: Double) {
        var input = [Double](repeating: 0, count: bandCount), output = input, peak = 0.0
        eqc_meter_read(meter, &input, &output, &peak)
        return (input, output, peak)
    }

    var inputDB: [Double] { levels().input }
    var outputDB: [Double] { levels().output }
    var peakDB: Double { levels().peak }

    func configure(sampleRate: Double) { eqc_meter_configure(meter, sampleRate) }

    func reset() { eqc_meter_reset(meter) }

    /// Races the audio thread; call only while nothing is rendering.
    func stateForTesting() -> [Float] {
        var state = [Float](repeating: 0, count: 6 * bandCount + 1)
        state.removeLast(state.count - Int(eqc_meter_render_state(meter, &state, Int32(state.count))))
        return state
    }

    /// Audio thread. `input`/`output` are the deinterleaved channels; mono = 0.5*(L+R).
    func feed(input: [UnsafeMutablePointer<Float>], output: [UnsafeMutablePointer<Float>], frameCount: Int) {
        eqc_meter_feed(meter, input, Int32(input.count), output, Int32(output.count), Int32(frameCount))
    }
}

/// Raw memory for an EQCore object, 16-byte aligned, freed with the last reference to it.
final class CoreStorage {
    let pointer: UnsafeMutableRawPointer

    init(size: Int) {
        pointer = .allocate(byteCount: size, alignment: 16)
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: size)
    }

    deinit { pointer.deallocate() }
}
