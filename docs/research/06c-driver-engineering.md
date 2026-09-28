# Driver mode, engineering: how eq would build design A, and what it would feel like

Date: 2026-09-28. Scope: the build side of "design A": an output-only virtual AudioServerPlugIn
that runs eq's chain inside Core Audio's driver host and plays the result on the real device from
inside the plug-in. Whether to do it at all is a separate question; this report says how, what it
costs, and how to find out cheaply whether it holds.

Sources read for this report (clones in the session scratchpad, commit noted):

- eqMac `04e5a3a` (2025-11-02): `native/driver/Source/*.swift`, the Swift HAL driver.
- BackgroundMusic `8c25450` (2026-06-10): `BGMDriver/`, `BGMApp/BGMXPCHelper/`,
  `BGMApp/BGMApp/BGMDeviceControlSync.h`, `BGMTermination.mm`, `DEVELOPING.md`.
- BlackHole `62953f5` (2026-09-22): `BlackHole/BlackHole.c`, `BlackHoleTests/main.c`,
  `Installer/create_installer.sh`, `Installer/Scripts/*`.
- libASPL `633e0f7` (v3.1.2, 2025-04-14): `README.md`, `include/aspl/*.hpp`, `src/Device.cpp`,
  `test/*`.
- Proxy Audio Device `be390f7` (2026-05-21): `proxyAudioDevice/ProxyAudioDevice.cpp`, and its
  issue tracker (#6, #14, #19, #43, #62, #69).
- The macOS 26.6 SDK header `CoreAudio/AudioServerPlugIn.h`, this Mac's
  `/System/Library/Sandbox/Profiles/com.apple.audio.coreaudiod.sb`, the entitlements of
  `com.apple.audio.Core-Audio-Driver-Service.helper.xpc`, and the running process list.
- Homebrew casks `proxy-audio-device`, `blackhole-2ch`, `background-music`, `eqmac`.
- eq itself: `Sources/eq/Engine/{EQProcessor,BiquadFilter,DynamicsStage,AudioRing,BandMeter,ProcessTapEngine}.swift`,
  `Sources/EQAtomics/include/EQAtomics.h`, README "How it works", and `eq status` on this Mac.

## 0. The two facts that shape everything else

**Apple forbids exactly what design A does.** The SDK header is unambiguous:

> "An AudioServerPlugIn operates in its own process separate from the system daemon. First and
> foremost, an AudioServerPlugIn may not make any calls to the client HAL API in the
> CoreAudio.framework. This will result in undefined (but generally bad) behavior."
> — `AudioServerPlugIn.h`, macOS 26.6 SDK, lines ~33–35

Design A has to be a HAL *client* of the real device (`AudioDeviceCreateIOProcID`,
`AudioDeviceStart`, property listeners) from inside the plug-in. Proxy Audio Device does precisely
this, and its author says so: "Proxy Audio Device is breaking some rules and doing some hacky
things. I went out of my way to have any calls to the HAL API happen in a separate thread …
So far it seems to prevent deadlocks" (proxy-audio-device #6). Every other surveyed driver
(eqMac, BackgroundMusic, BlackHole-based setups) keeps the plug-in a pure loopback and does the
real-device output in a user process, which is within the rules. So design A is built on
unsupported behaviour that one maintained project has shipped for years. That is the risk
milestone 1 must retire, and nothing else in this report matters if it does not.

**The plug-in does not run inside coreaudiod.** On this Mac (macOS 26.6.2) the one third-party
plug-in installed runs as its own process, `_coreaudiod  Core Audio Driver (ParrotAudioPlugin.driver)`,
an instance of `CoreAudio.framework/XPCServices/com.apple.audio.Core-Audio-Driver-Service.helper.xpc`
(`_MultipleInstances = true`). Proxy's users' logs show the same host
(`com.apple.audio.Core-Audio-Driver-Service`, proxy #14). Consequences:

- A crash in eq's plug-in kills its helper, not coreaudiod. Whether coreaudiod respawns the helper
  on its own is not documented; milestone 1 tests it.
- The helper is signed with `com.apple.security.cs.disable-library-validation` (checked with
  `codesign -d --entitlements`), so an ad-hoc or differently-signed `.driver` loads. Useful for
  development; says nothing about Gatekeeper on a quarantined download (see §6).
- The helper is a HAL client like any app when the plug-in calls the client API, which is why
  Proxy works at all, and why the HAL can treat it like a background daemon: one Proxy user's
  failures were each preceded by `HALC_ProxyIOContext::_StartIO(): Client running as an adaptive
  unboosted daemon` and `AudioDeviceStart` returning `kAudioHardwareIllegalOperationError`
  (proxy #43). That is a concrete failure mode for milestone 1 to hunt.

## 1. Framework and language

### Options

| | libASPL (MIT, C++17) | Apple NullAudio / BlackHole style (C) | eqMac style (Swift) |
| --- | --- | --- | --- |
| Boilerplate owned by eq | little: typed getters/setters, generated dispatch | all of it: BlackHole.c is 211 KB, Proxy's .cpp 5 865 lines | all of it: eqMac 2 461 lines of Swift, dispatch by hand |
| Custom properties | `RegisterCustomProperty(selector, getter, setter)`, CFString or CFPropertyList (`Object.hpp`) | hand-written | hand-written (`EQMDevice.swift`) |
| Persistent storage | `driver->GetStorage()->Read/WriteString…` over the host's storage API | host calls by hand | host calls by hand |
| Clock | `GetZeroTimeStampImpl()` overridable; `ClockAlgorithm`, `ZeroTimeStampPeriod`, `Latency`, `SafetyOffset` parameters (`Device.hpp`) | own code | own code |
| Testability | objects construct without the HAL; tests inject a fake `AudioServerPlugInHostInterface` (`test/TestStorage.cpp`) | include the `.c` and call the vtable (`BlackHoleTests/main.c`) | none shipped |
| Realtime notes | `IORequestHandler` is the only realtime surface; realtime tracing off by default (`EnableRealtimeTracing = false`); lock-free `DoubleBuffer` for config→IO | as written | pthread mutex in `doIO` and `getZeroTimeStamp` (`EQMDevice.swift` L590, L561), `Mutex` = `pthread_mutex_t` (`shared/Source/Mutex.swift`) |
| Maintenance | last release 2025-04; used by roc-vad | Apple sample, frozen | eqMac driver unchanged since 2021 |

libASPL itself still takes a `std::recursive_mutex` on the IO path (`Device::GetZeroTimeStamp`,
`DoIOOperation` lock `ioMutex_`, also taken by `StartIO`/`StopIO`: `src/Device.cpp` L1073–1562).
Apple's samples do the same, it is only contended during start/stop, and eq's override of
`GetZeroTimeStampImpl` runs under it either way. Accept it, and keep eq's own IO code lock-free.

### Can a HAL plug-in be Swift?

Yes, eqMac ships one. How it does it:

- An Objective-C shim exports the CFPlugIn factory (`EQM_Create` in `Bridge/EQMDriverBridge.m`)
  because in 2021 there was no stable way to export a C symbol from Swift; today `@_cdecl` does it.
- The `AudioServerPlugInDriverInterface` vtable is filled with Swift `@convention(c)` functions and
  pinned in static storage (`EQMDriver.createRef()`).
- Build: `WRAPPER_EXTENSION = driver`, `ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES = YES` because the
  deployment target is 10.10, and a SwiftPM dependency on swift-atomics. On macOS ≥ 10.14.4 the
  Swift runtime is in the OS, so eq would embed nothing; eq's whole CLI+daemon is 3.0 MB and links
  only system frameworks (`otool -L` on the installed binary), and a plug-in carrying just the
  chain would be a few hundred KB (estimate, not measured).
- Realtime: eq already runs Swift on realtime IOProc threads today (the tap and output IOProcs
  call `EQProcessor.process`), with a try-lock snapshot swap, retired snapshots freed off the audio
  thread, and raw pointers for per-channel state. So "Swift on a realtime thread" is not the new
  risk. What is new in a plug-in: exclusivity checks on static/global state (`SWIFT_ENFORCE_EXCLUSIVE_ACCESS = on`
  in eqMac's build turns every static access on the IO path into a runtime call), and any
  accidental ARC traffic becomes glitches in *every* app's audio, not just eq's.

### Recommendation: one C core, two hosts

Move the DSP into a small C17 target, `EQCore`, used by both the daemon (as a SwiftPM C target,
exactly like the existing `EQAtomics`) and the plug-in (compiled into the `.driver`):

- `eqc_design(params, rate) -> coefficients`: the RBJ shelf/peaking/pass designs now in
  `BiquadFilter.make`, the K-weighting detector filters and the dynamics coefficients now in
  `DynamicsCoefficients`. In C so the plug-in can redesign on a sample-rate change without the
  daemon.
- `eqc_process(state, coeffs, float **ch, nch, frames)`: preamp → biquad cascade → output gain →
  compressor → colour → soft limiter, denormal flush, silence gate; no allocation, no locks.
- `eqc_meter(...)`: the `BandMeter` filters and envelopes.

Why C and not "reuse the Swift": bit-identical output between tap mode and driver mode is only
guaranteed if both run the *same object code*. Two Swift compilations (a SwiftPM executable and a
plug-in bundle) with different flags, whole-module settings or compiler versions are not
guaranteed to contract or reorder float operations the same way; one C object compiled once with
`-ffp-contract=off` (or a fixed setting) is. The plug-in side is C++ (libASPL) anyway, and the
daemon calling C from Swift costs nothing. Migration path: port, then run the existing golden
impulse-response tests against both implementations until the C one matches the Swift one within
1e-6, then delete the Swift DSP so the tolerance becomes zero by construction.

Plug-in: libASPL (vendored at v3.1.2, MIT, noted in NOTICE) + ~1–1.5 kLOC of eq C++ + `EQCore`.
This keeps eq's zero-*runtime*-dependency stance (vendored source, like OnlyEQ's) and puts all
realtime-sensitive code in C where the rules are simplest.

## 2. Clocking, ring and latency

### What the references do

- **Proxy**: the virtual device free-runs on `mach_absolute_time`, and each `GetZeroTimeStamp`
  scales the period by the *average* `mRateScalar` the real device's IOProc saw since the last call,
  then resets the average (`ProxyAudioDevice.cpp` L5140–5176, L5358–5367). The read position into
  the ring is fixed once at start (`inputOutputSampleDelta`, L5380–5386) and never corrected.
  That is open-loop rate matching with no phase correction, and the result is Proxy's one big
  bug: "the proxied and proxy devices don't read / write to the buffer at precisely the same
  speed, and it eventually goes too far out of sync and runs out of audio … usually it takes hours"
  (owner, proxy #14; also #19, #43). Users work around it by toggling the buffer size several times
  a day. It also reports `kAudioDevicePropertyLatency = 0` (L2918–2926).
- **eqMac, BackgroundMusic, libASPL, BlackHole**: free-running virtual clock on host time
  (`anchorHostTime + n·period·ticksPerFrame`); the output side lives in another process and deals
  with drift there. BackgroundMusic leaves latency as a TODO: "Should we return the real
  kAudioDevicePropertyLatency … for the real/wrapped output device?" (`BGM_Device.cpp` L785).

### Proposal: slave the virtual clock to the target's timestamps

The target's IOProc gets `inOutputTime` (sample time, host time, rate scalar) every cycle, already
filtered by the HAL. Publish the latest `(sampleTime, hostTime)` from that IOProc with the seqlock
eq already has (`eq_stamp_publish` / `eq_stamp_read` in `EQAtomics.h`). In
`GetZeroTimeStampImpl`, return zero stamps on the virtual timeline `V = T_target + offset`:
the period boundary `k·P` maps to the target host time interpolated from the two latest stamps.
Then the virtual device runs at exactly the target's rate, drift cannot accumulate, and the ring
fill stays constant by construction instead of by luck. Details:

- Period `P` = 16 384 frames like the samples, `ClockAlgorithm = kAudioDeviceClockAlgorithmSimpleIIR`
  (libASPL's default) so the HAL smooths residual jitter.
- Before the first target stamp (target not started yet) and after the target stops, fall back to
  host time at nominal rate; on every switch between the two timelines, bump `outSeed` so the HAL
  resynchronises instead of seeing a jump.
- Keep a closed-loop guard anyway: the ring reader tracks fill against a target (eq's
  `RingPacer` already does target/ceiling/underrun/overrun) and reports slips. With a slaved clock
  a slip is a bug to log, not the steady state Proxy lives in.
- Unverified assumption, tested in milestone 1: that the HAL accepts zero stamps whose host-time
  spacing follows the target's measured rate. Real hardware drivers report exactly that kind of
  stamp, so it should.

### Ring

Same shape as eq's `AudioRing` (SPSC, interleaved, positions never wrap), written by the plug-in's
`WriteMix` operation on the HAL's IO thread for the virtual device and read by the target IOProc.
Both threads live in the same helper process. Capacity: next power of two above
`2 × (virtual buffer + target buffer + cushion)`, e.g. 4 096 frames; the plug-in allocates it in
`OnStartIO`, never on the IO thread.

### Latency the virtual device must report

Players compute presentation time from the device they play to: device latency + stream latency
+ safety offset + buffer size. In driver mode the default device is the virtual one, so whatever
it reports is all a player knows. Report:

```
virtual Latency      = target.deviceLatency + target.streamLatency + target.safetyOffset
                       + target.bufferFrames + ringCushion
virtual SafetyOffset = 0 (the HAL may write right up to "now"; the ring absorbs the phase)
```

Update it (via `SetLatencyAsync`, which goes through a device configuration change and so briefly
restarts IO) whenever the target, its buffer size or its rate changes. Measure it end to end with
`scripts/measure-latency.sh` rather than trusting the formula.

### What it adds, and whether it helps lip sync

Today on this Mac: `eq status` → `BE-RCA [bluetooth] 44100 Hz, latency 190 ms (device 180, eq adds 10)`.
The README's split-path figure is 12.8 ms; the measured range is 10–13 ms.

Driver mode estimate: no tap buffer (128 frames) and no second process hop. What remains is one
target buffer of phase wait plus the jitter cushion, ≈ 128 + 64–128 frames on top of the target
buffer: **roughly 4–8 ms at 128-frame buffers, 44.1 kHz** (estimate; milestone 1 measures it).
More importantly it is *reported*: a compliant player would see ~190 ms and compensate all of it.

An honest caveat that cuts against the motivation: the 10–13 ms eq adds today, unreported, is far
below what anyone can see. ITU-R BT.1359 puts detectability at about 45 ms of audio leading and
125 ms of audio lagging video; tap mode's error is audio lagging by ~12 ms. The Bluetooth device's
own ~180 ms is already reported by the real device in tap mode and compensated by players. So
driver mode does not fix a lip-sync problem eq has; it removes a 10 ms error nobody perceives. If
lip sync is the reason for design A, it is not a strong one. (eqMac has an open A/V-sync complaint
over Bluetooth, eqMac #94; I did not establish its cause.)

## 3. Control plane

### Transport: custom properties, not strings in box names

Proxy passes configuration by setting the *box name* to `key=value` from a process whose PID it
learnt earlier through `kAudioObjectPropertyIdentify` (`ProxyAudioDevice.cpp` L2185–2230; the
owner calls it "a total hack", #6). eqMac and BackgroundMusic use proper custom properties
(`EQMDevice.swift` L376–501; `BGM_Types.h` L88–126). eq should use libASPL custom properties with
`kAudioServerPlugInCustomPropertyDataTypeCFPropertyList` payloads on the device object:

| Selector | Dir | Payload | Notes |
| --- | --- | --- | --- |
| `eqPm` | set/get | dict `{v:1, curves:{deviceUID: params}, default: params}` | params = bands, filters, preamp, output gain, limiter, dynamics, colour, bypass. Not coefficients: the plug-in designs them at its current rate. |
| `eqSo` | set | `{low, high}` or empty | solo; kept out of storage (transient) |
| `eqTg` | set/get | `{uid, policy}` | target device and fallback policy |
| `eqMd` | set/get | `{active: bool}` | active = visible + default-capable; inactive = hidden |
| `eqMt` | get | CFData: 2×10 band levels, peak, comp reduction | reading it arms metering for 1 s |
| `eqHl` | get | dict: io cycles, target cycles, ring fill, slips, drift ppm, last OSStatus, target uid/rate/buffer, safe-mode flag | health, polled by the daemon and `eq status` |
| `eqVr` | get | `{plugin, protocol}` | handshake; daemon refuses to drive an unknown protocol |

The setter runs on a HAL control thread: validate every field (type, count ≤ 42 filters, finite,
ranges; reject a filter whose poles leave the unit circle), design coefficients, publish them to
the IO side with a lock-free swap (libASPL `DoubleBuffer`, or eq's current try-lock snapshot),
then write the accepted params to host storage. A malformed payload must be rejected, never
crash: a crash takes every app's audio with it for the respawn interval.

### Who may set it

The HAL hands the setter only a PID. eqMac and BackgroundMusic check the *client bundle ID*
(`guard client?.bundleId == APP_BUNDLE_ID`, `EQMDevice.swift` L448; `BGM_Clients::IsBGMApp`), but
that list holds IO clients, which eq's daemon is not in driver mode. Options: ignore authorisation
(any local process can already change the system volume and default device; the worst a rogue
caller does is change the EQ curve), or check the caller's code signature from its PID
(`SecCodeCopyGuestWithAttributes` + a requirement on `identifier "com.servitola.eq"` and eq's
team). coreaudiod's sandbox profile allows `process-codesigning-status*` and `csops`; whether the
driver helper's profile does is unverified. Recommendation: validate strictly, skip authorisation
in milestone 2, revisit only if a real abuse case shows up.

### Meters, `eq watch`, solo, compressor

- `eq watch` reads `eqMt` itself at 30 Hz with `AudioObjectGetPropertyData`: a HAL call to
  coreaudiod, forwarded to the helper. 30 small reads a second is modest; measure it in
  milestone 2. `eq watch` then works even with the daemon down.
- Metering costs nothing while unread: the getter stamps "last read" into an atomic, the IO thread
  runs `eqc_meter` only if that stamp is under 1 s old. Same "zero cost while nobody watches" rule
  eq has today.
- Solo and the compressor are just parameters in the chain; compressor reduction comes back in
  `eqMt`.
- Push model for state changes (the daemon's `eq events`): the plug-in calls `PropertiesChanged`
  on `eqHl` when health flips (target lost, safe mode), which listeners get as a normal HAL
  property notification. Header rule: that is allowed for changes "that don't have any effect on
  IO or on the structure of the AudioDevice".

### When the daemon is not running

The plug-in keeps playing the last accepted curve for the current target, from host storage, across
coreaudiod restarts and reboots. That is the property that makes driver mode worth having over
tap mode, and it means the daemon becomes a *controller*, not part of the audio path. The failure
direction is "EQ frozen at last settings", never "silence".

## 4. System integration

**Default device.** In driver mode the daemon makes the virtual device the default output and
system output, remembering the real one it replaced (BGM keeps the same memory for crash cleanup:
`outputDeviceToMakeDefaultOnAbnormalTermination`, `BGMXPCHelperService.mm` L246). The daemon owns
this; the plug-in never touches defaults.

**Device switching.** When the virtual device is default, the user picking "AirPods" in Control
Center, or macOS auto-switching to newly connected headphones, makes the *real* device default and
bypasses eq. The daemon listens for default-output changes: if the new default is a real device
while driver mode is on, it retargets the plug-in (`eqTg`) and sets the virtual device default
again, a ~100 ms flip. This is the same interception BackgroundMusic does, and it is what makes
the virtual device feel invisible. Without the daemon: the user gets plain, un-EQ'd sound on the
device they picked. That is fail-open, the right direction.

**Target disappears** (Bluetooth off, cable out) while the virtual device stays default: the
plug-in must not play into nothing. On `kAudioDevicePropertyDeviceIsAlive` = 0 or a device-list
change it retargets by itself: the daemon's preferred list in `eqTg` if any member is alive,
otherwise the first non-virtual output with the built-in speakers preferred (Proxy's
`copyDefaultProxyOutputDeviceUID`, L5648–5675). Never target itself, an aggregate or a multi-output
device containing it (feedback loop): exclude by UID and by `kAudioAggregateDevicePropertyFullSubDeviceList`.

**Volume and mute.** The virtual device exposes volume and mute controls, so the volume keys and
HUD act on it. The plug-in forwards the scalar to the target's own volume control (Bluetooth
absolute volume included), and mirrors the target's changes back (AirPods' own buttons) with loop
suppression. BackgroundMusic's `BGMDeviceControlSync` does exactly this from the app side and
disables virtual controls the output device lacks. Do it in the plug-in, not the daemon, so volume
keys keep working with the daemon down. For targets with no hardware volume (HDMI, many USB DACs)
apply software gain *after* the limiter so the ceiling stays honest. Proxy's issue list shows the
cost of doing only software gain: "Notification sounds full volume" (#48), "Audio fades up after
silence" (#24).

**Sample rate.** Follow the target, never resample: on a target rate change, request a device
configuration change to the same rate (Proxy does this, L4828–4881), redesign coefficients in the
new-rate `PerformDeviceConfigurationChange`. Offer the target's rates as the virtual device's
available rates. A Bluetooth headset dropping to 16/24 kHz for a call drags the virtual device
and all its clients with it; that is what the real device does to them today as well.

**Sleep/wake.** Proxy's macOS 26 reports: audio gone after the monitor sleeps, restored only by
switching outputs (#62); eqMac: crash after wake (#134), and preventing sleep (#228). The plug-in
must treat "target IOProc stopped firing" as a state, restart with backoff (`AudioDeviceStart`
retries at 0.1/0.5/2/5 s), and expose it in `eqHl`. The daemon, which can hear the workspace wake
notification, pokes a `resync` field in `eqTg`. Also: stop the target IO when the virtual device
has no IO clients (after a short hold), so the Mac can sleep and Bluetooth can idle; Proxy's
"when user is active" condition exists because an always-running target keeps hardware awake.

**Hidden when off.** `eqMd {active:false}` sets `kAudioDevicePropertyIsHidden = 1` and
`CanBeDefaultDevice = 0`, persisted in storage, so after `eq mode tap` and a reboot the device does
not reappear in menus. Proxy added the same toggle recently (`outputDeviceHideWhenUnavailable`).

**AirPlay.** Unknown and probably bad: nobody in the tap niche handles AirPlay (05 §1), eqMac has
the same open bug (#390), and driving an AirPlay route as an IOProc client from the driver helper
is untested anywhere I found. Recommendation: when the chosen target is AirPlay, driver mode steps
aside (virtual device hidden, AirPlay default, tap mode or no EQ), and the README says so.

## 5. Testing, soak, recovery, escape hatch

**Unit tests without coreaudiod.**

- `EQCore`: plain C unit tests plus the existing Swift golden IR tests through the C entry points.
- Plug-in logic on libASPL: libASPL's own tests construct `Device`/`Stream` objects with a fake
  `AudioServerPlugInHostInterface` whose `CopyFromStorage`/`WriteToStorage` are in-memory
  (`test/TestStorage.cpp` L95–110). Extend that fake with `PropertiesChanged` (record) and
  `RequestDeviceConfigurationChange` (call `PerformDeviceConfigurationChange` synchronously).
- Put the real device behind an interface (`TargetOutput`: start, stop, stamps, pull). A simulated
  target pulls from the ring at a configurable rate ratio (±300 ppm) with scheduling jitter and
  occasional stalls, so a day of drift runs in seconds and asserts: no underrun after priming, fill
  bounded, seed bumps on timeline switches, latency property matches the formula. This test is the
  one Proxy never had.
- BlackHole's trick for the vtable: include the source in a test and call the function table
  directly (`BlackHoleTests/main.c`).

**A user-space host for the real binary.** Load `eq.driver` in an ordinary process with
`CFBundleCreate` + `CFPlugInInstanceCreate(kAudioServerPlugInTypeUUID)`, hand it the fake host,
drive `StartIO`/`GetZeroTimeStamp`/`DoIOOperation` from a realtime thread with a generated tone.
Because the plug-in's target side is a normal HAL client, it plays to the real Bluetooth device
from this test host too. This gives lldb, Instruments and sanitizers on the exact binary that ships,
which matters because SIP stops lldb attaching to coreaudiod and its helpers
(BackgroundMusic `DEVELOPING.md` L116–118). What it cannot reproduce: the helper's sandbox, and
the "adaptive unboosted daemon" treatment.

**Soak in the real host.** Installed plug-in, default output = virtual, target = the Bluetooth
speaker, a looping signal (music plus a periodic click train), 8 h minimum and one overnight run.
A script polls `eqHl` every 10 s into CSV: ring fill, slips, drift ppm, helper CPU and footprint
(`ps`, `footprint`), target cycle count advancing. `log stream --predicate 'process BEGINSWITH "Core Audio Driver (eq"'`
captures `HALC_*` errors. Scripted perturbations during the run: default-device changes, BT off/on,
headphones in/out, rate change in Audio MIDI Setup, lid-close sleep and wake, a FaceTime call.

**Fault injection** (development Mac only): `sudo kill -STOP <helper pid>` simulates a wedged
plug-in; check whether coreaudiod, other devices, and `eq mode tap` still work, and then `-CONT`.
`sudo kill -9 <helper pid>` checks whether coreaudiod respawns the helper and whether the device
comes back as default.

**Recovering a hung audio system during development.** On macOS ≥ 14.4,
`sudo killall coreaudiod` (launchd restarts it; `launchctl kickstart` no longer works there, per
Proxy's README). If the plug-in hangs or crashes at load, a restart just repeats it; the way out is
removing the bundle: `sudo rm -rf /Library/Audio/Plug-Ins/HAL/eq.driver && sudo killall coreaudiod`.
Two cheaper switches, both readable by a sandboxed plug-in (it may read its own bundle):

- **Kill file**: at `Initialize`, if `eq.driver/Contents/Resources/disabled` exists, publish no
  device. `sudo touch …/disabled && sudo killall coreaudiod`.
- **Crash-loop guard**: at `Initialize` append a boot timestamp to storage; after 60 s of healthy IO
  clear the list. Three boots in five minutes without a healthy mark → come up hidden, not
  default-capable, `safeMode` in `eqHl`.

**The user's escape hatch: `eq mode tap` must always restore sound.** Order matters, and each step
must not depend on the plug-in answering:

1. Set the default output and system output back to the remembered real device. This is a
   property of the system object, served by coreaudiod, not by the plug-in; it should work even
   with the helper stopped (the `kill -STOP` test proves or disproves it).
2. Ask the plug-in to deactivate (`eqMd {active:false}`) on a background thread with a 2 s
   timeout; give up silently on timeout.
3. Start the tap engine on the real device.
4. If step 1 failed or the default did not change within 2 s, print the exact recovery line:
   `sudo killall coreaudiod`, and if that does not help, the kill-file command above.

BackgroundMusic backs its own cleanup with a separate privileged XPC helper that restores the
default device when the app dies (`BGMXPCHelperService.mm` L130–160). eq doesn't need one:
driver mode is fail-open (the plug-in keeps playing without the daemon), and the default-device
restore in step 1 needs no privileges.

## 6. Distribution

**A separate cask**, `eq-driver`, in the same tap, depending on the `eq` cask. Model it on
`proxy-audio-device`, the only cask in the set that installs a bare `.driver` without a pkg:

```ruby
artifact "eq.driver", target: "/Library/Audio/Plug-Ins/HAL/eq.driver"
postflight_steps do
  set_ownership "/Library/Audio/Plug-Ins/HAL/eq.driver", user: "root", group: "wheel"
  terminate_process "coreaudiod", sudo: true, must_succeed: true
end
uninstall_postflight_steps do
  terminate_process "coreaudiod", sudo: true, must_succeed: true
end
```

BlackHole and BackgroundMusic ship pkgs instead (their postinstall does the same
`chown root:wheel`, `chmod 755/644`: `BlackHole/Installer/Scripts/postinstall`); a pkg only buys a
GUI installer, which eq doesn't need. Keeping the driver out of the main cask keeps `brew install eq`
admin-free and the tap mode default.

**Signing and notarization.** Sign the bundle with Developer ID Application, hardened runtime,
secure timestamp (BlackHole: `codesign --force --deep --options runtime --sign`), zip it, submit
with `notarytool --wait`, staple the `.driver`. The helper's `disable-library-validation`
entitlement means a mismatched team ID will not stop loading; whether a *quarantined* bundle
installed by a cask loads without notarization is unverified (the roadmap's Round E already asks
the same question for the app). Notarize regardless; it is cheap once the pipeline exists.

**Updates.** Never overwrite the loaded binary in place: the helper has it mapped, and in-place
overwrites of signed code are a known cause of code-signing kills after launch (Apple:
"Updating Mac Software", linked from the forum FAQ at developer.apple.com/forums/thread/706442).
Stage the new bundle beside the old one, `mv` it over (a rename on the same volume), then restart
coreaudiod. Brew's artifact move does a replace, not an in-place write. Every upgrade restarts
coreaudiod, which drops all apps' audio for about a second; the cask caveat should say so. The
daemon reads `eqVr` at start: an older protocol means "upgrade eq-driver", and until then it stays
in tap mode.

**Uninstall.** `eq mode tap` first (a `preflight` in the uninstall), then delete the bundle and
restart coreaudiod. Leftover: the plug-in's storage lives in coreaudiod's settings under
`/Library/Preferences/Audio/`; harmless, and there is no supported API to delete it from outside.

## Recommended architecture

```
 apps ──► [eq virtual device]  (Core Audio Driver helper process)
             WriteMix (HAL IO thread)
               └─► EQCore chain (C) ─► SPSC ring ─► target IOProc (HAL client, same process)
                                                        └─► real device (BT/USB/built-in)
             zero timestamps ◄── slaved to target IOProc stamps (seqlock)
             custom props: eqPm eqSo eqTg eqMd eqMt eqHl eqVr   storage: last curves, mode, target
 eq daemon (EQ.app agent) ──► sets props, owns default-device interception, wake resync
 eq watch / eq status ──► read eqMt / eqHl directly
 tap mode (today's engine) stays the default and the fallback; EQCore is shared by both
```

Build: libASPL (vendored) + ~1.5 kLOC C++ + `EQCore` (C17, SwiftPM C target for the daemon).
Output: `eq.driver` via a CMake or plain `clang++` script, not Xcode.

## Milestones

**M0 — EQCore (no driver, useful regardless).** Port the chain to C behind the daemon; golden IR
tests pass against the C path; delete the Swift DSP. Ships in tap mode with no user-visible change.
Also makes a future loopback design (B) cheaper.

**M1 — prove the risky part: a pass-through plug-in, no EQ.** Output-only libASPL device that
plays its mix to one configured Bluetooth output from inside the helper, via its own IOProc on the
target. In scope: slaved zero timestamps, the ring with health counters, reported latency,
retargeting on target loss, kill file, `eqHl`. Out of scope: EQ, volume forwarding, custom-property
control beyond target and health, daemon integration, cask. Test with the user-space host, then
installed with ad-hoc signing on this Mac.

**Go/no-go after M1** (all must hold; any one failing is no-go for design A, and the next
candidate is the rule-compliant loopback design):

1. **8 h continuous playback to the Bluetooth speaker** with zero ring slips after priming and no
   audible dropout; drift reported ≤ 1 ppm residual (slaved clock working); helper CPU ≤ 1 %,
   footprint flat.
2. **No hangs**: coreaudiod and all other devices stay responsive throughout; no
   `HALC_ProxyIOContext … adaptive unboosted daemon` / `AudioDeviceStart` failures; or, if they
   appear, the plug-in recovers by itself within 5 s every time.
3. **Perturbations survive**: 20 sleep/wake cycles, 20 BT disconnect/reconnects, 20 default-device
   flips, 5 rate changes, with sound back within 3 s each time and without restarting coreaudiod.
4. **Escape hatch works under fault**: with the helper `kill -STOP`ped, setting the default back to
   the real device restores sound; with the helper `kill -9`ed, audio recovers (respawn) or the
   system stays usable on the real device.
5. **Latency**: measured added latency ≤ 10 ms at 128-frame target buffers, and reported latency
   within ±3 ms of measured on the built-in speakers (the BT device's own share is Apple's number).

If 1–4 hold but 5 does not, driver mode is still viable; drop the lip-sync claim.

**M2 — EQ inside.** `EQCore` in the IO path, `eqPm`/`eqSo`/`eqMt`, storage of last curves, safe
mode, `eq watch` reading meters from the plug-in. Bit-identical check: the same click train through
tap mode and driver mode, compared sample by sample after alignment.

**M3 — integration.** Daemon: `eq mode driver|tap`, default-device interception, wake resync,
`eq status`/`eq doctor` showing plug-in health; volume/mute forwarding; hidden when off.

**M4 — distribution.** `eq-driver` cask, Developer ID signing, notarization, upgrade/uninstall flow,
README section with the recovery commands.

## Open questions this report could not settle

- Whether coreaudiod respawns a crashed driver helper, and how fast (M1 fault test).
- Whether the driver helper's sandbox allows `SecCode` checks on a caller PID (only matters if
  authorisation is ever wanted).
- Whether a quarantined, un-notarized `.driver` loads (M4, or earlier as a five-minute test).
- Whether slaved zero stamps behave on every target type (USB clocks, HDMI) or only on BT and
  built-in (M1 on BT; widen in M3).
- Whether Apple tightens the "no client HAL API" rule in a future release. Nothing in 26.6 enforces
  it; the header has said it since the plug-in API existed. This is the permanent risk of design A.
