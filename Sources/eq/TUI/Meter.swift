import EQTerm
import Foundation

enum MeterMsg {
    /// Sets the terminal's mouse reporting to the saved setting.
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
    /// SIGINT, SIGTERM or SIGHUP: leave as `q` does.
    case signal
}

enum MeterCmd: Equatable {
    case edit(WatchAction)
    case send(String)
    case refreshHeader
    case mouse(Bool)
    case retry(after: Double)
    case connect
    case quit(Int32)
}

/// The meter view as a program: every piece of state the old frame loop kept in captured
/// variables, and `update`, which never touches a file or a socket.
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
    var note: Countdown<String>?
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

    init(size: Size, zones: Bool = false, header: Watch.Header = Watch.Header(), reconnects: Bool = false) {
        self.size = size
        strip = zones
        self.header = header
        self.reconnects = reconnects
    }

    var focused: Instrument? { focus.map { Instruments.all[$0] } }

    var layout: WatchLayout {
        .fit(cols: size.cols, rows: size.rows, zones: strip ? (focus == nil ? Instruments.all.count : 1) : 0, bracket: focus != nil)
    }

    static let firstRetry = 0.5
    static let lastRetry = 4.0

    mutating func update(_ msg: MeterMsg) -> [MeterCmd] {
        switch msg {
        case .start:
            return syncMouse()
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
                show(failure.split(separator: "\n").first.map(String.init) ?? "")
            } else if case .bandStep(let band, _) = action {
                flash = Countdown(value: band, left: Watch.flashFrames)
            }
            return [.refreshHeader]
        case .sendFailed:
            // A failed send most likely means the socket is gone, and the daemon clears the solo then.
            show(Watch.listenFailed)
            listening = false
            return []
        case .meterClosed:
            // The socket is gone, and the daemon dropped the solo with it: nothing to send.
            guard reconnects else {
                listening = false
                return [.quit(1)]
            }
            requestedAt = nil
            retry = Self.firstRetry
            return [.retry(after: Self.firstRetry)]
        case .retry:
            return [.connect]
        case .connected:
            retry = nil
            return []
        case .connectFailed:
            let next = min((retry ?? Self.firstRetry) * 2, Self.lastRetry)
            retry = next
            return [.retry(after: next)]
        case .signal:
            return quit(0)
        }
    }

    /// The note, error or prompt of the moment lasts `noteFrames`; while the daemon is gone
    /// the reconnect message stays under it.
    var message: String? { note?.value ?? (retry != nil ? Watch.reconnecting : nil) }

    func picture() -> MeterPicture? {
        guard let f = last else { return nil }
        return Watch.picture(f, layout: layout, strip: strip, focus: focused, modal: modal, flash: flash?.value,
                             note: message, preset: header.preset, preference: header.preference, knobs: header.knobs,
                             dynamics: header.dynamics, prompt: prompt, listening: listening, mouse: mouseOn)
    }

    /// The screen as painted lines: what the golden files hold.
    func lines() -> [String]? { picture()?.lines() }

    func view(into screen: inout Screen) {
        picture()?.draw(into: &screen)
    }

    private mutating func show(_ text: String) {
        note = Countdown(value: text, left: Watch.noteFrames)
    }

    private mutating func syncMouse() -> [MeterCmd] {
        guard header.mouse != mouseOn else { return [] }
        mouseOn = header.mouse
        return [.mouse(mouseOn)]
    }

    private mutating func quit(_ code: Int32) -> [MeterCmd] {
        let clear: [MeterCmd] = listening ? [.send(Watch.soloRequest(nil))] : []
        listening = false
        return clear + [.quit(code)]
    }

    private mutating func frame(_ f: MeterFrame) -> [MeterCmd] {
        flash = flash.flatMap { $0.left > 0 ? Countdown(value: $0.value, left: $0.left - 1) : nil }
        note = note.flatMap { $0.left > 0 ? Countdown(value: $0.value, left: $0.left - 1) : nil }
        let hadSolo = last?.solo != nil
        last = f
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

    private mutating func input(_ event: InputEvent) -> [MeterCmd] {
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
        guard let key = Key(event), let action = KeyTable.action(for: key, in: modal?.context ?? .meter) else { return [] }
        let count = Instruments.all.count
        switch action {
        case .quit:
            return quit(0)
        case .zones:
            strip.toggle()
        case .help: modal = .help(scroll: 0)
        case .instruments: modal = .instruments(scroll: 0)
        case .closeModal: modal = nil
        case .scrollUp, .scrollDown:
            modal = modal.map { $0.scrolled(by: action == .scrollUp ? -1 : 1, layout: layout) }
        case .palette: show(Watch.paletteNote)
        case .startSave: prompt = TextField()
        case .focusNext: return refocus(focus.map { ($0 + 1) % count } ?? 0)
        case .focusPrevious: return refocus(focus.map { ($0 + count - 1) % count } ?? count - 1)
        case .unfocus:
            if focus != nil { return refocus(nil) }
        case .listen:
            guard focused != nil else { show(Watch.listenNeedsFocus); break }
            return request(listening ? nil : focused?.characterRange)
        case .knob(let delta):
            guard let instrument = focused else { show(Watch.listenNeedsFocus); break }
            return apply(.boost(instrument.name, delta))
        case .bandStep, .preamp, .bass, .treble, .cyclePreset, .previousPreset, .undo, .savePreset, .boost,
             .cycleComp, .cycleColour, .colourAmount, .mouse:
            return apply(action)
        }
        return []
    }
}
