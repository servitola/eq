import EQTerm
import Foundation
@testable import eq

/// The meter program on the real `Runtime`, woken by a script instead of `poll`: each line is
/// one meter socket read ("" for a wake-up with no frame), followed by what `readKey` returns
/// for that wake-up, as whole keys. A frame is drawn as it arrives; keys that came with no
/// frame are drawn at once. The source ending is the daemon closing the socket.
struct MeterRun {
    /// Each drawn screen as the painted lines the view drew from.
    var drawn: [String] = []
    /// Whether that screen was drawn whole (a resize, a resume) rather than as a diff.
    var whole: [Bool] = []
    var code: Int32 = 0
}

enum MeterHarness {
    static func run(lines: [String], size: () -> (Int, Int) = { (80, 24) }, zones: Bool = false,
                    readKey: () -> String?, edit: (WatchAction) throws -> Void = { _ in },
                    header: () -> Watch.Header = { Watch.Header() }, send: (String) throws -> Void = { _ in },
                    invalidated: () -> Bool = { false }, mouse: (Bool) -> Void = { _ in }) -> MeterRun {
        withoutActuallyEscaping(edit) { edit in
            withoutActuallyEscaping(header) { header in
                withoutActuallyEscaping(send) { send in
                    withoutActuallyEscaping(mouse) { mouse in
                        script(lines: lines, size: size, zones: zones, readKey: readKey, invalidated: invalidated,
                               effects: MeterEffects(edit: edit, header: header, send: send, mouse: mouse, connect: { nil }))
                    }
                }
            }
        }
    }

    private static func script(lines: [String], size: () -> (Int, Int), zones: Bool, readKey: () -> String?,
                               invalidated: () -> Bool, effects: MeterEffects) -> MeterRun {
        var result = MeterRun()
        var written: [UInt8] = []
        let (cols, rows) = size()
        let runtime = Runtime(MeterModel(size: Size(cols: cols, rows: rows), zones: zones, header: effects.header()),
                              size: Size(cols: cols, rows: rows), translate: MeterEffects.translate,
                              perform: effects.perform, output: { written = $0 })
        func draw() {
            written = []
            guard runtime.program.last != nil, runtime.render() else { return }
            result.drawn.append((runtime.program.lines() ?? []).joined(separator: "\n"))
            result.whole.append(String(decoding: written, as: UTF8.self).contains(Renderer.clear))
        }
        runtime.send(.start)
        for line in lines {
            let now = size()
            if Size(cols: now.0, rows: now.1) != runtime.size { runtime.handle(.resize(Size(cols: now.0, rows: now.1))) }
            if invalidated() { runtime.handle(.redraw) }
            let isFrame = MeterEffects.translate(.line(source: MeterEffects.meterSource, line)) != nil
            if isFrame {
                runtime.handle(.line(source: MeterEffects.meterSource, line))
                draw()
            }
            if runtime.finished { break }
            if let keys = readKey() {
                for event in InputParser.events(in: keys) {
                    runtime.handle(.input(event))
                    if runtime.finished { break }
                }
            }
            if runtime.finished { break }
            if !isFrame { draw() }
        }
        if !runtime.finished { runtime.handle(.closed(source: MeterEffects.meterSource)) }
        result.code = runtime.exitCode ?? 1
        return result
    }
}
