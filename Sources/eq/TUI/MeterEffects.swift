import EQTerm
import Foundation

/// What the meter's commands do outside the model: the session's edits, the daemon's socket,
/// the terminal's mouse mode. Tests give fakes for each.
struct MeterEffects {
    static let meterSource = 1
    static let retryTimer = 1

    var edit: (WatchAction) throws -> Void
    var header: () -> Watch.Header
    var send: (String) throws -> Void
    var mouse: (Bool) -> Void
    /// Opens the meter socket anew; its descriptor, or nil while the daemon is away.
    var connect: () -> Int32?

    func perform(_ cmd: MeterCmd, _ runtime: Runtime<MeterModel>) -> [MeterMsg] {
        switch cmd {
        case .edit(let action):
            do {
                try edit(action)
                return [.edited(action, failure: nil)]
            } catch {
                return [.edited(action, failure: String(describing: error))]
            }
        case .send(let line):
            do {
                try send(line)
                return []
            } catch {
                return [.sendFailed]
            }
        case .refreshHeader:
            return [.header(header())]
        case .mouse(let on):
            mouse(on)
            return []
        case .retry(let delay):
            runtime.after(delay, id: Self.retryTimer)
            return []
        case .connect:
            guard let fd = connect() else { return [.connectFailed] }
            runtime.watch(fd: fd, id: Self.meterSource, latestOnly: true)
            return [.connected]
        case .quit(let code):
            runtime.quit(code)
            return []
        }
    }

    private static let decoder = JSONDecoder()

    static func translate(_ event: Event) -> MeterMsg? {
        switch event {
        case .input(let input): return .input(input)
        case .line(meterSource, let line): return (try? decoder.decode(MeterFrame.self, from: Data(line.utf8))).map(MeterMsg.frame)
        case .closed(meterSource): return .meterClosed
        case .timer(retryTimer): return .retry
        case .resize(let size): return .resize(size)
        case .signal: return .signal
        default: return nil
        }
    }
}
