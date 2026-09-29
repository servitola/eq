import EQTerm
import Foundation
@testable import eq

/// The meter program on the real `Runtime`, woken by a script instead of `poll`: each line is
/// one meter socket read ("" for a wake-up with no frame), followed by what `readKey` returns
/// for that wake-up, as whole keys. A frame is drawn as it arrives; keys that came with no
/// frame are drawn at once. The source ending is the daemon closing the socket.
struct MeterRun {
    /// Each drawn screen as text, and with its styled runs marked.
    var drawn: [String] = []
    var styled: [String] = []
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
            var screen = Screen(runtime.size)
            runtime.program.view(into: &screen)
            result.drawn.append(screen.lines().joined(separator: "\n"))
            result.styled.append(screen.markedLines().joined(separator: "\n"))
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

/// One meter screen from a frame and the state around it, as `MeterModel` would draw it.
enum MeterScreens {
    static func scene(_ f: MeterFrame, cols: Int, rows: Int, strip: Bool = false, focus: Instrument? = nil, modal: WatchModal? = nil,
                      flash: Int? = nil, note: String? = nil, preset: Table.PresetMark? = nil, preference: Preference? = nil,
                      knobs: [String: Double]? = nil, dynamics: Dynamics? = nil, prompt: TextField? = nil, listening: Bool = false,
                      look: Look = .studio, depth: ColorDepth = .none) -> MeterScene {
        var scene = MeterScene(frame: f, size: Size(cols: cols, rows: rows))
        scene.strip = strip
        scene.focus = focus
        scene.modal = modal
        scene.flash = flash.map { ($0, Watch.flashFrames + MeterScene.flashBlendFrames) }
        scene.message = note.map { MeterScene.Message(text: $0, kind: .warn) }
        scene.header = Watch.Header(preset: preset, preference: preference, knobs: knobs, dynamics: dynamics)
        scene.prompt = prompt
        scene.listening = listening
        scene.limiting = f.limiting
        scene.settings.look = look
        scene.settings.depth = depth
        return scene
    }

    static func screen(_ scene: MeterScene) -> Screen {
        var screen = Screen(scene.size)
        scene.draw(into: &screen)
        return screen
    }

    static func lines(_ f: MeterFrame, cols: Int, rows: Int, strip: Bool = false, focus: Instrument? = nil, modal: WatchModal? = nil,
                      note: String? = nil, preset: Table.PresetMark? = nil, preference: Preference? = nil,
                      knobs: [String: Double]? = nil, dynamics: Dynamics? = nil) -> [String] {
        screen(scene(f, cols: cols, rows: rows, strip: strip, focus: focus, modal: modal, note: note, preset: preset,
                     preference: preference, knobs: knobs, dynamics: dynamics)).lines()
    }
}
