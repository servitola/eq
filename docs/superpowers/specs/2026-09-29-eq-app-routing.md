# eq app routing — an output per app, with fallback

Date: 2026-09-29. Status: draft for the user's review; not approved. Research:
`docs/research/07-app-routing.md` (SDK quotes, FineTune, Background Music, SoundSource, forums).

## The request, and how this spec reads it

The request: "choose a specific output device for an app, and play through another only if that
one is absent."

How this spec reads it (to confirm):
- An app gets an ordered list of outputs, for example Spotify → [BE-RCA, MacBook Pro Speakers].
- While BE-RCA is present, Spotify plays there, with BE-RCA's curve, whatever the system default is.
- When BE-RCA is gone, Spotify plays on the next available device in its list.
- When the first choice comes back, Spotify goes back to it on its own. Fallback is a state the
  daemon computes; it is never written to `eq.json`.
- When no device in the list is available, the app follows the system default, as it does today.
- Apps without a rule follow the system default, exactly as today.

**How this relates to "per-app mixing: not yet"** (Round F scoped out SoundSource-style per-app
mixing):
- This is a narrower step: no per-app volume, no mixer, no per-app curve on a shared device.
- It does bring in the building block such mixing would need: a muted per-process tap feeding its
  own engine. As a side effect, two curves play at once when two apps play on two devices (the
  system on the speakers with their curve, Spotify on BE-RCA with BE-RCA's).
- "An app on the *same* device with its own curve" would be the next step (a route whose target is
  the default device). It stays out of scope here, and the code should not grow hooks for it.

## Behaviour

**Rules.** `"routes"` in `eq.json` is an ordered list:

```json
"routes": [
  {"app": "com.spotify.client", "outputs": ["EB-06-EF-24-61-CF:output", "BuiltInSpeakerDevice"]}
],
"experimental": {"routes": true}
```

- `app` is a bundle ID, matched the way F2 matches it (case-insensitive, helpers count as their app;
  `AppIdentity`). One rule per app. `outputs` holds 1–4 device UIDs.
- Off unless `experimental.routes` is true, as F2 is. `Experimental` gains a `routes` key next to
  `apps`.
- A config with `routes` but the flag off keeps its rules and does nothing.

**Available.** A device is available when all of these hold:
- it is in the HAL device list with at least one output stream and `kAudioDevicePropertyDeviceIsAlive`
  is 1;
- its nominal rate is above 0 (a Bluetooth device arrives in two steps; eq already waits for the
  second);
- it is a real device: not eq's virtual device, not one of eq's aggregates, not AirPlay.

AirPlay targets are refused at `eq route set` for now: taps and AirPlay are an unsolved class of bugs
(`05` §AirPlay, FineTune #334). A device that appears must stay available for the existing settle
delay before a route moves to it. A device that disappears ends its routes at once.

**Effective target.** For each app that has audio open, the effective target is the first available
UID in its `outputs`. Then:
- **Identity.** If the effective target is the device the main path plays on (the default output in
  tap mode, the driver's target in driver mode), there is no route: the app stays in the main path.
- **Exhausted.** If no UID in `outputs` is available, the app follows the system default. The spec
  recommends this over silence (open question 1).

**Flapping.** If a target appears and disappears more than three times in 10 s, its routes hold on
their current device for 30 s. This is the same policy driver mode uses for the default output.

**Curve.**
- A route plays with its target's own curve (`config.profile(forDeviceUID:)`, the device's profile
  or the default one).
- If `experimental.apps` is on and an app on that route engine has an F2 rule, the rule's preset
  overlays the target's curve, exactly as F2 does on the main path. When several routed apps with
  rules share one target, F2's winner logic picks one, among those apps only.
- The main path's F2 resolution ignores apps that are currently routed away. Spotify on BE-RCA must
  not swap the speakers' curve.
- `eq set --device BE-RCA …` edits the curve a BE-RCA route plays, live.
- `eq off` bypasses EQ on route engines too, but routing continues: `off` is about the EQ, not about
  where sound goes.
- Solo and the meter (`eq watch`, `eq stream`) stay on the main path in this version.

**Volume.** A process tap carries the app's signal before any device volume, and a route plays
through its target's own volume. The volume keys change the default output, so they do not move a
routed app. This goes in the README, not a fix.

**If eq stops.** The route taps are the daemon's own. When the daemon exits cleanly it destroys
them, and the app is heard on its own device again, without EQ. A `kill -9` is expected to end the
same way, but FineTune's code says a force-killed owner can leave taps that "silently mute apps".
M0 settles it, and the daemon's existing `destroyStaleAggregates` at start is the backstop.

## Tap mode design

**Signal path, one engine per target in use** (not per app):

```
app processes ──▶ route tap (muted, private) ─┐
                                              ├─ private aggregate: main/clock sub-device = target,
                                              │  sub-tap with drift compensation
                                              └─ one IOProc: tap in → EQCore (target's curve) → target out
everything else ──▶ main tap on the default device, excluding eq and every routed process (unchanged path)
```

- **Layout L1** (tap and target in one aggregate, as FineTune and AudioCap do) is the first
  choice: the HAL converts rates and absorbs the drift between the default device's clock and the
  target's, with no new DSP in eq.
- If M0 measures L1 adding more than ~60 ms over the target's own latency, or it crackles, **L2** is
  the fallback: eq's split path (tap-only aggregate, ring, output IOProc on the target) plus a
  steered asynchronous resampler in EQCore. L2 is a separate, larger milestone (see M2b).
- **Code.** A new `RouteEngine` next to `ProcessTapEngine`. It shares `EQProcessor`/EQCore, the
  stranded-IOProc handling and the aggregate UID prefix (`com.servitola.eq.aggregate-route-<target
  UID>`, so the existing stale sweep finds it). It is not a second `ProcessTapEngine`: the tap
  shape, the aggregate and the IOProc count differ, and forcing both into one class would bend the
  main path.
- **Tap shape.**
  - `CATapDescription(stereoMixdownOfProcesses:)` on the app's process objects, `isPrivate`.
  - On macOS 26, also `bundleIDs` if M0 shows that a bundle-ID tap picks up processes that start
    after it was made. That would close the race when a new Chrome helper starts playing.
  - Routed audio is stereo; a multichannel app is mixed down.
- **Mute.** `CATapMuted`, not `mutedWhenTapped`: whatever the app plays while the engine is not
  reading is lost rather than heard on the wrong speaker. The engine keeps reading while any process
  of its apps has IO running (`kAudioProcessPropertyIsRunning`), plus a 30 s tail, so a gap between
  tracks never stops it. Open question 3.
- **Main tap exclusion.**
  - Every process of a routed app is added to the main tap's exclusion list by setting
    `kAudioTapPropertyDescription` on the live tap, which the header says is supported.
  - If M0 finds that live edit glitchy or ignored, the fallback is to rebuild the main engine, one
    ~100 ms gap per change.
  - The exclusion is applied on every process-list event, **with no debounce**: F2's 1 s debounce
    would leak a second of Spotify to the speakers.
  - Order when a route starts: bring the route engine's target IO up, create the route tap (which
    mutes the app), then exclude the app from the main tap. When a route ends: include the app in the
    main tap, then destroy the route tap. A few milliseconds of doubling are possible; a gap is the
    worse failure.
- **Process tracking.** `CoreAudioProcesses` already listens to the process list and to
  `IsRunning`/`IsRunningOutput` per process. Add a 10 s re-read as a safety net (FineTune:
  listeners "can miss notifications during rapid process lifecycle changes").
- **Health.**
  - Each route engine gets the main engine's watchdog: callbacks stalled, ring or IO failing, and
    all-zero tap buffers while the app is running IO. The last is forum thread 825780's failure,
    whose only cure is to destroy the tap and the aggregate and build both again.
  - After three failed rebuilds in a minute, the route is suspended, the app goes back to the main
    path, and `eq status`/`doctor` say why.
- **Latency.** The app sees the latency of the device it renders to, not the target's. Tap mode
  cannot fix lip sync for a routed video app, and the README says so. `eq status` shows each route's
  measured latency.
- **Cost.** One tap, one aggregate and one IOProc per target in use. Budget: ≤ 0.4 % CPU and ≤ 2 MB
  per active route engine, measured with `scripts/footprint.sh`.

## Driver mode design

**Recommended: the hybrid (design H in `07` §4.2).** Routed apps use the same `RouteEngine` while
driver mode stays on:
- The routed app still plays into "BE-RCA · EQ".
- The route tap mutes it there, so the plug-in's mix no longer carries it, and plays it on the route
  target with that target's curve.
- The plug-in does not change.
- Identity is measured against the driver's current target: a rule pointing at it means no route.

Costs, stated in `eq mode` and the README:
- The System Audio Recording permission, which EQ.app already holds from tap mode.
- The Privacy indicator, but only while a route engine runs, which means only while a routed app
  plays on a device other than the driver's target.
- If the permission is missing, routing stays off, and `eq status`/`doctor` say so. Driver mode
  itself is unaffected.

**Not now: per-client routing inside the plug-in (design P).** The header allows it:
- `WillDoIOOperation`: *"A device is allowed to do different sets of operations for different
  clients."*
- `DoIOOperation` has `inClientID`.
- Background Music scales each client's buffer in `ProcessOutput`.

The plug-in would:
1. keep each client's pid and bundle ID from `AddDeviceClient`;
2. copy a routed client's `ProcessOutput` buffer into a per-target ring and zero it in place;
3. play each extra target from its own IOProc, with a resampler, because the virtual clock follows
   only one target;
4. take a routing table from the daemon over a custom property.

It is the riskiest code eq could write:
- another forbidden HAL client call per extra target;
- real-time SRC and a second servo in C;
- a multi-target state machine;
- a failure mode that silences every app.

No shipped project does it. Revisit only if the indicator during routed playback is unacceptable,
and only after driver mode has passed its own go/no-go (8 h, 20× reconnect).

**An idea to probe later.** The plug-in's `GetPropertyData` receives the caller's pid. It might
report a routed app's latency as that of its route target, which would give lip sync back in driver
mode. Untested (`07` §4.3); not a dependency of any milestone.

## Command line and visibility

| Command | |
| --- | --- |
| `eq route` / `eq route list [--json]` | the rules; for each, its outputs marked present/absent and where the app plays now |
| `eq route set <app> <device> [<device>…]` | set the ordered list; app by name or bundle ID (as `eq app set`), devices by a piece of their name (as `--device`) |
| `eq route rm <app>` | remove the rule |
| `eq route on\|off` | the experimental flag |

- `set` refuses eq's virtual device, eq's aggregates, AirPlay, an ambiguous name, and a list with
  duplicates. It accepts a device that is absent now, if eq has a profile for it.
- `--dry-run` works for `set`, `rm`, `on` and `off` through the existing sandbox in `DryRun.swift`.
- Completions offer running audio apps and installed apps for `<app>`, and connected devices plus
  devices with a profile for `<device>`. The man page and help come from the same command table.
- `eq` and `eq status` add one line per rule for an app that has audio open:
  - `route: Spotify → BE-RCA`;
  - `route: Spotify → MacBook Pro Speakers (BE-RCA absent)`;
  - `route: Spotify follows the default (no output in its list is available)`.

  `--json` adds `routes: [{app, name, target: {uid, name}|null, reason: "first"|"fallback"|"identity"|"exhausted"|"suspended", latencyMs, underruns, overruns}]`.
- `eq watch` shows the same line in its header; tuning stays on the main path's curve.
- `eq events` adds
  `{"event":"route","app":"com.spotify.client","name":"Spotify","target":"EB-06-EF-24-61-CF:output","targetName":"BE-RCA","reason":"first"}`,
  with `"target":null` when the app is back on the main path. The JSON envelope's `schemaVersion`
  bumps if the status shape changes incompatibly (it should not: fields are added only).
- Hooks: a `route` hook name, run on each route event, as `device` and `preset` are.
- `eq doctor` gets a `routes` row (while on) that flags:
  - a rule whose outputs eq has never seen;
  - an AirPlay or virtual output;
  - a suspended route;
  - a missing permission in driver mode;
  - a routed app that is a known video player or browser, as a lip-sync warning (info, not failure).

## Milestones

**M0 — spike on this Mac (throwaway code in `scripts/`, no daemon changes). Go/no-go for M2.**
It measures, with a tone from `afplay` (PID-based taps) and then with Spotify:
1. L1 latency and quality, speakers → BE-RCA and BE-RCA → speakers, with sub-tap drift
   compensation on and off (FineTune turns it off for Bluetooth; the reasoning may not hold across
   clocks).
2. Setting `kAudioTapPropertyDescription` live on an exclusion tap: does the exclusion take effect,
   and does anything glitch?
3. Whether a `bundleIDs` tap, with and without `processRestoreEnabled`, catches a process that
   starts after the tap exists. Exact match or prefix, for `com.google.Chrome.helper*`.
4. A route tap and the main tap on the same source device in one process: no doubling, no
   `AudioDeviceStart` block (forum thread 848578).
5. `CATapMuted` vs `mutedWhenTapped`: what is lost or leaked at start, in ms.
6. What a `kill -9` of the owner leaves behind: is the app still muted?
7. The tap format of a stereo-mixdown tap on a process playing at 48 kHz.
8. Whether DRM-protected Apple Music comes through a tap silent (reported on the forums), since
   that would make routing Music silent.

Output: a short results table appended to `07`. The spike must be run only with the user present;
it does not touch the default output or the installed driver.

**M1 — the resolver, pure and tested (no Core Audio).**
- `Config.routes`, `Experimental.routes`, validation (1–4 UIDs, no duplicates, one rule per app).
- `RouteResolver(rules, processes, devices, mainTarget) → RoutePlan`, where `RoutePlan` holds engines
  (target UID → apps and process IDs), `mainExclusions` and a reason per app.
- `RoutePlanner(old, new) → [Action]` in the switch-over order above.
- F2 ignores routed apps; flap hold.

Tests with fake process lists and device lists:
- first choice present; absent → fallback; all absent → default;
- identity with the default, and with the driver target in driver mode;
- two apps to one target, one engine;
- helpers merged, WebKit GPU;
- an app starts and stops; a device appears in two steps; flapping;
- F2 overlay on a route and F2 ignoring routed apps;
- action ordering.

**M2 — the tap-mode route engine.**
- `RouteEngine` (L1), the main tap's live exclusion, the no-debounce process path with a 10 s
  re-read, watchdog and suspension, cleanup on exit and at start.
- A `RouteSink` protocol between the daemon and the engine, so daemon policy is tested with a fake.
- Unit tests cover the IOProc render function without Core Audio, as `ProcessTapEngine`'s are driven
  through `prepare`.
- Live tests with the user (below).

**M2b — only if M0 rejects L1.** Split path plus a resampler in EQCore (windowed-sinc polyphase,
ratio steered by ring fill). Tests: THD+N and passband ripple at 44.1↔48 kHz, ±500 ppm drift over
simulated hours, no ring slips. This roughly doubles the feature's size.

**M3 — command line and visibility.** `eq route …`, completions, man page, help, dry-run, status,
watch header, events, the `route` hook, the doctor row, README section with the honest limits (lip
sync, volume keys, stereo, WebKit shared, no AirPlay).

**M4 — driver mode, hybrid.** Identity against the driver's target; route engines run beside the
plug-in; permission check; `eq mode` and README text on the indicator.

**M5 — soak and footprint.** 8 h of Spotify routed to BE-RCA with the system on the speakers.
Footprint numbers into the README.

**Size.**
- M1 ≈ 400 lines plus 500 of tests.
- M2 ≈ 600 plus 300.
- M3 ≈ 400 plus 400.
- M4 ≈ 150 plus 100.

About 2 800 lines, most of it tests. M2b adds ≈ 700 lines of C and tests. M0 is half a day with the
user.

## Live tests with the user (acceptance)

Setup: default output MacBook Pro Speakers, rule Spotify → [BE-RCA, MacBook Pro Speakers], tap mode
first, then driver mode.

1. Spotify plays on BE-RCA with BE-RCA's curve; a YouTube tab and system sounds play on the speakers
   with theirs. Nothing is doubled: muting BE-RCA silences Spotify completely.
2. Turn BE-RCA off: Spotify continues on the speakers within 2 s, with the speakers' curve. Turn it
   back on: Spotify returns to BE-RCA within 3 s of the speaker being usable, without touching the
   Sound menu. Twenty times each, no stuck state.
3. Make BE-RCA the default output: Spotify stays on BE-RCA (identity), with no duplicate engine
   (`eq status` shows no route engine).
4. Remove both devices from reach (rule → [BE-RCA] only, BE-RCA off): Spotify follows the default.
5. Start Chrome audio in a new tab with a rule for Chrome: no audible leak on the wrong device
   (target: none; accepted: under 100 ms, documented).
6. `kill -9` the daemon: within the launchd restart, Spotify is audible (on the default without EQ,
   then routed again); no app stays muted; no stale aggregate survives.
7. `eq route off`: everything follows the default within 1 s.
8. Driver mode: tests 1–4 again. The indicator shows only while Spotify plays on BE-RCA with the
   driver on the speakers.
9. Soak: 8 h routed playback with no growth in underruns/overruns and no rebuilds. CPU within the
   budget.

## Risks

- **Crash leaves an app muted** (FineTune's orphan cleanup exists for this). Mitigation:
  `destroyStaleAggregates` at start, M0 test 6, and the README recovery line (`eq route off` or
  restart the daemon).
- **Start leak or clip.** Mitigation: `CATapMuted`, the 30 s tail and, on 26, `bundleIDs` taps.
- **L1 latency or drift crackle over Bluetooth** (FineTune #424, #324). Mitigation: M0 measures; M2b
  is the fallback.
- **Chrome-specific garble** (FineTune #269): test Chrome in M2.
- **Live exclusion edits do nothing** (no one else relies on them). Mitigation: fall back to
  rebuilding the main engine.
- **AirPods auto-switching fights routing** (FineTune #316/#326): routing never changes the default
  output, so it should not fight. Verify in M2.
- **The indicator in driver mode** undercuts driver mode's point, but only while a route plays.
  Open question 2.

## Open questions for the user

1. When no output in an app's list is available: follow the system default (recommended), or stay
   silent?
2. In driver mode, is the Privacy indicator acceptable while a routed app plays on another device
   (hybrid, small)? Or must routing work with no indicator (plug-in routing: large and risky; not
   recommended now)?
3. When a routed app starts playing after a pause, which is less bad? (a) Losing up to ~0.3 s
   (recommended). (b) Hearing that moment on the wrong speaker. (c) Keeping BE-RCA's audio running
   the whole time the app is open, which avoids both but keeps the speaker from sleeping.

## Answers (2026-09-29)
1. No available output in the list → follow the system default.
2. Driver mode: the user asked why an indicator would be needed. The spec's answer: routing
   has to capture the app's audio, which is a tap. The driver avoids that only by routing inside
   itself, and that option is deferred. Pending a decision.
3. Start of playback: the user says BE-RCA never sleeps. Here "sleep" means the Mac stops the
   device's audio stream when idle, not that the speaker powers off. M0 test 5 measures what is
   lost at start. Losing ≤ 0.3 s is the default, and keeping the stream running (which blocks
   idle system sleep) is not.
