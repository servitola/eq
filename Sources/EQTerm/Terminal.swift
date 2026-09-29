import Darwin

// Signal handlers are C function pointers that cannot capture, and may only call
// async-signal-safe functions, so what they need is set up here before any is installed:
// plain values and C strings, never a Swift String or Array built inside a handler.
private var savedTermios = termios()
private var termiosSaved = false
private var leaveBytes: UnsafeMutablePointer<CChar>?
private var signalWriteFD: Int32 = -1

private func writeAll(_ text: UnsafeMutablePointer<CChar>?) {
    guard let text else { return }
    let count = strlen(text)
    var offset = 0
    while offset < count {
        let n = write(1, text + offset, count - offset)
        if n > 0 { offset += n } else if n < 0, errno == EINTR { continue } else { return }
    }
}

/// Raw mode off first, then out of the alternate screen, as ratatui's `restore` does.
private func restoreTerminal() {
    if termiosSaved { tcsetattr(0, TCSANOW, &savedTermios) }
    writeAll(leaveBytes)
}

/// Only records the signal; the loop reads it from the pipe and does the work.
private func forwardSignal(_ signal: Int32) {
    let saved = errno
    var byte = UInt8(truncatingIfNeeded: signal)
    _ = write(signalWriteFD, &byte, 1)
    errno = saved
}

/// The re-raise takes the default action, so the crash report is still written: a Swift trap on
/// arm64 is `brk`, SIGTRAP. The reset is explicit because SA_RESETHAND leaves SIGILL and SIGTRAP
/// installed, and the re-raise would recurse until the stack runs out.
private func restoreOnCrash(_ signal: Int32) {
    restoreTerminal()
    Darwin.signal(signal, SIG_DFL)
    raise(signal)
}

/// The terminal state a full-screen program changes, and every way out that puts it back.
/// `enter` and `leave` are the only places that change it.
public enum Terminal {
    public static let crashSignals = [SIGTRAP, SIGILL, SIGSEGV, SIGBUS, SIGABRT, SIGFPE]
    /// Delivered through `signals()`, never acted on inside the handler.
    public static let forwardedSignals = [SIGINT, SIGTERM, SIGHUP, SIGTSTP, SIGCONT, SIGWINCH]

    /// Alternate screen, cursor hidden, bracketed paste, focus reports, and a DECRQM query for
    /// synchronized updates, which a terminal that knows the mode answers (`InputEvent.modeReport`).
    public static let enterSequence = "\u{1B}[?1049h\u{1B}[?25l\u{1B}[?2004h\u{1B}[?1004h\u{1B}[?2026$p"
    public static let leaveSequence = "\u{1B}[0m\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1006l\u{1B}[?1004l\u{1B}[?2004l\u{1B}[?25h\u{1B}[?1049l"
    /// Presses, drags and the wheel in SGR form (1006), which never sends raw bytes above 127.
    public static let mouseOn = "\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1006h"
    public static let mouseOff = "\u{1B}[?1002l\u{1B}[?1000l\u{1B}[?1006l"

    public private(set) static var mouse = false
    private static var signalReadFD: Int32 = -1

    /// The read end of the pipe the signal handlers write to; the loop polls it.
    public static var signalFD: Int32 { signalReadFD }

    public static func probe() -> (isTTY: Bool, cols: Int, rows: Int) {
        var size = winsize()
        guard isatty(0) == 1, isatty(1) == 1, ioctl(1, TIOCGWINSZ, &size) == 0 else { return (false, 0, 0) }
        return (true, Int(size.ws_col), Int(size.ws_row))
    }

    public static func width(fd: Int32) -> Int {
        var size = winsize()
        guard isatty(fd) == 1, ioctl(fd, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return 80 }
        return Int(size.ws_col)
    }

    public static func size() -> Size? {
        var size = winsize()
        guard ioctl(1, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0 else { return nil }
        return Size(cols: Int(size.ws_col), rows: Int(size.ws_row))
    }

    /// Raw: no line editing, no echo, and ISIG off so Ctrl-C and Ctrl-Z arrive as keys and quit
    /// and suspend go through the loop. SIGINT, SIGTERM, SIGHUP, SIGTSTP from `kill`, SIGCONT and
    /// SIGWINCH go to the signal pipe; a crash restores the terminal and dies as it would have.
    public static func enter(mouse: Bool = false) {
        TerminalText.useUTF8Widths()
        leaveBytes = strdup(leaveSequence)
        var fds: [Int32] = [-1, -1]
        if pipe(&fds) == 0 {
            for fd in fds {
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            }
            signalReadFD = fds[0]
            signalWriteFD = fds[1]
        }
        for forwarded in forwardedSignals { signal(forwarded, forwardSignal) }
        for crash in crashSignals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = restoreOnCrash
            action.sa_flags = SA_RESETHAND | SA_NODEFER
            sigaction(crash, &action, nil)
        }
        take(mouse: mouse)
    }

    public static func leave() {
        restoreTerminal()
        for handled in forwardedSignals + crashSignals { signal(handled, SIG_DFL) }
        for fd in [signalReadFD, signalWriteFD] where fd >= 0 { close(fd) }
        signalReadFD = -1
        signalWriteFD = -1
        mouse = false
    }

    /// What the process would have done had nothing caught `signal`: the parent sees it.
    public static func reraise(_ signal: Int32) {
        Darwin.signal(signal, SIG_DFL)
        raise(signal)
    }

    /// Signals caught since the last call, oldest first.
    public static func signals() -> [Int32] {
        var result: [Int32] = []
        var bytes = [UInt8](repeating: 0, count: 64)
        while signalReadFD >= 0 {
            let n = read(signalReadFD, &bytes, bytes.count)
            guard n > 0 else { break }
            result += bytes.prefix(n).map { Int32($0) }
        }
        return result
    }

    public static func setMouse(_ on: Bool) {
        mouse = on
        write(on ? mouseOn : mouseOff)
    }

    /// Ctrl-Z: the shell gets its screen and cooked mode back, then the process stops for real;
    /// `fg` continues right here, where the screen is taken again. The caller redraws it whole.
    public static func suspend() {
        restoreTerminal()
        signal(SIGTSTP, SIG_DFL)
        var tstp: sigset_t = 1 << (SIGTSTP - 1)
        sigprocmask(SIG_UNBLOCK, &tstp, nil)
        kill(0, SIGTSTP)
        signal(SIGTSTP, forwardSignal)
        take(mouse: mouse)
    }

    /// The shell may have changed the modes while it had the terminal, so they are saved anew.
    private static func take(mouse: Bool) {
        termiosSaved = tcgetattr(0, &savedTermios) == 0
        if termiosSaved {
            var raw = savedTermios
            raw.c_lflag &= ~tcflag_t(ICANON | ECHO | IEXTEN | ISIG)
            tcsetattr(0, TCSANOW, &raw)
        }
        write(enterSequence)
        self.mouse = mouse
        if mouse { write(mouseOn) }
    }

    public static func write(_ text: String) {
        write(Array(text.utf8))
    }

    /// All of it, whatever the tty takes per call.
    public static func write(_ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { Darwin.write(1, $0.baseAddress, $0.count) }
            if n > 0 { offset += n } else if n < 0, errno == EINTR || errno == EAGAIN { continue } else { return }
        }
    }
}
