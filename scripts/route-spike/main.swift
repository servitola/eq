// routespike — M0 spike for eq app routing. Throwaway; see README-less usage below and run-all.sh.
import CoreAudio
import Foundation

let usage = """
usage: routespike <command> [options]
  devices                                   output devices, marking the ones the spike refuses
  procs                                     Core Audio process objects
  cleanup                                   destroy leftover spike aggregates/public taps, kill stray tones
  check      [--source D]                   1 s quiet beep: does this binary's tap capture anything?
  l1         --source D --target D [--drift 0|1] [--clicks N] [--sine-seconds S]
  exclude    --source D [--mute]            live exclusion edit on a main-style device tap
  bundle     --source D [--restore 0|1] [--pre]
  dual       --source D --target D [--route-first]
  start      --source D --target D [--mute muted|mwt] [--tap-first]
  kill       --source D --target D [--mute muted|mwt] [--public]
  format     --source D --target D [--rate Hz]
  music
common: --ask  ask the listener questions on /dev/tty and record the answers
D: builtin, an exact device UID, or a unique piece of the name
"""

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { print(usage); exit(2) }
func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}
func flag(_ name: String) -> Bool { arguments.contains(name) }
askUser = flag("--ask")

func shell(_ path: String, _ args: [String]) -> (status: Int32, out: String)? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Refuses while eq runs in tap mode: its main tap sits on the default output, which the spike's
/// sources and targets share, and two muting taps on one device would stack.
func preflight() {
    let daemon = shell("/usr/bin/pgrep", ["-f", "MacOS/eq daemon"])?.out.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let eq = ["/opt/homebrew/bin/eq", "/usr/local/bin/eq", "/Applications/EQ.app/Contents/MacOS/eq"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    var mode = "unknown", state = "unknown", target = "-"
    if let eq, let result = shell(eq, ["status", "--json"]),
       let json = try? JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any] {
        mode = json["mode"] as? String ?? "unknown"
        state = json["state"] as? String ?? "unknown"
        target = ((json["driver"] as? [String: Any])?["target"] as? [String: Any])?["name"] as? String ?? "-"
    }
    say("eq: daemon \(daemon.isEmpty ? "not running" : "pid \(daemon.replacingOccurrences(of: "\n", with: ","))"), mode \(mode), state \(state), driver target \(target); default output \(defaultOutputUID() ?? "-")")
    if !daemon.isEmpty, mode != "driver" {
        fail("the eq daemon is running in \(mode) mode; the spike runs only with eq in driver mode or stopped (launchctl bootout gui/$UID/com.servitola.eq.daemon)")
    }
}

func need(_ name: String) -> Device {
    guard let spec = option(name) else { fail("\(name) is required\n\(usage)") }
    return resolveDevice(spec)
}

switch command {
case "devices":
    let def = defaultOutputUID()
    for d in allDevices() where d.outputStreams > 0 {
        say("\(d.uid == def ? "*" : " ") \(d.describe())\(d.refusal.map { "  — refused: \($0)" } ?? "")")
    }
    exit(0)
case "procs":
    for p in audioProcesses() {
        say("\(p.object)\tpid \(p.pid)\t\(p.runningOutput ? "output" : "      ")\t\(p.bundleID)")
    }
    exit(0)
case "cleanup":
    let found = destroyLeftovers(verbose: true)
    for pid in pids(named: "spiketone") { kill(pid, SIGKILL) }
    say("cleanup: \(found.aggregates) aggregates, \(found.taps) public taps destroyed; private ones die with their owner")
    exit(0)
case "hold":
    installTeardown()
    guard let pid = option("--pid").flatMap(pid_t.init) else { fail("--pid") }
    hold(pid: pid, source: need("--source"), target: need("--target"), mute: parseMute(option("--mute")),
         isPublic: flag("--public"))
default:
    break
}

preflight()
installTeardown()
let defaultBefore = defaultOutputUID()

switch command {
case "check":
    testCheck(resolveDevice(option("--source") ?? "builtin"))
case "l1":
    let source = need("--source"), target = need("--target")
    guard source.uid != target.uid else { fail("source and target must differ") }
    testL1(source: source, target: target, drift: option("--drift") != "0", clicks: Int(option("--clicks") ?? "") ?? 6,
           sineSeconds: Double(option("--sine-seconds") ?? "") ?? 60)
case "exclude":
    testExcludeLive(device: need("--source"), mute: flag("--mute"))
case "bundle":
    testBundle(device: need("--source"), restore: option("--restore") == "1", pre: flag("--pre"))
case "dual":
    let source = need("--source"), target = need("--target")
    guard source.uid != target.uid else { fail("source and target must differ") }
    testDual(source: source, target: target, routeFirst: flag("--route-first"))
case "start":
    let source = need("--source"), target = need("--target")
    guard source.uid != target.uid else { fail("source and target must differ") }
    testStart(source: source, target: target, mute: parseMute(option("--mute")), tapFirst: flag("--tap-first"))
case "kill":
    let source = need("--source"), target = need("--target")
    guard source.uid != target.uid else { fail("source and target must differ") }
    testKill(source: source, target: target, mute: parseMute(option("--mute")), isPublic: flag("--public"))
case "format":
    testFormat(device: need("--source"), target: need("--target"), processRate: option("--rate").flatMap(Double.init))
case "music":
    testMusic()
default:
    fail("unknown command \(command)\n\(usage)")
}

let defaultAfter = defaultOutputUID()
if defaultAfter != defaultBefore {
    say("WARNING: the default output changed during the test (\(defaultBefore ?? "-") → \(defaultAfter ?? "-")); the spike never sets it")
}
exit(0)
