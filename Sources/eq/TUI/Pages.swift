import EQTerm
import Foundation

/// What the System view shows of the daemon: its status file while it lives, and the mode eq.json
/// asks for. Read when the view opens, on a daemon, mode or target event, and on `r`.
struct SystemInfo: Equatable {
    var status: Status?
    var mode = AudioMode.tap
    /// This eq's version, which the daemon's may not be.
    var version = Build.version
    var loaded = false
    var error: String?

    var running: AudioMode? { status.map { $0.mode ?? .tap } }
}

/// `eq doctor --json` as the child printed it; it runs beside the screen, since its checks wait on
/// the daemon for a second or two.
struct DoctorState: Equatable {
    var report: DoctorReport?
    var running = false
    var failure: String?

    func check(_ name: String) -> DoctorCheck? { report?.checks.first { $0.name == name } }
}

/// `eq history` for the History view: each version's curve on the current device.
struct HistoryList: Equatable {
    struct Version: Equatable {
        var index: Int
        var date: Date
        var profile: Profile?
        var enabled: Bool?
        var mark: PresetMark?
        /// The file is there but is not a config eq can read.
        var unreadable: Bool
    }

    struct PresetMark: Equatable {
        var name: String
        var modified: Bool
    }

    var position = 0
    var versions: [Version] = []
    var note: String?
    var device: String?
    var loaded = false
    var error: String?

    var live: Version? { versions.first { $0.index == position } }
}

extension CLI {
    static func systemInfo(_ ctx: CLIContext) -> SystemInfo {
        var info = SystemInfo(status: Status.read(from: ctx.statusURL).flatMap { $0.isAlive() ? $0 : nil }, loaded: true)
        do {
            info.mode = try loadConfig(ctx).audioMode
        } catch {
            info.error = "\(error)"
        }
        return info
    }

    static func historyList(_ ctx: CLIContext) -> HistoryList {
        var list = HistoryList(loaded: true)
        do {
            let (position, note, versions) = try historyVersions(ctx)
            list.position = position
            list.note = note
            list.versions = versions.map { v in
                HistoryList.Version(index: v.index, date: v.date, profile: v.profile, enabled: v.config?.enabled,
                                    mark: v.profile.flatMap { profile in v.config.flatMap { presetMark(profile, $0) } }
                                        .map { HistoryList.PresetMark(name: $0.name, modified: $0.modified) },
                                    unreadable: v.config == nil)
            }
        } catch {
            list.error = "\(error)"
        }
        list.device = (try? currentDevice(ctx))?.name
        return list
    }
}

/// The children the TUI runs for itself, each its own source and reap timer on the runtime.
enum MeterJob: Int, CaseIterable {
    case doctor = 4
    /// `eq mode X --dry-run --json`: what a switch would do, asked before the question.
    case modePlan = 5
}

/// The list `a` and `Enter` open on the Apps view: an app with audio open, then a preset for it.
struct Picker: Equatable {
    enum Stage: Equatable {
        case app
        case preset(app: String, name: String)
    }

    struct Item: Equatable {
        /// What a pick hands on: a bundle ID, a name to look up, or a preset.
        var value: String
        var label: String
        var detail: String
    }

    var stage: Stage
    var field = TextField()
    var chosen = 0

    var title: String {
        switch stage {
        case .app: return "an app with audio open"
        case .preset(_, let name): return "a preset for \(name)"
        }
    }

    var prompt: String {
        switch stage {
        case .app: return "app: "
        case .preset: return "preset: "
        }
    }

    /// The apps or presets that have what is typed; an app not among them is offered as typed,
    /// which `eq app set` resolves as a bundle ID or an installed app's name.
    func items(running: [PlayingApp], presets: [String], rules: [AppRule]) -> [Item] {
        let typed = field.text.trimmingCharacters(in: .whitespaces)
        func has(_ texts: String...) -> Bool { typed.isEmpty || texts.contains { $0.localizedCaseInsensitiveContains(typed) } }
        switch stage {
        case .app:
            var items = running.filter { has($0.name, $0.id) }.map { app in
                Item(value: app.id, label: app.name, detail: rules.first { $0.matches(app.id) }.map { "\(app.id) · → \($0.preset)" } ?? app.id)
            }
            if !typed.isEmpty, !running.contains(where: { $0.id.caseInsensitiveCompare(typed) == .orderedSame || $0.name.caseInsensitiveCompare(typed) == .orderedSame }) {
                items.append(Item(value: typed, label: "“\(typed)”", detail: "as typed: a bundle ID or an installed app's name"))
            }
            return items
        case .preset:
            return presets.filter { has($0) }.map { Item(value: $0, label: $0, detail: "") }
        }
    }
}

/// `/` on a list: the row it started on, for Esc to go back to.
struct ListSearch: Equatable {
    var field = TextField()
    var from: Int
}

extension MeterModel {
    /// What a view reads when it comes on screen.
    mutating func arrive() -> [MeterCmd] {
        switch view {
        case .apps: return [.refreshApps]
        case .system: return [.refreshSystem] + runDoctor(unlessDone: true)
        case .history: return [.refreshHistory]
        default: return []
        }
    }

    /// What is read again after an edit, a command or an event changed the config or the daemon.
    var refreshes: [MeterCmd] {
        (needsLibrary ? [.refreshLibrary] : []) + (view == .history ? [.refreshHistory] : []) + (view == .system ? [.refreshSystem] : [])
    }

    mutating func runDoctor(unlessDone: Bool = false) -> [MeterCmd] {
        guard !doctor.running, !(unlessDone && (doctor.report != nil || doctor.failure != nil)) else { return [] }
        doctor.running = true
        return [.job(.doctor, ["doctor", "--json"])]
    }

    var selectedRule: AppRule? { library.apps.indices.contains(lists.app) ? library.apps[lists.app] : nil }

    var selectedVersion: HistoryList.Version? {
        versions.versions.indices.contains(lists.version) ? versions.versions[lists.version] : nil
    }

    /// An app's name where something says it: running now, or heard.
    func appName(_ id: String) -> String {
        running.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }?.name
            ?? [library.heard, library.held].compactMap { $0 }.first { $0.app.caseInsensitiveCompare(id) == .orderedSame }?.name ?? id
    }

    /// The Apps, System and History views' keys.
    mutating func pageAction(_ action: WatchAction, in context: KeyContext) -> [MeterCmd] {
        switch (action, context) {
        case (.primary, .apps):
            guard let rule = selectedRule else { return [] }
            picker = Picker(stage: .preset(app: rule.app, name: appName(rule.app)))
            picker?.chosen = library.presetNames.firstIndex { $0.lowercased() == rule.preset.lowercased() } ?? 0
            return library.loaded ? [] : [.refreshLibrary]
        case (.startAdd, .apps):
            picker = Picker(stage: .app)
            return [.refreshApps]
        case (.startDelete, .apps):
            guard let rule = selectedRule else { return [] }
            let name = appName(rule.app)
            let heard = library.heard?.app.caseInsensitiveCompare(rule.app) == .orderedSame
            confirm = Confirm(action: .removeAppRule(rule.app),
                              question: "remove the rule \(name) → \(rule.preset)?" + (heard ? " \(name) plays now: the device's curve comes back." : "") + " y removes")
            return []
        case (.toggleApps, _):
            return apply(.followApps(!library.followsApps))
        case (.primary, .history):
            guard let version = selectedVersion else { return [] }
            guard version.index != versions.position else {
                show("version \(version.index) is the live one", .ok)
                return []
            }
            guard !version.unreadable else {
                show("version \(version.index) cannot be read", .error)
                return []
            }
            return apply(.restoreVersion(version.index))
        case (.historyStep(let delta), _):
            let target = versions.position + delta
            guard let at = versions.versions.firstIndex(where: { $0.index == target }) else {
                show(delta > 0 ? "nothing older: eq keeps \(ConfigStore.backupCount) versions" : "this is the latest version")
                return []
            }
            lists.version = at
            return apply(.restoreVersion(target))
        case (.refresh, _):
            return [.refreshSystem] + runDoctor()
        case (.switchMode, _):
            guard modePlan == nil else { return [] }
            let target: AudioMode = system.mode == .driver ? .tap : .driver
            modePlan = target
            show("asking eq mode \(target.rawValue) --dry-run what it would do …", .plain)
            return [.job(.modePlan, ["mode", target.rawValue, "--dry-run", "--json"])]
        case (.search, _):
            search = ListSearch(from: searchRow)
            return []
        default:
            return []
        }
    }

    /// The row `/` moves on the view on screen, and the texts it searches, one per row.
    var searchRow: Int {
        get {
            switch view {
            case .presets: return lists.preset
            case .devices: return lists.device
            case .apps: return lists.app
            case .system: return lists.check
            default: return 0
            }
        }
        set {
            switch view {
            case .presets: lists.preset = newValue
            case .devices: lists.device = newValue
            case .apps: lists.app = newValue
            case .system: lists.check = newValue
            default: break
            }
        }
    }

    var searchTexts: [String] {
        switch view {
        case .presets: return library.presetNames
        case .devices: return library.rows.map(\.name)
        case .apps: return library.apps.map { "\(appName($0.app)) \($0.app) \($0.preset)" }
        case .system: return doctor.report?.checks.map { "\($0.name) \($0.detail)" } ?? []
        default: return []
        }
    }

    mutating func searchInput(_ event: InputEvent) -> [MeterCmd] {
        guard var open = search else { return [] }
        switch open.field.handle(event) {
        case .editing:
            search = open
            let typed = open.field.text
            if !typed.isEmpty, let at = searchTexts.firstIndex(where: { $0.localizedCaseInsensitiveContains(typed) }) { searchRow = at }
        case .cancel:
            searchRow = open.from
            search = nil
        case .submit:
            search = nil
        case .ignored:
            break
        }
        return []
    }

    mutating func pickerInput(_ event: InputEvent) -> [MeterCmd] {
        guard var open = picker else { return [] }
        let items = open.items(running: running, presets: library.presetNames, rules: library.apps)
        if case .key(let press) = event {
            switch press.code {
            case .esc, .char("\u{03}"):
                picker = nil
                return []
            case .up, .down:
                open.chosen = min(max(open.chosen + (press.code == .up ? -1 : 1), 0), max(items.count - 1, 0))
                picker = open
                return []
            case .char("\n"), .char("\r"):
                guard items.indices.contains(open.chosen) else { return [] }
                let item = items[open.chosen]
                switch open.stage {
                case .app:
                    let name = running.first { $0.id == item.value }?.name ?? item.value
                    picker = Picker(stage: .preset(app: item.value, name: name))
                    return []
                case .preset(let app, _):
                    picker = nil
                    return apply(.setAppRule(app, item.value))
                }
            default: break
            }
        }
        let before = open.field
        guard case .editing = open.field.handle(event), open.field != before else { return [] }
        open.chosen = 0
        picker = open
        return []
    }

    /// A child the TUI ran for itself ended: the doctor's report, or what a mode switch would do.
    mutating func jobEnded(_ job: MeterJob, code: Int32) -> [MeterCmd] {
        let text = (jobLines.removeValue(forKey: job) ?? []).joined(separator: "\n")
        let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        let error = (object?["error"] as? [String: Any])?["message"] as? String
        switch job {
        case .doctor:
            doctor.running = false
            if let report = try? JSONDecoder().decode(DoctorReport.self, from: Data(text.utf8)) {
                doctor.report = report
                doctor.failure = nil
                lists.check = min(lists.check, max(report.checks.count - 1, 0))
            } else {
                doctor.failure = error ?? (text.isEmpty ? "eq doctor printed nothing (exit \(code))" : ChildOutput.plain(text.components(separatedBy: "\n")[0]))
            }
            return []
        case .modePlan:
            guard let target = modePlan else { return [] }
            modePlan = nil
            guard let object, error == nil else {
                show(error ?? "eq mode \(target.rawValue) --dry-run failed (exit \(code))", .error)
                return []
            }
            if object["install"] != nil {
                show("eq mode driver installs the EQ driver first, and macOS asks for an administrator password: q, then run eq mode driver in a shell")
                return []
            }
            let output = (object["output"] as? [String: Any])?["name"] as? String
            let question: String
            switch target {
            case .driver:
                question = "switch to driver mode? " + (output.map { "\($0) · EQ becomes the system output and plays on \($0)." } ?? "the EQ device becomes the system output.")
            case .tap:
                question = "switch to tap mode? the EQ device hides, a real device is the output again and eq taps it."
            }
            confirm = Confirm(action: .run(["mode", target.rawValue]), question: question + " y switches")
            return []
        }
    }

    /// What the message row says once an edit from the Apps or History view is saved.
    func donePage(_ action: WatchAction) -> String? {
        switch action {
        case .setAppRule(let app, let preset):
            let name = running.first { $0.id.caseInsensitiveCompare(app) == .orderedSame || $0.name.caseInsensitiveCompare(app) == .orderedSame }?.name ?? app
            return "\(name) → \(preset)" + (library.followsApps ? "" : " · apps are off: o follows the rules")
        case .removeAppRule(let app): return "removed the rule of \(appName(app))"
        case .followApps(let on):
            return on ? "apps on (experimental): while an app with a rule plays, its preset does" : "apps off: the device's curve plays whatever plays"
        case .restoreVersion(let index):
            let date = versions.versions.first { $0.index == index }.map { " from " + HistoryView.time($0.date) } ?? ""
            return "restored version \(index)\(date) · ← → step, Enter jumps back"
        default: return nil
        }
    }
}
