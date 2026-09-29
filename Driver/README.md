# EQDriver

An output-only virtual audio device, **"<target> · EQ"**, that plays whatever apps send it on a
real output device (the *target*) from inside a Core Audio plug-in. Nothing reads audio, so macOS
shows no Privacy indicator. This is milestone 2 of driver mode
(`docs/superpowers/specs/2026-09-28-eq-driver-mode.md`): EQCore, the daemon's own DSP, runs in the
target's IOProc on the curve eq last sent for that target. Nothing switches modes yet.

It breaks one of Apple's rules: `AudioServerPlugIn.h` forbids a plug-in to call the HAL client
API, and playing on another device is exactly that. The research is in `docs/research/06a–06c`.

Derived from [Proxy Audio Device](https://github.com/briankendall/proxy-audio-device) v1.1.0b1
(Unlicense), with the lock-free ring of the marrusl fork.

## Build

```sh
Driver/build.sh             # build/EQDriver.driver and build/probe, Developer ID + hardened runtime
Driver/build.sh --adhoc     # ad-hoc signed
Driver/test.sh              # ring, clock servo, timeline checks, latency, target state machine, the
                            # settings record, per-target settings, EQ processing, writer checks
Driver/test.sh --host-idle  # also loads the built plug-in into a fake host that never starts IO:
                            # configuration changes performed inside Request, on another thread
                            # while Request waits, and after it returns; the kill file; settings
                            # writes and the meter
Driver/test.sh --host       # the same, then plays silence on the built-in output for about 25 s
```

## In EQ.app

`scripts/build-app.sh` runs `build.sh` with the app's identity and puts the bundle in
`EQ.app/Contents/PlugIns`. `eq mode driver` installs it from there, and `eq driver uninstall`
removes it, each through one privileged `/bin/sh` script that lives in the eq binary
(`DriverInstall.script`): it copies to a staging folder beside `HAL/`, makes it root-owned, checks
the copy against eq's own team (`codesign --test-requirement`), renames it into place and restarts
coreaudiod. Two keys in `Info.plist` say which driver it is:

| Key | |
| --- | --- |
| `EQDriverProtocol` | `EQC_BLOB_VERSION`, the settings record it reads; eq falls back to the tap below its own |
| `EQDriverRevision` | commits that touched `Driver/Source`, `Info.plist`, `build.sh` or `Sources/EQCore`; eq offers an update when its own is higher, so a release that leaves the driver alone asks for no password |

A driver installed before these keys reads as revision 0.

## Development install

```sh
sudo Driver/dev-install.sh     # copies to /Library/Audio/Plug-Ins/HAL, restarts coreaudiod
Driver/build/probe             # health: target, IO, underruns, clock correction, latency, errors
Driver/build/probe target <UID>
Driver/build/probe hidden 1
sudo Driver/dev-uninstall.sh
```

At first load the target is the default output if it is a real device, else the first external
output, else the built-in one. The device hides while its target has been gone for 3 s.

Send it a curve with the eq in a signed EQ.app (see *Who may write settings*):

```sh
eq driver status   # the health below, as eq reads it
eq driver push     # the driver's target's own profile (or the default one), as the daemon would play it
```

A target eq never sent a curve for plays untouched.

## Recovery

If sound stops or apps hang on audio after the install, in order, stopping at the first step that
brings sound back:

1. Restart the audio server: `sudo killall coreaudiod`. launchd starts it again within a second.
2. If it is still hung (the command returns but nothing plays, or `coreaudiod` does not come back),
   force it and the plug-in's helper process, which coreaudiod runs out of process:

   ```sh
   sudo killall -9 coreaudiod
   sudo pkill -9 -f 'Core Audio Driver \(EQDriver'
   ```
3. Keep the plug-in from doing anything on the next load: the kill file leaves the device hidden,
   unable to be the default, and without IO.

   ```sh
   sudo touch /Library/Audio/Plug-Ins/HAL/EQDriver.driver/Contents/Resources/disabled
   sudo killall coreaudiod
   ```
4. Remove it: `sudo Driver/dev-uninstall.sh` (deletes the bundle and restarts coreaudiod). Without
   the repository at hand: `sudo rm -rf /Library/Audio/Plug-Ins/HAL/EQDriver.driver && sudo killall coreaudiod`.

`log stream --predicate 'subsystem == "com.servitola.eq.driver"'` shows what the plug-in logged.

## Custom properties

On the device, `kAudioObjectPropertyScopeGlobal`, element main:

| Selector | Type | |
| --- | --- | --- |
| `eqTg` | CFString, settable | target device UID; `""` picks the default again |
| `eqHd` | CFBoolean, settable | hide the device |
| `eqHl` | CFDictionary | health; `eqActive`, `settingsSerial` and `settingsError` for the curve |
| `eqSt` | CFData, settable | the settings record (`Sources/EQCore/include/EQDriverProtocol.h`) for one target; reads back what plays |
| `eqMt` | CFData | the meter frame; reading it keeps the meter running for 1 s |

The record carries `eqc_settings` and the target UID it belongs to. The plug-in checks every field
(size, magic, version, UID, finite values, ranges) before use, stores it in host storage under
that UID, and plays it when that UID is the target, across coreaudiod restarts and without the
daemon. Solo is never stored.

### Who may write settings

The host gives `SetPropertyData` only the caller's pid. The driver helper, `Core Audio Driver
(EQDriver.driver)`, runs outside coreaudiod's sandbox (`sandbox_check` on its pid says so on macOS
26.6), so the plug-in asks the Security framework whether that pid's code meets:

- Developer ID build: `identifier "com.servitola.eq" and anchor apple generic and certificate
  leaf[subject.OU] = "<the plug-in's team>"`;
- ad-hoc build: `identifier "com.servitola.eq"`, which anything signed ad hoc with that identifier
  meets.

Anything else gets `kAudioDevicePermissionsError`, and so does pid 0, which the host uses for its
own requests. `eqTg` and `eqHd` stay open to any process, as in milestone 1.
