import EQAtomics

/// Single-producer, single-consumer ring of interleaved Float frames: the tap's IOProc writes,
/// the output device's IOProc reads. Positions count frames since the last reset and never
/// wrap, so `written - read` is the fill. Writing and reading never allocate, lock or retain.
final class AudioRing {
    struct Source {
        var pointer: UnsafePointer<Float>
        var stride: Int
    }

    private(set) var channels = 1
    private(set) var capacity = 1
    private var mask: Int64 = 0
    private var samples: UnsafeMutablePointer<Float>
    // `written` at [0], `read` at [cursorGap]: a cache line apart, so each thread's store does not
    // invalidate the line the other one keeps loading.
    private let cursors: UnsafeMutablePointer<Int64>
    private static let cursorGap = 16

    init(channels: Int, minimumCapacity: Int) {
        samples = .allocate(capacity: 1)
        cursors = .allocate(capacity: 2 * Self.cursorGap)
        cursors.initialize(repeating: 0, count: 2 * Self.cursorGap)
        reset(channels: channels, minimumCapacity: minimumCapacity)
    }

    deinit {
        samples.deallocate()
        cursors.deallocate()
    }

    /// Empties the ring and reshapes it. Only while neither IOProc runs: the IOProcs hold this
    /// object for the engine's whole life, so a new shape never means a new object, and the
    /// render threads never pay for a reference count.
    func reset(channels: Int, minimumCapacity: Int) {
        precondition(channels > 0 && minimumCapacity > 0)
        var capacity = 1
        while capacity < minimumCapacity { capacity <<= 1 }
        if capacity * channels != self.capacity * self.channels {
            samples.deallocate()
            samples = .allocate(capacity: capacity * channels)
        }
        samples.initialize(repeating: 0, count: capacity * channels)
        self.channels = channels
        self.capacity = capacity
        mask = Int64(capacity - 1)
        eq_store_release(cursors, 0)
        eq_store_release(cursors + Self.cursorGap, 0)
    }

    var written: Int64 { eq_load_acquire(cursors) }
    var read: Int64 { eq_load_acquire(cursors + Self.cursorGap) }

    /// Producer only. `sources` holds one entry per channel; returns the position of the first frame.
    @discardableResult
    func write(_ sources: UnsafeBufferPointer<Source>, frames: Int) -> Int64 {
        let start = eq_load_relaxed(cursors)
        let count = min(sources.count, channels)
        for frame in 0..<frames {
            let slot = samples + Int((start + Int64(frame)) & mask) * channels
            for channel in 0..<count {
                let source = sources[channel]
                slot[channel] = source.pointer[frame * source.stride]
            }
            for channel in count..<channels { slot[channel] = 0 }
        }
        eq_store_release(cursors, start + Int64(frames))
        return start
    }

    /// Consumer only. Copies `frames` frames starting at `position` into one buffer per channel,
    /// beginning at `offset` in each.
    func copy(from position: Int64, frames: Int, into destinations: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
              offset: Int = 0) {
        let count = min(destinations.count, channels)
        for frame in 0..<frames {
            let slot = samples + Int((position + Int64(frame)) & mask) * channels
            for channel in 0..<count { destinations[channel][offset + frame] = slot[channel] }
        }
    }

    /// Consumer only: everything before `position` may be overwritten.
    func consume(through position: Int64) {
        eq_store_release(cursors + Self.cursorGap, position)
    }
}

/// Where the output IOProc reads next. The tap and the output run on one clock but on two IO
/// threads whose order within a cycle can flip, so the ring keeps a cushion: `target` frames at
/// each read. Too few frames is an underrun (silence for the gap, then wait to refill to the
/// target); more than `ceiling` means delay piled up after a stall, and the oldest frames go.
struct RingPacer: Equatable {
    enum Event: Equatable {
        case none, primed, underrun, overrun
    }

    struct Plan: Equatable {
        var start: Int64
        var count: Int
        var event: Event
    }

    let target: Int
    let ceiling: Int
    private(set) var primed = false

    init(target: Int, ceiling: Int) {
        self.target = target
        self.ceiling = max(ceiling, target)
    }

    /// `outputFrames` to read, `tapFrames` of phase slack because the tap delivers whole buffers,
    /// 64 frames of scheduling jitter: the cushion measured at 12.8 ms end to end with 128-frame
    /// buffers at 44.1 kHz. Four buffers of drift or a stall's backlog above it snap back.
    static func forBuffers(output outputFrames: Int, tap tapFrames: Int) -> RingPacer {
        let target = outputFrames + tapFrames + 64
        return RingPacer(target: target, ceiling: target + 4 * max(outputFrames, tapFrames))
    }

    mutating func plan(written: Int64, read: Int64, frames: Int) -> Plan {
        let fill = written - read
        guard primed else {
            guard fill >= Int64(target) else { return Plan(start: read, count: 0, event: .none) }
            primed = true
            return Plan(start: written - Int64(target), count: min(frames, target), event: .primed)
        }
        if fill > Int64(ceiling) {
            return Plan(start: written - Int64(target), count: min(frames, target), event: .overrun)
        }
        if fill < Int64(frames) {
            primed = false
            return Plan(start: read, count: Int(max(fill, 0)), event: .underrun)
        }
        return Plan(start: read, count: frames, event: .none)
    }

    mutating func reset() { primed = false }
}
