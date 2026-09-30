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
cask, no more. The cask also carries the audio driver for [driver mode](#driver-mode-experimental),
inside EQ.app; nothing goes into `/Library` until you turn driver mode on.

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

### Uninstall

```sh
brew uninstall --cask eq          # --zap also removes the config, cache, log and login items
```

If driver mode ever installed the driver, this takes it out too: eq switches to tap mode, which
moves the default output back to a real device, then asks once for an administrator password to
remove `/Library/Audio/Plug-Ins/HAL/EQDriver.driver` and restart coreaudiod. `brew upgrade` and
`brew reinstall` run the same cask step, and there the driver stays: Homebrew passes the step
nothing that tells them apart, so eq reads the command line of the `brew` process above it and
removes the driver only under `brew uninstall` (`rm`, `remove`). Without Homebrew, or to drop the
driver and keep eq: `eq driver uninstall`.

coreaudiod keeps the curves the driver stored, a few kilobytes under `Plug-In.com.servitola.eq.driver`
in `/Library/Preferences/Audio/com.apple.audio.SystemSettings.plist`. eq leaves them: that file is
coreaudiod's own, rewritten while it runs, and nothing reads the entry once the driver is gone.

## Commands

| Command | |
| --- | --- |
| `eq` | the curve in effect on the current output |
| `eq status [--json]` | is the daemon alive, on which device, at what rate |
| `eq watch [--zones] [--look LOOK] …` | the live equalizer in the terminal; tune from the keyboard, `?` lists every key, `y` switches the look, `q` quits; the flags are under [Looks](#looks) |
| `eq tui [meter\|tune\|instruments\|presets\|devices\|filters\|events] [--zones] [--look LOOK] …` | the terminal UI, opened on the meter (the same screen as `eq watch`), the curve to edit, the instruments, the presets, the outputs, the filters or the daemon's events; `;` opens a palette of every command |
| `eq zones [--json]` | the instruments' frequency ranges in Hz and the bands each one touches |
| `eq export > config.txt` | the curve as Equalizer APO text; `--format graphiceq\|eqmac\|camilla\|json`, `--out FILE` |
| `eq stream` | meter frames as JSON lines, 30 a second, until Ctrl-C; `solo` is the range being listened to, or `null` |
| `eq events` | state changes as JSON lines until Ctrl-C: device, rate, profile, enabled, solo, daemon, app, mode, target; never meter ticks |

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
| `eq app set Spotify favourite` | while Spotify plays, hear the `favourite` preset (experimental, see below) |
| `eq app [list]`, `eq app rm <app>`, `eq app on\|off` | list the app rules, remove one, follow apps or stop |
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
| `eq mode [driver\|tap]` | show or switch the audio path; see [Driver mode](#driver-mode-experimental) |
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
would for real. `eq device use --dry-run` shows both curves and leaves the output alone;
`eq mode driver|tap --dry-run` says what the switch would do.

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

## Curve per app (experimental)

An app rule gives an app its own preset while it plays:

```sh
eq app set Spotify favourite     # a name, or a bundle ID: com.spotify.client
eq app set com.google.Chrome flat
eq app on                        # off by default
```

The rules sit in `eq.json` in order, and the feature stays off until `"experimental": {"apps":
true}` is there, which `eq app on` writes:

```json
"apps": [{"app": "com.spotify.client", "preset": "favourite"}, {"app": "com.google.Chrome", "preset": "flat"}],
"experimental": {"apps": true}
```

While an app with a rule plays, the daemon plays the rule's preset instead of the device's curve,
as `eq preset use` would, and goes back to the device's curve a second after the app stops. The
switch lives only in the daemon: `eq.json` keeps the device's own curve, and nothing lands in undo
or history. `eq`, `eq status` and `eq watch` say `app: Spotify → favourite` while it lasts, `eq
events` sends `{"event":"app","app":"com.spotify.client","name":"Spotify","preset":"favourite"}`,
and `"preset":null` when the device's curve comes back. The `profile` event and the hooks stay
about the device's curve. An edit to the curve while an app plays goes to the device's curve as
always and is heard at once; the rule rests until that app stops, and applies again the next time
it plays.

The daemon learns what plays from Core Audio's list of audio clients, through listeners and without
polling; with the feature off it does not listen at all. Browsers and Electron apps play from a
helper process, which counts as the app whose bundle holds it: Chrome's helper is Chrome. Safari and
other WebKit apps play from WebKit's shared `com.apple.WebKit.GPU` service, which names no app; a
rule for that bundle ID catches all of them. When two apps with rules play at once, the one macOS
shows as now playing wins if `/opt/homebrew/bin/nowplayingseek` is
installed, and the first rule otherwise.

The honest limit: there is one curve for the whole system at a time. When two apps play together,
both are heard through the winner's curve. `eq doctor` has an `apps` row while this is on.

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
and history see them like any edit. `eq` shows a `dynamics:` line when either is on. A mode or
kind this eq does not know, from a newer version or a hand edit, does not reject the file: it
runs nothing, stays in the file, is logged once by the daemon and flagged by `eq doctor`, and
`eq comp` or `eq color` replaces it.

`eq comp gentle|night|off` (or `none`, in any case) is a feed-forward compressor, linked across channels so the stereo
image stays put: the loudest channel sets one gain for all, so dialogue on the centre of 5.1
alone is compressed as it would be on both sides of stereo. Its detector listens the way a
loudness meter does, through ITU-R BS.1770's K-weighting (a high-pass at 38 Hz and +4 dB above
1.7 kHz), so the bass your curve boosts counts towards the level instead of being ignored. It
measures RMS, over 50 ms for `gentle` and 2.5 ms for `night`, and smooths the gain in dB with the
attack and release below, over a soft knee. A steady 40 Hz tone at −10 dBFS does not pump the
gain: it moves by 0.001 dB (`gentle`) and 0.06 dB (`night`) over each cycle.

Makeup gain is automatic. `gentle` gives back the reduction it has averaged over the last 3
seconds, up to 6 dB, so a song ends up as loud as without it and only its dynamics within a
phrase are tighter; a pause does not count, so the next song starts with the makeup the last one
had. `night` adds a fixed makeup that gives back exactly what it takes from film dialogue at
−24 dBFS RMS, so quiet dialogue comes up.

| Mode | Ratio | Threshold | Knee | Attack | Release | Makeup | For |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `gentle` | 2:1 | −18 dBFS | 6 dB | 30 ms | 250 ms | follows the reduction, 3 s, up to +6 dB | glue on music |
| `night` | 4:1 | −30 dBFS | 10 dB | 5 ms | 400 ms | +4.5 dB (level at −24 dBFS RMS, film dialogue) | quiet dialogue up, explosions down |

The RMS window and the attack add up on a step: `gentle` reaches 63 % of its reduction in
about 65 ms, `night` in 6 ms.

What `gentle` does to a whole mix, on the `favourite` curve, measured offline by
`CompressorBalanceTests` against the same chain with the compressor off:

| Material | Loudness | Bass (32–125 Hz) against mids (0.5–2 kHz) | Widest gap between octave bands | Reduction on loud parts |
| --- | --- | --- | --- | --- |
| music at −14 LUFS | −0.3 LU | −0.1 dB | 0.3 dB | 3.6 dB |
| music at −20 LUFS | −0.0 LU | +0.0 dB | 0.3 dB | 0.9 dB |
| pink noise swinging 12 dB | −0.7 LU | −0.0 dB | 0.1 dB | 0.9 dB (mean) |

`eq color tape|tube <amount>` shapes the waveform. `tape` is a symmetric soft clip,
`tanh(k·x)/k`, which adds odd harmonics only; `tube` biases the same curve off centre, which
adds even harmonics too, with a DC blocker at 5 Hz on what the curve adds. The drive `k` is twice the amount,
and dividing by it keeps a quiet signal exactly as loud; at −12 dBFS the level moves less than
1 dB at any amount. At −12 dBFS and amount 1, tape measures 2 % THD, tube 11 %; at 0.3, 0.2 %
and 1.1 %. `eq color tape 0` removes it like `off`.

Switching either one on or off, or changing the mode, the kind or the amount, glides instead of
jumping: the compressor's gain over 10 ms, or over its attack when that is longer, so switching
it on never swells before it compresses, and the colour's drive over 10 ms, so the curve and the
tube's DC come in without a click. A stage switched off stops running once it has glided out.

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

A whole `eq watch` or `eq tui` session is one undo step: only its first save makes a backup, so after
quitting, `eq undo` returns to the curve from before the session. Every change made in the Presets,
Devices and Filters views is the same change its `eq` command makes, and belongs to that one step.

## Watch

```
 ◉ BE-RCA  44.1 kHz │ preamp -4.8 dB │ ◆ favourite*                peak -6.0 dB
  Meter   Tune   Instruments   Presets   Devices   Filters   Events
   ╭─ meter ─────────────────────────────────────────────── dBFS · gain dB ╮
   │  0 ┤        ▔▔▔                                                  ├+12 │
   │ -6 ┤  ▔▔▔   ▂▂▂   ▔▔▔                                                 │
   │-12 ┤  ▇▇▇         ▃▃▃   ▔▔▔                                           │
   │        ⡀    ⢀⡀          ▃▃▃   ▔▔▔   ▔▔▔                               │
   │      ⡠⠊⠈⠑⠢⠔⠊⠁⠈⠑⠢⠔⠊⠉⠑⢄         ▃▃▃   ▇▇▇   ▔▔▔                    ├+6  │
   │-24 ┤                 ⠉⠒⠒⠢⢄⡀               ▅▅▅   ▔▔▔  ⢀⠤⠤⡀   ⢀         │
   │                           ⠈⠢⣀                   ▅▅▅⣀⠔⠁▔▔⠈⠢⠤⠤⠊⠱⡀       │
   │      ┈   ┈┈┈   ┈┈┈   ┈┈┈   ┈┈⠉⠒⠤⣀┈┈┈   ┈┈⢀⣀⠤⠤⠤⠒⠒⠒⠉⠉┈┈┈▇▇▇┈┈┈▔▔⠑⠒⠒├ 0  │
   │-36 ┤                             ⠉⠢⡀  ⢀⠔⠊⠁                            │
   │                                    ⠈⠑⠊⠁                     ▇▇▇       │
   │                                                                       │
   │-48 ┤                                                             ├-6  │
   │                                                                       │
   │                                                                       │
   │-60 ┤                                                             ├-12 │
   ╰───────────────────────────────────────────────────────────────────────╯
           -9    -8    -11   -15   -19   -17   -22   -26   -29   -37
          32Hz  64Hz  125Hz 250Hz 500Hz 1kHz  2kHz  4kHz  8kHz  16kHz
          +4.8  +4.0  +4.2  +2.3   0.0  -3.1   0.0   0.0  +3.1  +2.4

 1…0  band   ⇧  down   z  zones off   i  instruments   ?  keys   q  quit
```

`eq watch` draws all ten bands live at ~30 fps, in one of two looks (above as text; the bars are
painted cells, so `cat docs/design/tui/actual/studio-meter-120x40.ans` shows it in colour).
**studio**, the default, puts the bands in a panel: each bar is painted by height, green below
−18 dBFS, amber up to −6, red above, with `░` where the input reaches above the output (a cut)
and a tick `▔` holding each band's peak for 1.5 s before it falls at the IEC Type I rate (20 dB
in 1.7 s). Over the bars the EQ's response is drawn in braille from the band gains, as the daemon
runs them (peaking filters, Q 1.41, at the device's rate), with the boost tinted green and the cut
magenta against the 0 dB line; the dBFS scale is on the left and the gain scale on the right.
Under the panel come each band's level in dBFS (`·` when silent), its label, and its gain as a
chip. At 110 columns and wider a column of gauges sits beside it: output peak and limiter,
compressor reduction and colour, bass, treble and tilt, and the eight instrument knobs.
**console** draws a mixing desk instead: a channel strip per band with a paper label, an LED
ladder whose unlit segments stay faintly lit, an amber readout and a fader whose cap sits at the
band's gain; SOLO, BYPASS and LIMIT are lamps in the header rail, and at 110 columns a master
section shows the compressor's gain reduction as a needle in a backlit window, with its lamps,
the peak, the preamp and a knob for tone and each instrument. `y` switches the look, `Y` the
palette, and both are remembered.

Below 60 columns or 12 rows both looks fall back to compact rows in their own colours: narrower
bars and short labels first, then the highest bands drop off with a note to widen the window.
Resizing the terminal redraws the whole frame for the new size. `eq stream` is the same numbers as
JSON lines instead, for anyone who wants to draw their own. Both need a running daemon; `watch`
needs a TTY and exits on `q` or Ctrl-C.

### Looks

| Setting | Flag (`eq watch`, `eq tui`) | `eq.json` | Values | Default |
| --- | --- | --- | --- | --- |
| look | `--look LOOK` | `tui.look` | `studio`, `console` | `studio` |
| palette | `--palette PALETTE` | `tui.palette` | `auto`, `ink`, `paper`, `brass` | `auto`: `ink` for studio, `brass` for console |
| colours | `--colors DEPTH` | `tui.colors` | `auto`, `24bit`, `256`, `16`, `none` | `auto` |
| meter | `--meter STYLE` | `tui.meter` | `auto`, `bars`, `leds` | the look's: bars in studio, LEDs in console |
| response curve | `--curve`, `--no-curve` | `tui.curve` | `true`, `false` | on in studio, off in console |
| scales | `--scale`, `--no-scale` | `tui.scale` | `true`, `false` | on |
| peak hold | `--peaks`, `--no-peaks` | `tui.peaks` | `true`, `false` | on |
| ground | `--background GROUND` | `tui.background` | `terminal`, `theme` | `terminal` |

A flag holds for that run, `eq.json` holds until changed, and `y` (`н`) and `Y` (`Н`) write
`tui.look` and `tui.palette` there as `m` writes `tui.mouse`. `auto` colours means: `NO_COLOR`
or `TERM=dumb` give none, `COLORTERM=truecolor` (or `24bit`, which tmux sets in every pane and
then converts itself for an older terminal) gives 24-bit, a `TERM` ending in `-direct` too, a
`TERM` with `256color` gives 256, anything else the terminal's sixteen. Each palette colour has a
hand-picked stand-in at sixteen colours rather than a conversion: green still means a boost,
magenta a cut, yellow a warning, red a failure. With no colour at all the look stays and reverse
video carries what colour did: the bars, the chips, the flags. `NO_COLOR` and `TERM=dumb` win over
any flag. The default ground is the terminal's own, so a translucent terminal stays translucent
and only panels, chips and tints are painted; `--background theme` paints the palette's ground
under everything, which the light `paper` palette needs on a dark terminal.

### Views

Under the status bar a row of tabs names the views, the current one a solid chip and each other
one with its letter underlined; `g` and that letter goes there, and a small menu over the keybar
lists the letters after `g` (`п`, then `ь`, `е`, `ш`, `з`, `в`, `а` or `у` on a Russian layout). `Esc` with nothing
left to cancel goes back to the view before. `eq tui VIEW` opens on one (`eq tui events`); `eq
watch` is the meter. Below 14 rows the tabs give their row to the meter, and below 60 columns only
the current one shows.

- **Meter** (`g m`): the screen above.
- **Tune** (`g t`): the curve to edit, laid out as a panel. On top, the response of the whole
  chain (bands, filters, tone, tilt and knobs, as the daemon runs them at the device's rate) in
  braille over its boost and cut tints, with a node on each band and the selected one marked;
  `! clips +1.9 dB` in its title when the curve with the preamp lifts some frequency over 0 dBFS.
  Under it the ten bands as vertical sliders from −12 to +12 dB, each with its gain and a live
  mini-meter, and beside them (under them below 110 columns) the chain: preamp, bass, treble,
  tilt, the compressor's mode, the colour's kind and amount, and the output: peak, limiter,
  headroom. `←`/`→` select a band or a control, `↑`/`↓` step it 0.5 dB (the tilt 0.1 dB/octave,
  the amount 0.1, a mode to the next), `⇧↑`/`⇧↓` or `PgUp`/`PgDn` 3 dB, `Alt↑`/`Alt↓` 0.1 dB,
  `0`, `Backspace` or `Del` set it to 0 or off, `Enter` types an exact value (`-3,5`, `night`,
  `tape`), `Tab` jumps between the bands, the chain and the dynamics. Arrows are the same on
  every layout, so any band goes up and down from a Russian one without Shift. Every change is
  saved at once and belongs to the session's one undo step, as on the meter; `u` walks back.
  `d` and `D` switch the curve being edited to the next or previous device, playing or not, with
  its name in the response panel's title; leaving Tune goes back to the playing device's.
  In console the sliders are faders on channel strips with a tape label and an amber readout,
  the response a backlit window, and the chain a master section of faders, knobs and lamps.
- **Instruments** (`g i`, or `i` on the meter): `eq zones` and `eq boost` as one table, each
  instrument in its colour with its knob as a centre-zero gauge, a live mini-meter of its loudest
  band, its ranges in Hz, where each sits on a 20 Hz–20 kHz map and the bands each touches, and
  the ten bands as they sound now under it. `↑`/`↓` choose, `←`/`→` turn the chosen knob,
  `l` listens to it alone, `Enter` focuses it on the meter.
- **Presets** (`g p`): every preset, the current device's marked `◆` and with a yellow `*` once
  the curve has moved away from it, each with its ten gains as a spark and its preamp; beside
  them the chosen one's curve in braille over its boost and cut tints, and its layers: preamp,
  bass, treble and tilt, knobs, compressor and colour, filters. `Enter` plays it on the current
  device (`eq preset use`), `s` saves the current curve as a new one (`eq preset save`), `r`
  renames it with devices and app rules following (`eq preset rename`), `d` deletes it
  (`eq preset rm`) once `y` answers the question in the message row, which first says which
  devices keep its curve unmarked and how many app rules will match nothing; any other key keeps
  it. `v` compares it with the current device's curve: both drawn, the current one faint, and
  each band, the preamp and each layer that differs listed as `32 Hz +4.8 → +3.0`.
- **Devices** (`g d`): the outputs connected now, then the devices with a profile of their own
  that are not, as `eq device list` lists them: `◉` on the one whose curve plays, a glyph for how
  each is connected (`■` built-in, `▪` USB, `◇` Bluetooth, `□` HDMI or DisplayPort, `○` AirPlay,
  `◆` Thunderbolt, `·` offline), whether it has its own curve and its preset; beside them the
  chosen one's curve and layers. `Enter` makes it the system's output (`eq device use`); `c`
  copies the playing device's curve to it (`eq device copy --to`); `e` opens Tune on its curve,
  whether it plays or not. In driver mode the EQ device heads the list as the system's output and
  the device it plays on, and is never one to pick: `Enter` on a real device sets the system's
  output to it, and the daemon, as for a pick in the Sound menu, points the EQ device at it and
  takes the output back.
- **Filters** (`g f`): the current device's parametric filters as `eq filter list` numbers them,
  with type, frequency, gain, Q and whether an import or a hand added each; under them the
  filters' combined response, a dot on each, the chosen one's own response lit. `Enter` (or `→`)
  changes a filter in place: `←`/`→` pick the type, frequency, gain or Q, `↑`/`↓` step it (the
  next type, a sixth of an octave, 0.5 dB, Q 0.1), `⇧↑`/`⇧↓` an octave, 3 dB or Q 1, `Alt↑`/`Alt↓`
  a 24th of an octave, 0.1 dB or Q 0.01, each step saved at once (`eq filter set`); `Esc` goes
  back to moving between filters. `a` opens a row under the others for a new filter, set the same
  way, which `Enter` adds (`eq filter add`); `d` removes one (`eq filter rm`) once `y` answers.
- **Events** (`g e`): the daemon's `eq events` as a log, newest at the bottom, each kind in its
  colour: device, rate, preset, bypass, solo, app, mode. `Space` pauses it while events keep
  arriving (the panel counts them), `/` filters by kind or text, `PgUp`/`PgDn`/`Home`/`End`
  scroll. The status bar follows these events on every view.

The meter connection is held only while a view that draws levels is on screen, or a solo sounds:
on the Events view the daemon stops its meter work, and the status bar leaves out the peak and
LIMIT, which only meter frames carry. The events connection stays open from start to end.

`;` (`ж` on a Russian layout, the same key) or Ctrl-P opens the command palette in the message
row: every `eq` command form from the help, and the screen's own actions by name (`go events`,
`zones`, `look`, `listen`), fuzzy-matched as you type, with the best match marked. Once a command's
words are typed its operand completes from the same values the shell completions use: presets,
devices, instruments, bands, formats, apps. `Tab` takes a suggestion into the line, `↑`/`↓`
choose, `Enter` runs it; with the line empty the last commands run come first (the last 100 are
kept in `~/.cache/eq/tui-history`). An `eq` command runs as a child process beside the screen,
which keeps drawing; a one-line answer shows in the message row, a longer one in a panel over the
view with its colours kept, laid out for the panel's width, where `Ctrl-C` stops it and `Esc`
closes it. The status bar is read again when it ends, so `: preset use favourite` shows the preset
at once. Commands that stream (`watch`, `stream`, `events`, `tui`) point at the view that does
the same instead. `eq …` in front names the command when a screen action has the same name
(`eq zones`).

### Keys

| Key | Russian | Where | Action |
| --- | --- | --- | --- |
| `g` | `п` `П` | every view | go to a view: m meter, t tune, i instruments, p presets, d devices, f filters, e events; a menu lists them |
| `;` `Ctrl-P` | `ж` | every view | the command palette: any eq command, run beside the screen |
| `u` | `г` `Г` | every view | undo the last change made in this session, back to how it started |
| `m` | `ь` `Ь` | every view | mouse on and off, remembered as tui.mouse in eq.json; on, a click on a tab opens it, a click on a band or a control in Tune or on a list's row selects it, and the wheel scrolls a list or steps what it is over |
| `?` `h` | `р` `Р` | every view | the list of every key; ?, Esc or q closes it |
| `q` | `й` `Й` | every view | quit |
| `Ctrl-C` |  | every view | quit, from the lists too |
| `Ctrl-Z` |  | every view | suspend to the shell; fg brings the screen back as it was |
| `y` `Y` | `н` `Н` | every view | next look: studio → console / next palette: ink → paper → brass; saved as tui.look and tui.palette |
| `1` … `9` `0` |  | Meter | raise band 32 Hz … 16 kHz by 0.5 dB (0 is the tenth band, 16 kHz) |
| `⇧1` … `⇧0` | `"` `№` `:` | Meter | lower it by 0.5 dB: ! @ # $ % ^ & * ( ) on a US layout |
| `+` `-` |  | Meter | preamp ±0.5 dB (= and _ work too, no Shift needed) |
| `b` `B` `t` `T` | `и` `И` `е` `Е` | Meter | bass / treble shelf +0.5 dB, with Shift −0.5 dB |
| `p` `↓` `↑` | `з` `З` | Meter | next preset (p, ↓) / previous one (↑), alphabetically, wrapping round |
| `c` | `с` `С` | Meter | compressor: off → gentle → night → off |
| `v` `V` | `м` `М` | Meter | colour: off → tape → tube → off, starting at 0.3 / raise the amount by 0.1, from 1 back to 0.1 |
| `s` | `ы` `Ы` | Meter | save the curve as a preset: type a name, Enter saves, Esc cancels |
| `z` | `я` `Я` | Meter | the instrument strip, on and off |
| `i` | `ш` `Ш` | Meter | the Instruments view: ranges in Hz, the bands each touches, knob gains, levels; Esc comes back |
| `]` `Tab` `[` | `ъ` `Ъ` `х` `Х` | Meter | focus the next / previous instrument |
| `→` `←` | `ю` `Ю` `б` `Б` | Meter | the focused instrument's knob ±0.5 dB (. and , work too, no Shift needed) |
| `l` | `д` `Д` | Meter | listen to the focused instrument alone, and back |
| `Esc` |  | Meter | leave the focus (and stop listening); with no focus, back to the view before |
| `←` `→` |  | Tune | select the band, or the preamp, bass, treble, tilt, compressor, colour and its amount after them |
| `↑` `↓` `k` `j` | `л` `о` | Tune | the selected control ±0.5 dB (tilt ±0.1 dB/octave, amount ±0.1, a mode the next one); lowers a band on any layout |
| `⇧↑` `⇧↓` `PgUp` `PgDn` |  | Tune | ±3 dB (tilt ±0.5, amount ±0.3) |
| `Alt↑` `Alt↓` |  | Tune | ±0.1 dB (tilt ±0.05, amount ±0.05) |
| `Enter` |  | Tune | type the selected control's value in the message row: -3, 2.5, night, tape |
| `0` `Backspace` `Del` |  | Tune | the selected control back to 0, a mode or the colour off |
| `Tab` `⇧Tab` |  | Tune | the next / previous group: bands, chain (preamp, tone, tilt), dynamics; each keeps its selection |
| `1` … `9` |  | Tune | raise band 32 Hz … 8 kHz by 0.5 dB, as on the meter; 0 resets here, so 16 kHz goes up with ↑ |
| `⇧1` … `⇧0` | `"` `№` `:` | Tune | lower band 32 Hz … 16 kHz by 0.5 dB, as on the meter |
| `s` | `ы` `Ы` | Tune | save the curve as a preset |
| `d` `D` | `в` `В` | Tune | edit the next / previous device's curve, playing or not; the playing one comes first |
| `Esc` |  | Tune | back to the view before |
| `↑` `↓` `j` `k` | `л` `о` | Instruments | move between the instruments |
| `Home` `End` |  | Instruments | the first / the last instrument |
| `Enter` |  | Instruments | focus the instrument on the meter |
| `→` `←` | `ю` `Ю` `б` `Б` | Instruments | its knob ±0.5 dB (. and , work too) |
| `l` | `д` `Д` | Instruments | listen to it alone, and back; it becomes the meter's focus |
| `Esc` |  | Instruments | back to the view before |
| `↑` `↓` `j` `k` | `л` `о` | Presets | move between the presets |
| `PgUp` `PgDn` `Home` `End` |  | Presets | a page up / down, the first / the last |
| `Enter` |  | Presets | play it on the current device, as eq preset use does |
| `s` | `ы` `Ы` | Presets | save the current device's curve as a preset: type its name in the message row, Enter saves |
| `r` | `к` `К` | Presets | rename it; devices and app rules that name it follow |
| `d` | `в` `В` | Presets | delete it once y answers the question in the message row; devices that used it keep the curve |
| `v` | `м` `М` | Presets | compare it with the current device's curve: both drawn, and what differs listed |
| `Esc` |  | Presets | back to the view before |
| `↑` `↓` `j` `k` | `л` `о` | Devices | move between the outputs and the profiles of devices not connected |
| `PgUp` `PgDn` `Home` `End` |  | Devices | a page up / down, the first / the last |
| `Enter` |  | Devices | make it the system's output, as eq device use does; in driver mode the EQ device plays on it instead |
| `c` | `с` `С` | Devices | copy the current device's curve to it, as eq device copy --to does |
| `e` | `у` `У` | Devices | edit its curve in Tune, whether it plays or not |
| `Esc` |  | Devices | back to the view before |
| `↑` `↓` `j` `k` | `л` `о` | Filters | move between the filters |
| `PgUp` `PgDn` `Home` `End` |  | Filters | a page up / down, the first / the last |
| `Enter` `→` |  | Filters | change the filter in place: ← → pick its type, frequency, gain or Q, ↑ ↓ change it |
| `a` | `ф` `Ф` | Filters | add a filter: a row under the others to set its type, frequency, gain and Q, Enter adds it |
| `d` | `в` `В` | Filters | remove it once y answers the question in the message row |
| `Esc` |  | Filters | back to the view before |
| `←` `→` |  | a filter's fields | the type, the frequency, the gain or Q |
| `↑` `↓` `k` `j` | `л` `о` | a filter's fields | change it, saved at once: the next type, a sixth of an octave, 0.5 dB, Q 0.1 |
| `⇧↑` `⇧↓` `PgUp` `PgDn` |  | a filter's fields | an octave, 3 dB, Q 1 |
| `Alt↑` `Alt↓` |  | a filter's fields | a 24th of an octave, 0.1 dB, Q 0.01 |
| `Enter` `Esc` |  | a filter's fields | done: ↑ ↓ move between the filters again |
| `←` `→` `Tab` |  | new filter | the type, the frequency, the gain or Q |
| `↑` `↓` `k` `j` | `л` `о` | new filter | change it: the next type, a sixth of an octave, 0.5 dB, Q 0.1 |
| `⇧↑` `⇧↓` `Alt↑` `Alt↓` |  | new filter | coarse: an octave, 3 dB, Q 1; fine: a 24th of an octave, 0.1 dB, Q 0.01 |
| `Enter` |  | new filter | add it, as eq filter add does |
| `Esc` |  | new filter | cancel |
| `↑` `↓` `j` `k` | `л` `о` | Events | scroll the log |
| `PgUp` `PgDn` `Home` `End` |  | Events | a page up / down, the oldest / the newest |
| `Space` |  | Events | pause the log and go on; events keep arriving underneath, the panel counts them |
| `/` | `.` | Events | show only events whose kind or text has what you type |
| `Esc` |  | Events | clear the filter, then back to the view before |
| `g` `m` | `ь` | after g | the meter |
| `g` `t` | `е` | after g | the curve to edit: bands as sliders, preamp, tone, dynamics |
| `g` `i` | `ш` | after g | the instruments, their knobs and levels |
| `g` `p` | `з` | after g | the presets: apply, save as, rename, delete, compare |
| `g` `d` | `в` | after g | the outputs and their curves: use one, copy the curve to one, edit one |
| `g` `f` | `а` | after g | the current device's parametric filters: add, change, remove |
| `g` `e` | `у` | after g | the daemon's events as they happen |
| `Esc` |  | after g | stay; any other key does too |
| `Enter` |  | palette | run the chosen line: an eq command as a child process, or a screen action |
| `Tab` |  | palette | take the chosen suggestion into the line |
| `↑` `↓` |  | palette | choose a suggestion; with the line empty, the last commands run come first |
| `Esc` |  | palette | close it |
| `↑` `↓` `j` `k` | `л` `о` | command output | scroll |
| `Ctrl-C` |  | command output | stop the command |
| `Esc` `q` | `й` `Й` | command output | close it; a command still running is stopped |

The bottom row is the keybar: the keys of the view on screen, then those every view shares,
most useful first, whole entries dropped from the right when the terminal is narrow, `? keys` and
`q quit` always kept. It never hides. The row above it holds the save-as prompt, the palette's
line and the notes that last two seconds, and stays reserved when empty, so a note never moves the
meter. Below ten rows the two share one row and the keybar is only `? keys  q quit`. `z` shows its
state on the keybar (`z zones on`), and while an instrument is focused its knob, `l listen` and
`Esc unfocus` join it.

`?` or `h` opens the list of every key over the view, grouped: the view's own keys first, then
those of every view, `g`'s letters, the palette's and the command output's. It stays until `?`,
`Esc` or `q` closes it; `↑`/`↓` (`j`/`k`) scroll it when it is taller than the terminal. Keys under
it do nothing to the curve. `m` turns mouse reporting on and remembers it as
`"tui": {"mouse": true}` in eq.json; it is off by default because it takes plain drag-to-select
away from the terminal; on, a click on a tab opens that view, a click on a band or a control in
Tune or on a row of Presets, Devices or Filters selects it, and the wheel scrolls the lists and steps whatever it is over in Tune. The table
above is generated from the same key table the TUI reads its keys from, and a test keeps the two
equal.

Ctrl-Z hands the terminal back to the shell and `fg` brings the screen back as it was. The
terminal is put back the same way when the TUI is closed with `kill`, loses its terminal, or
crashes, so the shell is left usable. When the daemon goes away `eq watch` ends with exit 1;
`eq tui` says "daemon gone — reconnecting" in the message row and picks the meter up again once
the daemon is back.

Each frame writes only the cells that changed since the last one, in a single write wrapped in
synchronized-update brackets (`ESC [?2026h` … `ESC [?2026l`), so a terminal that knows them never
shows half a frame; one that answers that it does not know the mode gets no brackets. Levels that
stand still cost no output at all.

A step edits the current device's profile — the same one `eq set` would: the daemon's device,
else the default output — clamps to ±12 dB (preamp −30…+12), and saves at once; the daemon
picks it up and the curve moves on the next frame, while the band's gain chip turns solid for
half a second (the console's fader cap lights up). When the edit cannot be saved (no config yet,
say), the reason shows in the message row behind a `✗` for two seconds. Every letter key works from the same physical key on a Russian
layout, as the table's middle column shows. Three keys collide there, and the US meaning wins:
Shift+7 types `?`, the key list, so band 7 (2 kHz) is lowered from a US layout; Shift+4 types
`;`, the palette's key, so band 4 (250 Hz) is too; and the key that types `?` on a US layout
types `,`, which turns the knob down, so `h` (`р`) opens the key list there.

The header names the device's preset after the preamp, with the yellow `*` once the curve has
moved away from it. Bass, treble and tilt follow it when set: `bass +3 treble -2`, then the
instrument knobs that are set, each behind a dot in its colour, and the focused one even at 0:
`● voice +3.0`, then the compressor with its live reduction and the colour:
`night comp -3.2 │ tape 0.3`. The peak sits at the right edge, and SOLO, BYPASS and LIMIT as solid
flags after it; LIMIT stays lit a third of a second after the limiter lets go, so a one-frame
limit is seen. `p` applies the presets in turn, as `eq preset use` would. `u` walks back
through this session's steps, preset changes included, one per press, until the curve is as it
was when the session started; it does not reach past the session — that is `eq undo`. `s`
turns the message row into `save as: ▏`; while it is open every key types into it, digits
included, Backspace deletes, and a bad name shows its error in the same line for two seconds.

### Instruments

`z` (or `eq watch --zones`) opens a strip under the gain chips (in the compact rows, directly
above the level row): one row per instrument — kick, bass, snare, guitar, piano, voice, cymbals, air — with each of its
ranges drawn as a `━` span on the same frequency axis as the bars. A bar stands for the octave
around its band, so a range that starts at 85 Hz begins between the 64 Hz and 125 Hz bars, not
on either. Neighbouring ranges of one instrument are kept apart by a gap, and a range's name
(`F1`, `thump`, `sibilance`) is written into its span when it fits. Each instrument has its own
colour, warm to cool from kick to air, the same in the strip, the bracket, the knobs and the
instrument table; a row is in full colour while any of its bands is above −20 dBFS and faded
otherwise. The strip takes its rows from the meter; on a short terminal the lowest instruments
drop.
`eq zones` prints the same table in Hz with the bands each range touches.

```
 ◉ BE-RCA  44.1 kHz │ preamp -4.8 dB │ ◆ favourite* │ ● voice +3.0 │ focus: voice (85 Hz–9 kHz)     peak -6.0 dB  SOLO
╭─ meter ─────────────────────────────────────────────────────────────────── dBFS · gain dB ╮╭─ output ────────────────╮
│                    ┌────────────┐ ┌─── F1 ────┐ ┌── F2 ──┐ ┌──────┐ ┌────┐                ││ peak ███████████·▏  -6.0│
               ...
         -9      -8      -11     -15     -19     -17     -22     -26     -29     -37
        32Hz    64Hz    125Hz   250Hz   500Hz   1kHz    2kHz    4kHz    8kHz    16kHz
        +4.8    +4.0    +4.2    +2.3     0.0    -3.1     0.0     0.0    +3.1    +2.4
 vox                 ━━━━━━━━━━━━━━ ━━━━ F1 ━━━━━ ━━━ F2 ━━━ ━━━━━━━━ ━━━━━━
 ! listening to voice alone: 85 Hz–9 kHz — l again or Esc to stop
```

`]` or `Tab` focuses the next instrument, `[` the previous one, `Esc` lets go. While focused,
the header says `focus: voice (85 Hz–9 kHz)`, a bracket row above the bars marks each of its
ranges in the instrument's colour — the character range bright, the rest faded — the bars,
labels and gains of bands it does not touch fade toward the ground, its level numbers turn bold,
and the panel's border and the instrument's knob row light up. The strip, when open, shows only that instrument. Digit keys still name all ten
bands, but a band outside the focus is refused with `outside voice — Esc to unfocus` in the
message row, so tuning stays on the instrument. A band belongs to the focus when any of the
instrument's ranges overlaps the octave around the band's centre, which is why voice reaches
down to the 64 Hz band.

`l` listens to the focus alone: the daemon adds a steep high-pass and low-pass at the edges
of the instrument's character range (voice is heard at 2–5 kHz, not across its whole
85 Hz–9 kHz, which isolates little), and the header shows a yellow `SOLO` flag for as long as the daemon reports
it. Switching focus moves the solo to the new instrument. `l` again, `Esc` and `q` switch it
off; so does the watch going away in any other way, since the daemon drops a solo the moment
the client that asked for it disconnects. At a rate too low for the focus (air on a headset
in call mode) the message row says `can't listen to air at this rate` and nothing plays solo until
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
| `app` | `app`, `name`, `preset` (or `null`) | an app rule starts or stops being heard (experimental) |
| `mode` | `mode` (`tap` or `driver`), `target` (or `null`), `reason` (or `null`) | the path changes; `reason` says why the tap runs in driver mode |
| `target` | `device`, `uid` | in driver mode, the EQ device plays on another real device |

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
terminal too. `eq watch` and `eq tui` go further where the terminal can: 24-bit or 256 colours,
with these sixteen as the fallback (see [Looks](#looks)).

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

## Driver mode (experimental)

Tap mode, the default, needs the System Audio Recording permission, and macOS shows its Privacy
indicator while eq runs. Driver mode plays through a virtual output device instead, **"BE-RCA · EQ"**
(named after the real device it plays on), from a Core Audio plug-in in `Driver/`: apps play to it,
and the plug-in runs the same EQ, compressor, colour and limiter on the real device. Nothing
records audio, so there is no permission and no indicator, and the device reports its whole latency,
so video players keep lip sync. It breaks Apple's rule that a plug-in may not use the HAL client
API, which is how it plays on the real device; see `docs/research/06a–06c`.

```sh
eq mode driver
```

The first time, it installs the driver EQ.app carries: one administrator prompt (sudo in a
terminal, a macOS dialog otherwise), a copy to `/Library/Audio/Plug-Ins/HAL`, and a coreaudiod
restart, which drops every app's sound for about a second; eq waits for the EQ device, then
switches. It shows the device, points it at the current output, sends it that output's curve,
makes it the default output and writes `"mode": "driver"` to `eq.json`; the daemon then stops its
tap. `eq mode` shows the mode and the driver's build, `--dry-run` says what a switch would do,
password prompt included.

After `brew upgrade eq` the driver in `/Library` stays and keeps playing. When the new EQ.app carries
a newer one, `eq status`, `eq mode` and `eq doctor` say so, and `eq mode driver` updates it with the
same one prompt; until then nothing asks. Only a driver too old to read this eq's settings sends the
daemon back to the tap until you run it. The daemon never asks for a password. A driver disabled by
its kill file (below) is never replaced.

From a checkout: `Driver/build.sh && sudo Driver/dev-install.sh` (see `Driver/README.md`).

While the daemon runs in driver mode:

- Keep picking real devices in the Sound menu. When the default output becomes a real device, eq
  plays on it with its curve and makes the EQ device the default again, 0.4 s after the last change,
  so clicking through the menu costs one switch. Virtual devices, aggregates and AirPlay are left
  alone as the default, and if something moves the default more than three times in 10 s, eq stops
  taking it back for 30 s.
- Every change to the config, a preset, an app rule, `eq on|off`, the dynamics or a solo is sent to
  the plug-in, which keeps the last curve per device and plays it without the daemon, across
  coreaudiod restarts.
- `eq status` shows `mode: driver (BE-RCA · EQ → BE-RCA)`, the latency the device reports, and the
  plug-in's IO, underruns, overruns, clock correction and whether it plays a curve; `eq watch`
  reads the plug-in's meter; `eq events` adds `mode` and `target` events; `eq doctor` adds driver rows.
- If the EQ device is missing when the daemon starts, or stays gone for 3 s, the daemon runs the
  tap and says why in `eq status`, `eq mode` and `eq doctor`, rather than leave you without EQ; it
  goes back to the driver when the device returns.

In tap mode the EQ device is hidden and never the default output. `"driver": {"hideWhileDefault":
true}` tries hiding it while it is the default too; `eq doctor` reports whether macOS kept it.

### Back to tap mode, and recovery

```sh
eq mode tap
```

It writes the mode first, moves the default output back to the real device, then hides the EQ
device, each step giving up after 2 s, so a hung plug-in cannot hang it. If the default output
cannot be moved, it says so and prints the next steps. In order, stop at the first that brings sound back:

1. `sudo killall coreaudiod` (launchd starts it again).
2. Disable the plug-in with its kill file:
   `sudo touch /Library/Audio/Plug-Ins/HAL/EQDriver.driver/Contents/Resources/disabled && sudo killall coreaudiod`.
3. Remove it: `eq driver uninstall`, or `sudo rm -rf /Library/Audio/Plug-Ins/HAL/EQDriver.driver && sudo killall coreaudiod`.

`Driver/README.md` has more on the plug-in.

## Footprint

Measured with `scripts/footprint.sh` while a tone played over Bluetooth at 44.1 kHz.

| Metric | v2 (installed) | v3 (release @256) |
| --- | --- | --- |
| physical footprint | 6.4 MB | 5.2 MB |
| CPU while playing | 0.30 % | 0.30 % |
| context switches | 189 /s | 191 /s |
| status.json writes | 12 /min | ≤ 2 /min (30 s heartbeat + changes) |
| log | unrotated | capped by the cleanup job |
| `brew uninstall` | agent stays loaded | daemon exits with its binary, the EQ driver is removed; `eq agent uninstall` first removes the login item; `--zap` also unloads both jobs and removes a hand-installed plist |

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
- One curve per device, applied to everything on that device. An app rule swaps the whole
  system's curve while that app plays; it does not give two apps two curves at once.
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
