# eq driver mode — a second audio path with no Privacy indicator

Date: 2026-09-28. Status: approved in chat ("давай идем дальше"). Research is in
`docs/research/06a/06b/06c`. It goes against `AudioServerPlugIn.h`'s ban on HAL client calls
from a plug-in, and the user has accepted that risk. Tap mode stays the default. Driver mode is
opt-in, shipped as a separate cask, and can be thrown away.

## The user's decisions
1. The virtual device gets a clear name: "<target> · EQ" (for example "BE-RCA · EQ"), or "EQ"
   when there is no target.
2. The user keeps picking real devices in the Sound menu. eq retargets to the device picked and
   makes the virtual device the default output again.
3. The virtual device is hidden when the mode is `tap` and when its target is unavailable.
4. Experiment: keep the virtual device hidden *while* it is the default output. Adopt it only if
   macOS allows it.

## Live evidence so far (Proxy Audio Device v1.1.0b1, BE-RCA)
- The plug-in runs in `Core Audio Driver (ProxyAudioDevice.driver)`. It opened IO on the
  Bluetooth speaker, and no Privacy indicator appeared.
- Bug seen live: the plug-in loaded before the speaker appeared, logged "could not find output
  device", and never retried. The result was silence until the target was re-selected.
- The device reports 0 latency, so video players cannot compensate.

## Milestones
- **M0 — EQCore.** EQProcessor's DSP (biquads, preamp, limiter, compressor and colour, band
  meter, solo) is ported to a C target shared by the daemon and the plug-in, so both modes are
  bit-identical. The daemon switches to it; the golden tests pass unchanged.
- **M1 — pass-through plug-in.**
  - A fork of Proxy Audio Device v1.1.0b1 (Unlicense) under `Driver/`, renamed with its own
    bundle ID.
  - Output-only.
  - Retargets whenever the device list changes, and when a device appears or disappears.
  - The clock is locked to the target, following the rules in `06b`.
  - Reports its latency: the target's latency and safety offset plus its own buffering.
  - Volume and mute are forwarded to the target's hardware volume.
  - Health counters are exposed as custom properties.
  - A kill file makes the device hidden and inert.
  - Built and signed by a script. Installed on this Mac through a narrowly scoped dev install
    script.
- **M2 — EQ inside.** EQCore runs in the plug-in. Settings arrive over a custom property that
  the daemon writes and that is checked against eq's bundle ID/team. The plug-in keeps the last
  curve per target. Meter frames are read back so `eq watch` works.
- **M3 — `eq mode driver|tap`.**
  - The daemon makes the virtual device the default output and follows the user's device
    choice (decision 2).
  - Hiding follows decisions 3 and 4.
  - The escape hatch: `eq mode tap` always restores sound, and if it cannot, eq tells the user
    to run `sudo killall coreaudiod`.
  - `eq doctor` gets driver rows.
- **M4 — distribution.** An `eq-driver` cask (admin install, coreaudiod restart), notarization,
  and a README section.

## Go/no-go after M1 on this Mac
All must hold:
- 8 hours of Bluetooth playback with no slips;
- sleep/wake, Bluetooth reconnect and default switch 20× each, with sound back within 3 s;
- a reboot with the speaker connected, with sound and no manual step;
- the escape hatch works;
- the latency the device reports is within ±3 ms of what is measured.
