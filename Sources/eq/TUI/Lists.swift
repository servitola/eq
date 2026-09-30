import EQTerm
import Foundation

/// What the Presets and Devices views list, and Tune shows of a device that is not playing: read
/// from eq.json, the status file and the system's outputs when one of them comes on screen or
/// something changed, never per frame.
struct Library: Equatable {
    struct Driver: Equatable {
        /// "BE-RCA · EQ", as the Sound menu shows it.
        var name: String
        var target: DeviceChoice?
    }

    var presets: [String: Profile] = [:]
    var devices: [String: Profile] = [:]
    var fallback = Profile.flat
    /// `eq device list`'s rows, the EQ device left out: it is never an output of its own.
    var rows: [DeviceRow] = []
    /// The device whose curve plays.
    var current: DeviceChoice?
    /// The system's default output.
    var output: String?
    /// Set in driver mode, where the EQ device is the system's output and plays on its target.
    var driver: Driver?
    var apps: [AppRule] = []
    var loaded = false
    var error: String?

    var presetNames: [String] { presets.keys.sorted { $0.lowercased() < $1.lowercased() } }

    func profile(_ uid: String) -> Profile { devices[uid] ?? fallback }

    func mark(_ profile: Profile) -> Table.PresetMark? { CLI.presetMark(profile, presets: presets) }

    /// What deleting the preset leaves behind, for the question before it.
    func uses(of preset: String) -> (devices: [String], rules: Int) {
        let needle = preset.lowercased()
        let names = devices.filter { $0.value.preset?.lowercased() == needle }
            .map { uid, profile in rows.first { $0.uid == uid }?.name ?? profile.name ?? uid }.sorted()
        return (names, apps.filter { $0.preset.lowercased() == needle }.count)
    }

    static func isTarget(_ uid: String) -> Bool {
        uid != DriverControl.deviceUID && !uid.hasPrefix(AudioDeviceManager.aggregateUIDPrefix)
    }
}

extension CLI {
    static func library(_ ctx: CLIContext) -> Library {
        var library = Library(loaded: true)
        do {
            var config = try loadConfig(ctx)
            _ = config.seedPresetsIfNeeded()
            library.presets = config.presets ?? [:]
            library.devices = config.devices
            library.fallback = config.default
            library.apps = config.apps ?? []
            library.rows = deviceRows(config, connected: ctx.connectedDevices()).filter { Library.isTarget($0.uid) }
        } catch {
            library.error = "\(error)"
        }
        library.current = (try? currentDevice(ctx)).map { DeviceChoice(uid: $0.uid, name: $0.name) }
        library.output = ctx.defaultOutput()?.uid
        if let status = Status.read(from: ctx.statusURL), status.isAlive(), status.mode == .driver, let driver = status.driver {
            library.driver = Library.Driver(name: driver.deviceName, target: driver.target.map { DeviceChoice(uid: $0.uid, name: $0.name) })
        }
        return library
    }
}

/// A filter's four settings, as the Filters view steps them.
enum FilterField: Int, CaseIterable {
    case type, frequency, gain, q

    var name: String { ["type", "frequency", "gain", "Q"][rawValue] }

    /// A key's nudge (±0.1, ±0.5 or ±3, as a band takes it) in this field's own units: the next
    /// type; a 24th, a sixth of an octave or an octave; 0.1, 0.5 or 3 dB; Q 0.01, 0.1 or 1.
    func step(_ filter: inout Filter, _ nudge: Double) {
        let size = abs(nudge) < 0.3 ? 0 : (abs(nudge) < 1 ? 1 : 2)
        let sign = nudge < 0 ? -1.0 : 1.0
        func held(_ value: Double, _ range: ClosedRange<Double>) -> Double { min(max(value, range.lowerBound), range.upperBound) }
        switch self {
        case .type:
            let all = FilterType.allCases
            let at = all.firstIndex(of: filter.type) ?? 0
            filter.type = all[(at + Int(sign) + all.count) % all.count]
        case .frequency:
            let f = held(filter.frequency * pow(2, [1.0 / 24, 1.0 / 6, 1][size] * sign), Config.filterFrequencyRange)
            filter.frequency = held(Self.threeDigits(f), Config.filterFrequencyRange)
        case .gain:
            filter.gain = (held(filter.gain + [0.1, 0.5, 3][size] * sign, Config.filterGainRange) * 100).rounded() / 100
        case .q:
            filter.q = (held(filter.q + [0.01, 0.1, 1][size] * sign, Config.filterQRange) * 100).rounded() / 100
        }
    }

    /// Three significant digits, so a sixth of an octave from 1 kHz saves as 1120, not 1122.4620483…
    static func threeDigits(_ f: Double) -> Double {
        let exponent = Int(floor(log10(f))) - 2
        return exponent >= 0 ? (f / pow(10, Double(exponent))).rounded() * pow(10, Double(exponent))
            : (f * pow(10, Double(-exponent))).rounded() / pow(10, Double(-exponent))
    }

    func text(_ filter: Filter) -> String {
        switch self {
        case .type: return filter.type.rawValue.lowercased()
        case .frequency: return Self.hz(filter.frequency)
        case .gain: return String(format: "%+.1f dB", filter.gain)
        case .q: return String(format: "%.2f", filter.q)
        }
    }

    static func hz(_ f: Double) -> String { f >= 1000 ? String(format: "%g kHz", f / 1000) : String(format: "%g Hz", f) }

    /// Low- and high-pass, notch and band-pass have no gain.
    static func usesGain(_ type: FilterType) -> Bool { [.peak, .lowShelf, .highShelf].contains(type) }

    /// The message row while a field is chosen: what it is and how it moves.
    func hint(adding: Bool) -> String {
        let lead = adding ? "new filter · " : ""
        switch self {
        case .type: return lead + "type — ↑↓ peak · lowshelf · highshelf · lowpass · highpass · notch · bandpass"
        case .frequency: return lead + "frequency — ↑↓ a sixth of an octave, ⇧↑↓ an octave, Alt↑↓ a 24th"
        case .gain: return lead + "gain — ↑↓ 0.5 dB, ⇧↑↓ 3 dB, Alt↑↓ 0.1 dB"
        case .q: return lead + "Q — ↑↓ 0.1, ⇧↑↓ 1, Alt↑↓ 0.01; higher is narrower"
        }
    }
}

/// The filter being added, under the table until Enter adds it.
struct FilterForm: Equatable {
    var filter = Filter(type: .peak, frequency: 1000, gain: 0, q: CLI.defaultQ(for: .peak), origin: .hand)
    var field = FilterField.type

    /// A new type takes its own default Q while the Q is still the old type's default.
    mutating func step(_ nudge: Double) {
        let before = filter.type
        field.step(&filter, nudge)
        if filter.type != before, filter.q == CLI.defaultQ(for: before) { filter.q = CLI.defaultQ(for: filter.type) }
    }
}

/// An edit that waits for `y` in the message row, and what it will do, said first.
struct Confirm: Equatable {
    var action: WatchAction
    var question: String
}

/// The list views' selections: a row each, the Filters view's field while one is being changed,
/// and the Presets view's comparison.
struct Lists: Equatable {
    var preset = 0
    var device = 0
    var filter = 0
    var field: FilterField?
    var diff = false
    /// The name to select once the presets are read again: one just saved or renamed.
    var follow: String?

    /// The first row shown, so that the selected one is in sight.
    static func offset(selected: Int, visible: Int) -> Int {
        visible <= 0 ? 0 : max(selected - visible + 1, 0)
    }
}

/// The Presets, Devices and Filters views' keys, and Tune's other device.
extension MeterModel {
    /// Presets and Devices list what the library read; Tune shows a device that is not playing from it.
    var needsLibrary: Bool { view == .presets || view == .devices || (view == .tune && editing != nil) }

    var filters: [Filter] { header.profile?.filters ?? [] }

    var selectedPreset: String? {
        let names = library.presetNames
        return names.indices.contains(lists.preset) ? names[lists.preset] : nil
    }

    var selectedDevice: DeviceRow? { library.rows.indices.contains(lists.device) ? library.rows[lists.device] : nil }

    /// What the message row says once an edit from a list is saved.
    func done(_ action: WatchAction) -> String? {
        switch action {
        case .usePreset(let name): return "\(library.presetNames.first { $0.lowercased() == name.lowercased() } ?? name) plays on \(library.current?.name ?? "the current device")"
        case .savePreset(let name) where view == .presets: return "saved \(Config.normalizedPresetName(name))"
        case .renamePreset(let old, let new): return "renamed \(old) → \(Config.normalizedPresetName(new))"
        case .removePreset(let name): return "deleted \(name)"
        case .useDevice(let uid):
            let name = library.rows.first { $0.uid == uid }?.name ?? uid
            return library.driver != nil ? "the EQ device plays on \(name) now" : "output → \(name)"
        case .copyCurve(let device): return "copied \(library.current?.name ?? "the current curve") → \(device.name) · u undoes"
        case .addFilter(let filter): return "added a \(FilterField.type.text(filter)) at \(FilterField.hz(filter.frequency))"
        case .removeFilter(let index): return "removed filter \(index + 1)"
        default: return nil
        }
    }

    /// A click on a list's row selects it.
    mutating func select(at mouse: Mouse) -> Bool {
        switch view {
        case .presets:
            guard let row = PresetsView.item(at: mouse.x, mouse.y, size: size, count: library.presetNames.count, selected: lists.preset) else { return false }
            lists.preset = row
        case .devices:
            guard let row = DevicesView.item(at: mouse.x, mouse.y, size: size, library: library, selected: lists.device) else { return false }
            lists.device = row
        case .filters:
            guard form == nil, let row = FiltersView.item(at: mouse.x, mouse.y, size: size, count: filters.count, selected: lists.filter) else { return false }
            lists.filter = row
        default:
            return false
        }
        return true
    }

    mutating func listAction(_ action: WatchAction, in context: KeyContext) -> [MeterCmd] {
        switch action {
        case .primary:
            switch context {
            case .presets:
                guard let name = selectedPreset else { return [] }
                return apply(.usePreset(name))
            case .devices:
                guard let row = selectedDevice else { return [] }
                guard row.connected else {
                    show("\(row.name) is not connected")
                    return []
                }
                // In driver mode the output is the EQ device: picking its target again would only make it flicker.
                guard row.uid != library.current?.uid || (library.driver == nil && row.uid != library.output) else {
                    show("\(row.name) already plays", .ok)
                    return []
                }
                return apply(.useDevice(row.uid))
            case .form:
                guard let form else { return [] }
                self.form = nil
                lists.filter = filters.count
                return apply(.addFilter(form.filter))
            default: return []
            }
        case .startRename:
            if let name = selectedPreset { rename = TextField(name) }
        case .startDelete:
            confirm = deletion(in: context)
        case .toggleDiff:
            lists.diff.toggle()
        case .copyHere:
            guard let row = selectedDevice else { return [] }
            guard row.uid != library.current?.uid else {
                show("\(row.name) is the device playing: its curve is the one copied")
                return []
            }
            return apply(.copyCurve(DeviceChoice(uid: row.uid, name: row.name)))
        case .editInTune:
            guard let row = selectedDevice else { return [] }
            let choice = row.uid == library.current?.uid ? nil : DeviceChoice(uid: row.uid, name: row.name)
            let cmds = goTo(.tune)
            editing = choice
            return cmds + [.target(choice)] + (choice != nil ? [.refreshLibrary] : [])
        case .startAdd:
            let cmds = goTo(.filters)
            lists.field = nil
            form = FilterForm()
            return cmds
        case .editFields:
            if context == .fields {
                lists.field = nil
            } else if !filters.isEmpty {
                lists.field = .type
            }
        case .field(let delta):
            let all = FilterField.allCases
            if context == .form, let at = form?.field.rawValue {
                form?.field = all[(at + delta + all.count) % all.count]
            } else if let at = lists.field?.rawValue {
                lists.field = all[min(max(at + delta, 0), all.count - 1)]
            }
        case .otherDevice(let delta):
            pendingDevice = delta
            return [.refreshLibrary]
        default:
            break
        }
        return []
    }

    /// ↑ ↓ on a field: the form's changes in place, a filter's is saved at once.
    mutating func nudgeFilter(_ size: Double, in context: KeyContext) -> [MeterCmd] {
        if context == .form {
            form?.step(size)
            return []
        }
        guard let field = lists.field, filters.indices.contains(lists.filter) else { return [] }
        var filter = filters[lists.filter]
        field.step(&filter, size)
        return filter == filters[lists.filter] ? [] : apply(.setFilter(lists.filter, filter))
    }

    /// The next device for Tune to edit, the playing one first; the playing one edits as usual.
    mutating func otherDevice(_ delta: Int) -> [MeterCmd] {
        var order = library.rows
        if let at = order.firstIndex(where: { $0.uid == library.current?.uid }) { order.insert(order.remove(at: at), at: 0) }
        guard order.count > 1 else {
            show("no other device to edit")
            return []
        }
        let at = order.firstIndex { $0.uid == (editing?.uid ?? library.current?.uid) } ?? 0
        let next = order[(at + delta + order.count) % order.count]
        editing = next.uid == library.current?.uid ? nil : DeviceChoice(uid: next.uid, name: next.name)
        show(editing.map { "editing \($0.name)'s curve, which is not playing" } ?? "editing the curve that plays", .ok)
        return [.target(editing)]
    }

    /// The question before a delete, saying what it leaves behind, as a dry run would.
    private func deletion(in context: KeyContext) -> Confirm? {
        switch context {
        case .presets:
            guard let name = selectedPreset else { return nil }
            let uses = library.uses(of: name)
            var question = "delete preset \(name)?"
            if !uses.devices.isEmpty {
                question += " \(uses.devices.joined(separator: ", ")) keep\(uses.devices.count == 1 ? "s" : "") its curve, unmarked."
            }
            if uses.rules > 0 { question += " \(uses.rules) app rule\(uses.rules == 1 ? "" : "s") will match nothing." }
            return Confirm(action: .removePreset(name), question: question + " y deletes")
        case .filters:
            guard filters.indices.contains(lists.filter) else { return nil }
            let f = filters[lists.filter]
            var what = "\(FilterField.type.text(f)) \(FilterField.hz(f.frequency))"
            if FilterField.usesGain(f.type) { what += " " + FilterField.gain.text(f) }
            what += " Q " + FilterField.q.text(f) + (f.origin == .import ? ", imported" : "")
            let lastImport = f.origin == .import && filters.filter { $0.origin == .import }.count == 1
            let label = lastImport && header.profile?.imported != nil ? " The import label goes with it." : ""
            return Confirm(action: .removeFilter(lists.filter), question: "remove filter \(lists.filter + 1), \(what)?\(label) y removes")
        default:
            return nil
        }
    }
}
