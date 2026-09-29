import Darwin
import Foundation

// Signal handlers are C function pointers that cannot capture, and may only call
// async-signal-safe functions, so what they need is set up here before any is installed:
// plain values and C strings, never a Swift String or Array built inside a handler.
private var savedTermios = termios()
private var termiosSaved = false
private var enterBytes: UnsafeMutablePointer<CChar>?
private var leaveBytes: UnsafeMutablePointer<CChar>?
private var mouseOnBytes: UnsafeMutablePointer<CChar>?
private var mouseWanted: sig_atomic_t = 0
private var redrawPending: sig_atomic_t = 0

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

private func enterRawMode() {
    guard termiosSaved else { return }
    var raw = savedTermios
    raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
    tcsetattr(0, TCSANOW, &raw)
}

private func quitOnInterrupt(_: Int32) {
    restoreTerminal()
    _exit(0)
}

/// SIGTERM and SIGHUP: the terminal back, then the default action, so the parent sees the signal.
private func endOnSignal(_ signal: Int32) {
    restoreTerminal()
    Darwin.signal(signal, SIG_DFL)
    raise(signal)
}

/// The re-raise takes the default action, so the crash report is still written: a Swift trap on
/// arm64 is `brk`, SIGTRAP. The reset is explicit because SA_RESETHAND leaves SIGILL and SIGTRAP
/// installed, and the re-raise would recurse until the stack runs out.
private func restoreOnCrash(_ signal: Int32) {
    restoreTerminal()
    Darwin.signal(signal, SIG_DFL)
    raise(signal)
}

/// Ctrl-Z: the shell gets its screen and cooked mode back, then the process stops for real; `fg`
/// continues right here, where the screen is taken again and the loop told to redraw it whole.
private func suspend(_: Int32) {
    let saved = errno
    restoreTerminal()
    signal(SIGTSTP, SIG_DFL)
    var tstp: sigset_t = 1 << (SIGTSTP - 1)
    sigprocmask(SIG_UNBLOCK, &tstp, nil)
    kill(0, SIGTSTP)
    signal(SIGTSTP, suspend)
    // The shell may have changed the modes while it had the terminal.
    termiosSaved = tcgetattr(0, &savedTermios) == 0
    enterRawMode()
    writeAll(enterBytes)
    if mouseWanted != 0 { writeAll(mouseOnBytes) }
    redrawPending = 1
    errno = saved
}

private func markRedraw(_: Int32) {
    redrawPending = 1
}

/// The terminal state `eq watch` and `eq tui` change, and every way out that puts it back.
enum TerminalSession {
    static let crashSignals = [SIGTRAP, SIGILL, SIGSEGV, SIGBUS, SIGABRT, SIGFPE]

    /// Non-canonical and silent so `q` arrives without Enter and is not echoed over the meters;
    /// ISIG stays on so Ctrl-C and Ctrl-Z reach their handlers even while the loop waits.
    static func enter() {
        enterBytes = strdup(Watch.enter)
        leaveBytes = strdup(Watch.leave)
        mouseOnBytes = strdup(Watch.mouseOn)
        mouseWanted = 0
        redrawPending = 0
        termiosSaved = tcgetattr(0, &savedTermios) == 0
        signal(SIGINT, quitOnInterrupt)
        signal(SIGTERM, endOnSignal)
        signal(SIGHUP, endOnSignal)
        signal(SIGTSTP, suspend)
        signal(SIGCONT, markRedraw)
        signal(SIGWINCH, markRedraw)
        for crash in crashSignals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = restoreOnCrash
            action.sa_flags = SA_RESETHAND | SA_NODEFER
            sigaction(crash, &action, nil)
        }
        enterRawMode()
    }

    static func leave() {
        if termiosSaved { tcsetattr(0, TCSANOW, &savedTermios) }
        for handled in [SIGINT, SIGTERM, SIGHUP, SIGTSTP, SIGCONT, SIGWINCH] + crashSignals { signal(handled, SIG_DFL) }
    }

    static func setMouse(_ on: Bool) {
        mouseWanted = on ? 1 : 0
        LiveTerminal.emit(on ? Watch.mouseOn : Watch.mouseOff)
    }

    /// True once after a resume or a resize: the screen must be drawn again in full.
    static func takeRedraw() -> Bool {
        guard redrawPending != 0 else { return false }
        redrawPending = 0
        return true
    }
}
