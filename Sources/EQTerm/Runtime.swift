import Darwin

/// The Elm architecture, as Bubble Tea and ratatui's recommended pattern do it: the model is a
/// value, `update` is pure and names its effects as commands, `view` only draws cells.
public protocol Program {
    associatedtype Msg
    associatedtype Cmd
    mutating func update(_ msg: Msg) -> [Cmd]
    func view(into screen: inout Screen)
}

/// What the runtime has to tell a program; `Runtime`'s `translate` turns it into the program's Msg.
public enum Event {
    case input(InputEvent)
    /// A whole line from a watched descriptor, without its newline.
    case line(source: Int, String)
    /// The descriptor reached end of file or failed; it is no longer watched.
    case closed(source: Int)
    case timer(Int)
    case resize(Size)
    /// The screen was lost and has been drawn again in full: a resume, a focus-in.
    case redraw
    /// SIGINT, SIGTERM or SIGHUP.
    case signal(Int32)
}

/// One thread, one `poll(2)` over stdin, the signal pipe, every watched descriptor, with the
/// nearest timer as its timeout. Every wake-up runs `update` for what arrived, performs the
/// commands, and draws once if anything changed — at most every `frameInterval`.
public final class Runtime<P: Program> {
    public private(set) var program: P
    public private(set) var size: Size
    /// The signal that ended the loop, for the caller to die of once the terminal is back.
    public private(set) var endedBy: Int32?
    public var frameInterval = 1.0 / 60
    public var renderer = Renderer()

    private let translate: (Event) -> P.Msg?
    private let perform: (P.Cmd, Runtime<P>) -> [P.Msg]
    private let output: ([UInt8]) -> Void
    private var decoder = InputDecoder()
    private var sources: [(id: Int, fd: Int32, pending: [UInt8], latestOnly: Bool)] = []
    private var timers: [Int: Double] = [:]
    public private(set) var exitCode: Int32?
    /// The terminal's input; a pipe in tests.
    public var inputFD: Int32 = 0
    private var dirty = true
    private var lastRender = -Double.infinity
    private var back: Screen

    public init(_ program: P, size: Size, translate: @escaping (Event) -> P.Msg?,
                perform: @escaping (P.Cmd, Runtime<P>) -> [P.Msg], output: @escaping ([UInt8]) -> Void = Terminal.write) {
        self.program = program
        self.size = size
        self.translate = translate
        self.perform = perform
        self.output = output
        back = Screen(size)
    }

    public var finished: Bool { exitCode != nil }

    // MARK: What commands call

    public func quit(_ code: Int32) {
        if exitCode == nil { exitCode = code }
    }

    /// `latestOnly`: of the lines one wake-up brings, only the last is delivered — a meter that
    /// fell behind must not build a backlog on a slow terminal.
    public func watch(fd: Int32, id: Int, latestOnly: Bool = false) {
        unwatch(id)
        sources.append((id, fd, [], latestOnly))
    }

    public func unwatch(_ id: Int) {
        sources.removeAll { $0.id == id }
    }

    public func after(_ seconds: Double, id: Int) {
        timers[id] = Self.now() + seconds
    }

    public func cancelTimer(_ id: Int) {
        timers[id] = nil
    }

    /// The next frame is drawn whole.
    public func invalidate() {
        renderer.invalidate()
        dirty = true
    }

    // MARK: Driving

    /// Runs `update` and every command it returns, and the messages those bring back, in order.
    public func send(_ msg: P.Msg) {
        dirty = true
        var queue = [msg]
        while !queue.isEmpty {
            let next = queue.removeFirst()
            for cmd in program.update(next) { queue += perform(cmd, self) }
        }
    }

    public func handle(_ event: Event) {
        if case .resize(let new) = event { size = new }
        if case .redraw = event { invalidate() }
        if case .input(.focus(true)) = event { invalidate() }
        if case .input(.modeReport(2026, let value)) = event {
            // 0: not recognised; 4: permanently reset. Either way the brackets would be noise.
            renderer.synchronized = value != 0 && value != 4
            return
        }
        if let msg = translate(event) { send(msg) }
    }

    /// Draws now if anything changed since the last frame; returns whether it did.
    @discardableResult
    public func render() -> Bool {
        guard dirty else { return false }
        if back.size != size { back = Screen(size) } else { back.clear() }
        program.view(into: &back)
        let bytes = renderer.render(back)
        if !bytes.isEmpty { output(bytes) }
        dirty = false
        lastRender = Self.now()
        return true
    }

    /// Bytes read from stdin, as one wake-up would bring them.
    public func input(_ bytes: [UInt8]) {
        for event in decoder.feed(bytes) {
            if case .key(KeyPress(.char("\u{1A}"), [])) = event {
                suspend()
                continue
            }
            handle(.input(event))
        }
    }

    public func suspend() {
        Terminal.suspend()
        invalidate()
        handle(.redraw)
    }

    /// The loop, until a command quits: returns the exit code.
    public func run() -> Int32 {
        var chunk = [UInt8](repeating: 0, count: 4096)
        render()
        while exitCode == nil {
            var fds = [pollfd(fd: inputFD, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: Terminal.signalFD, events: Int16(POLLIN), revents: 0)]
            fds += sources.map { pollfd(fd: $0.fd, events: Int16(POLLIN), revents: 0) }
            let ids = sources.map(\.id)
            let ready = poll(&fds, nfds_t(fds.count), timeout())
            if ready < 0, errno != EINTR { break }
            if ready > 0 {
                if fds[1].revents != 0 { signals() }
                for (index, id) in ids.enumerated() where fds[index + 2].revents != 0 { readSource(id, &chunk) }
                if fds[0].revents & Int16(POLLIN) != 0 {
                    readInput(&chunk)
                } else if fds[0].revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                    stopReadingInput()
                }
            }
            fireTimers()
            if exitCode == nil, dirty, Self.now() - lastRender >= frameInterval { render() }
        }
        return exitCode ?? 1
    }

    /// A hung-up terminal stays readable forever; polling it would spin. Its SIGHUP ends the loop.
    private func stopReadingInput() {
        inputFD = -1
    }

    private func timeout() -> Int32 {
        let now = Self.now()
        var wait = timers.values.min().map { max($0 - now, 0) }
        if dirty { wait = min(wait ?? .infinity, max(lastRender + frameInterval - now, 0)) }
        guard let wait else { return -1 }
        return Int32(min(wait * 1000, 60_000).rounded(.up))
    }

    private func signals() {
        for signal in Terminal.signals() {
            switch signal {
            case SIGWINCH:
                if let new = Terminal.size(), new != size { handle(.resize(new)) }
            case SIGCONT: handle(.redraw)
            case SIGTSTP: suspend()
            default:
                if endedBy == nil { endedBy = signal }
                handle(.signal(signal))
            }
        }
    }

    private func readInput(_ chunk: inout [UInt8]) {
        let n = read(inputFD, &chunk, chunk.count)
        guard n > 0 else {
            if n == 0 || (errno != EINTR && errno != EAGAIN) { stopReadingInput() }
            return
        }
        input(Array(chunk.prefix(n)))
        // A bare ESC is the Esc key only if nothing follows at once: one re-poll that does not wait.
        if decoder.holdsEscape {
            var pfd = pollfd(fd: inputFD, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, 0) <= 0 { input([]) }
        }
    }

    private func readSource(_ id: Int, _ chunk: inout [UInt8]) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        let n = read(sources[index].fd, &chunk, chunk.count)
        guard n > 0 else {
            if n < 0, errno == EINTR || errno == EAGAIN { return }
            sources.remove(at: index)
            handle(.closed(source: id))
            return
        }
        sources[index].pending += chunk.prefix(n)
        var lines: [String] = []
        while let newline = sources[index].pending.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(String(decoding: sources[index].pending[..<newline], as: UTF8.self))
            sources[index].pending.removeSubrange(...newline)
        }
        if sources[index].latestOnly, let last = lines.last { lines = [last] }
        for line in lines {
            handle(.line(source: id, line))
            if exitCode != nil { return }
        }
    }

    private func fireTimers() {
        let now = Self.now()
        for (id, deadline) in timers.sorted(by: { $0.value < $1.value }) where deadline <= now {
            timers[id] = nil
            handle(.timer(id))
        }
    }

    static func now() -> Double {
        var t = timespec()
        clock_gettime(CLOCK_MONOTONIC, &t)
        return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9
    }
}
