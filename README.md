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
wanted a different curve for each output, which eqMac promised and, on macOS 26, did not
deliver. Every open-source equalizer I found is a menu-bar app. This is the opposite: a
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

Bands are `32hz 64hz 125hz 250hz 500hz 1khz 2khz 4khz 8khz 16khz`, gains `-12` to `+12` dB.
A device without its own curve gets `default`; the first `eq set` on it makes a copy.
Everything lives in `~/.config/eq/eq.json`, which you can also edit by hand — the daemon
picks it up within a tenth of a second.

## How it works

The daemon opens a Core Audio process tap on the system mix (macOS 14.4+), which mutes the
original output and hands the audio to the daemon. Ten peaking biquads, a preamp and a
limiter at −1 dBFS later, the daemon plays it back on the same device. About 10 ms of
latency; volume keys keep working. No driver, no `sudo`, nothing in `/Library`.

It listens for the default output changing and rebuilds on the new device with that device's
curve. Bluetooth devices arrive in two steps, so it waits for audio to actually flow before
it calls the switch done.

The engine — tap, aggregate device, IO callback, Bluetooth and sample-rate handling — is taken
from [OnlyEQ](https://github.com/zollans/OnlyEQ) (Unlicense, commit 6569655) and trimmed to
what a headless daemon needs. That code is the part that took someone months of bug reports
to get right; the rest of this project is small.

## Limits

- macOS 14.4 or newer, Apple Silicon. Tested on macOS 26.6.
- Fixed bands, fixed Q. If you want a parametric EQ, this is not it.
- One curve per device, applied to everything on that device. No per-app EQ.
- A DAW that needs zero latency: `eq off` while you work.
- The tap only delivers audio while something plays, so `eq status` reports `running` with
  zero frames on a silent Mac. That is normal.

## Development

```sh
swift test               # 49 unit tests
scripts/build-app.sh     # build/EQ.app, ad-hoc signed
scripts/smoke.sh         # starts the daemon against a scratch config; play something first
```

Releases are cut from this Mac with the Homebrew tap's `bin/release-eq.sh <version>`: tag,
Developer ID signature, smoke, GitHub release, cask bump.

## Licence

[MIT](LICENSE) © [servitola](https://github.com/servitola). The vendored engine keeps its
Unlicense.
