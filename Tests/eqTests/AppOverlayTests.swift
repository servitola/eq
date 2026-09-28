import XCTest
@testable import eq

final class AppOverlayTests: XCTestCase {
    private let spotify = AppMatch(app: "com.spotify.client", name: "Spotify", preset: "favourite")

    private var config: Config {
        var config = Config.initial(builtInUID: "BUILTIN", builtInName: "MacBook Pro Speakers")
        config.devices["BUILTIN"] = Profile(name: "MacBook Pro Speakers", preamp: -1, bands: Profile.flat.bands, preference: Preference(bass: 3))
        config.apps = [AppRule(app: spotify.app, preset: "Favourite")]
        config.setFollowsApps(true)
        return config
    }

    func testTheMatchedPresetReplacesTheCurveAndKeepsTheDeviceName() {
        let config = config
        let base = config.profile(forDeviceUID: "BUILTIN").profile
        let heard = AppOverlay.heard(base, spotify, in: config)
        XCTAssertEqual(heard.bands, Config.screenshotCurve)
        XCTAssertEqual(heard.preamp, 0)
        XCTAssertNil(heard.preference)
        XCTAssertEqual(heard.preset, "favourite")
        XCTAssertEqual(heard.name, "MacBook Pro Speakers")
        XCTAssertEqual(AppOverlay.heard(base, nil, in: config), base)
        XCTAssertEqual(AppOverlay.heard(base, AppMatch(app: "x", name: "X", preset: "gone"), in: config), base)
    }

    func testOnlyACurveChangeCountsAsAnEdit() {
        let old = config
        var renamed = old
        renamed.devices["BUILTIN"]?.name = "Speakers"
        XCTAssertFalse(AppOverlay.edited(old, renamed, uid: "BUILTIN"))
        var toggled = old
        toggled.enabled = false
        toggled.apps = []
        XCTAssertFalse(AppOverlay.edited(old, toggled, uid: "BUILTIN"))
        var tuned = old
        tuned.devices["BUILTIN"]?.bands[3] = 2
        XCTAssertTrue(AppOverlay.edited(old, tuned, uid: "BUILTIN"))
        var defaultTuned = old
        defaultTuned.default.preamp = -3
        XCTAssertTrue(AppOverlay.edited(old, defaultTuned, uid: "JBL"), "a device without its own curve plays the default")
        XCTAssertFalse(AppOverlay.edited(old, defaultTuned, uid: "BUILTIN"))
    }

    func testTheOverlayNeverReachesTheConfigFileOrItsHistory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-overlay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(url: dir.appendingPathComponent("eq.json"))
        try store.save(config)
        let before = try Data(contentsOf: store.url)
        let listing = try FileManager.default.contentsOfDirectory(atPath: dir.path)

        final class Playing: AudioProcessSource {
            var changed: (() -> Void)?
            func snapshot() -> [AudioProcess] { [AudioProcess(pid: 7, bundleID: "com.spotify.client", path: nil, playing: true)] }
            func start(_ changed: @escaping () -> Void) -> Bool { self.changed = changed; return true }
            func stop() {}
        }
        var work: [() -> Void] = []
        var heard: [Profile] = []
        let loaded = try store.load()
        var follower: AppFollower!
        follower = AppFollower(source: Playing(), identify: { PlayingApp(id: $0.bundleID!, name: "Spotify") }, nowPlaying: { $0(nil) },
                               schedule: { _, run in work.append(run) }, excluding: 1,
                               onChange: { match, _ in heard.append(AppOverlay.heard(loaded.profile(forDeviceUID: "BUILTIN").profile, match, in: loaded)) })
        follower.configure(loaded)
        work.forEach { $0() }
        XCTAssertEqual(follower.overlay, spotify)
        XCTAssertEqual(heard.last?.bands, Config.screenshotCurve)
        XCTAssertEqual(try Data(contentsOf: store.url), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), listing, "no backup, no history entry")
        XCTAssertEqual(try store.load().devices["BUILTIN"]?.bands, Profile.flat.bands)
    }

    // MARK: - What the daemon reports

    func testTheAppEventCarriesThePresetOrNullOnRestore() throws {
        func text(_ event: DaemonEvent) throws -> String { String(decoding: try DaemonEvent.encodeLine(event, at: 1.5), as: UTF8.self) }
        XCTAssertEqual(try text(.app(app: "com.spotify.client", name: "Spotify", preset: "favourite")),
                       #"{"app":"com.spotify.client","event":"app","name":"Spotify","preset":"favourite","t":1.5}"# + "\n")
        XCTAssertEqual(try text(.app(app: "com.spotify.client", name: "Spotify", preset: nil)),
                       #"{"app":"com.spotify.client","event":"app","name":"Spotify","preset":null,"t":1.5}"# + "\n")

        var published: [DaemonEvent] = []
        var runs: [HookRun] = []
        var scheduled: [() -> Void] = []
        let hooks = Hooks(schedule: { _, work in scheduled.append(work) }, run: { runs.append($0) })
        hooks.configure(["device": "true", "preset": "true"])
        let tracker = EventTracker(enabled: true, hooks: hooks) { published.append($0) }
        tracker.app(spotify, previous: nil)
        tracker.app(nil, previous: spotify)
        tracker.app(nil, previous: nil)
        XCTAssertEqual(published, [.app(app: spotify.app, name: "Spotify", preset: "favourite"), .app(app: spotify.app, name: "Spotify", preset: nil)])
        scheduled.forEach { $0() }
        XCTAssertEqual(runs, [], "hooks never run for an app rule")
    }

    func testStatusAndFrameCarryTheApp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-overlay-status-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let apps = AppsStatus(listening: true, overlay: spotify, held: nil, lastMatch: spotify, lastMatchAt: Date(timeIntervalSince1970: 1790500000))
        let status = Status(state: .running, device: nil, sampleRate: 48000, profile: .device, framesProcessed: 0, callbacks: 0, writes: 1,
                            enabled: true, error: nil, pid: 1, version: "1", updatedAt: Date(timeIntervalSince1970: 1790500000), apps: apps)
        try status.write(to: dir)
        XCTAssertEqual(Status.read(from: dir)?.apps, apps)
        var off = status
        off.apps = nil
        try off.write(to: dir)
        XCTAssertFalse(try String(contentsOf: dir, encoding: .utf8).contains("apps"))

        var frame = MeterFrame(t: 1, device: "X", rate: 48000, in: [], out: [], peak: -90, limiting: false, gains: [], preamp: 0, enabled: true)
        XCTAssertFalse(String(decoding: try MeterFrame.encodeLine(frame), as: UTF8.self).contains("app"))
        frame.app = spotify
        let line = try MeterFrame.encodeLine(frame)
        XCTAssertEqual(try JSONDecoder().decode(MeterFrame.self, from: line).app, spotify)
    }
}
