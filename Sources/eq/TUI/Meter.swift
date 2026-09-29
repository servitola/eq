import EQTerm
import Foundation

enum MeterMsg {
    /// Sets the terminal's mouse reporting to the saved setting and opens the events connection.
    case start
    case frame(MeterFrame)
    case input(InputEvent)
    case resize(Size)
    case header(Watch.Header)
    /// An edit was saved, or `failure` says why not.
    case edited(WatchAction, failure: String?)
    case sendFailed
    case meterClosed
    case retry
    case connected
    case connectFailed
    case event(EventEntry)
    case eventsClosed
    case eventsRetry
    case eventsConnected
    case eventsConnectFailed
    case completions(Completions.Kind, [String])
    case childOutput(String)
    /// The command's output ended; the runtime reaps it next.
    case childClosed
    case childExit(Int32)
    /// SIGINT, SIGTERM or SIGHUP: leave as `q` does.
    case signal
}

enum MeterCmd: Equatable {
    case edit(WatchAction)
    /// The next frame is written whole: a new look or palette changes nearly every cell.
    case redraw
    case send(String)
    case refreshHeader
    case mouse(Bool)
    case retry(after: Double)
    case connect
    /// Closes the meter connection: no view on screen draws levels.
    case disconnect
    case connectEvents
    case retryEvents(after: Double)
    case complete(Completions.Kind)
    /// `eq` with these words as a child process, its output laid out for `columns`.
    case run([String], columns: Int)
    case stop
    case reap
    case saveHistory([String])
    case quit(Int32)
}

/// The TUI as a program: every piece of state the old frame loop kept in captured variables, the
/// views and their menus, and `update`, which never touches a file or a socket.
struct MeterModel: Program {
    struct Countdown<T: Equatable>: Equatable {
        var value: T
        /// Frames still to show it; it shows on the frame that takes this to 0 too.
        var left: Int
    }

    var size: Size
    var strip: Bool
    var focus: Int?
    var listening = false
    var modal: WatchModal?
    var flash: Countdown<Int>?
    var note: Countdown<MeterScene.Message>?
    var prompt: TextField?
    var header: Watch.Header
    /// What the terminal was last told about mouse reporting.
    var mouseOn = false
    var framesSinceMark = 0
    var last: MeterFrame?
    /// The rate the current solo was asked at; nil while it waits for one.
    var requestedAt: Double?
    /// `eq tui` reconnects when the daemon goes; `eq watch` ends with exit 1, as it always has.
    var reconnects: Bool
    /// The wait before the next attempt while the daemon is gone.
    var retry: Double?
    var look: LookSettings
    /// Each band's peak tick and the frames it still holds before it falls.
    var peaks: [Double] = []
    private var holds: [Int] = []
    var outputPeak = Watch.floorDB
    private var outputHold = 0
    /// Frames LIMIT stays lit after the daemon last reported limiting.
    private var limitLeft = 0
    let curve = CurveCache()
    let chainCurve = ChainCurve()

    var view = TUIView.meter
    /// Where Esc goes back to, most recent last.
    var stack: [TUIView] = []
    var goMenu = false
    /// The Instruments view's row.
    var selected = 0
    /// The meter connection is open.
    var meterOpen = true
    var events = EventLog()
    var eventsRetry: Double?
    var palette: CommandPalette?
    var paletteValues: [Completions.Kind: [String]] = [:]
    private var asked: Set<String> = []
    var history: [String]
    var child: ChildOutput?
    var filterField: TextField?
    var tune = TuneState()
    /// The Tune view's value typed in the message row.
    var entry: TextField?
    /// Whether the last update changed what the screen shows.
    private(set) var needsRedraw = true

    init(size: Size, zones: Bool = false, header: Watch.Header = Watch.Header(), reconnects: Bool = false,
         look: LookSettings = LookSettings(), view: TUIView = .meter, history: [String] = []) {
        self.size = size
        strip = zones
        self.header = header
        self.reconnects = reconnects
        self.look = look
        self.view = view
        self.history = history
    }

    /// IEC 60268-10 Type I return: 20 dB in 1.7 s. No standard names a hold; 1.5 s is the convention.
    static let peakHoldFrames = 45
    static let peakFall = 20 / 1.7 / 30
    static let limitFrames = 10
    static let stackLimit = 16

    var focused: Instrument? { focus.map { Instruments.all[$0] } }

    /// Levels are on screen, or a solo sounds that only the meter connection holds.
    var wantsMeter: Bool { view.showsLevels || listening }

    static let firstRetry = 0.5
    static let lastRetry = 4.0

    mutating func update(_ msg: MeterMsg) -> [MeterCmd] {
        needsRedraw = true
        switch msg {
        case .start:
            return syncMouse() + [.connectEvents]
        case .frame(let f):
            return frame(f)
        case .input(let event):
            return input(event)
        case .resize(let new):
            size = new
            return []
        case .header(let new):
            header = new
            framesSinceMark = 0
            return syncMouse()
        case .edited(let action, let failure):
            if let failure {
                show(failure.split(separator: "\n").first.map(String.init) ?? "", failure.hasPrefix("nothing left") ? .warn : .error)
            } else if let band = Self.band(action) {
                flash = Countdown(value: band, left: Watch.flashFrames + MeterScene.flashBlendFrames)
            }
            return [.refreshHeader]
        case .sendFailed:
            // A failed send most likely means the socket is gone, and the daemon clears the solo then.
            show(Watch.listenFailed, .error)
            listening = false
            return []
        case .meterClosed:
            meterOpen = false
            // The socket is gone, and the daemon dropped the solo with it: nothing to send.
            guard reconnects else {
                listening = false
                return [.quit(1)]
            }
            requestedAt = nil
            retry = Self.firstRetry
            return [.retry(after: Self.firstRetry)]
        case .retry:
            guard wantsMeter else {
                retry = nil
                return []
            }
            return [.connect]
        case .connected:
            retry = nil
            meterOpen = true
            return []
        case .connectFailed:
            let next = min((retry ?? Self.firstRetry) * 2, Self.lastRetry)
            retry = next
            return [.retry(after: next)]
        case .event(let entry):
            return event(entry)
        case .eventsClosed:
            eventsRetry = Self.firstRetry
            return [.retryEvents(after: Self.firstRetry)]
        case .eventsRetry:
            return [.connectEvents]
        case .eventsConnected:
            eventsRetry = nil
            return []
        case .eventsConnectFailed:
            let next = min((eventsRetry ?? Self.firstRetry / 2) * 2, Self.lastRetry)
            eventsRetry = next
            return [.retryEvents(after: next)]
        case .completions(let kind, let words):
            paletteValues[kind] = words
            return []
        case .childOutput(let line):
            guard var output = child else { return [] }
            output.lines.append(line)
            if output.lines.count > ChildOutput.limit { output.lines.removeFirst() }
            if output.lines.count > 1 { output.shown = true }
            child = output
            return []
        case .childClosed:
            return [.reap]
        case .childExit(let code):
            return exited(code)
        case .signal:
            return quit(0)
        }
    }

    /// The note, error or prompt of the moment lasts `noteFrames`; under it a running command
    /// says so, and while the daemon is gone the reconnect message stays. On the Tune view an
    /// empty row says what the selected control is and how it moves.
    var message: MeterScene.Message? {
        if let note { return note.value }
        if let child, child.status == nil, !child.shown { return MeterScene.Message(text: "running eq \(child.command) …") }
        if retry != nil && wantsMeter { return MeterScene.Message(text: Watch.reconnecting, kind: .warn) }
        return view == .tune ? MeterScene.Message(text: TuneView.hint(tune.selected, app: last?.app)) : nil
    }

    /// The band an edit changed, for its chip to flash.
    static func band(_ action: WatchAction) -> Int? {
        switch action {
        case .bandStep(let band, _), .adjust(.band(let band), _), .assign(.band(let band), _): return band
        default: return nil
        }
    }

    /// Before the first frame a view without levels still has a status bar to draw.
    private var placeholder: MeterFrame {
        MeterFrame(t: 0, device: nil, rate: 0, in: [], out: [], peak: -.infinity, limiting: false, gains: [], preamp: 0, enabled: true)
    }

    func scene() -> MeterScene? {
        guard let f = last ?? (view.showsLevels ? nil : placeholder) else { return nil }
        var scene = MeterScene(frame: f, size: size)
        scene.strip = strip
        scene.focus = focused
        scene.modal = modal
        scene.flash = flash.map { ($0.value, $0.left) }
        scene.message = message
        scene.messageLeft = note?.left ?? Watch.noteFrames
        var header = self.header
        header.mouse = mouseOn
        scene.header = header
        scene.prompt = prompt
        scene.listening = listening
        scene.peaks = look.peaks && peaks.count == scene.bands ? peaks : nil
        scene.outputPeak = look.peaks ? outputPeak : nil
        scene.live = meterOpen && last != nil
        scene.limiting = scene.live && (f.limiting || limitLeft > 0)
        scene.settings = look
        scene.curve = curve
        scene.chainCurve = chainCurve
        scene.view = view
        scene.selected = selected
        scene.events = events
        scene.eventsGone = eventsRetry != nil
        scene.goMenu = goMenu
        scene.palette = palette
        scene.paletteValues = paletteValues
        scene.child = child
        scene.filterField = filterField
        scene.tune = tune
        scene.entry = entry
        return scene
    }

    /// The screen as text: what the golden files hold.
    func lines() -> [String]? { scene()?.lines() }

    func view(into screen: inout Screen) {
        scene()?.draw(into: &screen)
    }

    private mutating func show(_ text: String, _ kind: MeterScene.Message.Kind = .warn) {
        note = Countdown(value: MeterScene.Message(text: text, kind: kind), left: Watch.noteFrames)
    }

    private mutating func hold(_ f: MeterFrame) {
        let out = Watch.padded(f.out, to: Config.bandLabels.count, with: Watch.floorDB).map(MeterScene.clampLevel)
        if peaks.count != out.count {
            peaks = out
            holds = Array(repeating: Self.peakHoldFrames, count: out.count)
        }
        for i in out.indices {
            (peaks[i], holds[i]) = Self.held(peaks[i], hold: holds[i], level: out[i])
        }
        (outputPeak, outputHold) = Self.held(outputPeak, hold: outputHold, level: MeterScene.clampLevel(f.peak.isFinite ? f.peak : Watch.floorDB))
        limitLeft = f.limiting ? Self.limitFrames : max(limitLeft - 1, 0)
    }

    static func held(_ peak: Double, hold: Int, level: Double) -> (Double, Int) {
        if level >= peak { return (level, peakHoldFrames) }
        if hold > 0 { return (peak, hold - 1) }
        return (max(peak - peakFall, level), 0)
    }

    private mutating func syncMouse() -> [MeterCmd] {
        guard header.mouse != mouseOn else { return [] }
        mouseOn = header.mouse
        return [.mouse(mouseOn)]
    }

    private mutating func quit(_ code: Int32) -> [MeterCmd] {
        let clear: [MeterCmd] = listening ? [.send(Watch.soloRequest(nil))] : []
        listening = false
        let stop: [MeterCmd] = child?.status == nil && child != nil ? [.stop] : []
        return clear + stop + [.quit(code)]
    }

    private mutating func frame(_ f: MeterFrame) -> [MeterCmd] {
        let before = (flash, note, peaks, outputPeak, limitLeft > 0)
        let same = last.map { var a = $0; a.t = f.t; return a == f } ?? false
        flash = flash.flatMap { $0.left > 0 ? Countdown(value: $0.value, left: $0.left - 1) : nil }
        note = note.flatMap { $0.left > 0 ? Countdown(value: $0.value, left: $0.left - 1) : nil }
        let hadSolo = last?.solo != nil
        last = f
        hold(f)
        // Levels standing still, nothing counting down: the screen would be the same.
        needsRedraw = !(same && before.0 == nil && before.1 == nil && flash == nil && note == nil && before.2 == peaks
            && before.3 == outputPeak && before.4 == (limitLeft > 0))
        var cmds: [MeterCmd] = []
        // The daemon keeps a solo across a device switch, so only a frame without one asks again:
        // once per rate, or once when it vanished at a rate the range can play (refused at a 0 Hz
        // moment no frame showed).
        if listening, let instrument = focused, f.solo == nil, f.rate > 0 {
            let range = instrument.characterRange
            let dropped = hadSolo && EQProcessor.clampSolo(low: range.low, high: range.high, sampleRate: f.rate) != nil
            if requestedAt != f.rate || dropped { cmds += request(range) }
        }
        framesSinceMark += 1
        if framesSinceMark >= Watch.markFrames {
            framesSinceMark = 0
            cmds.append(.refreshHeader)
        }
        // A view without levels took this one frame for its status bar; the connection goes again.
        if !wantsMeter, meterOpen {
            meterOpen = false
            cmds.append(.disconnect)
        }
        return cmds
    }

    /// At 0 Hz the daemon refuses any range, so the frame loop asks once a rate arrives; a solo
    /// already sounding is cleared now, or the daemon would carry it across the rebuild.
    private mutating func request(_ range: HzRange?) -> [MeterCmd] {
        let deferred = range != nil && last?.rate == 0
        requestedAt = deferred ? nil : last?.rate
        let wasListening = listening
        listening = range != nil
        if deferred, !wasListening { return [] }
        // The daemon refuses silently (and drops the previous solo); the same clamp here says why.
        if !deferred, let range, let rate = last?.rate, let instrument = focused,
           EQProcessor.clampSolo(low: range.low, high: range.high, sampleRate: rate) == nil {
            show(Watch.cannotListen(instrument))
        }
        return [.send(Watch.soloRequest(deferred ? nil : range))]
    }

    private mutating func refocus(_ index: Int?) -> [MeterCmd] {
        focus = index
        guard listening else { return [] }
        return request(focused?.characterRange)
    }

    private mutating func apply(_ action: WatchAction) -> [MeterCmd] {
        if case .bandStep(let band, _) = action, let instrument = focused, !instrument.bands.contains(band) {
            show(Watch.outsideNote(instrument))
            return []
        }
        return [.edit(action)]
    }

    // MARK: Views

    /// Opens or closes the meter connection to match the view: a view with levels needs it, one
    /// without lets the daemon stop its meter work (a solo keeps it).
    private mutating func syncMeter() -> [MeterCmd] {
        if wantsMeter, !meterOpen, retry == nil { return [.connect] }
        if !wantsMeter, meterOpen {
            meterOpen = false
            return [.disconnect]
        }
        return []
    }

    private mutating func goTo(_ next: TUIView) -> [MeterCmd] {
        goMenu = false
        modal = nil
        guard next != view else { return [] }
        stack.append(view)
        if stack.count > Self.stackLimit { stack.removeFirst() }
        if next == .instruments { selected = focus ?? selected }
        view = next
        return syncMeter()
    }

    private mutating func back() -> [MeterCmd] {
        guard let previous = stack.popLast() else { return [] }
        view = previous
        return syncMeter()
    }

    /// A status change seen on the events connection: the status bar follows it on every view.
    private mutating func event(_ entry: EventEntry) -> [MeterCmd] {
        let wasEmpty = events.shown.isEmpty
        events.append(entry)
        if events.scroll > 0, events.paused == nil, !wasEmpty { events.scroll += events.matches(entry) ? 1 : 0 }
        guard let effect = entry.effect else { return [] }
        switch effect {
        case .device(let name, let rate):
            last?.device = name
            last?.rate = rate
        case .rate(let rate): last?.rate = rate
        case .enabled(let on): last?.enabled = on
        case .solo(let range): last?.solo = range
        case .profile:
            // Gains and preamp come only with frames: a view without levels takes one more.
            return [.refreshHeader] + (!wantsMeter && !meterOpen ? [.connect] : [])
        }
        return []
    }

    // MARK: Command palette

    private mutating func paletteInput(_ event: InputEvent) -> [MeterCmd] {
        guard var open = palette else { return [] }
        let suggestions = open.suggestions(values: paletteValues)
        let count = suggestions.items.count
        if case .key(let press) = event {
            switch press.code {
            case .esc, .char("\u{03}"), .char("\u{10}"):
                palette = nil
                return []
            case .up:
                open.chosen = max((open.chosen ?? 0) - 1, suggestions.prefersFirst ? 0 : -1)
                if open.chosen == -1 { open.chosen = nil }
                palette = open
                return []
            case .down:
                open.chosen = min((open.chosen ?? -1) + 1, max(count - 1, 0))
                palette = open
                return []
            case .char("\t"):
                guard let entry = open.chosen.flatMap({ $0 < count ? suggestions.items[$0] : nil }) ?? suggestions.items.first else { return [] }
                open.field = TextField(entry.runnable ? entry.text + (entry.action == nil ? " " : "") : CommandPalette.stem(entry.text))
                return typed(open)
            case .char("\n"), .char("\r"):
                if let index = open.chosen, index < count {
                    let entry = suggestions.items[index]
                    guard entry.runnable else {
                        open.field = TextField(CommandPalette.stem(entry.text))
                        return typed(open)
                    }
                    return run(entry.text, action: entry.action)
                }
                return run(open.field.text, action: nil)
            default: break
            }
        }
        let before = open.field
        guard case .editing = open.field.handle(event), open.field != before else { return [] }
        return typed(open)
    }

    /// A new line: the choice goes back to the best match, and an operand whose values are not
    /// here yet asks for them.
    private mutating func typed(_ open: CommandPalette) -> [MeterCmd] {
        var open = open
        let suggestions = open.suggestions(values: paletteValues)
        open.chosen = suggestions.prefersFirst && !suggestions.items.isEmpty ? 0 : nil
        palette = open
        guard let kind = suggestions.kind, kind.words.isEmpty, asked.insert(kind.rawValue).inserted else { return [] }
        return [.complete(kind)]
    }

    private mutating func remember(_ line: String) -> [MeterCmd] {
        history.removeAll { $0 == line }
        history.insert(line, at: 0)
        if history.count > CommandPalette.historyLimit { history.removeLast() }
        return [.saveHistory(history)]
    }

    /// A screen action by its name, or an `eq` command as a child.
    private mutating func run(_ line: String, action: WatchAction?) -> [MeterCmd] {
        palette = nil
        let text = line.trimmingCharacters(in: .whitespaces)
        if let action { return remember(text) + act(action) }
        var words = CommandPalette.words(text)
        if words.first == "eq" { words.removeFirst() }
        guard let first = words.first else { return [] }
        if let why = CommandPalette.streaming[first] {
            show("eq \(first) streams: \(why)")
            return []
        }
        if child?.status == nil, child != nil {
            show("eq \(child!.command) is still running — Esc stops it")
            return []
        }
        let command = words.map(CommandPalette.quoted).joined(separator: " ")
        child = ChildOutput(command: command)
        // Kept with its `eq`, so the line runs the command again even where a screen action has its name.
        return remember("eq " + command) + [.run(words, columns: OutputPane.columns(size))]
    }

    /// One line said in the message row; more open the pane, which stays until closed. Either
    /// way the status bar is read again, since the command may have changed what it shows.
    private mutating func exited(_ code: Int32) -> [MeterCmd] {
        guard var output = child else { return [] }
        output.status = code
        if output.shown {
            child = output
        } else {
            let line = output.lines.first.map(ChildOutput.plain) ?? ""
            let fallback = code == 0 ? "done: eq \(output.command)" : "eq \(output.command) ended with exit \(code)"
            show(line.isEmpty ? fallback : line, code == 0 ? .ok : .error)
            child = nil
        }
        return [.refreshHeader] + (!wantsMeter && !meterOpen ? [.connect] : [])
    }

    // MARK: Keys

    private mutating func input(_ event: InputEvent) -> [MeterCmd] {
        if case .mouse(let mouse) = event, view == .tune, modal == nil, !goMenu, palette == nil, prompt == nil, entry == nil,
           child?.shown != true, let control = TuneView.control(at: mouse.x, mouse.y, size: size, look: look.look) {
            switch mouse.action {
            case .press where mouse.button == .left:
                tune.select(control)
                return []
            case .wheelUp, .wheelDown:
                tune.select(control)
                return apply(.adjust(control, control.delta(mouse.action == .wheelUp ? KeyTable.step : -KeyTable.step)))
            default: break
            }
        }
        if case .mouse(let mouse) = event, mouse.action == .press, mouse.button == .left {
            guard mouse.y == 1, size.rows >= TabRow.minRows, palette == nil, prompt == nil,
                  let target = TabRow.view(at: mouse.x, width: size.cols, current: view) else { return [] }
            return goTo(target)
        }
        if palette != nil { return paletteInput(event) }
        if var field = prompt {
            switch field.handle(event) {
            case .editing: prompt = field
            case .cancel: prompt = nil
            case .submit(let name):
                prompt = nil
                return apply(.savePreset(name))
            case .ignored: break
            }
            return []
        }
        if var field = entry {
            switch field.handle(event) {
            case .editing: entry = field
            case .cancel: entry = nil
            case .submit(let text):
                entry = nil
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
                guard let value = tune.selected.parse(text) else {
                    show("not a value for \(tune.selected.name): \"\(text)\"", .error)
                    return []
                }
                return apply(.assign(tune.selected, value))
            case .ignored: break
            }
            return []
        }
        if var field = filterField {
            switch field.handle(event) {
            case .editing:
                filterField = field
                events.filter = field.text
                events.scroll = 0
            case .cancel:
                filterField = nil
                events.filter = ""
            case .submit:
                filterField = nil
            case .ignored: break
            }
            return []
        }
        guard let key = Key(event) else { return [] }
        let context = MeterScene.context(prompt: prompt, entry: entry, filter: filterField, palette: palette, go: goMenu,
                                         pane: child?.shown == true, modal: modal, view: view)
        let action = KeyTable.action(for: key, in: context)
        if goMenu {
            guard case .go? = action else {
                goMenu = false
                return []
            }
        }
        guard let action else { return [] }
        return act(action, in: context)
    }

    /// What an action does here: from a key in `context`, or by name from the palette.
    private mutating func act(_ action: WatchAction, in context: KeyContext? = nil) -> [MeterCmd] {
        let count = Instruments.all.count
        let context = context ?? view.context
        switch action {
        case .quit:
            return quit(0)
        case .zones:
            strip.toggle()
        case .help: modal = .help(scroll: 0)
        case .closeModal:
            if goMenu {
                goMenu = false
            } else if context == .pane {
                let stop: [MeterCmd] = child?.status == nil ? [.stop] : []
                child = nil
                return stop
            } else {
                modal = nil
            }
        case .scrollUp, .scrollDown, .pageUp, .pageDown, .top, .bottom:
            move(action, in: context)
        case .palette:
            palette = CommandPalette(history: history)
            modal = nil
        case .goMenu: goMenu = true
        case .go(let target): return goTo(target)
        case .back:
            if view == .events, !events.filter.isEmpty {
                events.filter = ""
                return []
            }
            return back()
        case .focusInMeter:
            let cmds = refocus(selected)
            return cmds + goTo(.meter)
        case .pause: events.togglePause()
        case .filter: filterField = TextField(events.filter)
        case .stop:
            guard child?.status == nil, child != nil else {
                child = nil
                return []
            }
            return [.stop]
        case .suspend: break
        case .nextLook:
            let all = Look.allCases
            look.look = all[((all.firstIndex(of: look.look) ?? 0) + 1) % all.count]
            show("look: \(look.look.rawValue) · palette \(look.paletteName.rawValue)", .ok)
            return [.redraw, .edit(.setLook(look.look.rawValue))]
        case .nextPalette:
            let all = PaletteName.allCases
            look.palette = all[((all.firstIndex(of: look.paletteName) ?? 0) + 1) % all.count]
            show("palette: \(look.paletteName.rawValue)", .ok)
            return [.redraw, .edit(.setPalette(look.paletteName.rawValue))]
        case .startSave: prompt = TextField()
        case .focusNext: return refocus(focus.map { ($0 + 1) % count } ?? 0)
        case .focusPrevious: return refocus(focus.map { ($0 + count - 1) % count } ?? count - 1)
        case .unfocus:
            if focus != nil { return refocus(nil) }
            return back()
        case .listen:
            if view == .instruments, focus != selected {
                focus = selected
                return request(focused?.characterRange)
            }
            guard focused != nil else { show(Watch.listenNeedsFocus); break }
            let cmds = request(listening ? nil : focused?.characterRange)
            return cmds + syncMeter()
        case .knob(let delta):
            if view == .instruments { return apply(.boost(Instruments.all[selected].name, delta)) }
            guard let instrument = focused else { show(Watch.listenNeedsFocus); break }
            return apply(.boost(instrument.name, delta))
        case .tuneSelect(let delta): tune.move(delta)
        case .tuneGroup(let delta): tune.jump(delta)
        case .nudge(let size): return apply(.adjust(tune.selected, tune.selected.delta(size)))
        case .tuneReset: return apply(.assign(tune.selected, 0))
        case .tuneEntry: entry = TextField()
        case .bandStep, .preamp, .bass, .treble, .cyclePreset, .previousPreset, .undo, .savePreset, .boost,
             .cycleComp, .cycleColour, .colourAmount, .mouse, .setLook, .setPalette, .adjust, .assign:
            return apply(action)
        }
        return []
    }

    private mutating func move(_ action: WatchAction, in context: KeyContext) {
        let delta: Int
        switch action {
        case .scrollUp: delta = -1
        case .scrollDown: delta = 1
        case .pageUp: delta = -10
        case .pageDown: delta = 10
        case .top: delta = -Int(Int32.max)
        default: delta = Int(Int32.max)
        }
        switch context {
        case .help:
            modal = modal.map { $0.scrolled(by: delta, size: size, view: view.context) }
        case .pane:
            guard var output = child else { return }
            let visible = OutputPane.visible(size)
            output.scroll = min(max(output.scroll - delta, 0), max(output.lines.count - visible, 0))
            child = output
        case .instruments:
            selected = min(max(selected + delta, 0), Instruments.all.count - 1)
        case .events:
            let page = EventsView.visible(size)
            events.scroll(by: -(abs(delta) == 10 ? delta / 10 * max(page - 1, 1) : delta), visible: page)
        default:
            break
        }
    }
}
