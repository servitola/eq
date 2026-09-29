import XCTest
import CoreAudio
@testable import eq

private final class FakeProcesses: AudioProcessSource {
    var processes: [AudioProcess] = []
    var changed: (() -> Void)?
    var starts = 0
    var stops = 0
    var refuses = false

    func snapshot() -> [AudioProcess] { processes }

    func start(_ changed: @escaping () -> Void) -> Bool {
        starts += 1
        guard !refuses else { return false }
        self.changed = changed
        return true
    }

    func stop() {
        stops += 1
        changed = nil
    }

    func play(_ pid: pid_t, _ id: String, path: String? = nil, _ on: Bool = true) {
        processes.removeAll { $0.pid == pid }
        processes.append(AudioProcess(pid: pid, bundleID: id, path: path, playing: on))
        changed?()
    }

    func quit(_ pid: pid_t) {
        processes.removeAll { $0.pid == pid }
        changed?()
    }
}

final class AppIdentityTests: XCTestCase {
    private let bundles: [String: PlayingApp] = [
        "/Applications/Vivaldi.app": PlayingApp(id: "com.vivaldi.Vivaldi", name: "Vivaldi"),
        "/Applications/Spotify.app": PlayingApp(id: "com.spotify.client", name: "Spotify"),
    ]

    private func identify(_ process: AudioProcess) -> PlayingApp? {
        AppIdentity.identify(process, bundleInfo: { self.bundles[$0] })
    }

    func testAHelperNestedInAnAppIsThatApp() {
        let helper = AudioProcess(pid: 1, bundleID: "com.vivaldi.Vivaldi.helper",
                                  path: "/Applications/Vivaldi.app/Contents/Frameworks/Vivaldi Framework.framework/Versions/8.2/Helpers/Vivaldi Helper.app/Contents/MacOS/Vivaldi Helper",
                                  playing: true)
        XCTAssertEqual(identify(helper), PlayingApp(id: "com.vivaldi.Vivaldi", name: "Vivaldi"))
        XCTAssertEqual(identify(AudioProcess(pid: 2, bundleID: "com.spotify.client", path: "/Applications/Spotify.app/Contents/MacOS/Spotify", playing: true)),
                       PlayingApp(id: "com.spotify.client", name: "Spotify"))
    }

    func testWithoutAReadablePathTheHelperSuffixIsDropped() {
        XCTAssertEqual(AppIdentity.strippingHelper("com.google.Chrome.helper"), "com.google.Chrome")
        XCTAssertEqual(AppIdentity.strippingHelper("com.google.Chrome.helper.Renderer"), "com.google.Chrome")
        XCTAssertEqual(AppIdentity.strippingHelper("com.spotify.client.Helper"), "com.spotify.client")
        XCTAssertEqual(AppIdentity.strippingHelper("com.example.helpers"), "com.example.helpers")
        XCTAssertEqual(AppIdentity.strippingHelper("com.spotify.client"), "com.spotify.client")
        XCTAssertEqual(identify(AudioProcess(pid: 3, bundleID: "com.google.Chrome.helper", path: nil, playing: true)),
                       PlayingApp(id: "com.google.Chrome", name: "com.google.Chrome"))
    }

    func testAnXPCServiceOutsideAnyAppKeepsItsOwnIdentity() {
        let gpu = AudioProcess(pid: 4, bundleID: "com.apple.WebKit.GPU",
                               path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU",
                               playing: true)
        XCTAssertEqual(identify(gpu), PlayingApp(id: "com.apple.WebKit.GPU", name: "com.apple.WebKit.GPU"))
        XCTAssertNil(identify(AudioProcess(pid: 5, bundleID: "", path: nil, playing: true)))
    }

    func testControlCharactersInAnotherBundlesNameNeverReachTheTerminal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-bundle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("Evil.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.evil", "CFBundleName": "Ev\u{1B}[2Jil\u{7F}\u{85}\u{9B}31m Player\n"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(AppIdentity.liveBundleInfo(app.path), PlayingApp(id: "com.example.evil", name: "Ev[2Jil31m Player"))
        XCTAssertEqual(AppIdentity.printable("Café\u{0}\t Ω"), "Café Ω")
    }

    func testOutermostApp() {
        XCTAssertEqual(AppIdentity.outermostApp("/Applications/A.app/Contents/Frameworks/B.app/Contents/MacOS/B"), "/Applications/A.app")
        XCTAssertEqual(AppIdentity.outermostApp("/Applications/A.app"), "/Applications/A.app")
        XCTAssertNil(AppIdentity.outermostApp("/usr/libexec/avconferenced"))
        XCTAssertNil(AppIdentity.outermostApp("/Volumes/My.apps/tool"))
    }
}

final class AppResolverTests: XCTestCase {
    private var config: Config {
        var config = Config.initial(builtInUID: nil, builtInName: nil)
        config.presets?["voice"] = Profile(name: nil, preamp: 0, bands: Profile.flat.bands)
        config.apps = [AppRule(app: "com.spotify.client", preset: "favourite"), AppRule(app: "com.google.Chrome", preset: "Voice"),
                       AppRule(app: "com.apple.Music", preset: "gone")]
        return config
    }

    private let spotify = PlayingApp(id: "com.spotify.client", name: "Spotify")
    private let chrome = PlayingApp(id: "com.google.chrome", name: "Google Chrome")
    private let music = PlayingApp(id: "com.apple.Music", name: "Music")

    func testRuleOrderDecidesAndAMissingPresetMatchesNothing() {
        let config = config
        let both = AppResolver.candidates(rules: config.apps!, playing: [chrome, spotify, music], config: config)
        XCTAssertEqual(both, [AppMatch(app: "com.spotify.client", name: "Spotify", preset: "favourite"),
                              AppMatch(app: "com.google.chrome", name: "Google Chrome", preset: "voice")])
        XCTAssertEqual(AppResolver.winner(both, nowPlaying: nil)?.name, "Spotify")
        XCTAssertEqual(AppResolver.candidates(rules: config.apps!, playing: [music], config: config), [])
    }

    func testNowPlayingBreaksOnlyATie() {
        let config = config
        let both = AppResolver.candidates(rules: config.apps!, playing: [spotify, chrome], config: config)
        XCTAssertEqual(AppResolver.winner(both, nowPlaying: "com.google.Chrome")?.name, "Google Chrome")
        XCTAssertEqual(AppResolver.winner(both, nowPlaying: "com.google.Chrome.helper")?.name, "Google Chrome")
        XCTAssertEqual(AppResolver.winner(both, nowPlaying: "com.apple.Safari")?.name, "Spotify")
        let one = AppResolver.candidates(rules: config.apps!, playing: [spotify], config: config)
        XCTAssertEqual(AppResolver.winner(one, nowPlaying: "com.google.Chrome")?.name, "Spotify")
    }
}

final class AppFollowerTests: XCTestCase {
    private var source: FakeProcesses!
    private var scheduled: [() -> Void] = []
    private var changes: [(new: AppMatch?, previous: AppMatch?)] = []
    private var asked = 0
    private var answer: String?
    private var pendingAnswers: [(String?) -> Void] = []
    private var deferAnswers = false
    private var clock = Date(timeIntervalSince1970: 1000)
    private var follower: AppFollower!

    private let spotifyMatch = AppMatch(app: "com.spotify.client", name: "Spotify", preset: "favourite")
    private let chromeMatch = AppMatch(app: "com.google.Chrome", name: "Google Chrome", preset: "flat")

    override func setUp() {
        source = FakeProcesses()
        scheduled = []
        changes = []
        follower = AppFollower(
            source: source,
            identify: { process in
                let names = ["com.spotify.client": "Spotify", "com.google.Chrome": "Google Chrome", "com.servitola.eq": "EQ"]
                let id = AppIdentity.strippingHelper(process.bundleID ?? "")
                return names[id].map { PlayingApp(id: id, name: $0) }
            },
            nowPlaying: { [unowned self] reply in
                self.asked += 1
                if self.deferAnswers { self.pendingAnswers.append(reply) } else { reply(self.answer) }
            },
            schedule: { [unowned self] _, work in self.scheduled.append(work) },
            now: { [unowned self] in self.clock },
            excluding: 99,
            onChange: { [unowned self] in self.changes.append(($0, $1)) })
    }

    private func config(on: Bool = true) -> Config {
        var config = Config.initial(builtInUID: nil, builtInName: nil)
        config.apps = [AppRule(app: "com.spotify.client", preset: "favourite"), AppRule(app: "com.google.Chrome", preset: "flat")]
        config.setFollowsApps(on)
        return config
    }

    /// Only the latest wait fires anything: the debouncer drops the others.
    private func settle() {
        let work = scheduled
        scheduled = []
        work.forEach { $0() }
    }

    func testOffInstallsNoListeners() {
        follower.configure(config(on: false))
        XCTAssertEqual(source.starts, 0)
        XCTAssertNil(follower.status)
        source.play(1, "com.spotify.client")
        settle()
        XCTAssertTrue(changes.isEmpty)
    }

    func testAnAppThatPlaysGetsItsPresetAfterTheWaitAndLosesItWhenItStops() {
        follower.configure(config())
        XCTAssertEqual(source.starts, 1)
        settle()
        XCTAssertTrue(changes.isEmpty)
        source.play(1, "com.spotify.client.helper")
        XCTAssertTrue(changes.isEmpty, "nothing before the quiet second")
        settle()
        XCTAssertEqual(follower.overlay, spotifyMatch)
        XCTAssertEqual(changes.last?.new, spotifyMatch)
        XCTAssertEqual(follower.status, AppsStatus(listening: true, overlay: spotifyMatch, held: nil, lastMatch: spotifyMatch, lastMatchAt: clock))

        source.play(1, "com.spotify.client.helper", false)
        source.play(1, "com.spotify.client.helper", true)
        settle()
        XCTAssertEqual(changes.count, 1, "a gap shorter than the wait changes nothing")

        source.play(1, "com.spotify.client.helper", false)
        settle()
        XCTAssertNil(follower.overlay)
        XCTAssertEqual(changes.last?.new, nil)
        XCTAssertEqual(changes.last?.previous, spotifyMatch)
        XCTAssertEqual(follower.lastMatch, spotifyMatch)
    }

    func testEqItselfAndUnruledAppsNeverMatch() {
        follower.configure(config())
        source.play(99, "com.spotify.client")
        source.play(2, "com.servitola.eq")
        settle()
        XCTAssertNil(follower.overlay)
        XCTAssertTrue(changes.isEmpty)
    }

    func testFirstRuleWinsWithoutNowPlayingAndTheLookupIsAskedOnlyOnATie() {
        follower.configure(config())
        source.play(1, "com.google.Chrome.helper")
        settle()
        XCTAssertEqual(follower.overlay, chromeMatch)
        XCTAssertEqual(asked, 0)
        source.play(2, "com.spotify.client")
        settle()
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(follower.overlay, spotifyMatch)
    }

    func testNowPlayingPicksTheTieWinner() {
        answer = "com.google.Chrome"
        follower.configure(config())
        source.play(2, "com.spotify.client")
        source.play(1, "com.google.Chrome.helper")
        settle()
        XCTAssertEqual(follower.overlay, chromeMatch)
    }

    func testALateNowPlayingAnswerIsDropped() {
        deferAnswers = true
        follower.configure(config())
        source.play(2, "com.spotify.client")
        source.play(1, "com.google.Chrome.helper")
        settle()
        source.quit(1)
        settle()
        XCTAssertEqual(follower.overlay, spotifyMatch)
        pendingAnswers.first?("com.google.Chrome")
        XCTAssertEqual(follower.overlay, spotifyMatch)
    }

    func testAnEditHoldsTheOverlayOffUntilTheAppStops() {
        follower.configure(config())
        source.play(1, "com.spotify.client")
        settle()
        XCTAssertEqual(follower.hold(), spotifyMatch)
        XCTAssertNil(follower.overlay)
        XCTAssertEqual(follower.held, spotifyMatch)
        source.play(3, "com.spotify.client")
        settle()
        XCTAssertNil(follower.overlay, "the same app still playing keeps the edit")
        source.quit(1)
        source.quit(3)
        settle()
        XCTAssertNil(follower.held)
        source.play(1, "com.spotify.client")
        settle()
        XCTAssertEqual(follower.overlay, spotifyMatch, "the next time it plays, the rule applies again")
    }

    func testAHeldAppGivesWayToAnother() {
        follower.configure(config())
        source.play(1, "com.spotify.client")
        settle()
        _ = follower.hold()
        source.quit(1)
        source.play(2, "com.google.Chrome")
        settle()
        XCTAssertEqual(follower.overlay, chromeMatch)
        XCTAssertNil(follower.held)
    }

    func testTurningOffRestoresAtOnceAndStopsListening() {
        follower.configure(config())
        source.play(1, "com.spotify.client")
        settle()
        follower.configure(config(on: false))
        XCTAssertEqual(source.stops, 1)
        XCTAssertNil(follower.overlay)
        XCTAssertEqual(changes.last?.previous, spotifyMatch)
        XCTAssertNil(follower.status)
        settle()
        XCTAssertEqual(changes.count, 2)
    }

    func testRenamingThePlayingPresetFollowsItAtOnce() {
        follower.configure(config())
        source.play(1, "com.spotify.client")
        settle()
        var renamed = config()
        let favourite = renamed.presets?.removeValue(forKey: "favourite")
        renamed.presets?["fav"] = favourite
        renamed.apps = [AppRule(app: "com.spotify.client", preset: "fav"), AppRule(app: "com.google.Chrome", preset: "flat")]
        follower.configure(renamed)
        let fav = AppMatch(app: "com.spotify.client", name: "Spotify", preset: "fav")
        XCTAssertEqual(follower.overlay, fav, "no wait with the old name playing nothing")
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes.last?.new, fav)
        settle()
        XCTAssertEqual(changes.count, 2)
    }

    func testRemovingThePlayingPresetEndsTheOverlayAtOnce() {
        follower.configure(config())
        source.play(1, "com.spotify.client")
        settle()
        var removed = config()
        removed.presets?.removeValue(forKey: "favourite")
        follower.configure(removed)
        XCTAssertNil(follower.overlay)
        XCTAssertNil(follower.status?.overlay)
        XCTAssertEqual(changes.count, 2)
        XCTAssertNil(changes.last?.new)
        XCTAssertEqual(changes.last?.previous, spotifyMatch)
        settle()
        XCTAssertEqual(changes.count, 2)
    }

    func testAFailedStartIsRetriedOnTheNextReloadAndOnATimer() {
        source.refuses = true
        follower.configure(config())
        XCTAssertEqual(follower.status?.listening, false)
        follower.configure(config())
        XCTAssertEqual(source.starts, 2, "a reload tries again")
        settle()
        XCTAssertEqual(source.starts, 3, "and so does the wait")
        source.refuses = false
        settle()
        XCTAssertEqual(source.starts, 4)
        XCTAssertEqual(follower.status?.listening, true)
        source.play(1, "com.spotify.client")
        settle()
        XCTAssertEqual(follower.overlay, spotifyMatch)
        XCTAssertEqual(source.starts, 4, "no retry once listening")
        follower.configure(config())
        XCTAssertEqual(source.starts, 4)
    }

    func testTurningOffStopsTheRetry() {
        source.refuses = true
        follower.configure(config())
        follower.configure(config(on: false))
        source.refuses = false
        settle()
        XCTAssertEqual(source.starts, 1)
        XCTAssertNil(follower.status)
    }

    func testARuleChangeTakesEffectAndAListenerFailureIsReported() {
        follower.configure(config())
        source.play(1, "com.spotify.client")
        settle()
        var changed = config()
        changed.apps = [AppRule(app: "com.spotify.client", preset: "flat")]
        follower.configure(changed)
        settle()
        XCTAssertEqual(follower.overlay?.preset, "flat")
        XCTAssertEqual(source.starts, 1, "listeners are installed once")

        let refused = FakeProcesses()
        refused.refuses = true
        let broken = AppFollower(source: refused, identify: { _ in nil }, nowPlaying: { $0(nil) }, schedule: { _, _ in }, onChange: { _, _ in })
        broken.configure(config())
        XCTAssertEqual(broken.status?.listening, false)
    }

    func testAnAppRoutedAwayChoosesNothingOnTheMainPathAndChoosesAgainWhenItComesBack() {
        follower.configure(config())
        source.play(1, "com.spotify.client")
        settle()
        XCTAssertEqual(follower.overlay, spotifyMatch)

        follower.routed(["COM.SPOTIFY.CLIENT"])
        XCTAssertNil(follower.overlay, "at once, not after the quiet second")
        XCTAssertEqual(changes.last?.previous, spotifyMatch)

        source.play(2, "com.google.Chrome.helper")
        settle()
        XCTAssertEqual(follower.overlay, chromeMatch)
        XCTAssertEqual(asked, 0, "a routed app is no tie")

        source.quit(2)
        settle()
        follower.routed([])
        XCTAssertEqual(follower.overlay, spotifyMatch)
        let count = changes.count
        follower.routed([])
        XCTAssertEqual(changes.count, count, "the same set evaluates nothing")
    }

    func testRoutedAppsAreKeptWhileOff() {
        follower.routed(["com.spotify.client"])
        follower.configure(config())
        source.play(1, "com.spotify.client")
        settle()
        XCTAssertNil(follower.overlay)
    }
}

final class NowPlayingTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-nowplaying-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func script(_ body: String) throws -> String {
        let url = dir.appendingPathComponent("nowplayingseek")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func testOnlyAPlayingAppCounts() {
        XCTAssertEqual(NowPlaying.parse(Data(#"{"app":"com.spotify.client","playing":true,"title":"x"}"#.utf8)), "com.spotify.client")
        XCTAssertNil(NowPlaying.parse(Data(#"{"app":"com.vivaldi.Vivaldi","playing":false}"#.utf8)))
        XCTAssertNil(NowPlaying.parse(Data(#"{"playing":true}"#.utf8)))
        XCTAssertNil(NowPlaying.parse(Data("not json".utf8)))
    }

    func testAsksTheBinaryAndGivesUpOnASlowOne() throws {
        let fast = try script(#"[ "$1 $2" = "status --minify" ] && echo '{"app":"com.spotify.client","playing":true}'"#)
        XCTAssertEqual(NowPlaying.ask(fast, timeout: 5), "com.spotify.client")
        let slow = try script("sleep 5")
        let started = Date()
        XCTAssertNil(NowPlaying.ask(slow, timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testAnAnswerLargerThanThePipeIsReadWhileTheChildWrites() throws {
        let big = try script(#"printf '{"app":"com.spotify.client","playing":true,"pad":"'; head -c 200000 /dev/zero | tr '\0' x; printf '"}'"#)
        XCTAssertEqual(NowPlaying.ask(big, timeout: 5), "com.spotify.client")
    }

    func testEndlessOutputIsCutAndTheChildEnds() throws {
        let endless = try script("yes")
        let started = Date()
        XCTAssertNil(NowPlaying.ask(endless, timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testAChildIgnoringTermIsStillKilled() throws {
        let stubborn = try script("trap '' TERM; sleep 5; sleep 5")
        let started = Date()
        XCTAssertNil(NowPlaying.ask(stubborn, timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testAMissingBinaryAnswersNothingAtOnce() {
        var answered: [String?] = ["unset"]
        NowPlaying.live(queue: .main, binary: dir.appendingPathComponent("absent").path)({ answered = [$0] })
        XCTAssertEqual(answered, [nil])
    }
}

final class CoreAudioProcessesTests: XCTestCase {
    private var objects: [AudioObjectID] = [10]
    private var listeners: [(id: AudioObjectID, block: AudioObjectPropertyListenerBlock)] = []
    private var removed: [AudioObjectID] = []
    private var processes: CoreAudioProcesses!

    override func setUp() {
        objects = [10]
        listeners = []
        removed = []
        processes = CoreAudioProcesses(hal: CoreAudioProcesses.HAL(
            objects: { [unowned self] in self.objects },
            add: { [unowned self] id, _, block in self.listeners.append((id, block)); return true },
            remove: { [unowned self] id, _, _ in self.removed.append(id) }))
    }

    private func fire(_ block: AudioObjectPropertyListenerBlock) {
        var address = AudioObjectPropertyAddress()
        withUnsafePointer(to: &address) { block(1, $0) }
    }

    private var listBlock: AudioObjectPropertyListenerBlock {
        listeners.first { $0.id == AudioObjectID(kAudioObjectSystemObject) }!.block
    }

    func testANewProcessIsWatchedAndStopRemovesEverything() {
        var changes = 0
        XCTAssertTrue(processes.start { changes += 1 })
        XCTAssertEqual(listeners.map(\.id), [AudioObjectID(kAudioObjectSystemObject), 10, 10])
        objects = [10, 11]
        fire(listBlock)
        XCTAssertEqual(listeners.map(\.id).filter { $0 == 11 }.count, 2)
        XCTAssertEqual(changes, 1)
        processes.stop()
        XCTAssertEqual(removed.sorted(), [AudioObjectID(kAudioObjectSystemObject), 10, 10, 11, 11].sorted())
    }

    func testAListChangeQueuedBeforeStopAddsNothingAfterIt() {
        var changes = 0
        XCTAssertTrue(processes.start { changes += 1 })
        let queued = listBlock
        let installed = listeners.count
        processes.stop()
        objects = [10, 11]
        fire(queued)
        XCTAssertEqual(listeners.count, installed, "removing a HAL listener does not cancel its queued blocks")
        XCTAssertEqual(changes, 0)
    }
}
