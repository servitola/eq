import EQTerm
import Foundation

/// The app rules, the one heard now marked; the apps with audio open; and, when eq.json has any,
/// the routes as the daemon plays them, which only eq.json edits.
struct AppsView {
    let scene: MeterScene

    private let t: Theme
    private let p: Palette
    private var console: Bool { scene.settings.look == .console }

    init(scene: MeterScene) {
        self.scene = scene
        t = scene.theme
        p = t.p
    }

    struct Layout {
        var rules: Rect
        var playing: Rect?
        var routes: Rect?
    }

    /// Why no route plays although eq.json has some.
    static func routeNote(_ library: Library) -> String? {
        if library.driver != nil { return RoutePolicy.driverNote }
        return library.followsRoutes ? nil : "experimental.routes is off in eq.json: the rules wait"
    }

    /// The rules take what the apps with audio open (up to six) and the routes leave.
    static func layout(_ size: Size, library: Library, running: Int) -> Layout {
        let body = Chrome.body(size)
        let routesHeight = library.routes.isEmpty ? 0
            : min(library.routes.count + 3 + (routeNote(library) != nil ? 1 : 0), max(body.height / 3, 5))
        let rest = body.height - routesHeight
        let playing = min(max(running, 1), 6) + 2
        let rules = rest - playing >= 5 ? rest - playing : rest
        var layout = Layout(rules: Rect(x: body.x, y: body.y, width: body.width, height: max(rules, 0)))
        if rules < rest { layout.playing = Rect(x: body.x, y: body.y + rules, width: body.width, height: playing) }
        if routesHeight >= 4 { layout.routes = Rect(x: body.x, y: body.y + rest, width: body.width, height: routesHeight) }
        return layout
    }

    static func item(at x: Int, _ y: Int, size: Size, library: Library, running: Int, selected: Int) -> Int? {
        let box = layout(size, library: library, running: running).rules
        let first = box.y + 2, visible = max(box.height - 3, 0)
        guard box.inset(by: 1).contains(x: x, y: y), y >= first, y - first < visible else { return nil }
        let index = Lists.offset(selected: selected, visible: visible) + y - first
        return index < library.apps.count ? index : nil
    }

    private func label(_ text: String) -> String { console ? text.uppercased() : text }

    private func name(_ id: String) -> String {
        scene.running.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }?.name
            ?? [scene.library.heard, scene.library.held].compactMap { $0 }.first { $0.app.caseInsensitiveCompare(id) == .orderedSame }?.name ?? id
    }

    private func same(_ a: String?, _ b: String) -> Bool { a.map { $0.caseInsensitiveCompare(b) == .orderedSame } ?? false }

    func draw(into screen: inout Screen) {
        Chrome.top(scene, into: &screen)
        let l = Self.layout(scene.size, library: scene.library, running: scene.running.count)
        rules(l.rules, into: &screen)
        if let r = l.playing { playing(r, into: &screen) }
        if let r = l.routes { routes(r, into: &screen) }
        Chrome.bottom(scene, into: &screen)
    }

    private func rules(_ box: Rect, into screen: inout Screen) {
        let library = scene.library
        let rules = library.apps
        let state = library.followsApps ? "on · experimental" : "off — o follows them"
        Boxes.draw(box, into: &screen, t, border: p.borderHi, title: label("app rules"),
                   right: library.loaded ? "\(state) · \(rules.count)" : nil, fill: console ? p.surface : nil)
        guard box.height >= 4, box.width >= 40 else { return }
        let wide = box.width >= 90
        let nameX = box.x + 5, idX = box.x + 23
        let presetX = wide ? box.x + 53 : idX
        let statusX = box.right - 17
        screen.ink(label("app"), x: nameX, y: box.y + 1, t.style(p.text3))
        if wide { screen.ink(label("bundle ID"), x: idX, y: box.y + 1, t.style(p.text3)) }
        screen.ink(label("preset"), x: presetX + 2, y: box.y + 1, t.style(p.text3))
        screen.ink(label("now"), x: statusX, y: box.y + 1, t.style(p.text3))
        if let error = library.error {
            screen.ink(error, x: box.x + 2, y: box.y + 2, t.style(p.danger), limit: box.width - 4)
            return
        }
        guard !rules.isEmpty else {
            let text = library.loaded ? "no rules — a adds one: an app with audio open, then its preset" : "reading the rules…"
            screen.ink(text, x: box.x + 2, y: box.y + 2, t.style(p.text3), limit: box.width - 4)
            return
        }
        let visible = max(box.height - 3, 0)
        let first = Lists.offset(selected: scene.lists.app, visible: visible)
        for (i, rule) in rules.enumerated().dropFirst(first).prefix(visible) {
            let y = box.y + 2 + i - first
            let here = i == scene.lists.app
            let bg: Swatch? = here ? p.sel : nil
            if here {
                screen.fill(Rect(x: box.x + 1, y: y, width: box.width - 2, height: 1), with: Cell(" ", style: t.style(nil, p.sel)))
                screen.ink("▸", x: box.x + 1, y: y, t.style(p.accent, bg, .bold))
            }
            let heard = library.followsApps && same(library.heard?.app, rule.app)
            let held = same(library.held?.app, rule.app)
            if heard { screen.ink("◉", x: box.x + 3, y: y, t.style(p.accent, bg, .bold)) }
            let plays = scene.running.contains { $0.id.caseInsensitiveCompare(rule.app) == .orderedSame }
            let name = name(rule.app)
            screen.ink(TerminalText.truncated(name, columns: (wide ? idX : presetX) - nameX - 1), x: nameX, y: y,
                       t.style(heard || here ? p.title : p.text, bg, heard || here ? .bold : []))
            if wide { screen.ink(TerminalText.truncated(rule.app, columns: presetX - idX - 1), x: idX, y: y, t.style(p.text3, bg)) }
            let missing = !library.presets.keys.contains { $0.lowercased() == rule.preset.lowercased() }
            screen.ink("→ ", x: presetX, y: y, t.style(p.text3, bg))
            screen.ink(TerminalText.truncated(rule.preset, columns: statusX - presetX - 4), x: presetX + 2, y: y,
                       t.style(missing ? p.warn : p.accent, bg, missing ? [] : .bold))
            let status: (String, Swatch)? = missing ? ("no such preset", p.warn) : heard ? ("heard now", p.ok)
                : held ? ("your edit held", p.warn) : plays ? ("has audio", p.text2) : nil
            if let status { screen.ink(status.0, x: statusX, y: y, t.style(status.1, bg), limit: box.right - 1 - statusX) }
        }
    }

    private func playing(_ box: Rect, into screen: inout Screen) {
        let running = scene.running
        Boxes.draw(box, into: &screen, t, border: p.border, title: label("with audio open"), right: "\(running.count)",
                   fill: console ? p.surface : nil)
        guard box.height >= 3, box.width >= 40 else { return }
        guard !running.isEmpty else {
            screen.ink("no app has audio open now", x: box.x + 2, y: box.y + 1, t.style(p.text3), limit: box.width - 4)
            return
        }
        let wide = box.width >= 90
        let idX = box.x + 23, ruleX = wide ? box.x + 53 : idX
        for (i, app) in running.prefix(box.height - 2).enumerated() {
            let y = box.y + 1 + i
            let heard = scene.library.followsApps && same(scene.library.heard?.app, app.id)
            screen.ink("●", x: box.x + 3, y: y, t.style(heard ? p.accent : p.text3))
            screen.ink(TerminalText.truncated(app.name, columns: (wide ? idX : ruleX) - box.x - 6), x: box.x + 5, y: y,
                       t.style(heard ? p.title : p.text, nil, heard ? .bold : []))
            if wide { screen.ink(TerminalText.truncated(app.id, columns: ruleX - idX - 1), x: idX, y: y, t.style(p.text3)) }
            if let rule = scene.library.apps.first(where: { $0.matches(app.id) }) {
                screen.ink("→ ", x: ruleX, y: y, t.style(p.text3))
                screen.ink(rule.preset, x: ruleX + 2, y: y, t.style(p.accent), limit: box.right - 2 - ruleX - 2)
            } else {
                screen.ink("no rule — a adds one", x: ruleX, y: y, t.style(p.text3), limit: box.right - 2 - ruleX)
            }
        }
    }

    private func routes(_ box: Rect, into screen: inout Screen) {
        let library = scene.library
        Boxes.draw(box, into: &screen, t, border: p.border, title: label("routes · read-only"),
                   right: library.followsRoutes ? "on · eq.json" : "off · eq.json", fill: console ? p.surface : nil)
        guard box.height >= 4, box.width >= 40 else { return }
        let outputsX = box.x + 23, nowX = box.right - 36, whyX = box.right - 14
        for (x, text) in [(box.x + 5, "app"), (outputsX, "outputs, first available"), (nowX, "plays on"), (whyX, "why")] {
            screen.ink(label(text), x: x, y: box.y + 1, t.style(p.text3))
        }
        let note = Self.routeNote(library)
        let rows = box.height - 3 - (note != nil ? 1 : 0)
        for (i, rule) in library.routes.prefix(max(rows, 0)).enumerated() {
            let y = box.y + 2 + i
            let live = library.routed.first { $0.app.caseInsensitiveCompare(rule.app) == .orderedSame }
            screen.ink(TerminalText.truncated(live?.name ?? name(rule.app), columns: outputsX - box.x - 6), x: box.x + 5, y: y, t.style(p.text))
            screen.ink(TerminalText.truncated(rule.outputs.joined(separator: " › "), columns: nowX - outputsX - 1), x: outputsX, y: y,
                       t.style(p.text2))
            guard let live, live.playing else {
                screen.ink("—", x: nowX, y: y, t.style(p.text3))
                screen.ink("not playing", x: whyX, y: y, t.style(p.text3), limit: box.right - 2 - whyX)
                continue
            }
            screen.ink(TerminalText.truncated(live.target?.name ?? "the main path", columns: whyX - nowX - 1), x: nowX, y: y,
                       t.style(live.target != nil ? p.accent : p.text2, nil, .bold))
            let why = live.idle == true ? "idle" : live.reason.rawValue
            screen.ink(why, x: whyX, y: y, t.style(live.reason == .suspended || live.reason == .exhausted ? p.warn : p.text2),
                       limit: box.right - 2 - whyX)
        }
        if let note { screen.ink("! " + note, x: box.x + 2, y: box.bottom - 2, t.style(p.warn), limit: box.width - 4) }
    }
}

/// The daemon's state, the mode and, in driver mode, the driver's health; beside them `eq doctor`
/// check by check, the chosen one's whole text under the list.
struct SystemView {
    let scene: MeterScene

    private let t: Theme
    private let p: Palette
    private var console: Bool { scene.settings.look == .console }

    init(scene: MeterScene) {
        self.scene = scene
        t = scene.theme
        p = t.p
    }

    struct Layout {
        var status: Rect
        var driver: Rect?
        var doctor: Rect?
    }

    /// The daemon's rows, then the driver's beside or under them in driver mode; the rest is the
    /// doctor's, beside them from 100 columns.
    var layout: Layout {
        let body = Chrome.body(scene.size)
        let status = statusRows.count + 2
        let driver = driverRows.map { $0.count + 2 }
        if body.width >= 100 {
            let left = 50
            let top = Rect(x: body.x, y: body.y, width: left, height: min(status, body.height))
            let rest = body.height - top.height
            return Layout(status: top, driver: driver.flatMap { rest >= 5 ? Rect(x: body.x, y: top.bottom, width: left, height: min($0, rest)) : nil },
                          doctor: Rect(x: body.x + left + 1, y: body.y, width: body.width - left - 1, height: body.height))
        }
        let height = min(max(status, driver ?? 0), body.height)
        let half = driver != nil ? body.width / 2 : body.width
        let rest = body.height - height
        return Layout(status: Rect(x: body.x, y: body.y, width: half, height: height),
                      driver: driver.map { _ in Rect(x: body.x + half, y: body.y, width: body.width - half, height: height) },
                      doctor: rest >= 4 ? Rect(x: body.x, y: body.y + height, width: body.width, height: rest) : nil)
    }

    /// Rows under the doctor's list for the chosen check's whole text.
    static func detailRows(_ box: Rect) -> Int { box.height >= 10 ? 3 : 0 }

    static func item(at x: Int, _ y: Int, scene: MeterScene) -> Int? {
        guard let box = SystemView(scene: scene).layout.doctor, let count = scene.doctor.report?.checks.count else { return nil }
        let detail = detailRows(box)
        let visible = max(box.height - 2 - (detail > 0 ? detail + 1 : 0), 0)
        let first = box.y + 1
        guard box.inset(by: 1).contains(x: x, y: y), y >= first, y - first < visible else { return nil }
        let index = Lists.offset(selected: scene.lists.check, visible: visible) + y - first
        return index < count ? index : nil
    }

    private func label(_ text: String) -> String { console ? text.uppercased() : text }

    func draw(into screen: inout Screen) {
        Chrome.top(scene, into: &screen)
        let l = layout
        status(l.status, into: &screen)
        if let r = l.driver { driver(r, into: &screen) }
        if let r = l.doctor { doctor(r, into: &screen) }
        Chrome.bottom(scene, into: &screen)
    }

    private typealias Row = (label: String, runs: [(String, Swatch)])

    private func rows(_ box: Rect, _ rows: [Row], into screen: inout Screen) {
        for (i, row) in rows.prefix(box.height - 2).enumerated() {
            let y = box.y + 1 + i
            screen.ink(label(row.label), x: box.x + 2, y: y, t.style(p.text3))
            var x = box.x + 11
            for run in row.runs where x < box.right - 2 {
                x += screen.ink(run.0, x: x, y: y, t.style(run.1), limit: box.right - 2 - x)
            }
        }
    }

    /// A doctor check as a row: its mark and detail, or what stands in while the doctor runs.
    private func checkRuns(_ name: String) -> [(String, Swatch)] {
        guard let check = scene.doctor.check(name) else { return [(scene.doctor.running ? "eq doctor is running…" : "—", p.text3)] }
        return [(mark(check).0 + " ", mark(check).1), (check.detail, p.text2)]
    }

    private func mark(_ check: DoctorCheck) -> (String, Swatch) {
        check.warning ? ("!", p.warn) : (check.ok ? ("✓", p.ok) : ("✗", p.danger))
    }

    private func status(_ box: Rect, into screen: inout Screen) {
        Boxes.draw(box, into: &screen, t, border: p.borderHi, title: label("daemon"), right: scene.system.loaded ? nil : "reading…",
                   fill: console ? p.surface : nil)
        guard box.height >= 3, box.width >= 30 else { return }
        rows(box, statusRows, into: &screen)
    }

    private var statusRows: [Row] {
        let info = scene.system
        guard let status = info.status else {
            return [("daemon", [("not running", p.danger), (" — see the doctor", p.text3)]), ("mode", [(info.mode.rawValue, p.title)]),
                    ("eq", [(info.version, p.text2)]), ("agent", checkRuns("launch agent"))]
        }
        var rows: [Row] = []
        let state: Swatch = status.state == .running ? p.ok : (status.state == .starting || status.state == .bypassed ? p.warn : p.danger)
        rows.append(("daemon", [(status.state.rawValue, state), (" · pid \(status.pid)", p.text2)]))
        let running = info.running ?? .tap
        var mode: [(String, Swatch)] = [(info.mode.rawValue, p.title)]
        if running != info.mode { mode.append((" · the daemon runs the \(running.rawValue)", p.warn)) }
        if let driver = status.driver, running == .driver { mode.append((" · \(driver.deviceName)", p.text2)) }
        rows.append(("mode", mode))
        if let device = status.driver?.target ?? status.device {
            let source = status.profile == .device ? "own profile" : (status.profile == .default ? "default profile" : "")
            rows.append(("device", [(device.name, p.title), (" [\(device.transport)] ", p.text3), ("\(Table.whole(status.sampleRate)) Hz", p.text2)]
                         + (source.isEmpty ? [] : [(" · " + source, status.profile == .device ? p.text2 : p.warn)])))
        }
        if running == .driver, let ms = status.driver?.latencyMs {
            rows.append(("latency", [("\(Table.whole(ms)) ms", p.text), (", reported to players", p.text3)]))
        } else if let latency = CLI.latencyText(status, paint: false) {
            rows.append(("latency", [(latency, p.text)]))
        }
        let slips = running == .driver ? nil : CLI.ringCounts(status)
        rows.append(("audio", [(status.enabled ? "on" : "bypassed", status.enabled ? p.ok : p.warn)]
                     + (running == .driver ? [] : [(" · " + (slips ?? "no slips"), slips == nil ? p.text2 : p.warn)])))
        if let reduction = status.compReductionDB { rows.append(("comp", [(String(format: "%.1f dB", reduction == 0 ? 0 : reduction), p.warn)])) }
        if let heard = status.apps?.overlay { rows.append(("app", [(heard.name, p.title), (" → ", p.text3), (heard.preset, p.accent)])) }
        let version = status.version ?? "pre-v3"
        rows.append(("eq", [(info.version, p.text2)] + (version == info.version ? [] : [(" · daemon \(version)", p.warn)])))
        rows.append(("agent", checkRuns("launch agent")))
        if let error = status.error { rows.append(("error", [(error, p.danger)])) }
        for warning in status.warnings ?? [] { rows.append(("warning", [(warning, p.warn)])) }
        return rows
    }

    private func driver(_ box: Rect, into screen: inout Screen) {
        guard let driver = scene.system.status?.driver, let rows = driverRows else { return }
        Boxes.draw(box, into: &screen, t, border: p.border, title: label("driver"), right: driver.deviceName, fill: console ? p.surface : nil)
        guard box.height >= 3, box.width >= 30 else { return }
        self.rows(box, rows, into: &screen)
    }

    /// Only in driver mode: what the plug-in reports about playing on its target.
    private var driverRows: [Row]? {
        guard scene.system.running == .driver, let driver = scene.system.status?.driver else { return nil }
        let slipped = driver.underruns + driver.overruns > 0
        let steady = abs(driver.clockPpm) <= Doctor.clockPpmLimit
        var rows: [Row] = [
            ("target", driver.target.map { [($0.name, p.title), (" [\($0.transport)]", p.text3)] } ?? [("none", p.danger)]),
            ("IO", [(driver.ioRunning ? "running" : "idle", driver.ioRunning ? p.ok : p.warn)]),
            ("EQ", [(driver.eqActive ? "active" : "no curve", driver.eqActive ? p.ok : p.warn)]),
            ("slips", [("\(driver.underruns) underruns, \(driver.overruns) overruns", slipped ? p.warn : p.text2)]),
            ("clock", [(String(format: "%+.1f ppm", driver.clockPpm), steady ? p.text2 : p.warn)]),
            ("default", [(driver.isDefault ? "the EQ device" : "not the EQ device — sound bypasses eq", driver.isDefault ? p.ok : p.warn)]),
            ("writer", checkRuns("driver writer")),
        ]
        if driver.hidden { rows.append(("hidden", [("yes", p.text2)])) }
        return rows
    }

    private func doctor(_ box: Rect, into screen: inout Screen) {
        let doctor = scene.doctor
        let checks = doctor.report?.checks ?? []
        let problems = checks.filter { !$0.ok && !$0.warning }.count, warnings = checks.filter(\.warning).count
        var right = doctor.running ? "running…" : (doctor.failure != nil ? "failed" : "")
        if doctor.report != nil, !doctor.running {
            right = problems + warnings == 0 ? "ok"
                : [problems > 0 ? "\(problems) problem\(problems == 1 ? "" : "s")" : nil, warnings > 0 ? "\(warnings) warning\(warnings == 1 ? "" : "s")" : nil]
                    .compactMap { $0 }.joined(separator: " · ")
        }
        Boxes.draw(box, into: &screen, t, border: problems > 0 ? p.danger : p.border, title: label("doctor"), right: right + " · r runs it again",
                   fill: console ? p.surface : nil)
        guard box.height >= 3, box.width >= 30 else { return }
        if let failure = doctor.failure, checks.isEmpty {
            screen.ink(failure, x: box.x + 2, y: box.y + 1, t.style(p.danger), limit: box.width - 4)
            return
        }
        guard !checks.isEmpty else {
            screen.ink("running eq doctor …", x: box.x + 2, y: box.y + 1, t.style(p.text3), limit: box.width - 4)
            return
        }
        let detail = Self.detailRows(box)
        let visible = max(box.height - 2 - (detail > 0 ? detail + 1 : 0), 0)
        let first = Lists.offset(selected: scene.lists.check, visible: visible)
        let nameWidth = min(checks.map { TerminalText.width($0.name) }.max() ?? 0, 16)
        for (i, check) in checks.enumerated().dropFirst(first).prefix(visible) {
            let y = box.y + 1 + i - first
            let here = i == scene.lists.check
            let bg: Swatch? = here ? p.sel : nil
            if here {
                screen.fill(Rect(x: box.x + 1, y: y, width: box.width - 2, height: 1), with: Cell(" ", style: t.style(nil, p.sel)))
                screen.ink("▸", x: box.x + 1, y: y, t.style(p.accent, bg, .bold))
            }
            let (symbol, ink) = mark(check)
            screen.ink(symbol, x: box.x + 3, y: y, t.style(ink, bg, .bold))
            screen.ink(TerminalText.truncated(check.name, columns: nameWidth), x: box.x + 5, y: y, t.style(here ? p.title : p.text, bg, here ? .bold : []))
            let x = box.x + 7 + nameWidth
            screen.ink(TerminalText.truncated(check.detail, columns: max(box.right - 2 - x, 0)), x: x, y: y, t.style(p.text2, bg))
        }
        guard detail > 0, checks.indices.contains(scene.lists.check) else { return }
        let rule = box.bottom - 2 - detail
        screen.ink("├" + String(repeating: "─", count: box.width - 2) + "┤", x: box.x, y: rule, t.style(p.border, console ? p.surface : nil))
        let check = checks[scene.lists.check]
        let lines = HelpLayout.wrap(check.name + " — " + check.detail, width: max(box.width - 6, 8))
        for (i, line) in lines.prefix(detail).enumerated() {
            screen.ink(line, x: box.x + 3, y: rule + 1 + i, t.style(i == 0 ? mark(check).1 : p.text2))
        }
    }
}

/// `eq history`: each saved version of eq.json with the current device's curve in it, the live one
/// marked; beside them the chosen one's curve over the live one's, and what differs.
struct HistoryView {
    let scene: MeterScene

    private let t: Theme
    private let p: Palette
    private var console: Bool { scene.settings.look == .console }

    init(scene: MeterScene) {
        self.scene = scene
        t = scene.theme
        p = t.p
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    static func time(_ date: Date) -> String { clock.string(from: date) }

    /// Wide enough for the seconds, the preamp and the preset beside each version's spark.
    static func split(_ size: Size) -> SplitLayout { SplitLayout(size, wide: 58) }

    static func item(at x: Int, _ y: Int, size: Size, count: Int, selected: Int) -> Int? {
        split(size).item(at: x, y, count: count, selected: selected)
    }

    private func label(_ text: String) -> String { console ? text.uppercased() : text }

    func draw(into screen: inout Screen) {
        Chrome.top(scene, into: &screen)
        let l = Self.split(scene.size)
        list(l, into: &screen)
        if let r = l.preview { preview(r, into: &screen) }
        Chrome.bottom(scene, into: &screen)
    }

    private func list(_ l: SplitLayout, into screen: inout Screen) {
        let box = l.list
        let history = scene.versions
        let full = box.width >= 56
        Boxes.draw(box, into: &screen, t, border: p.borderHi, title: label("history") + (history.device.map { " · " + $0 } ?? ""),
                   right: history.loaded ? "\(history.versions.count) · live \(history.position)" : nil, fill: console ? p.surface : nil)
        guard box.height >= 4, box.width >= 30 else { return }
        let spark = box.x + (full ? 23 : 20), preamp = spark + 12, preset = preamp + 7
        screen.ink(label("#"), x: box.x + 5, y: box.y + 1, t.style(p.text3))
        screen.ink(label("saved"), x: box.x + 8, y: box.y + 1, t.style(p.text3))
        if spark + 10 < box.right - 1 { screen.ink(label("curve"), x: spark, y: box.y + 1, t.style(p.text3)) }
        if full {
            screen.ink(label("pre"), x: preamp + 1, y: box.y + 1, t.style(p.text3))
            screen.ink(label("preset"), x: preset, y: box.y + 1, t.style(p.text3), limit: box.right - 2 - preset)
        }
        if let error = history.error {
            screen.ink(error, x: box.x + 2, y: box.y + 2, t.style(p.danger), limit: box.width - 4)
            return
        }
        guard !history.versions.isEmpty else {
            let text = history.loaded ? "no history yet — nothing has been saved" : "reading eq history…"
            screen.ink(text, x: box.x + 2, y: box.y + 2, t.style(p.text3), limit: box.width - 4)
            return
        }
        let visible = l.visible()
        let first = Lists.offset(selected: scene.lists.version, visible: visible)
        for (i, version) in history.versions.enumerated().dropFirst(first).prefix(visible) {
            let y = box.y + 2 + i - first
            let here = i == scene.lists.version
            let live = version.index == history.position
            let bg: Swatch? = here ? p.sel : nil
            if here {
                screen.fill(Rect(x: box.x + 1, y: y, width: box.width - 2, height: 1), with: Cell(" ", style: t.style(nil, p.sel)))
                screen.ink("▸", x: box.x + 1, y: y, t.style(p.accent, bg, .bold))
            }
            if live { screen.ink("◉", x: box.x + 3, y: y, t.style(p.accent, bg, .bold)) }
            screen.ink(String(format: "%2d", version.index), x: box.x + 5, y: y, t.style(live ? p.title : p.text3, bg, live ? .bold : []))
            let time = Self.time(version.date)
            screen.ink(full ? time : String(time.dropLast(3)), x: box.x + 8, y: y, t.style(live || here ? p.text : p.text2, bg))
            guard spark + 10 < box.right - 1 else { continue }
            if version.unreadable {
                screen.ink("unreadable", x: spark, y: y, t.style(p.danger, bg))
                continue
            }
            guard let profile = version.profile else { continue }
            Spark.draw(profile.bands, x: spark, y: y, t, bg: bg, into: &screen)
            guard full else { continue }
            screen.ink(MeterScene.gainText(profile.preamp).leftPadded(to: 5), x: preamp, y: y, t.style(t.gain(profile.preamp), bg))
            var x = preset
            if version.enabled == false { x += screen.ink("off ", x: x, y: y, t.style(p.warn, bg)) }
            if let mark = version.mark {
                let used = screen.ink(TerminalText.truncated(mark.name, columns: max(box.right - 3 - x, 0)), x: x, y: y, t.style(p.text, bg))
                if mark.modified { screen.ink("*", x: x + used, y: y, t.style(p.warn, bg, .bold)) }
            }
        }
    }

    private func preview(_ r: Rect, into screen: inout Screen) {
        let history = scene.versions
        let chosen = history.versions.indices.contains(scene.lists.version) ? history.versions[scene.lists.version] : nil
        guard let chosen, let profile = chosen.profile else {
            Boxes.draw(r, into: &screen, t, border: p.border, title: label("curve"), fill: console ? p.surface : nil)
            return
        }
        let live = history.live?.profile
        let isLive = chosen.index == history.position
        let beside = r.width >= 64
        let side = beside ? 26 : 0
        let lines = isLive ? Layers.lines(profile, mark: nil, t) : Layers.differences(live, profile, t, same: "the same curve as the live version")
        let under = beside ? 0 : min(lines.count, max(r.height - 9, 0))
        ResponsePanel(scene: scene).draw(Rect(x: r.x, y: r.y, width: r.width - side, height: r.height - under),
                                         title: "version \(chosen.index) · \(Self.time(chosen.date))", right: isLive ? "live" : "vs live, faint",
                                         bands: profile.engineBands, behind: isLive ? nil : live?.engineBands, into: &screen)
        if beside {
            let box = Rect(x: r.right - side + 1, y: r.y, width: side - 1, height: r.height)
            Boxes.draw(box, into: &screen, t, border: p.border, title: label(isLive ? "layers" : "differs"), fill: console ? p.surface : nil)
            Layers.draw(lines, x: box.x + 2, y: box.y + 1, width: box.width - 3, rows: box.height - 2, t, upper: console, into: &screen)
        } else if under > 0 {
            Layers.draw(lines, x: r.x + 2, y: r.bottom - under, width: r.width - 3, rows: under, t, upper: console, into: &screen)
        }
    }
}

/// The Apps view's picker over the message row: the apps with audio open, then the presets.
struct PickerView {
    let scene: MeterScene
    let picker: Picker

    static let maxRows = 10

    func draw(into screen: inout Screen) {
        let t = scene.theme, p = t.p
        let size = scene.size
        let messageY = size.rows - 2
        let items = picker.items(running: scene.running, presets: scene.library.presetNames, rules: scene.library.apps)
        let rows = min(max(items.count, 1), Self.maxRows, messageY - 1 - scene.tabRows - 2)
        guard rows > 0 else { return }
        let box = Rect(x: 1, y: messageY - rows - 2, width: min(size.cols - 2, 80), height: rows + 2)
        Boxes.draw(box, into: &screen, t, border: p.borderHi, title: picker.title, right: items.isEmpty ? nil : "\(items.count)",
                   titleInk: p.title, fill: p.surface)
        guard !items.isEmpty else {
            let text: String
            switch picker.stage {
            case .app: text = "no app has audio open: type a bundle ID or an installed app's name"
            case .preset: text = "no preset has “\(picker.field.text)”"
            }
            screen.ink(text, x: box.x + 2, y: box.y + 1, t.style(p.text3, p.surface), limit: box.width - 4)
            return
        }
        let offset = picker.chosen < rows ? 0 : picker.chosen - rows + 1
        let labelWidth = min(max(items.map { TerminalText.width($0.label) }.max() ?? 0, 12), box.width / 2)
        for (i, item) in items.dropFirst(offset).prefix(rows).enumerated() {
            let y = box.y + 1 + i
            let selected = offset + i == picker.chosen
            let bg = selected ? p.sel : p.surface
            if selected {
                screen.fill(Rect(x: box.x + 1, y: y, width: box.width - 2, height: 1), with: Cell(" ", style: t.style(nil, bg)))
                screen.ink("▸", x: box.x + 1, y: y, t.style(p.accent, bg, .bold))
            }
            screen.ink(TerminalText.truncated(item.label, columns: labelWidth), x: box.x + 3, y: y, t.style(selected ? p.title : p.text, bg, selected ? .bold : []))
            let x = box.x + 5 + labelWidth
            if x < box.right - 2 { screen.ink(item.detail, x: x, y: y, t.style(p.text3, bg), limit: box.right - 2 - x) }
        }
    }
}
