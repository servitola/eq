import XCTest
@testable import eq

final class AudioRingTests: XCTestCase {
    /// Writes `frames` stereo frames whose left sample is the ring position and right its negation.
    @discardableResult
    private func writeCounting(_ ring: AudioRing, frames: Int) -> Int64 {
        let start = ring.written
        let data = (0..<frames).flatMap { [Float(start + Int64($0)), -Float(start + Int64($0))] }
        return data.withUnsafeBufferPointer { buffer in
            let sources = [AudioRing.Source(pointer: buffer.baseAddress!, stride: 2),
                           AudioRing.Source(pointer: buffer.baseAddress! + 1, stride: 2)]
            return sources.withUnsafeBufferPointer { ring.write($0, frames: frames) }
        }
    }

    private func read(_ ring: AudioRing, from position: Int64, frames: Int) -> (left: [Float], right: [Float]) {
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { left.deallocate(); right.deallocate() }
        [left, right].withUnsafeBufferPointer { ring.copy(from: position, frames: frames, into: $0) }
        return (Array(UnsafeBufferPointer(start: left, count: frames)), Array(UnsafeBufferPointer(start: right, count: frames)))
    }

    func testCapacityRoundsUpToAPowerOfTwo() {
        XCTAssertEqual(AudioRing(channels: 2, minimumCapacity: 1000).capacity, 1024)
        XCTAssertEqual(AudioRing(channels: 1, minimumCapacity: 1024).capacity, 1024)
    }

    func testFramesSurviveWraparound() {
        let ring = AudioRing(channels: 2, minimumCapacity: 16)
        writeCounting(ring, frames: 12)
        ring.consume(through: 12)
        let start = writeCounting(ring, frames: 10)
        XCTAssertEqual(start, 12)
        XCTAssertEqual(ring.written, 22)
        let (left, right) = read(ring, from: 12, frames: 10)
        XCTAssertEqual(left, (12..<22).map(Float.init))
        XCTAssertEqual(right, (12..<22).map { -Float($0) })
    }

    func testMissingSourceChannelsAreSilent() {
        let ring = AudioRing(channels: 2, minimumCapacity: 8)
        let mono: [Float] = [1, 2, 3]
        mono.withUnsafeBufferPointer { buffer in
            _ = [AudioRing.Source(pointer: buffer.baseAddress!, stride: 1)].withUnsafeBufferPointer { ring.write($0, frames: 3) }
        }
        let (left, right) = read(ring, from: 0, frames: 3)
        XCTAssertEqual(left, [1, 2, 3])
        XCTAssertEqual(right, [0, 0, 0])
    }

    func testPacerWaitsForTheTargetThenReadsFromIt() {
        var pacer = RingPacer(target: 320, ceiling: 832)
        XCTAssertEqual(pacer.plan(written: 200, read: 0, frames: 128), .init(start: 0, count: 0, event: .none))
        XCTAssertFalse(pacer.primed)
        XCTAssertEqual(pacer.plan(written: 1000, read: 0, frames: 128), .init(start: 680, count: 128, event: .primed))
        XCTAssertTrue(pacer.primed)
        XCTAssertEqual(pacer.plan(written: 1128, read: 808, frames: 128), .init(start: 808, count: 128, event: .none))
    }

    func testFillHoldsAtTheTargetWhenBothSidesKeepPace() {
        var pacer = RingPacer.forBuffers(output: 128, tap: 128)
        XCTAssertEqual(pacer.target, 320)
        var written: Int64 = 0, read: Int64 = 0
        for cycle in 0..<1000 {
            written += 128
            let plan = pacer.plan(written: written, read: read, frames: 128)
            if cycle > 2 {
                XCTAssertEqual(plan.event, .none)
                XCTAssertEqual(written - plan.start, Int64(pacer.target))
            }
            read = plan.start + Int64(plan.count)
        }
    }

    func testUnderrunPlaysWhatIsLeftThenReprimes() {
        var pacer = RingPacer(target: 320, ceiling: 832)
        _ = pacer.plan(written: 320, read: 0, frames: 128)
        XCTAssertEqual(pacer.plan(written: 320, read: 128, frames: 128), .init(start: 128, count: 128, event: .none))
        XCTAssertEqual(pacer.plan(written: 320, read: 256, frames: 128), .init(start: 256, count: 64, event: .underrun))
        XCTAssertFalse(pacer.primed)
        XCTAssertEqual(pacer.plan(written: 400, read: 320, frames: 128), .init(start: 320, count: 0, event: .none))
        XCTAssertEqual(pacer.plan(written: 640, read: 320, frames: 128), .init(start: 320, count: 128, event: .primed))
    }

    func testOverrunDropsTheOldestAndSnapsBackToTheTarget() {
        var pacer = RingPacer(target: 320, ceiling: 832)
        _ = pacer.plan(written: 320, read: 0, frames: 128)
        XCTAssertEqual(pacer.plan(written: 960, read: 128, frames: 128), .init(start: 128, count: 128, event: .none))
        XCTAssertEqual(pacer.plan(written: 1100, read: 256, frames: 128), .init(start: 780, count: 128, event: .overrun))
        XCTAssertTrue(pacer.primed)
    }

    func testCeilingNeverBelowTarget() {
        XCTAssertEqual(RingPacer(target: 300, ceiling: 100).ceiling, 300)
    }

    /// The tap and the output on two threads: every frame the consumer takes must be the frame
    /// written at that position, whole, and positions must only move forward.
    func testConcurrentProducerAndConsumerNeverTear() {
        let ring = AudioRing(channels: 2, minimumCapacity: 4096)
        let total: Int64 = 1_000_000
        let chunk = 128
        let producer = Thread { [self] in
            while ring.written < total {
                if ring.written - ring.read > Int64(ring.capacity / 2) { continue }
                writeCounting(ring, frames: chunk)
            }
        }
        var pacer = RingPacer.forBuffers(output: 96, tap: chunk)
        var failures = 0, reads = 0, last: Int64 = -1
        let left = UnsafeMutablePointer<Float>.allocate(capacity: 96)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: 96)
        defer { left.deallocate(); right.deallocate() }
        let destinations = [left, right]
        producer.start()
        while ring.read < total - 1024 {
            let plan = pacer.plan(written: ring.written, read: ring.read, frames: 96)
            guard plan.count > 0 else { continue }
            destinations.withUnsafeBufferPointer { ring.copy(from: plan.start, frames: plan.count, into: $0) }
            for frame in 0..<plan.count {
                let position = Float(plan.start + Int64(frame))
                if left[frame] != position || right[frame] != -position { failures += 1 }
            }
            if plan.start <= last { failures += 1 }
            last = plan.start
            ring.consume(through: plan.start + Int64(plan.count))
            reads += 1
        }
        while ring.written < total { usleep(100) }
        XCTAssertEqual(failures, 0)
        XCTAssertGreaterThan(reads, 1000)
    }
}
