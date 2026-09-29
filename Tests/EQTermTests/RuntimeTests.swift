import Darwin
import EQTerm
import XCTest

/// A program just big enough to drive the runtime: keys, lines, a timer, effects that answer.
private struct Counter: Program {
    enum Msg: Equatable { case key(Character), line(String), closed, tick, echoed(Int) }
    enum Cmd: Equatable { case echo(Int), after(Double), quit }

    var count = 0
    var lines: [String] = []
    var log: [Msg] = []

    mutating func update(_ msg: Msg) -> [Cmd] {
        log.append(msg)
        switch msg {
        case .key("+"):
            count += 1
            return [.echo(count)]
        case .key("t"): return [.after(0.01)]
        case .key("q"), .tick, .closed: return [.quit]
        case .line(let text): lines.append(text)
        default: break
        }
        return []
    }

    func view(into screen: inout Screen) {
        screen.put("count \(count)", x: 0, y: 0)
    }
}

final class RuntimeTests: XCTestCase {
    private func runtime(_ output: @escaping ([UInt8]) -> Void = { _ in }) -> Runtime<Counter> {
        Runtime(Counter(), size: Size(cols: 20, rows: 2), translate: { event in
            switch event {
            case .input(.key(let key)): if case .char(let c) = key.code { return .key(c) } else { return nil }
            case .line(_, let text): return .line(text)
            case .closed: return .closed
            case .timer: return .tick
            default: return nil
            }
        }, perform: { cmd, runtime in
            switch cmd {
            case .echo(let n): return [.echoed(n)]
            case .after(let seconds):
                runtime.after(seconds, id: 1)
                return []
            case .quit:
                runtime.quit(0)
                return []
            }
        }, output: output)
    }

    private func pipePair() -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        return (fds[0], fds[1])
    }

    func testACommandsAnswerIsHandledBeforeTheNextMessage() {
        let r = runtime()
        r.input(Array("++".utf8))
        XCTAssertEqual(r.program.log, [.key("+"), .echoed(1), .key("+"), .echoed(2)])
    }

    func testTheLoopReadsKeysAndOnlyTheLatestLineAndDrawsOnce() {
        var written: [[UInt8]] = []
        let r = runtime { written.append($0) }
        let input = pipePair(), meter = pipePair()
        defer { [input.read, input.write, meter.read, meter.write].forEach { close($0) } }
        r.inputFD = input.read
        r.watch(fd: meter.read, id: 7, latestOnly: true)
        _ = write(meter.write, "a\nb\nc\n", 6)
        _ = write(input.write, "++q", 3)
        XCTAssertEqual(r.run(), 0)
        XCTAssertEqual(r.program.lines, ["c"], "a meter that fell behind is not replayed")
        XCTAssertEqual(r.program.count, 2)
        XCTAssertEqual(written.count, 1, "the first frame; the wake-up that quit draws nothing")
    }

    func testTimersAndAClosedSourceWakeTheLoop() {
        let r = runtime()
        let input = pipePair()
        defer { close(input.read); close(input.write) }
        r.inputFD = input.read
        _ = write(input.write, "t", 1)
        let started = Date()
        XCTAssertEqual(r.run(), 0)
        XCTAssertEqual(r.program.log.last, .tick)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)

        let closing = runtime()
        let meter = pipePair()
        close(meter.write)
        defer { close(meter.read) }
        closing.inputFD = input.read
        closing.watch(fd: meter.read, id: 3)
        XCTAssertEqual(closing.run(), 0)
        XCTAssertEqual(closing.program.log.last, .closed)
    }

    func testAnUnchangedModelIsNotDrawnAgain() {
        var written = 0
        let r = runtime { _ in written += 1 }
        XCTAssertTrue(r.render())
        XCTAssertFalse(r.render(), "nothing changed")
        r.input(Array("x".utf8))
        XCTAssertTrue(r.render())
        XCTAssertEqual(written, 1, "an update that changed no cell writes no bytes")
    }
}
