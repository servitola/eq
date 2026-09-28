# EQDriver

An output-only virtual audio device, **"<target> · EQ"**, that plays whatever apps send it on a
real output device (the *target*) from inside a Core Audio plug-in. Nothing reads audio, so macOS
shows no Privacy indicator. This is milestone 1 of driver mode
(`docs/superpowers/specs/2026-09-28-eq-driver-mode.md`): a pass-through, no EQ yet.

It breaks one of Apple's rules: `AudioServerPlugIn.h` forbids a plug-in to call the HAL client
API, and playing on another device is exactly that. The research is in `docs/research/06a–06c`.

Derived from [Proxy Audio Device](https://github.com/briankendall/proxy-audio-device) v1.1.0b1
(Unlicense), with the lock-free ring of the marrusl fork.

## Build

```sh
Driver/build.sh             # build/EQDriver.driver and build/probe, Developer ID + hardened runtime
Driver/build.sh --adhoc     # ad-hoc signed
Driver/test.sh              # ring, clock servo, timeline checks, latency, target state machine
Driver/test.sh --host-idle  # also loads the built plug-in into a fake host that never starts IO:
                            # configuration changes performed inside Request, on another thread
                            # while Request waits, and after it returns; the kill file
Driver/test.sh --host       # the same, then plays silence on the built-in output for about 25 s
```

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

If it misbehaves: `sudo touch /Library/Audio/Plug-Ins/HAL/EQDriver.driver/Contents/Resources/disabled && sudo killall coreaudiod`
leaves it hidden and idle; `sudo Driver/dev-uninstall.sh` removes it.

## Custom properties

On the device, `kAudioObjectPropertyScopeGlobal`, element main:

| Selector | Type | |
| --- | --- | --- |
| `eqTg` | CFString, settable | target device UID; `""` picks the default again |
| `eqHd` | CFBoolean, settable | hide the device |
| `eqHl` | CFDictionary | health |
