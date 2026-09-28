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
brew install --cask servitola/tap/eq
```

That is all. Homebrew wants third-party taps named in full; the line above trusts this one
cask, no more.

The first `eq` you run registers the daemon as a login item named **EQ**: macOS says "Background Items Added", and it is listed under System Settings →
General → Login Items → Allow in the Background, where it can be switched off. From then on
it starts at login and restarts if it dies. `eq agent uninstall` removes it for good: no later
`eq` command registers it again until `eq agent install`.

Its first start asks once for **System Audio Recording**. Grant it to *EQ*, and `eq status`
says `running`. Until then `eq` says on stderr that it is not equalising and where to allow it.

No config file is needed: every command works on the default curve until you change
something, and that first change writes `~/.config/eq/eq.json`. `eq init` writes it right away
if you want a file to edit by hand.

If you started eq with a hand-made `~/Library/LaunchAgents/com.servitola.eq.plist` before the
app carried its own, that plist keeps working and eq never registers a second daemon beside
it; `eq doctor` names it as `legacy`. `eq agent install --replace-legacy` boots it out, moves
the plist to the Trash and starts the bundled login item instead.

## Commands

| Command | |
| --- | --- |
| `eq` | the curve in effect on the current output |
| `eq status [--json]` | is the daemon alive, on which device, at what rate |
| `eq watch [--zones]` | the live equalizer in the terminal; tune from the keyboard, `q` to quit |
| `eq zones [--json]` | the instruments' frequency ranges in Hz and the bands each one touches |
| `eq export > config.txt` | the curve as Equalizer APO text; `--format graphiceq\|eqmac\|camilla\|json`, `--out FILE` |
| `eq stream` | meter frames as JSON lines, 30 a second, until Ctrl-C; `solo` is the range being listened to, or `null` |
| `eq events` | state changes as JSON lines until Ctrl-C: device, rate, profile, enabled, solo, daemon; never meter ticks |

Tune the curve:

| Command | |
| --- | --- |
| `eq set 64hz +4 1khz -3` | change bands on the current output's curve |
| `eq set --device JBL 16khz +1` | on another device, by a piece of its name |
| `eq preamp -1.5` | preamp for the current curve |
| `eq bass +3`, `eq treble -2` | AutoEq-style bass / treble shelf on top of the curve, `0` removes it |
| `eq tilt -0.5` | tilt the whole curve, in dB per octave |
| `eq boost voice +3` | turn one instrument up or down on its character range, `0` removes it; `eq boost` lists them |
| `eq comp gentle\|night\|off` | light compression after the EQ: `gentle` glues music, `night` evens out films |
| `eq color tape\|tube 0.3`, `eq color off` | saturation after the compressor; the amount runs 0…1 |
| `eq flat` | reset: everything to 0, dropping the preset label, filters, bass/treble/tilt, boosts, compression, color and any import |
| `eq off`, `eq on` | bypass, and back |
| `eq undo`, `eq redo` | step the config back one saved version at a time, and forward again |
| `eq history` | list saved versions with their time and curve, marking the current one (`eq undo --list` is an alias) |

Devices, presets, filters and imports each have their own group:

| Command | |
| --- | --- |
| `eq device list` | who has a curve, who is connected, which is active (`eq device` alone too) |
| `eq device use AirPods` | make AirPods the system output; its curve follows |
| `eq device copy --to AirPods` | give another device this curve (`--device AirPods` works the same) |
| `eq preset list` | list presets; the current device's one marked `*` (`eq preset` alone too) |
| `eq preset save\|use <name>` | save the current curve as a preset / apply one (`--device DEVICE` for another device) |
| `eq preset show\|rm <name>`, `eq preset rename <old> <new>` | look at, delete, rename a preset |
| `eq filter list` | the parametric filters, numbered, with where each came from (`eq filter` alone too) |
| `eq filter add peak 3k -2 2` | add a filter by hand: type, frequency, gain, optional Q |
| `eq filter set 2 gain=-3 q=4`, `eq filter rm 2\|all` | change or remove filters by number |
| `eq import "WH-1000XM4"` | fetch and apply an AutoEq correction by headphone name |
| `eq import "airpods pro 2" --variant anc-on` | pick one device state when a model has several |
| `eq import --search wh1000xm4` | list what a name matches in AutoEq and OPRA, with source and variant, without importing |
| `eq import "HD 600" --source opra` | take the correction from OPRA instead of AutoEq |
| `eq import file.txt` | apply an AutoEq correction from a local file or URL |
| `eq import --clear` | drop the imported correction, keep hand-tuned bands and filters |

Setup:

| Command | |
| --- | --- |
| `eq init` | write the default config now; optional, the first change writes it anyway |
| `eq doctor` | one-shot health check: config, daemon, permission, audio |
| `eq completions zsh\|bash\|fish` | the shell completion script |
| `eq man` | the man page, as roff |

The spellings from before the groups still work and mean the same: `eq devices` is
`eq device list`, `eq copy --to AirPods` is `eq device copy --to AirPods`.

`--json` works on any command; the answer becomes one JSON document on stdout, exit codes
unchanged.

`--dry-run` works on every command that changes something: it prints the curve before and
after, in the same form as `eq`, and writes nothing — no save, no backup, no history entry.
With `--json` the answer is `{"before": …, "after": …}`. It runs the real command against a
copy of `eq.json` and its history, so a bad band or an unreadable backup fails exactly as it
would for real. `eq device use --dry-run` shows both curves and leaves the output alone.

The Homebrew cask installs zsh, bash and fish completions and the man page (`man eq`). From a
source build, `eq completions zsh > ~/.zfunc/_eq` (a directory in `fpath`), `eq completions
bash > $(brew --prefix)/etc/bash_completion.d/eq`, `eq completions fish >
~/.config/fish/completions/eq.fish`. Device names, presets, instruments and export formats
complete too: the scripts ask `eq` for them, without the daemon.

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

## Compression and colour

Two stages sit after the whole curve and before the limiter, in this order: a compressor and a
colour. Each is off until you turn it on, and one that is off is skipped entirely. Both take
`--device DEVICE`; the config stores them per profile as `"dynamics": {"comp": "gentle",
"color": {"kind": "tape", "amount": 0.3}}`, presets carry them, `eq flat` drops them, and undo
and history see them like any edit. `eq` shows a `dynamics:` line when either is on.

`eq comp gentle|night|off` is a feed-forward compressor, linked across channels so the stereo
image stays put. Its detector listens through a 100 Hz high-pass (24 dB per octave), so bass
does not pump the gain: a 40 Hz tone at −10 dBFS is not compressed at all, the same level at
1 kHz is. It measures RMS over 2.5 ms and smooths the gain in dB with the attack and release
below, over a soft knee. Makeup gain is automatic: it gives back exactly what the compressor
takes at the mode's reference level, so material at that level plays as loud as before and
only what is louder or quieter moves.

| Mode | Ratio | Threshold | Knee | Attack | Release | Makeup | For |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `gentle` | 2:1 | −18 dBFS | 6 dB | 30 ms | 250 ms | +3 dB (level at −12 dBFS RMS) | glue on music |
| `night` | 4:1 | −30 dBFS | 10 dB | 5 ms | 400 ms | +4.5 dB (level at −24 dBFS RMS, film dialogue) | quiet dialogue up, explosions down |

`eq color tape|tube <amount>` shapes the waveform. `tape` is a symmetric soft clip,
`tanh(k·x)/k`, which adds odd harmonics only; `tube` biases the same curve off centre, which
adds even harmonics too, with a DC blocker at 5 Hz behind it. The drive `k` is twice the amount,
and dividing by it keeps a quiet signal exactly as loud; at −12 dBFS the level moves less than
1 dB at any amount. At −12 dBFS and amount 1, tape measures 2 % THD, tube 11 %; at 0.3, 0.2 %
and 1.1 %. `eq color tape 0` removes it like `off`.

There is no oversampling, so the harmonics of high notes fold back below Nyquist. The drive is
capped at amount 1 to keep that low: at 48 kHz a 10 kHz tone at −12 dBFS folds its 3rd harmonic
to 18 kHz at −34 dB (tape) or −42 dB (tube) under the tone, and its 5th to 2 kHz at −66 dB or
−81 dB. Anything below 8 kHz has no 3rd harmonic to fold, and real music has far less energy
up there than a test tone.

`eq status` shows the compressor's reduction, `comp: -3.2 dB`, as of the daemon's last status
write, and `--json` carries it as `compReductionDB`. `eq watch` shows it live in the header,
`night comp -3.2`, followed by the colour, `tape 0.3`; `eq stream` frames carry it as `comp`.
`eq export` writes both only in eq's own `json`: every other format has no place for them, so it
says so on stderr and exports the EQ alone.

## Undo

Every save of the config first copies the previous file to `eq.json.1`, shifting the older
ones up to `eq.json.10`; the oldest drops off. A save that changes nothing makes no copy. The
daemon's routine writes (refreshing device names) make no backup; the one exception is the
first time it seeds presets into a config from before they existed — that one backs up, so
the pre-presets file stays recoverable as `eq.json.1`.

`eq undo` steps `eq.json` back one saved version — `.1` first, then `.2`, and so on with each
further `eq undo`, refusing and leaving every file alone if a backup turns out not to be valid
JSON. `eq redo` steps forward again, back towards the latest edit. No version is lost: a new
edit after `eq undo` (`eq set`, `eq watch`, …) ends the redo branch, but first puts the
abandoned latest version into the history, just behind the version you edited — `eq undo`
right after returns to what you edited, and `eq history` still lists the version you walked
away from. A save that changes nothing and the daemon's device-name refresh keep the redo
branch. Editing `eq.json` by hand while stepped back makes that edit the latest version the
next time you run `eq undo` or `eq redo`; the version it started from and the previous latest
both go into the history. Both commands print the current device's curve. `eq history` lists
every saved version with its time and a one-line curve summary — `off` when EQ was off in that
version, `pref …` when bass, treble or tilt were set, `boost …` when a knob is — marking the current position with `←`; `eq undo --list` is kept as an alias for it. Undo and redo themselves never reorder
the backup files — they move only `eq.json` and two small bookkeeping files beside it,
`eq.json.pos` and `eq.json.redo`.

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
| `c` | compressor: off → gentle → night → off |
| `v` / `V` | colour: off → tape → tube → off, starting at amount 0.3 / raise the amount by 0.1, from 1 back to 0.1 |
| `u` | undo the last change made in this session, back to how it started |
| `s` | save the curve as a preset: type a name, Enter saves, Esc cancels |
| `z` | the instrument strip, on and off |
| `]`, `Tab` / `[` | focus the next / previous instrument |
| `→` / `←` | the focused instrument's knob ±0.5 dB (`.` / `,` work too, no Shift needed; `ю` / `б` on a Russian layout) |
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
physical keys on either layout (`и` for `b`, `е` for `t`, `з` for `p`, `г` for `u`, `ы` for `s`, `с` for `c`, `м` for `v`, `х`/`ъ` for `[`/`]`,
`д` for `l`, and so on).

The header names the device's preset after the preamp, with the yellow `*` once the curve has
moved away from it. Bass, treble and tilt follow it when set: `bass +3 treble -2`, then the
instrument knobs that are set, and the focused one even at 0: `voice +3.0`, then the
compressor with its live reduction and the colour: `night comp -3.2 · tape 0.3`. `p` applies the presets in turn, as `eq preset use` would. `u` walks back
through this session's steps, preset changes included, one per press, until the curve is as it
was when the session started; it does not reach past the session — that is `eq undo`. `s`
turns the bottom line into `save as: ▏`; while it is open every key types into it, digits
included, Backspace deletes, and a bad name shows its error in the same line for two seconds.

On start a small box in the top-right corner lists the keys. It hides after 8 seconds or on
any key; `h` brings it back. `x` hides it and writes the empty marker
`~/.cache/eq/watch-hint-off`, after which it no longer appears on start (delete the file to
get it back; one left in `~/.config/eq` by an older version still counts). A terminal narrower than twice the box shows one dim line at the bottom instead,
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
ranges — the character range bright, the rest dim — the bars, labels and gains of bands it does not touch turn dim, and its level numbers
turn bright. The strip, when open, shows only that instrument. Digit keys still name all ten
bands, but a band outside the focus is refused with `outside voice — Esc to unfocus` in the
footer, so tuning stays on the instrument. A band belongs to the focus when any of the
instrument's ranges overlaps the octave around the band's centre, which is why voice reaches
down to the 64 Hz band.

`l` listens to the focus alone: the daemon adds a steep high-pass and low-pass at the edges
of the instrument's character range (voice is heard at 2–5 kHz, not across its whole
85 Hz–9 kHz, which isolates little), and the header shows a yellow `SOLO` for as long as the daemon reports
it. Switching focus moves the solo to the new instrument. `l` again, `Esc` and `q` switch it
off; so does the watch going away in any other way, since the daemon drops a solo the moment
the client that asked for it disconnects. At a rate too low for the focus (air on a headset
in call mode) the footer says `can't listen to air at this rate` and nothing plays solo until
the focus moves to an instrument the rate can carry. A solo asked for while the device is
still settling at 0 Hz is asked for again once the rate arrives. A solo is never saved and never reaches `eq.json`.
It is the curve you hear through, not a second curve: the EQ stays one curve per device.

Each instrument has a knob for what the watch's focus only shows: `eq boost voice +3` (or `→`
while voice is focused) adds one peak filter at the geometric centre of the instrument's
character range, the range a mixing engineer reaches for to bring it forward, with a Q as wide
as that range; `−12`…`+12` dB, `0` removes it, and an unset knob costs nothing.

| Instrument | Character range | Why this one |
| --- | --- | --- |
| kick | thump 50–100 Hz | the weight you feel; the click shares 2–5 kHz with snare and guitar |
| bass | growl 700 Hz–1.2 kHz | what makes a bass line heard on small speakers; its low end is `eq bass` |
| snare | crack 4–6 kHz | cuts through; the body sits on the bass fundamental |
| guitar | bite 2–5 kHz | pick attack; the body spans four octaves |
| piano | brightness 4–8 kHz | hammer attack and clarity; the fundamental is most of the keyboard |
| voice | presence 2–5 kHz | intelligibility, where the ear is most sensitive |
| cymbals | shimmer 6–16 kHz | its only range |
| air | sparkle 10–20 kHz | its only range |

The knobs live as `"instruments": {"voice": 3}` on the profile next to `"preference"` and run
after it; presets carry them, `eq flat` drops them, `eq export` writes them as peak filters
(eqMac's format has no room for them and refuses), and undo and history see them like any
edit. `eq` prints `boost: voice +3 kick -2` when any is set; `eq boost` alone lists every
instrument with its range and gain. A name eq does not know, typed into `eq.json` by hand, is
ignored and logged by the daemon. A knob cannot split instruments that share a range: boosting
kick thump also lifts the bass there, and guitar bite and voice presence are the same knob.

Any meter client can ask for a solo by writing `{"solo":{"low":L,"high":H}}` to the socket,
one JSON object per line, with `0 ≤ L < H ≤ 100000` Hz; any other line is ignored. The last
accepted range wins and its sender owns it. Only the owner clears it: with `{"solo":null}`,
with a range the daemon refuses at the current sample rate, or by disconnecting. A `null` from
any other client is ignored, so a second `eq watch` cannot switch off the first one's solo.
The socket takes at most eight clients at once, meter and events clients together, and closes
any beyond that.

## Events and hooks

`eq events` prints one JSON line per state change until Ctrl-C, and exits 1 when the daemon
is not running or predates events. Every line has `t` (Unix seconds) and `event`:

| `event` | fields | when |
| --- | --- | --- |
| `daemon` | `state`, `version`, `error` | the daemon's state changes; also the first line, the state it is in now |
| `device` | `device`, `uid`, `transport`, `rate` | the EQ runs on another output |
| `rate` | `device`, `rate` | the same output changes sample rate |
| `profile` | `device`, `preset` (or `null`), `source` (`device` or `default`) | the curve, preset or knob in effect changes |
| `enabled` | `enabled` | `eq on` / `eq off` |
| `solo` | `solo`: `{"low":L,"high":H}` or `null` | a watch starts or stops listening to one range |

```sh
eq events | jq -r --unbuffered 'select(.event == "device") | "\(.device) at \(.rate) Hz"'
```

A `device` event is sent when the profile is applied to the new output, before the daemon has
confirmed that the output is running. A rate change that narrows or widens the range a solo can
actually play publishes no new `solo` event; the last one keeps the range clamped at the old rate.

It rides the meter socket: a client that writes `{"subscribe":"events"}` as its first line gets
events instead of frames, and the meter stays off for it. A client that writes nothing, as
`eq stream` and `eq watch` do, gets frames exactly as before.

Hooks are shell commands the daemon runs on a change, under `hooks` at the top of `eq.json`:

```json
"hooks": {
  "device": "say \"$EQ_DEVICE, $EQ_RATE hertz\"",
  "preset": "/Users/me/bin/on-preset.sh"
}
```

`device` runs when the output or its sample rate changes, `preset` when the preset in effect
does; both run once when the daemon starts. A burst of changes runs a hook once, a second after
the last, for the state it settled in. The daemon runs it with `/bin/sh -c`, off the audio
path, with `EQ_DEVICE`, `EQ_PRESET` (empty without one) and `EQ_RATE` in its environment. After
10 s the hook and everything it started are killed. Its output, cut at 4 KB, and its exit
status go to the daemon's log; a failing hook never touches the audio. Other names are logged
and ignored. `eq doctor` warns about a hook whose program is an absolute path that is missing
or not executable.

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
`GraphicEQ.txt` is reduced to the ten fixed bands and the preamp: eq fits them to the whole
curve, the level it sits at going to the preamp, which is close but not exact — ten
octave-wide peaks cannot draw every wiggle — so the `ParametricEQ.txt` of the same model is
preferred when both exist. Use
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

## Formats

`eq import <file|url>` recognises a file by what is in it, not by its name. It reads:

- **Equalizer APO** `config.txt`, the grammar the rest below write: `Preamp:` (several add
  up), `Filter N:` or `Filter:` with `ON`/`OFF` and every biquad type APO has — `PK`/`PEQ`/
  `Modal`, `LP`/`LPQ`, `HP`/`HPQ`, `BP`, `NO`, the shelves `LS`/`HS`, `LSC`/`HSC` with an
  optional `x dB` slope, `LS 6dB`/`LS 12dB` (and `HS`), and `LSQ`/`HSQ` — with `Fc` in Hz or
  kHz, `Gain`, and `Q` or `BW Oct`. Shelves and bandwidths become the same Q APO's own code
  computes, including its default slope, its corner-frequency shift for `LS`/`HS` with a slope
  or a Q, and its bandwidth warp (taken at 48 kHz). A decimal comma works.
- **AutoEq** `ParametricEQ.txt` and `GraphicEQ.txt`, and `FixedBandEQ.txt`, whose ten peaks
  at Q 1.41 land on the ten bands directly instead of as filters.
- **REW** "Export filter settings as text", with its header, its column spacing and its
  `ON None` empty slots.
- **squig.link**, **peqdb** and **SoundSource** headphone-EQ text, which are the same grammar;
  squig.link's CRLF line endings and `Channel: L`/`Channel: R` blocks included.
- **eqMac** preset export (JSON). An Advanced preset's ten gains are eqMac's ten bands, the
  same centres as eq's, and its global gain is the preamp; gains beyond ±12 dB come in as ten
  peak filters instead, so the curve still sounds the same. An Expert preset's bands become
  filters, bandwidth in octaves turned into Q. A file of several presets imports the first.
- **Poweramp** preset (JSON). Graphic mode's sliders become the ten bands (other slider counts
  are reduced to ten), its tone shelves come in only when they are not at 0 dB; parametric mode
  keeps every band as a filter. Bands for one channel only are skipped.
- **EasyEffects** preset (JSON), its equaliser plugin (`equalizer` or `equalizer#0`): Bell,
  shelves, low- and high-pass, notch and band-pass bands with their Q; input and output gain
  add up to the preamp. With `split-channels` the left channel is imported, with a warning when
  the right differs. Allpass, Resonance and Ladder bands are skipped; a slope steeper than `x1`
  comes in as one filter, with a warning.
- **Peace** `.peace` configurations. eq writes the same Equalizer APO lines Peace itself writes
  for each slider (its filter types, including its Butterworth and Linkwitz-Riley cascades
  whose Quality is the order, and its GraphicEQ mode) and reads them as above, so speaker groups
  work like `Channel:`. Commands from Peace's command window are read too. Peace's effects
  (routing, crossfeed, bass and treble, …) are named in a warning and not imported.
- **eq's own JSON profile**, what `eq export --format json` and `eq.json` write: the ten bands,
  the preamp, every filter with its type, and the bass/treble/tilt preference layer when it is
  not flat. Read back exactly, not fitted or reduced.
- **CamillaDSP** config (YAML). The `pipeline:` decides what imports: the filters channel 0
  runs, in order, with a warning when channel 1 runs something else; `Gain` filters on it add
  up to the preamp (`scale: linear` too); a step's channels are read in both CamillaDSP 2's
`channel: 0` and 3's `channels: [0, 1]` form; mixers and processors are named and skipped; with no
  pipeline every filter under `filters:` imports. Biquads `Peaking`, `Lowshelf`, `Highshelf`,
  `Lowpass`, `Highpass`, `Notch` and `Bandpass` with `q`, a shelf `slope` in dB per octave or a
  `bandwidth` in octaves (warped at the config's own sample rate, as CamillaDSP does); first-order,
  all-pass, `Free` and `BiquadCombo` filters are skipped with a warning. eq reads the YAML those
  configs are written in (block and one-line flow collections, quotes, comments) without a YAML
  library; anchors, tags and multi-line strings refuse the file with the line that has them.

`Channel:` scopes what follows, as in APO. eq is one curve for both ears, so it imports the
left channel and warns when the right one differs; filters only for other channels (`C`,
`LFE`, …) are skipped with a count. `Include:` is followed from a file, relative to the file
that names it, at most four levels deep, never in a circle, and never from a URL or a
headphone name. A relative path must stay inside the imported file's folder (`..` or a symlink
leading out of it is refused), so a downloaded config cannot reach into the rest of your home
folder; an absolute path is followed as written. Only a regular file up to 1 MB is read. `Device:`, `Copy:`, `Stage:`, `Eval:`, `If:`/`Else:`, `Delay:` and
`Convolution:` have no meaning for eq; each is named once in a warning and the filters around
it are imported. All-pass and `IIR` filters are skipped with a warning. The same regular-file,
1 MB guard applies to a path named directly on the command line, so `eq import /dev/zero`
is refused instead of reading forever.

A file is recognised by its content in this order: eqMac, eq's own JSON, Poweramp and
EasyEffects JSON by their keys, a `.peace` by its `[Frequencies]`-style sections, a CamillaDSP
config by a top-level `filters:` beside `pipeline:` or a `Biquad`, and anything with an APO `Filter:`, `Preamp:`,
`GraphicEQ:` or `Include:` line as APO text.

Every number is checked before it becomes a filter: a frequency outside 10–24000 Hz, a gain
outside ±30 dB, a Q outside 0.1–30, a filter that would be unstable at 48 kHz, or a line that
does not parse is skipped with a warning naming its line (or its band, slider or filter). A total preamp outside −30…12 dB
refuses the import. The preamp is the file's own: AutoEq's `.txt` files carry the peak of the
whole cascade, 0.1 dB less cautious than the README tables beside them, and eq does not
recompute it.

### Export

`eq export` writes the curve in effect on the current output (or `--device DEVICE`) for another
tool, to stdout or with `--out FILE`. `--out` writes a hidden file beside `FILE` and renames it
into place, so nothing ever sees half a file, and refuses a file that already exists unless
`--force` is given. `--json` wraps the result in a report with the device and format.

| `--format` | what you get |
| --- | --- |
| `apo` (default) | Equalizer APO `config.txt`: a comment naming eq, the device and the date, `Preamp:`, then one `Filter N: ON …` per band (a `PK` at each of the ten centres, Q 1.41), filter and bass/treble/tilt shelf — the same list eq runs. Shelves are written `LSC`/`HSC … Q` and passes `LPQ`/`HPQ`, the spellings APO reads as exactly the filter eq plays. Peace, REW and SoundSource's headphone EQ read the same file, and `eq import` reads it back to the same filters. |
| `graphiceq` | AutoEq's `GraphicEQ.txt`: the whole response, preamp included, at AutoEq's 127 fixed frequencies (20–19871 Hz), the only grid Wavelet accepts. |
| `eqmac` | an eqMac preset: the ten band gains and the preamp. eqMac holds nothing else, so a curve with filters or bass/treble/tilt is refused with a note saying which. |
| `camilla` | CamillaDSP YAML: a `filters:` block (a `Gain` filter for the preamp, one `Biquad` per band and filter) and a `pipeline:` step running them on `channels: [0, 1]`, to merge into a config. That is CamillaDSP 3 and 4's syntax; for 2.x, split the step into `channel: 0` and `channel: 1`. |
| `json` | eq's own profile, as it sits in `eq.json`. `eq import` reads this back exactly. |

## How it works

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

Measured with `scripts/footprint.sh` while a tone played over Bluetooth at 44.1 kHz.

| Metric | v2 (installed) | v3 (release @256) |
| --- | --- | --- |
| physical footprint | 6.4 MB | 5.2 MB |
| CPU while playing | 0.30 % | 0.30 % |
| context switches | 189 /s | 191 /s |
| status.json writes | 12 /min | ≤ 2 /min (30 s heartbeat + changes) |
| log | unrotated | capped by the cleanup job |
| `brew uninstall` | agent stays loaded | daemon exits with its binary; `eq agent uninstall` first removes the login item; `--zap` also unloads both jobs and removes a hand-installed plist |

512 IO frames halves context switches but more than doubles CPU, so 256 stays the default;
`EQ_IO_FRAMES` is the escape hatch to re-measure on other hardware (see "How it works" above).

The compressor and the colour cost nothing while off. Switched on, measured offline with
`swift test -c release -Xswiftc -enable-testing --filter DynamicsTests/testCost` on an M3 Pro,
per second of stereo audio at 48 kHz: the ten-band curve 0.97 ms, the compressor another
1.3 ms, tape 0.6 ms, compressor and tube together 2.3 ms — about 0.2 % of one core.

Zero cost while nobody watches: the meter and its 30 Hz timer exist only while a meter client
is connected. An `eq events` client does not count.

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
