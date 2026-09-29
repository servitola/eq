# 07 — Per-app output routing with fallback: research

Date: 2026-09-29. Question: can eq send one app to a chosen output ("Spotify → BE-RCA, else
MacBook Pro Speakers") while everything else follows the system default, in tap mode and in
driver mode? Spec: `docs/superpowers/specs/2026-09-29-eq-app-routing.md`.

Evidence levels used below: **[SDK]** quoted from the macOS 26.5 SDK headers on this Mac
(`xcrun --show-sdk-path`, `CoreAudio.framework/Headers`); **[code]** read in eq or in a cloned
project at the commit named; **[forum]/[doc]** a web source with its URL; **[inferred]** our
reasoning, not measured; **[unknown]** needs the M0 spike.

## 1. What the SDK says

### 1.1 Taps (`CATapDescription.h`, `AudioHardware.h`)

- **Per-process taps exist in two shapes.** [SDK]
  - `initStereoMixdownOfProcesses:` — *"Mix all given process audio streams down to stereo. Mono
    sources will be duplicated in both right and left channels."* Not tied to a device.
  - `initWithProcesses:andDeviceUID:withStream:` — *"Mix all given process audio streams destined
    for the selected device stream"*; *"The format of the tap will match the format of this
    stream."* Tied to one device. (Its `@param` text is copy-pasted from the exclusion variant and
    says "exclude"; the abstract is the authority.)
  - eq's main tap today is the device-bound exclusion form,
    `initExcludingProcesses:andDeviceUID:withStream:` (`ProcessTapEngine.swift` L274).
- **Mute behaviours** [SDK], verbatim:
  - `CATapMuted`: *"Audio is captured by the tap but no audio is sent from the process to the
    audio hardware"*
  - `CATapMutedWhenTapped`: *"Audio is captured by the tap and also sent to the audio hardware until
    the tap is read by another audio client. For the duration of the read activity on the tap no
    audio is sent to the audio hardware."*
  - Neither sentence says what happens when the tap is destroyed. That the process is heard again
    once the tap is gone, including when its owner crashes, is [inferred] from "for the duration of"
    and from eq's own daemon restarts (sound returns un-EQ'd on the device). M0 checks it with a
    `kill -9`.
- **The process list of a live tap can be changed.** [SDK] `kAudioTapPropertyDescription`:
  *"The CATapDescription used to initially create this tap. This property can be used to modify and
  set the description of an existing tap."* So the main tap's exclusion list can grow and shrink
  without destroying the tap and its aggregate. Whether that is glitch-free is [unknown] (M0).
- **macOS 26 adds bundle-ID taps.** [SDK] Both are `API_AVAILABLE(macos(26.0))`:
  - `bundleIDs`: *"An Array of Strings where each String holds the bundle ID of a process to tap or
    exclude."*
  - `processRestoreEnabled`: *"True if this tap should save tapped processes by bundle ID when they
    exit, and restore them to the tap when they start up again."*

  This is the most important find for routing. A process that is not running yet cannot be named
  by an `AudioObjectID`, so a PID-based design always leaks the first moments of a new helper (a new
  Chrome tab's renderer) to the default device until the daemon notices it. If a `bundleIDs` tap
  picks up a process that starts after the tap was made, that race is gone. The headers do not say
  whether matching is exact or by prefix (Chrome's helpers are `com.google.Chrome.helper`,
  `….helper.Renderer`, …), nor whether `processRestoreEnabled` is needed for a process that never
  ran before the tap. [unknown] → M0.
- `kAudioTapPropertyFormat`: *"the format of that data that will be accessible in any aggregate
  device that contains the tap."* [SDK] A stereo-mixdown tap's rate and clock are not documented;
  [unknown] → M0 reads it for a tap on a process playing to a 48 kHz device.
- `exclusive`: *"True if this description should tap all processes except the process listed in the
  'processes' property."* [SDK] — the same exclusion idea eq already uses, as a flag.
- **Process objects** [SDK]:
  - `kAudioProcessPropertyDevices`: *"An array of AudioObjectIDs that represent the devices currently
    used by the process for input or used by the process for output. The scope will select the input
    or output device list."* This tells the daemon which device a routed app actually plays to, so
    it can tell "follows the default" apps from apps that picked a device themselves.
  - `kAudioProcessPropertyIsRunningOutput` is not reliable as a notifier on macOS 26.6; eq already
    watches `kAudioProcessPropertyIsRunning` as well (`AudioProcesses.swift` header comment). [code]
- **Aggregate composition** [SDK]:
  - `kAudioAggregateDeviceMainSubDeviceKey`: *"the UID for the sub-device that is the time source for
    the AudioAggregateDevice."*
  - `kAudioAggregateDeviceClockDeviceKey`: *"the UID for the clock device that is the time source …
    If the aggregate device includes both a main audio device and a clock device, the clock device
    will control the time base."* A clock device is a separate object class (`AudioClockDevice`), not
    an output device, so this probably cannot clock a tap-only aggregate from a real speaker.
    [inferred]
  - `kAudioSubTapDriftCompensationKey`: *"a non-zero value indicates that drift compensation is enabled
    for the AudioSubTap"*. This is how the HAL resamples a tap onto an aggregate's clock.

### 1.2 The plug-in side (`AudioServerPlugIn.h`)

- **Clients are identified by process and bundle.** [SDK] `AudioServerPlugInClientInfo`:
  - `mClientID`: *"An ID that allows for differentiating multiple clients in the same process. This ID
    is passed to the plug-in during IO so that the plug-in can associate the IO with the client
    easily."*
  - `mProcessID`: *"The pid_t of the process that contains the client."*
  - `mBundleID`: *"the bundle ID of the main bundle of the process that contains the client."* For a
    Chrome helper that is the helper's bundle ID, not Chrome's. [inferred from "main bundle of the
    process"]
- **Per-client IO is allowed.** [SDK]
  - `WillDoIOOperation`: *"A device is allowed to do different sets of operations for different
    clients."*
  - `DoIOOperation` carries `inClientID`: *"The ID of the client doing the operation. This will have
    been established with the device by a previous call to AddDeviceClient()."*
  - The operations, in the order the header lists them: `kAudioServerPlugInIOOperationProcessOutput`
    *"performs arbitrary signal processing on the output data in the canonical format"*;
    `…MixOutput` *"mixes the output data into the device's ring buffer"*; `…ProcessMix` *"processes the
    full mix of all clients' data"*; `…WriteMix` *"puts the data into the device's ring buffer"*.
  - The header does not say in so many words that `ProcessOutput` runs once per client on that
    client's own buffer before the mix. It follows from the list: `ProcessMix` is the one described as
    "the full mix of all clients' data", and `ProcessOutput` comes before `MixOutput`. Background
    Music's per-app volume depends on exactly that; see §2.3.
- **Latency can in principle differ per process.** [SDK] `GetPropertyData` receives
  `pid_t inClientProcessID`, so a plug-in can answer `kAudioDevicePropertyLatency` differently for
  different processes. Whether the HAL passes each client's own query through uncached, and whether
  players re-read latency mid-stream, is [unknown]. Treat it as an idea, not a plan (§4.3).
- eq's plug-in today answers `WillDoIOOperation` with WriteMix only, ignores `inClientID`, and
  `AddDeviceClient` keeps nothing (`Driver/Source/Driver.cpp` L1380, L1474–1497). [code]

## 2. Prior art

### 2.1 FineTune — the closest match

[github.com/ronitsingh10/FineTune](https://github.com/ronitsingh10/FineTune), GPLv3, cloned at
`2285279` (2026-07-09). Its README promises exactly this feature: "route audio to different speakers
… Device priority … auto-fallback on disconnect … Auto-restore". GPLv3 means eq reads it for ideas
and copies nothing. [code]

- **No system-wide tap.** Every app gets its own tap and its own private aggregate, named
  `"FineTune-<app>"`. The question "exclude routed apps from the global tap" does not come up for
  FineTune; it does for eq, whose main tap stays.
- **Tap shape** (`Audio/Engine/ProcessTapController.swift` L530–577):
  - When the app follows the default and the target *is* the default, FineTune uses a device-stream
    tap: `CATapDescription(processes: app.processObjectIDs, deviceUID:, stream:)`, to avoid the
    multichannel attenuation of a mixdown.
  - Otherwise it uses `CATapDescription(stereoMixdownOfProcesses: app.processObjectIDs)`.
  - Both are `.mutedWhenTapped` and `isPrivate`.
  - `preferredTapSourceDeviceUID` (`AudioEngine.swift` L1798) returns the default device's UID only
    when the target list contains it. **So a route to a non-default device uses the stereo mixdown.**
- **Topology** (L357–413): the aggregate's sub-devices are the target output(s). The first one is the
  main and clock device (`kAudioAggregateDeviceMainSubDeviceKey` and `…ClockDeviceKey`). The tap is a
  sub-tap, and one block IOProc reads the tap and writes the target. This is layout L1 in §4.1.
  `TapAutoStart` is on.
  - Sub-tap drift compensation is *off* when the clock device is Bluetooth or the tap source is
    virtual. Their comment: *"Sub-tap drift comp must be OFF when the tap source and output share a
    clock domain: Bluetooth (tap and output both follow the BT clock — enabling it makes the HAL
    insert/delete a sample on the ~50ppm BT-vs-crystal offset every ~0.7s, the rhythmic call
    crackle)"*.
  - That reasoning holds when the tap sits on the Bluetooth device itself. For a route from the
    speakers to a Bluetooth speaker the clocks do differ, so drift compensation should probably be
    on. Test it both ways in M0.
- **Helpers** (`AudioProcessMonitor.swift` L90–141, L241–265): the owning app is found with the
  private `responsibility_get_pid_responsible_for_pid`, falling back to walking the parent chain.
  All matching process objects merge into one `processObjectIDs` array. Listeners on the process list
  and on `kAudioProcessPropertyIsRunning`, **plus a 10 s poll**: *"CoreAudio property listeners can
  miss notifications during rapid process lifecycle changes (quit + relaunch)."* eq's
  outermost-`.app` rule stays (public API only); the poll is worth copying as a safety net.
- **No live tap edits.** `kAudioTapPropertyDescription` is never set; on a process-set change
  FineTune rebuilds the tap, the aggregate and the IOProc, with a 50–350 ms equal-power crossfade
  (`performCrossfadeSwitch`, L876–962). An absence of evidence, not evidence that live edits fail.
- **Ordered fallback** (`AudioEngine.swift` L150–170), the same pattern the user asked for:

  ```swift
  for uid in priorityOrder {
      guard uid != excluding, let device = connected[uid], aliveCheck(device.id) else { continue }
      return device
  }
  return connectedDevices.first { $0.uid != excluding && aliveCheck($0.id) }
  ```

  On disconnect it reroutes affected apps and marks them "follow default" in memory *without*
  overwriting the saved preference, so the binding returns when the device does. The disconnect
  switch skips the crossfade (`sourceDeviceDead: true`).
- **Crash leftovers** (`OrphanedTapCleanup.swift`): *"Orphans occur when FineTune crashes or is
  force-killed, leaving aggregate devices with `.mutedWhenTapped` process taps that silently mute
  apps."* This contradicts the hope that a tap always dies with its process. eq already destroys
  stale aggregates by UID prefix at start (`destroyStaleAggregates`); routing must keep doing that,
  and M0 must check what a `kill -9` actually leaves behind.
- **Issues that apply to eq's design** (`gh issue list`, 2026-09-29):
  - [#424](https://github.com/ronitsingh10/FineTune/issues/424): ~0.5 s A/V desync over Bluetooth
    A2DP, gone when FineTune quits; suspected extra SRC between 44.1 and 48 kHz;
  - [#170](https://github.com/ronitsingh10/FineTune/issues/170): 200–500 ms of unprocessed audio
    before the tap takes hold (the `mutedWhenTapped` start leak);
  - [#176](https://github.com/ronitsingh10/FineTune/issues/176): CPU 0–1.5 % → 6–25 % regression;
  - [#269](https://github.com/ronitsingh10/FineTune/issues/269): garbled audio from Chrome only;
  - [#375](https://github.com/ronitsingh10/FineTune/issues/375): after a reconnect, "follow default"
    apps were left untapped at full volume (a missed branch in the fallback state machine);
  - [#316](https://github.com/ronitsingh10/FineTune/issues/316) and
    [#326](https://github.com/ronitsingh10/FineTune/issues/326): AirPods auto-switching fights
    FineTune's own switching;
  - [#452](https://github.com/ronitsingh10/FineTune/issues/452): Spotify not detected.

### 2.2 AudioCap

[github.com/insidegui/AudioCap](https://github.com/insidegui/AudioCap), `ProcessTap.swift`
L92–141. [code]
- One process: `CATapDescription(stereoMixdownOfProcesses: [objectID])`, `.unmuted` by default.
- The aggregate holds the tap and the default output, which is the main sub-device, with drift
  compensation on the sub-tap. The block IOProc receives the tap as input directly, with no ring.

This is the template FineTune grew from, and layout L1.

### 2.3 Background Music

[github.com/kyleneideck/BackgroundMusic](https://github.com/kyleneideck/BackgroundMusic). [code]
- `BGM_Client.h` L56–68 copies `AudioServerPlugInClientInfo` and adds `mRelativeVolume` and
  `mPanPosition`. `AddDeviceClient` registers clients (`BGM_Device.cpp` L1860–1877).
- **Per-app volume runs in `ProcessOutput`, per client** (`BGM_Device.cpp` L1473–1491):

  ```cpp
  case kAudioServerPlugInIOOperationProcessOutput: { … }
  mClients.RecordNonBGMAppIO(inClientID);
  ApplyClientRelativeVolume(inClientID, inIOBufferFrameSize, ioMainBuffer);
  ```

  `ApplyClientRelativeVolume` scales that client's buffer in place before the mix. A comment in
  `BeginIOOperation` (L1438–1446) notes the HAL no longer runs `…IOOperationThread` per client
  "on recent macOS", so per-client work belongs in `ProcessOutput`.
- **No per-client routing.** Every client feeds one ring and one output. The playthrough to the real
  device runs in BGMApp, never in the driver.

This is the evidence that design P in §4.2 has a hook to stand on, and that nobody has shipped P.

### 2.4 SoundSource (Rogue Amoeba)

[Manual](https://rogueamoeba.com/support/manuals/soundsource/). [doc]
- Per-app output: *"You can also redirect audio from the default output, enabling an application to
  play audio through a particular output."* One output per app; "Output Groups" mirror to several
  devices at once.
- **No documented ordered fallback**, and nothing documented about what happens when the chosen
  device disconnects.
- Latency ([KB Misc-AppLatency](https://rogueamoeba.com/support/knowledgebase/?showArticle=Misc-AppLatency)):
  *"At 44.1 kHz … latency of around 20-30 milliseconds"*.
- Engine: ACE, deprecated on macOS 15, replaced by ARK on 14.5+ (see `06b`). Exclusive (hog-mode)
  players cannot be reached.

eq's fallback list goes beyond SoundSource here.

### 2.5 eqMac

[github.com/bitgapp/eqMac](https://github.com/bitgapp/eqMac): no per-app routing. Its HAL driver
feeds the app one system stream; the Pro "Volume Mixer" is gain only. No `CATapDescription` in the
public source. [code]

### 2.6 Developer forums (not re-verified by eq beyond the quote)

- [thread 848578](https://developer.apple.com/forums/thread/848578): *"Two process taps on the same
  device from different processes interfere with each other: AudioDeviceStart blocks until the other
  tap is torn down."* eq's taps all live in one process; still a reason for M0 to run a route tap and
  the main tap on the same device together. Same thread: *"The tap delivers IOProc callbacks only
  while some process is rendering"* (for their auto-start setup).
- [thread 806799](https://developer.apple.com/forums/thread/806799): a mixdown tap attenuates by
  6 dB per extra stereo pair on multichannel devices (−12.04 dB at 8 outputs). Irrelevant for the
  user's two devices, but relevant to a route *from* a multichannel interface.
- [thread 825780](https://developer.apple.com/forums/thread/825780): taps delivering all-zero
  buffers; *"both the Process Tap and Aggregate Device must be destroyed and recreated."* eq's
  watchdog already rebuilds both; route engines need the same.
- [thread 819998](https://developer.apple.com/forums/thread/819998), unanswered: does a private tap
  or aggregate disappear when its process ends?
- [thread 770218](https://developer.apple.com/forums/thread/770218), cited in eq's own code: a
  Bluetooth device in the same aggregate as the tap is expected to raise the tap's latency.

## 3. What eq already has that routing reuses

- **The split tap path** (`ProcessTapEngine`): a tap alone in a private aggregate → `AudioRing` → a
  second IOProc on the output device runs EQCore and plays. Its comments record why: tap and
  Bluetooth device in one aggregate added 280 ms, split measured 12.8 ms (`ProcessTapEngine.swift`
  L287–293; README "How it works"). [code] Both IOProcs run on one device's clock; the ring has a
  pacer, not a resampler (`RingPacer`). A route crosses clocks (the app renders on the default
  device's clock, the target plays on its own), so the split path cannot be reused unchanged.
- **The engine is a class with no singletons.** `Daemon` owns one `ProcessTapEngine()`; a second
  instance per target is possible as far as the class goes. The stale-aggregate cleanup keys on
  the UID prefix `com.servitola.eq.aggregate-` followed by the device UID
  (`AudioDeviceManager.swift` L27, L272), so route aggregates need a distinct UID under the same
  prefix. [code]
- **Process discovery** (`CoreAudioProcesses`, `AppIdentity`): the HAL's process list with
  listeners and no polling; a helper maps to the outermost `.app` in its executable path; WebKit's
  `com.apple.WebKit.GPU` names no app. [code] F2 debounces for 1 s (`AppFollower.debounce`); routing
  cannot, because every millisecond before a new helper is excluded from the main tap is heard on the
  wrong device.
- **The plug-in** already stores settings per target UID and plays "the curve eq last sent for that
  target" (`Driver/README.md`). Its clock servo slaves the virtual device to *one* target
  (`Core/Clock.h`, `zeroTimeStamp` in `Driver.cpp`). [code] A second target has its own clock; the
  plug-in has no resampler.
- **The config** has `apps` (F2 rules), `experimental.apps`, `mode`, and per-device profiles keyed by
  UID. The user's `eq.json` today has `"mode": "driver"` and three devices:
  `BuiltInSpeakerDevice` (MacBook Pro Speakers), `EB-06-EF-24-61-CF:output` (BE-RCA) and
  `com.servitola.eq.device` (BE-RCA · EQ). [code, read-only]

## 4. Analysis

### 4.1 Tap mode

**What has to happen for Spotify → BE-RCA while the default is the speakers:**

1. Spotify's audio must stop reaching the speakers: a muted tap on Spotify.
2. The main tap on the speakers must not also carry Spotify: add Spotify to its exclusion list.
   The mute of the main tap applies only to the processes it taps, so after step 2 only step 1
   mutes Spotify and nothing is doubled.
3. Spotify's tapped audio must play on BE-RCA with BE-RCA's curve: an engine per *target device*.

**Where the clock goes.** Two layouts:

- **L1, one aggregate per target** (the layout FineTune and AudioCap-style tools use; see §2): the
  target is the aggregate's main sub-device, the route tap is a sub-tap with drift compensation, and
  one IOProc reads the tap and writes the target. The HAL resamples the tap onto the target's
  clock and converts rates (48 kHz speakers, 44.1 kHz Bluetooth). No new DSP in eq. The cost is
  latency: eq measured +280 ms on a Bluetooth speaker with that layout for the main tap. That
  number came from a tap on the *same* device as the aggregate; for a route (tap on the speakers,
  BE-RCA as sub-device) it is [unknown].
- **L2, eq's split path plus a resampler**: tap-only aggregate → ring → output IOProc on the target,
  with an asynchronous sample-rate converter in the ring's reader, steered by the ring's fill level
  (the driver's servo, `Core/Clock.h`, is the model). Low latency, but eq has to write and test a
  good resampler (a windowed-sinc polyphase SRC; linear or cubic interpolation is audible on an EQ
  tool whose users listen closely), and a steered SRC is the kind of code that fails in long soaks.

The route's latency only matters for video (see below). Recommendation: **L1 first**, measured
in M0. Build L2 only if L1 adds more than ~60 ms on top of the target's own latency or crackles
over an 8-hour soak.

**Lip sync cannot be fixed in tap mode.** The app renders to the device it thinks it plays on and
asks *that* device for its latency. A Chrome video routed from the speakers (~10 ms) to BE-RCA (the
speaker's own 150–250 ms plus eq's path) will run its picture ahead of its sound by the whole
difference. Nothing in the public API lets eq change the latency another process reads for a real
device. Say this plainly in the README: routing is for music and calls-free listening; route a
video app at your own risk.

**Two apps to one target** share one tap: a tap takes a list of processes (or bundle IDs on 26).
The engine count is the number of *distinct targets in use*, not the number of apps. With the
user's two devices, at most one route engine runs at a time, because a route to the current default
is no route.

**Helpers.** A routed app is the set of process objects whose `AppIdentity` is that app (Chrome plus
its helpers; `com.apple.WebKit.GPU` for Safari and every WebKit app together, which is the README's
existing caveat). On macOS 26, prefer `bundleIDs` (with the helper IDs seen so far) if M0 shows it
catches processes that start later; otherwise update both taps' process lists on every process-list
event, with no debounce.

**Muted vs muted-when-tapped for the route tap.** With `mutedWhenTapped`, whatever plays while the
route engine is not reading (it starts, or it is stopped to let the target sleep) is heard on the
default device: a short burst from the wrong speaker. With `muted`, that audio is lost instead: a
clipped start. If eq dies, the hope is that both taps die with it and the app is heard on its own
device again (fail-open). FineTune's `OrphanedTapCleanup` says a force-killed owner can leave
aggregates whose taps "silently mute apps" (§2.1), so this is [unknown] until M0 kills the daemon
with `-9` and listens. The existing `destroyStaleAggregates` at daemon start covers the case where
launchd restarts it. Recommendation: `muted`, and keep the route engine reading
while any process of the app has audio IO running, plus a 30 s tail so gaps between tracks never
stop it.

**Volume.** A process tap carries the app's signal before any device volume. The route engine
plays through the target's own volume. The volume keys change the default device's volume, so
they do not move a routed app. SoundSource behaves the same way (per-device volume). [inferred]

**CPU.** Today one engine costs 0.30 % CPU and ~190 context switches/s at 44.1 kHz (README
"Footprint"). An L1 route engine has one IOProc instead of two, so expect ≤ 0.3 % per target in
use; M3 measures it with `scripts/footprint.sh`.

**Permission.** The same System Audio Recording grant covers per-process taps; nothing new to ask.

### 4.2 Driver mode

In driver mode every app plays into "BE-RCA · EQ"; the plug-in plays the mix on one target.

- **P, per-client routing inside the plug-in.**
  1. Record each client's pid and bundle ID in `AddDeviceClient`.
  2. Ask for `ProcessOutput` in `WillDoIOOperation`.
  3. In `DoIOOperation(ProcessOutput, inClientID)`, copy a routed client's buffer into that target's
     ring and zero it in place, so the mix no longer carries it.
  4. Run one more target IOProc per extra target, with its own EQCore engine (the per-UID settings
     store already exists) and a resampler, because the virtual clock follows only the primary
     target.

  It works in principle ([SDK] §1.2; Background Music's per-client volume shows the hook runs per
  client). The costs:
  - every extra target is another forbidden HAL client call from inside the plug-in, the risk the
    user accepted once for one target;
  - a resampler and a second servo in C in a real-time plug-in;
  - the target state machine (`Core/TargetMachine.h`) turns from one target into many;
  - the plug-in gets a routing table over a custom property, from the daemon, which maps helpers
    to apps (the plug-in only sees each client's own main bundle);
  - a plug-in bug takes out all system audio, not one app.

  Honest size: L, and the riskiest code in the project.
- **H, hybrid: routed apps use the tap path while driver mode stays on.** The daemon runs the same
  route engine as in tap mode: a muted per-process tap on the routed app (which plays into the
  virtual device), played on the route target with that target's curve. The plug-in does not
  change. The mute takes the app out of the virtual device's mix, so nothing is doubled. The costs:
  - the System Audio Recording permission, and the Privacy indicator, but only while a routed app
    plays to a target other than the driver's;
  - the route's latency, as in tap mode.

  Size: small once tap-mode routing exists.

Recommendation: **H**. It gives routing in both modes from one implementation, and keeps the plug-in
as simple as its go/no-go criteria assume. P stays on the shelf. Revisit it only if the indicator
during routed playback is a deal-breaker for the user, and only after driver mode has passed its
8-hour and 20× reconnect criteria.

### 4.3 Per-process latency (idea, not planned)

Because the plug-in's `GetPropertyData` receives the caller's pid, in driver mode the plug-in could
report a routed app's latency as that of its route target, so the player would compensate. It
applies to H as well, because the routed app still opens the virtual device. [unknown] whether the
HAL forwards the pid of the real client and does not cache, and whether a player reads latency again
after a route changes mid-stream. Worth a one-hour probe after M3, not a dependency.

## 5. Sources

- Apple SDK: `CATapDescription.h`, `AudioHardware.h`, `AudioHardwareTapping.h`,
  `AudioServerPlugIn.h` from the macOS 26.5 SDK on this Mac.
- FineTune `2285279`: `ProcessTapController.swift`, `AudioEngine.swift`, `AudioProcessMonitor.swift`,
  `OrphanedTapCleanup.swift`; issues #170 #176 #269 #316 #326 #375 #424 #452.
- AudioCap: `ProcessTap.swift`.
- Background Music: `BGM_Client.h`, `BGM_Device.cpp`, `BGM_Clients.cpp`.
- Rogue Amoeba: SoundSource manual, KB Misc-AppLatency, KB ACE-Legacy.
- Apple Developer Forums threads 770218, 806799, 819998, 825780, 848578.
- eq: `ProcessTapEngine.swift`, `AudioProcesses.swift`, `AppFollower.swift`, `AudioDeviceManager.swift`,
  `Driver/Source/Driver.cpp`, `Driver/Source/Core/Clock.h`, `docs/research/05`, `06a–06c`,
  specs roundF and driver-mode.

## M0 results (2026-09-29, this Mac, BE-RCA ↔ MacBook Pro Speakers, driver mode on)

```
RESULT check capture=ok peak=-29.6 dBFS
RESULT l1 src=MacBook Pro Speakers dst=BE-RCA drift=1 added_ms=186.8 clicks=6/6 glitches=0 dropouts=0 gaps=0 overloads=0 heard=c
RESULT l1 src=MacBook Pro Speakers dst=BE-RCA drift=0 added_ms=186.8 clicks=6/6 glitches=0 dropouts=0 gaps=0 overloads=0 heard=c
RESULT l1 src=BE-RCA dst=MacBook Pro Speakers drift=1 added_ms=89.0 clicks=6/6 glitches=0 dropouts=0 gaps=0 overloads=0 heard=c
RESULT l1 src=BE-RCA dst=MacBook Pro Speakers drift=0 added_ms=89.0 clicks=6/6 glitches=0 dropouts=0 gaps=0 overloads=0 heard=c
RESULT exclude-live mute=0 status=0/0 gone_ms=22.9 back_ms=13.7 excluded_level=-111.8 dBFS b_dip=no glitches=3 gaps=0 heard=-
RESULT exclude-live mute=1 status=0/0 gone_ms=33.3 back_ms=15.3 excluded_level=-113.1 dBFS b_dip=no glitches=3 gaps=0 heard=n
RESULT bundle restore=0 pre=0 running_at_creation=- started_later=no helper_by_app=no helper_standalone=no
RESULT bundle restore=0 pre=1 running_at_creation=yes started_later=no helper_by_app=no helper_standalone=no
RESULT bundle restore=1 pre=0 running_at_creation=- started_later=yes helper_by_app=no helper_standalone=no
RESULT bundle restore=1 pre=1 running_at_creation=yes started_later=yes helper_by_app=no helper_standalone=no
RESULT dual first=main start_ms=35.4/0.1 blocked=no doubled=no main_1k=-113.8 dBFS route_1k=-20.0 dBFS route_2k=-111.9 dBFS heard=y
RESULT dual first=route start_ms=0.1/26.8 blocked=no doubled=no main_1k=-113.4 dBFS route_1k=-20.0 dBFS route_2k=-112.9 dBFS heard=y
RESULT start mute=muted order=tone-first window_ms=191.5 observer=uncalibrated heard=y
RESULT start mute=muted order=tap-first window_ms=164.2 observer=- heard=y
RESULT start mute=mutedWhenTapped order=tone-first window_ms=231.2 observer=uncalibrated heard=y
RESULT start mute=mutedWhenTapped order=tap-first window_ms=164.2 observer=- heard=y
RESULT kill mute=muted public=0 audible_after_kill=? leftovers=1+1 observer=uncalibrated heard_held=y heard_after=y heard_after_destroy=y
RESULT kill mute=muted public=1 audible_after_kill=? leftovers=2+2 observer=uncalibrated heard_held=y heard_after=n heard_after_destroy=y
RESULT kill mute=mutedWhenTapped public=1 audible_after_kill=? leftovers=2+2 observer=uncalibrated heard_held=y heard_after=y heard_after_destroy=y
RESULT format device=BE-RCA@44100 process=48000 mixdown=48000/48000/48000 mixdown_l1=48000/48000/44100 device_stream=44100/44100/44100 (creation/aggregate/delivered Hz)
RESULT format device=MacBook Pro Speakers@44100 process=48000 mixdown=48000/48000/48000 mixdown_l1=48000/48000/44100 device_stream=44100/44100/44100 (creation/aggregate/delivered Hz)
RESULT music pid_tap=audio(-12.9 dBFS) bundle_tap=audio(-12.5 dBFS) catalogue=y
```

Conclusions:
- **L1 is rejected.** It adds 186.8 ms going to BE-RCA and 89.0 ms going to the speakers, with or
  without drift compensation. That is far over the ~60 ms limit, so M2 is built as **M2b**: the
  split path, with its own resampler and drift servo.
- The live exclusion edit works. Audio is gone from the main tap in 23–33 ms and back in 14–15 ms,
  with no dip in the other audio.
- A `bundleIDs` tap with `processRestoreEnabled` catches processes of the same bundle that start
  later. It does NOT catch helper processes, whether the app starts them or they start on their
  own. Helpers need PID taps from the resolver's process list.
- A route tap and the main tap can share a source device: no doubled audio, and no blocked start.
- When a route starts, audio from the old place leaks for 164–231 ms in every variant. So routed
  apps must be tapped as soon as they open audio, before they play. The M1 resolver already does
  this.
- After a `kill -9`:
  - a private muted tap gives the audio back;
  - a public muted tap leaves the app muted until the leftovers are destroyed;
  - a public mutedWhenTapped tap gives it back.

  eq uses private taps and cleans up at start.
- A mixdown tap inside an L1 aggregate is labelled 48 kHz but delivered at 44.1 kHz, and its tone
  measured 1020.57 Hz. Taking the format at face value would therefore be wrong. Only a tap on the
  device's own stream is honest about its format. M2b takes the tap's own format and resamples.
- Apple Music catalogue (DRM) tracks come through a tap as normal audio (−12.9 dBFS, no silent
  blocks).
- By ear: the tone had no crackle on either device. Some answers about the start-of-route blip
  are ambiguous, and the measurements take precedence.
- Spike bug to note: every run numbers its questions from 1, so one answer was reused by later
  runs until the answer file was cleared after each one.
