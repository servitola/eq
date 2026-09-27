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
| `eq bass +3`, `eq treble -2` | AutoEq-style bass / treble shelf on top of the curve, `0` removes it |
| `eq tilt -0.5` | tilt the whole curve, in dB per octave |
| `eq flat` | reset: everything to 0, dropping the preset label, filters, bass/treble/tilt and any import |
| `eq copy --to AirPods` | give another device this curve |
| `eq devices` | who has a curve, who is connected, which is active |
| `eq off`, `eq on` | bypass, and back |
| `eq status [--json]` | is the daemon alive, on which device, at what rate |
| `eq init` | write the default config if there is none |
| `eq import "WH-1000XM4"` | fetch and apply an AutoEq correction by headphone name |
| `eq import "airpods pro 2" --variant anc-on` | pick one device state when a model has several |
| `eq import --search wh1000xm4` | list what a name matches in AutoEq and OPRA, with source and variant, without importing |
| `eq import "HD 600" --source opra` | take the correction from OPRA instead of AutoEq |
| `eq import file.txt` | apply an AutoEq correction from a local file or URL |
| `eq import --clear` | drop the imported correction, keep hand-tuned bands and filters |
| `eq filter` | the parametric filters, numbered, with where each came from |
| `eq filter add peak 3k -2 2` | add a filter by hand: type, frequency, gain, optional Q |
| `eq filter set 2 gain=-3 q=4`, `eq filter rm 2\|all` | change or remove filters by number |
| `eq preset` | list presets; the current device's one marked `*` |
| `eq preset save\|use <name>` | save the current curve as a preset / apply one (`--device DEVICE` for another device) |
| `eq preset show\|rm <name>`, `eq preset rename <old> <new>` | look at, delete, rename a preset |
| `eq undo [--list]` | put the config back as it was before the last change / list the ten backups |
| `eq doctor` | one-shot health check: config, daemon, permission, audio |
| `eq watch [--zones]` | the live equalizer in the terminal; tune from the keyboard, `q` to quit |
| `eq zones [--json]` | the instruments' frequency ranges in Hz and the bands each one touches |
| `eq stream` | meter frames as JSON lines, 30 a second, until Ctrl-C; `solo` is the range being listened to, or `null` |

`--json` works on any command; the answer becomes one JSON document on stdout, exit codes
unchanged.

Bands are `32hz 64hz 125hz 250hz 500hz 1khz 2khz 4khz 8khz 16khz`, gains `-12` to `+12` dB.
A device without its own curve gets `default`; the first `eq set` on it makes a copy.
Everything lives in `~/.config/eq/eq.json`, which you can also edit by hand — the daemon
picks it up within a tenth of a second.

## Presets

A preset is a named curve — bands, preamp and filters — that any device can use. `eq preset
save "club mix"` stores the current device's curve under that name and marks the device as
using it; `eq preset use flat` copies a preset onto the device. Names are 1–32 letters,
digits, spaces or `- _ .`, and are matched without regard to case. Two presets come with the
config: `favourite`, the curve eq ships with, and `flat`. A config from before presets gets
them when the daemon starts or on `eq init`, and also on the first `eq preset save|use|rm|rename`
or `eq watch` `p`/`s` — whichever touches presets first; delete them all and they stay deleted.

`eq` and every command that prints a curve show which preset the device uses: `BE-RCA (own
profile · favourite)`. Tune the curve afterwards and the name gets a yellow `*` —
`favourite*` — meaning the device started from that preset and has moved away from it; the
preset itself is unchanged until you save over it. `eq preset rm` and `rename` update the
devices that point at the preset, and leave their curves alone.

## Filters

Besides the ten bands a curve holds up to 32 parametric filters. `eq filter add <type> <freq>
<gain> [q]` adds one at the end: the type is `peak`, `lowshelf`, `highshelf`, `lowpass`,
`highpass`, `notch` or `bandpass`; the frequency is `3k`, `250hz` or `1000`; the gain is in dB
(`-30`…`+30`, ignored by the pass, notch and bandpass types); Q is `0.1`…`30` and defaults to
1.41 for peak, notch and bandpass, 0.707 for shelves and passes. `eq filter set <n>
freq=… gain=… q=… type=…` changes any of them, `eq filter rm <n>` or `rm all` removes. Every
command takes `--device DEVICE`. Numbers are the ones `eq` and `eq filter` show; a filter that
would ring at 48 kHz is refused, like one in a hand-edited config.

`eq` lists a `source` for each filter: `import` for the ones an import brought in, `hand` for
yours. They live in one list and a hand edit of an imported filter keeps it `import`. A new
import replaces only the imported filters and puts yours after them; `eq import --clear` drops
only the imported ones. A config from before this marks its filters `import` when the profile
names an import, else `hand`.

## Bass, treble and tilt

A third layer sits on top of the bands and filters, taken from AutoEq's own preference
settings so the numbers mean the same thing as its `--bass-boost`, `--treble-boost` and
`--tilt`: `eq bass <gain>` is a low shelf at 105 Hz, `eq treble <gain>` a high shelf at
10 kHz, both Q 0.7 and −12…+12 dB; `eq tilt <slope>` slopes the whole curve by that many dB per
octave around 632 Hz (the middle of 20 Hz–20 kHz on a log scale), −1.2…+1.2, positive
brighter. A straight slope is not something a biquad can do, so tilt runs as four shelves that
stay within 0.25 dB per dB/octave of AutoEq's line from 20 Hz to 20 kHz and level off outside
it. All three take `--device DEVICE`; `0` removes that part, and only the parts that are set
cost any processing. `eq` shows a `preference:` line when any is set, the config stores them
as `"preference"` on the profile, presets carry them, and `eq flat` drops them. A boost adds
gain the preamp does not take back; the limiter catches peaks, or lower the preamp yourself.

## Undo

Every save of the config first copies the previous file to `eq.json.1`, shifting the older
ones up to `eq.json.10`; the oldest drops off. A save that changes nothing makes no copy.
`eq undo` restores `eq.json.1` — checked first, so a broken backup is refused — and prints
the current device's curve; the file it replaced becomes the new `eq.json.1`, so a second
`eq undo` is a redo. `eq undo --list` shows the ten backups with their times and the current
device's curve in each. The daemon's routine writes (refreshing device names) make no backup;
the one exception is the first time it seeds presets into a config from before they existed —
that one backs up, so the pre-presets file stays recoverable as `eq.json.1`.

A whole `eq watch` session is one undo step: only its first save makes a backup, so after
quitting, `eq undo` returns to the curve from before the session.

## Watch

```
     BE-RCA · 44.1 kHz · preamp -4.8 dB · favourite* · peak -3.2 dB

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
| `b` / `B` | bass shelf ±0.5 dB |
| `t` / `T` | treble shelf ±0.5 dB |
| `p`, `↓` | next preset, alphabetically, wrapping round |
| `↑` | previous preset, wrapping round |
| `u` | undo the last change made in this session, back to how it started |
| `s` | save the curve as a preset: type a name, Enter saves, Esc cancels |
| `z` | the instrument strip, on and off |
| `]`, `Tab` / `[` | focus the next / previous instrument |
| `Esc` | leave the focus (and stop listening) |
| `l` | listen to the focused instrument alone, and back |
| `h`, `?` | show the hint again |
| `x` | hide the hint for good |
| `q`, Ctrl‑C | exit |

A step edits the current device's profile — the same one `eq set` would: the daemon's device,
else the default output — clamps to ±12 dB (preamp −30…+12), and saves at once; the daemon
picks it up and the slider marker moves on the next frame, while the band's label flashes
bold. When the edit cannot be saved (no config yet, say), the reason shows in a dim line at
the bottom for two seconds. On a Russian layout Shift+7 types `?`, which is the help key, so
band 7 (2 kHz) can only be lowered from a US layout; the letter keys work from the same
physical keys on either layout (`и` for `b`, `е` for `t`, `з` for `p`, `г` for `u`, `ы` for `s`, `х`/`ъ` for `[`/`]`,
`д` for `l`, and so on). `←` and `→` are reserved and do nothing yet.

The header names the device's preset after the preamp, with the yellow `*` once the curve has
moved away from it. Bass, treble and tilt follow it when set: `bass +3 treble -2`. `p` applies the presets in turn, as `eq preset use` would. `u` walks back
through this session's steps, preset changes included, one per press, until the curve is as it
was when the session started; it does not reach past the session — that is `eq undo`. `s`
turns the bottom line into `save as: ▏`; while it is open every key types into it, digits
included, Backspace deletes, and a bad name shows its error in the same line for two seconds.

On start a small box in the top-right corner lists the keys. It hides after 8 seconds or on
any key; `h` brings it back. `x` hides it and writes the empty marker
`~/.config/eq/watch-hint-off`, after which it no longer appears on start (delete the file to
get it back). A terminal narrower than twice the box shows one dim line at the bottom instead,
which leaves out whole keys rather than cut one in half, and always keeps `q quit`.

### Instruments

`z` (or `eq watch --zones`) opens a strip inside the meter, directly above the level row: one
row per instrument — kick, bass, snare, guitar, piano, voice, cymbals, air — with each of its
ranges drawn as a `━` span on the same frequency axis as the bars. A bar stands for the octave
around its band, so a range that starts at 85 Hz begins between the 64 Hz and 125 Hz bars, not
on either. Neighbouring ranges of one instrument are kept apart by a gap, and a range's name
(`F1`, `thump`, `sibilance`) is written into its span when it fits. The spans are dim except
near the instrument's loudest band, which lends them its bar's colour. The strip takes its rows
from the meter, which keeps at least four; on a short terminal the lowest instruments drop.
`eq zones` prints the same table in Hz with the bands each range touches.

```
    BE-RCA · 44.1 kHz · preamp -1.5 dB · favourite* · peak -6.0 dB · focus: voice (85 Hz–9 kHz) SOLO
                           ┌────────────┐ ┌─── F1 ────┐ ┌── F2 ──┐ ┌──────┐ ┌────┐
               ...
  voice                    ━━━━━━━━━━━━━━ ━━━━ F1 ━━━━━ ━━━ F2 ━━━ ━━━━━━━━ ━━━━━━
               -24     -24     -24     -24     -24      -9     -24     -24     -24     -24
              32Hz    64Hz   125Hz   250Hz   500Hz    1kHz    2kHz    4kHz    8kHz   16kHz
```

`]` or `Tab` focuses the next instrument, `[` the previous one, `Esc` lets go. While focused,
the header says `focus: voice (85 Hz–9 kHz)`, a bracket row above the bars marks each of its
ranges, the bars, labels and gains of bands it does not touch turn dim, and its level numbers
turn bright. The strip, when open, shows only that instrument. Digit keys still name all ten
bands, but a band outside the focus is refused with `outside voice — Esc to unfocus` in the
footer, so tuning stays on the instrument. A band belongs to the focus when any of the
instrument's ranges overlaps the octave around the band's centre, which is why voice reaches
down to the 64 Hz band.

`l` listens to the focus alone: the daemon adds a steep high-pass at the instrument's lowest
edge and a low-pass at its highest (a multi-range instrument is heard across its whole outer
span, gaps included), and the header shows a yellow `SOLO` for as long as the daemon reports
it. Switching focus moves the solo to the new instrument. `l` again, `Esc` and `q` switch it
off; so does the watch going away in any other way, since the daemon drops a solo the moment
the client that asked for it disconnects. At a rate too low for the focus (air on a headset
in call mode) the footer says `can't listen to air at this rate` and nothing plays solo until
the focus moves to an instrument the rate can carry. A solo is never saved and never reaches `eq.json`.
It is the curve you hear through, not a second curve: the EQ stays one curve per device.

Any meter client can ask for a solo by writing `{"solo":{"low":L,"high":H}}` to the socket,
one JSON object per line, with `0 ≤ L < H ≤ 100000` Hz; any other line is ignored. The last
accepted range wins and its sender owns it. Only the owner clears it: with `{"solo":null}`,
with a range the daemon refuses at the current sample rate, or by disconnecting. A `null` from
any other client is ignored, so a second `eq watch` cannot switch off the first one's solo.
The socket takes at most eight clients at once and closes any beyond that.

## Colour

On a terminal the output uses the sixteen standard terminal colours, each with one meaning
everywhere: green for a boost, a healthy check or a running engine, magenta for a cut,
yellow for a warning or a device on the default profile, red for a failure. `eq` and the
other curve-printing commands add a spark row of block glyphs above the band labels, so the
curve's shape reads at a glance. Piped or redirected output has no colour and no spark row,
so it keeps the three-line shape above; `NO_COLOR` or `TERM=dumb` turn colour off on a
terminal too.

`eq --help` is grouped into look, tune and setup, with commands bold, flags cyan and
placeholders such as `DEVICE` yellow; descriptions wrap inside their column at the terminal's
width, and below 60 columns each description moves under its command. `eq <command> --help`
shows one command, and a usage error shows only the command it is about. `--json` on a
terminal is coloured like `jq`; piped, it is the same bytes as before, and `eq stream` is never
coloured. `NO_COLOR` turns all of it off.

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

Names are matched loosely: case, spaces and hyphens don't count (`wh1000xm4`, `airpods pro2`),
the brand may be left out, and a few nicknames are known (`xm4`, `app2`). A typo gets a "did
you mean" list instead of a guess, and a name that fits several models lists them.

Many models are measured in several states, written as a tag after the name: `(ANC on)`,
`(ANC off)`, `(transparency mode)`, `(sample 2)`. Without `--variant`, `eq import` takes the
entry with no tag, then the ANC-on one, and otherwise stops and lists the variants.
`--variant` takes the tag in any spelling, or its start (`anc-off`, `transparency`, `51db`).
`eq import --search <name>` shows every match — model, variant, source — and marks with `*`
the one a plain `eq import` would apply; `--json` gives the same list.

### OPRA

[OPRA](https://github.com/opra-project/OPRA) is a second database, run by Roon Labs: hand-made
presets such as oratory1990's own, plus AutoEq runs against several targets. `eq import`
asks it when AutoEq has no match, `--source opra` asks it only, and `--search` lists both,
AutoEq first. Its whole database (about 12 MB) is fetched from Roon's mirror,
`opra.roonlabs.net`, as OPRA asks non-commercial clients to do, and cached at
`~/.cache/eq/opra` for 7 days like AutoEq's index. Where one model has several OPRA presets,
oratory1990's hand-made one wins, then AutoEq runs in the reviewer order above.

OPRA's data is licensed [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/);
every OPRA import prints the credit it asks for, preset author first:
`preset by oratory1990 (Harman Target) · via OPRA (https://github.com/opra-project/OPRA), CC BY-SA 4.0`.
The same line is in `--json` as `import.attribution`. The test fixture `opra.jsonl` holds a
few of its entries under the same licence.

[peqdb.com](https://peqdb.com) stays out: it has more reviewers, but its API is the private
backend of its own site, with no stated terms.

## How it works

The daemon opens a Core Audio process tap on the system mix (macOS 14.4+), which mutes the
original output and hands the audio to the daemon. Ten peaking biquads plus the imported
filters, a preamp and a limiter at −1 dBFS later, the daemon plays it back on the same device. Latency is
shown in `eq status`; Bluetooth adds the headset's own buffering. Volume keys keep working. No driver, no `sudo`, nothing in `/Library`.

It listens for the default output changing and rebuilds on the new device with that device's
curve. Bluetooth devices arrive in two steps, so it waits for the IO callback to fire before
it calls the switch done.

The engine — tap, aggregate device, IO callback, Bluetooth and sample-rate handling — is taken
from [OnlyEQ](https://github.com/zollans/OnlyEQ) (Unlicense, commit 6569655) and trimmed to
what a headless daemon needs. That code is the part that took someone months of bug reports
to get right; the rest of this project is small.

The IO buffer stays at 256 frames. The buffer adds ~10 ms at 256 frames; the device adds its own
(Bluetooth often 100–200 ms) — see `eq status`. Measured on
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
- Ten graphic bands plus up to 32 parametric filters, imported or added by hand. Filters are
  edited by number from the command line; `eq watch` tunes only the bands and the preamp.
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
Unlicense. OPRA data, fetched at run time and in the test fixture, is CC BY-SA 4.0 — see
[OPRA](#opra).

## Verified

2026-09-27, macOS 26.6.2, M3 Pro: MacBook Pro Speakers ↔ BE-RCA (Bluetooth), per-device curves, live config reload, `eq off`/`on`, launchd restart after SIGTERM. Daemon idle: 19–22 MB RSS, 0.0 % CPU.
