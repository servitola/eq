# How it works

The daemon opens a Core Audio process tap on the output device (macOS 14.4+), which mutes the
original output and hands the audio to the daemon. Ten peaking biquads plus the imported
filters, a preamp, the compressor and colour when on, and a limiter at −1 dBFS later, the daemon
plays it back on the same device. Latency is
shown in `eq status`; Bluetooth adds the headset's own buffering. Volume keys keep working. No driver, no `sudo`, nothing in `/Library`.

The daemon is a LaunchAgent inside the app, `EQ.app/Contents/Library/LaunchAgents/com.servitola.eq.daemon.plist`,
registered through `SMAppService` under the label `com.servitola.eq.daemon`; nothing is copied
into `~/Library/LaunchAgents`. It logs to
`~/Library/Logs/eq.log`. `eq agent status` shows how it is launched. `eq agent uninstall`
removes the login item, stops the daemon and leaves the empty marker `~/.cache/eq/agent-off`,
so no later `eq` command starts it again; `eq agent install` deletes the marker and puts the
login item back. After `brew upgrade` the daemon sees its binary replaced and exits, and
launchd starts the new one. After `brew uninstall` it exits once its binary has been gone for
a minute; run `eq agent uninstall` first to remove the login item as well.

It listens for the default output changing and rebuilds on the new device with that device's
curve. Bluetooth devices arrive in two steps, so it waits for the IO callback to fire before
it calls the switch done.

The engine's device, Bluetooth and sample-rate handling and its EQ chain are taken
from [OnlyEQ](https://github.com/zollans/OnlyEQ) (Unlicense, commit 6569655) and trimmed to
what a headless daemon needs. That code is the part that took someone months of bug reports
to get right; the rest of this project is small.

The signal path is eq's own. The tap sits alone in a private aggregate device, whose IO
callback writes into a lock-free ring; a second IO callback, on the output device itself,
reads the ring, runs the EQ and plays the result. With the device inside the tap's aggregate,
as OnlyEQ builds it, the tap's timestamps trailed the sound by the device's whole latency:
over a Bluetooth speaker eq added 280 ms, and video lost lip sync, because a player
compensates for the device's latency but cannot see eq's. Split, a probe of this layout
measured 12.8 ms at 44.1 kHz with clicks played from another process.

What eq adds is the tap's buffer, a ring cushion (one output buffer, one tap buffer and 64
frames of scheduling slack, 320 frames at the defaults) and the output buffer. `eq status`
shows it as "eq adds", measured from the two callbacks' host timestamps on the same samples,
and lists ring underruns, overruns and dropped buffers if the two sides ever slip; when they
keep slipping for 15 s, the daemon rebuilds the engine. `scripts/measure-latency.sh` times it
end to end.

The IO buffer is 128 frames on both sides; `EQ_IO_FRAMES` (daemon only, 64–4096) overrides
it. Core Audio keeps the buffer size per process, so other apps keep their own buffer size
when eq asks the shared output device for 128 frames. A smaller buffer wakes the daemon more
often: two IO threads, each about 345 times a second at 128 frames and 44.1 kHz.

## Footprint

Measured with `vmmap`, `top` and the status file's modification times while a tone played over
Bluetooth at 44.1 kHz.

| Metric | v2 (installed) | v3 (release @256) |
| --- | --- | --- |
| physical footprint | 6.4 MB | 5.2 MB |
| CPU while playing | 0.30 % | 0.30 % |
| context switches | 189 /s | 191 /s |
| status.json writes | 12 /min | ≤ 2 /min (30 s heartbeat + changes) |
| log | unrotated | capped by the cleanup job |
| `brew uninstall` | agent stays loaded | daemon exits with its binary, the EQ driver is removed; `eq agent uninstall` first removes the login item; `--zap` also unloads both jobs and removes a hand-installed plist |

512 IO frames halves context switches but more than doubles CPU, so 256 stays the default;
`EQ_IO_FRAMES` is the escape hatch to re-measure on other hardware (see above).

The compressor and the colour cost nothing while off. Switched on, measured offline with
`swift test -c release -Xswiftc -enable-testing --filter DynamicsTests/testCost` on an M3 Pro,
per second of stereo audio at 48 kHz: the ten-band curve 0.97 ms, the compressor another
1.3 ms, tape 0.6 ms, compressor and tube together 2.3 ms — about 0.2 % of one core.

Zero cost while nobody watches: the meter and its 30 Hz timer exist only while a meter client
is connected. An `eq events` client does not count.

## Verified

2026-09-27, macOS 26.6.2, M3 Pro: MacBook Pro Speakers ↔ BE-RCA (Bluetooth), per-device curves, live config reload, `eq off`/`on`, launchd restart after SIGTERM. Daemon idle: 19–22 MB RSS, 0.0 % CPU.
