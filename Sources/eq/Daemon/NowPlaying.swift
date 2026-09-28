import Foundation

/// Asks the user's `nowplayingseek` which app macOS considers now playing. Used only to break a
/// tie between two matching apps; a missing binary, a slow answer or a paused player all mean "no
/// opinion", and the first rule wins.
enum NowPlaying {
    static let binary = "/opt/homebrew/bin/nowplayingseek"
    static let timeout: TimeInterval = 0.3

    private struct Answer: Decodable {
        var app: String?
        var playing: Bool?
    }

    static func parse(_ data: Data) -> String? {
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data), answer.playing == true,
              let app = answer.app, !app.isEmpty else { return nil }
        return app
    }

    /// Runs off `queue` and answers on it.
    static func live(queue: DispatchQueue, binary: String = binary, timeout: TimeInterval = timeout) -> AppFollower.NowPlaying {
        { reply in
            guard FileManager.default.isExecutableFile(atPath: binary) else { return reply(nil) }
            DispatchQueue.global(qos: .utility).async {
                let app = ask(binary, timeout: timeout)
                queue.async { reply(app) }
            }
        }
    }

    static func ask(_ binary: String, timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["status", "--minify"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        guard done.wait(timeout: .now() + timeout) == .success else {
            // SIGKILL: the daemon ignores SIGTERM, and the child inherits that.
            kill(process.processIdentifier, SIGKILL)
            return nil
        }
        return parse(pipe.fileHandleForReading.readDataToEndOfFile())
    }
}
