# eq

Headless system-wide 10-band equalizer for macOS 14.4+. No icon, no window: `eq daemon`
runs under a LaunchAgent and follows the default output device, applying that device's
curve from `~/.config/eq/eq.json`; the `eq` CLI edits the file.

    eq                      current device's curve
    eq set 64hz +4 1khz -3  edit it
    eq set --device JBL …   edit another device's curve
    eq devices              who has a curve, who is connected
    eq on | off             bypass
    eq status               is the daemon alive, on which device

Build: `scripts/build-app.sh` → `build/EQ.app`. Smoke: `scripts/smoke.sh` (play music first;
the tap only delivers frames while something plays). Install: `brew install servitola/tap/eq`.

The audio engine (process tap + aggregate device + IOProc) is vendored from
[zollans/OnlyEQ](https://github.com/zollans/OnlyEQ) (Unlicense), commit 6569655.
