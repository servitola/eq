# eq

[![test](https://github.com/servitola/eq/actions/workflows/test.yml/badge.svg)](https://github.com/servitola/eq/actions/workflows/test.yml) [![release](https://img.shields.io/github/v/release/servitola/eq?color=black)](https://github.com/servitola/eq/releases) [![brew test-bot](https://github.com/servitola/homebrew-tap/actions/workflows/tests.yml/badge.svg)](https://github.com/servitola/homebrew-tap/actions/workflows/tests.yml) [![tested on macOS 26](https://img.shields.io/badge/tested%20on-macOS%2026-black)](#limits) [![licence](https://img.shields.io/github/license/servitola/eq?color=black)](LICENSE)

A system-wide equalizer for macOS with no icon, no window and no menu.

Ten bands, 32 Hz to 16 kHz. A curve per output device: the laptop speakers keep theirs,
the Bluetooth speakers theirs, the headphones theirs, and the right one is in effect the
moment macOS switches. A daemon does the work; a command edits the numbers.

```
$ eq
MacBook Pro Speakers (own profile)   preamp: +0.0 dB
  32Hz  64Hz 125Hz 250Hz 500Hz  1kHz  2kHz  4kHz  8kHz 16kHz
  +4.8  +4.0  +4.2  +2.3  +0.0  -3.1  +0.0  +0.0  +3.1  +2.4
```

## Why

I had one curve in eqMac and wanted nothing else from it — no menu-bar icon, no update
prompts, no UI loaded from a server, no kernel-adjacent driver asking for a password. And I
wanted a different curve for each output. Every open-source equalizer I found is a menu-bar app. This is the opposite: a
process that follows the output device and a file with ten numbers per device.

## Install

```sh
brew install servitola/tap/eq
```

Homebrew wants third-party taps named in full; the line above trusts this one cask, no more.
Then:

```sh
eq init                                   # writes ~/.config/eq/eq.json with a starting curve
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.servitola.eq.plist
```

The first start asks for **System Audio Recording** once (System Settings → Privacy &
Security). Grant it to *EQ*, then `eq status` says `running`.

The LaunchAgent plist is in my [dotfiles](https://github.com/servitola/dotfiles/tree/main/launchagents);
it runs `/Applications/EQ.app/Contents/MacOS/eq daemon` at login and restarts it if it dies.

## Commands

| Command | |
| --- | --- |
| `eq` | the curve in effect on the current output |
| `eq set 64hz +4 1khz -3` | change bands on the current output's curve |
| `eq set --device JBL 16khz +1` | on another device, by a piece of its name |
| `eq preamp -1.5` | preamp for the current curve |
| `eq flat` | everything to 0 |
| `eq copy --to AirPods` | give another device this curve |
| `eq devices` | who has a curve, who is connected, which is active |
| `eq off`, `eq on` | bypass, and back |
| `eq status [--json]` | is the daemon alive, on which device, at what rate |
| `eq init` | write the default config if there is none |
| `eq import "WH-1000XM4"` | fetch and apply an AutoEq correction by headphone name |
| `eq import file.txt` | apply an AutoEq correction from a local file or URL |
| `eq import --clear` | drop the imported correction, keep hand-tuned bands |
| `eq doctor` | one-shot health check: config, daemon, permission, audio |
| `eq watch [--zones]` | the live equalizer in the terminal; tune from the keyboard, `q` to quit |
| `eq zones` | which bands carry which instruments, under the current curve |
| `eq stream` | meter frames as JSON lines, 30 a second, until Ctrl-C |

`--json` works on any command; the answer becomes one JSON document on stdout, exit codes
unchanged.

Bands are `32hz 64hz 125hz 250hz 500hz 1khz 2khz 4khz 8khz 16khz`, gains `-12` to `+12` dB.
A device without its own curve gets `default`; the first `eq set` on it makes a copy.
Everything lives in `~/.config/eq/eq.json`, which you can also edit by hand — the daemon
picks it up within a tenth of a second.

## Watch

```
     BE-RCA · 44.1 kHz · preamp -4.8 dB · peak -3.2 dB

         ▆▆▆    ▆▆▆
         ███    ███    ▇▇▇
         ███    ███    ███
         ███    ███    ███    ███
         ▬▬▬    ███    ███    ███           ░░░
         ███    ▬▬▬    ▬▬▬    ███    ███    ▆▆▆    ▁▁▁
         ███    ███    ███    ▬▬▬    ███    ███    ███           ▬▬▬    ▬▬▬
         ███    ███    ███    ███    ███    ███    ███    ▄▄▄    ▂▂▂
         ███    ███    ███    ███    ▬▬▬    ███    ▬▬▬    ▬▬▬    ███
         ███    ███    ███    ███    ███    ███    ███    ███    ███
         ███    ███    ███    ███    ███    ▬▬▬    ███    ███    ███    ▄▄▄
         ███    ███    ███    ███    ███    ███    ███    ███    ███    ███
         ███    ███    ███    ███    ███    ███    ███    ███    ███    ███
         ███    ███    ███    ███    ███    ███    ███    ███    ███    ███
         ███    ███    ███    ███    ███    ███    ███    ███    ███    ███
         ███    ███    ███    ███    ███    ███    ███    ███    ███    ███
         ███    ███    ███    ███    ███    ███    ███    ███    ███    ███
         ███    ███    ███    ███    ███    ███    ███    ███    ███    ███
          -4     -4     -7    -13    -19    -20    -22    -27    -28    -37
        32Hz   64Hz  125Hz  250Hz  500Hz   1kHz   2kHz   4kHz   8kHz  16kHz
        +4.8   +4.0   +4.2   +2.3   +0.0   -3.1   +0.0   +0.0   +3.1   +2.4
```

`eq watch` draws all ten bands live at ~30 fps: `█`, in the gain's own colour, is the level
after the EQ; `░` shows where the input reaches above it (a cut); `▬` marks the slider
position from the curve. The row of numbers under the bars is each band's level in dBFS
after the EQ, `·` when it is silent. A band louder than −6 dBFS turns to the bright shade of
its colour, so the bands close to clipping stand out. It fits any terminal size: narrower
bars and short labels first, then the highest bands drop off with a note to widen the
window. Resizing the terminal redraws the whole frame for the new size. `eq stream` is the
same numbers as JSON lines instead, for anyone who wants to draw their own. Both need a
running daemon; `watch` needs a TTY and exits on `q` or Ctrl-C.

### Keys

| Key | Action |
| --- | --- |
| `1` … `9`, `0` | raise band 32 Hz … 16 kHz by 0.5 dB (`0` is the tenth band, 16 kHz) |
| Shift + the same key | lower it by 0.5 dB — `! @ # $ % ^ & * ( )` on a US layout, `! " № ; % : * ( )` on a Russian one |
| `+` / `-` | preamp ±0.5 dB (`=` and `_` work too, no Shift needed) |
| `z` | zones: off → compact → all → off |
| `h`, `?` | show the hint again |
| `x` | hide the hint for good |
| `q`, Ctrl‑C | exit |

A step edits the current device's profile — the same one `eq set` would: the daemon's device,
else the default output — clamps to ±12 dB (preamp −30…+12), and saves at once; the daemon
picks it up and the slider marker moves on the next frame, while the band's label flashes
bold. When the edit cannot be saved (no config yet, say), the reason shows in a dim line at
the bottom for two seconds. On a Russian layout Shift+7 types `?`, which is the help key, so
band 7 (2 kHz) can only be lowered from a US layout; `h`, `z`, `x` and `q` work from the
same physical keys on either layout.

On start a small box in the top-right corner lists the keys. It hides after 8 seconds or on
any key; `h` brings it back. `x` hides it and writes the empty marker
`~/.config/eq/watch-hint-off`, after which it no longer appears on start (delete the file to
get it back). A terminal narrower than twice the box shows one dim line at the bottom instead.

### Zones

`z` (or `eq watch --zones`) adds rows under the gains that show which bands carry which
instruments — sub, kick, bass, guitar, voice, cymbals, air in the compact set; `z` again adds
mud, snare and sibilance. Each zone is a `━` span under its bands, dim except under its
loudest band, which lends the span its bar's colour. `eq zones` prints the full set once,
under the current curve, with a line on why each span matters.

## Colour

On a terminal the output uses the sixteen standard terminal colours, each with one meaning
everywhere: green for a boost, a healthy check or a running engine, magenta for a cut,
yellow for a warning or a device on the default profile, red for a failure. `eq` and the
other curve-printing commands add a spark row of block glyphs above the band labels, so the
curve's shape reads at a glance. Piped or redirected output has no colour and no spark row,
so it keeps the three-line shape above; `NO_COLOR` or `TERM=dumb` turn colour off on a
terminal too.

## AutoEq

`eq import <file|url|"headphone name">` applies a published correction for a specific
headphone from [AutoEq](https://github.com/jaakkopasanen/AutoEq). A name is looked up in
AutoEq's index and the matching `ParametricEQ.txt` is fetched; a file or URL is read
directly. The index is cached at `~/.cache/eq/autoeq` for 7 days — `--refresh` forces a
re-fetch.

A `ParametricEQ.txt` becomes parametric filters applied exactly as measured. A
`GraphicEQ.txt` is reduced to the ten fixed bands by sampling its curve, which is close but
not exact — the `ParametricEQ.txt` of the same model is preferred when both exist. Use
`--source NAME` to pick a reviewer (oratory1990, crinacle, Rtings, …) when a name matches
several, and `--keep-bands` to layer the correction on top of your hand-tuned bands instead
of resetting them to flat.

## How it works

The daemon opens a Core Audio process tap on the system mix (macOS 14.4+), which mutes the
original output and hands the audio to the daemon. Ten peaking biquads plus the imported
filters, a preamp and a limiter at −1 dBFS later, the daemon plays it back on the same device. About 10 ms of
latency; volume keys keep working. No driver, no `sudo`, nothing in `/Library`.

It listens for the default output changing and rebuilds on the new device with that device's
curve. Bluetooth devices arrive in two steps, so it waits for the IO callback to fire before
it calls the switch done.

The engine — tap, aggregate device, IO callback, Bluetooth and sample-rate handling — is taken
from [OnlyEQ](https://github.com/zollans/OnlyEQ) (Unlicense, commit 6569655) and trimmed to
what a headless daemon needs. That code is the part that took someone months of bug reports
to get right; the rest of this project is small.

The IO buffer stays at 256 frames (≈10–12 ms end-to-end latency at 44.1/48 kHz). Measured on
this Mac with the same release build, 512 frames (≈21–23 ms) cut context switches from
191/s to 105/s but raised CPU while playing from 0.3% to ~0.7–0.8%, so it doesn't clear the
"halves both" bar for adopting it; `EQ_IO_FRAMES` (daemon only, 64–4096) is still there to
re-measure if the numbers ever look different on other hardware.

## Footprint

Measured with `scripts/footprint.sh` while a tone played over Bluetooth at 44.1 kHz.

| Metric | v2 (installed) | v3 (release @256) |
| --- | --- | --- |
| physical footprint | 6.4 MB | 5.2 MB |
| CPU while playing | 0.30 % | 0.30 % |
| context switches | 189 /s | 191 /s |
| status.json writes | 12 /min | ≤ 2 /min (30 s heartbeat + changes) |
| log | unrotated | capped by the cleanup job |
| `brew uninstall` | agent stays loaded | agent stays loaded, so an upgrade never loses it; `--zap` unloads it and removes the plist link |

512 IO frames halves context switches but more than doubles CPU, so 256 stays the default;
`EQ_IO_FRAMES` is the escape hatch to re-measure on other hardware (see "How it works" above).

Zero cost while nobody watches: the meter and its 30 Hz timer exist only while a client is
connected.

## Limits

- macOS 14.4 or newer, Apple Silicon. Tested on macOS 26.6.
- Ten graphic bands you edit by hand, plus the parametric filters an import brings in (up to
  32). There is no command for hand-editing a filter's type, frequency, gain or Q — if you
  want a parametric EQ you tune yourself, this is not it.
- One curve per device, applied to everything on that device. No per-app EQ.
- A DAW that needs zero latency: `eq off` while you work.

## Development

```sh
swift test               # 144 unit tests
scripts/build-app.sh     # build/EQ.app, ad-hoc signed
scripts/smoke.sh         # starts the daemon against a scratch config; play something first
```

Releases are cut from this Mac with the Homebrew tap's `bin/release-eq.sh <version>`: tag,
Developer ID signature, smoke, GitHub release, cask bump.

## Licence

[MIT](LICENSE) © [servitola](https://github.com/servitola). The vendored engine keeps its
Unlicense.

## Verified

2026-09-27, macOS 26.6.2, M3 Pro: MacBook Pro Speakers ↔ BE-RCA (Bluetooth), per-device curves, live config reload, `eq off`/`on`, launchd restart after SIGTERM. Daemon idle: 19–22 MB RSS, 0.0 % CPU.
