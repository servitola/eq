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

## Install

```sh
brew install --cask servitola/tap/eq
```

The first `eq` registers the daemon as a login item named **EQ**. Its first start asks once
for **System Audio Recording**: grant it to *EQ*, and `eq status` says `running`. No config
file is needed; the first change writes `~/.config/eq/eq.json`.
Login items, a hand-made LaunchAgent, uninstalling: [docs/install.md](docs/install.md).

## Use

| Command | |
| --- | --- |
| `eq` | the curve in effect on the current output |
| `eq set 64hz +4 1khz -3` | change bands; `--device JBL` for another output |
| `eq import "WH-1000XM4"` | apply an AutoEq or OPRA correction by headphone name, file or URL |
| `eq preset save\|use <name>` | keep a curve, put it on any device |
| `eq tui` | the live meter and every setting, from the keyboard; `?` lists the keys |

`eq off` and `eq on` bypass it, `eq undo` steps back, `eq doctor` checks the setup.
Every command takes `--json`; every change takes `--dry-run`.
All of them: [docs/commands.md](docs/commands.md).

## Driver mode

`eq mode driver` plays through a virtual output device, **"BE-RCA · EQ"**, named after the
real one, instead of tapping system audio: no permission, no Privacy indicator, and the
device reports its whole latency, so video keeps lip sync. Installing the driver asks once for
an administrator password and restarts coreaudiod. Experimental; `eq mode tap` goes back.
[docs/driver-mode.md](docs/driver-mode.md).

## Documentation

- [Commands](docs/commands.md): every command, presets, undo, terminal colours
- [Shaping the curve](docs/curve.md): app rules, parametric filters, bass, treble, tilt,
  compression and colour
- [The terminal UI](docs/tui.md): looks, views, keys, instruments
- [Import and export](docs/import-export.md): AutoEq, OPRA, Equalizer APO, REW, eqMac,
  Poweramp, EasyEffects, Peace, CamillaDSP
- [Events, hooks and the meter socket](docs/events.md)
- [Driver mode](docs/driver-mode.md), and recovery
- [How it works](docs/how-it-works.md): the signal path, latency, footprint
- [Development](docs/development.md)
- [Changelog](CHANGELOG.md)

## Limits

- macOS 14.4 or newer, Apple Silicon. Tested on macOS 26.6.
- Ten graphic bands plus up to 32 parametric filters, imported or added by hand.
- One curve per device, applied to everything on that device. An app rule swaps the whole
  system's curve while that app plays; it does not give two apps two curves at once.
- A DAW that needs zero latency: `eq off` while you work.

## Licence

[MIT](LICENSE) © [servitola](https://github.com/servitola). The vendored engine and the
driver's base keep their Unlicense. OPRA data, fetched at run time and in the test fixture, is
CC BY-SA 4.0: see [OPRA](docs/import-export.md#opra).
