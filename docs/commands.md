# Commands

| Command | |
| --- | --- |
| `eq` | the curve in effect on the current output |
| `eq status [--json]` | is the daemon alive, on which device, at what rate |
| `eq watch [--zones] [--look LOOK] …` | the live equalizer in the terminal; tune from the keyboard, `?` lists every key, `y` switches the look, `q` quits; the flags are under [Looks](tui.md#looks) |
| `eq tui [meter\|tune\|instruments\|presets\|devices\|filters\|apps\|system\|history\|events] [--zones] [--look LOOK] …` | the terminal UI, opened on the meter (the same screen as `eq watch`), the curve to edit, the instruments, the presets, the outputs, the filters, the app rules, the daemon and its doctor, the saved versions or the daemon's events; `;` opens a palette of every command |
| `eq zones [--json]` | the instruments' frequency ranges in Hz and the bands each one touches |
| `eq export > config.txt` | the curve as Equalizer APO text; `--format graphiceq\|eqmac\|camilla\|json`, `--out FILE` |
| `eq stream` | meter frames as JSON lines, 30 a second, until Ctrl-C; `solo` is the range being listened to, or `null`; `spectrum` the output's 31 third octaves from 20 Hz to 20 kHz in dBFS, absent while the daemon, or in driver mode the EQ driver, predates it |
| `eq events` | state changes as JSON lines until Ctrl-C: device, rate, profile, enabled, solo, daemon, app, mode, target, silent; never meter ticks |

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
| `eq device silence "Mac Studio Speakers"` | that output plays nothing, whatever the volume; `unsilence` undoes it (see [Silent outputs](#silent-outputs)) |
| `eq preset list` | list presets; the current device's one marked `*` (`eq preset` alone too) |
| `eq preset save\|use <name>` | save the current curve as a preset / apply one (`--device DEVICE` for another device) |
| `eq preset show\|rm <name>`, `eq preset rename <old> <new>` | look at, delete, rename a preset |
| `eq app set Spotify favourite` | while Spotify plays, hear the `favourite` preset (experimental, see [Curve per app](curve.md#curve-per-app-experimental)) |
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
| `eq mode [driver\|tap]` | show or switch the audio path; see [Driver mode](driver-mode.md) |
| `eq completions zsh\|bash\|fish` | the shell completion script |
| `eq man` | the man page, as roff |
| `eq --version`, `eq -V`, `eq version` | this eq's version; `--json` adds the build number |

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

## Silent outputs

`eq device silence DEVICE` keeps an output silent, for the speakers that take over when headphones
drop: macOS moves the sound there, and there it stays silent while you reach for the volume.
`eq.json` lists it under `"silent"`, by UID; `eq device list`, `eq` and the TUI mark it.

While the daemon runs, eq holds the hardware mute of every connected silent output, playing or
not, so the first sample that lands on it after a switch is already muted; volume keys or Control
Center unmuting it are undone at once, and `eq events` says so. On a silent output that plays, eq
also sends zeros, in tap and driver mode alike, `eq off`, a solo and an app rule included, which
covers a device without a mute control. `eq device unsilence` puts its mute back as it was before
eq set it, at once or when the device next appears. `eq doctor` has a `silent` row on how each one
is held.

Without the daemon, only the mute eq left set holds, and the volume keys can lift it; in driver
mode the EQ driver this eq bundles also keeps playing zeros on it (see [Driver mode](driver-mode.md)).

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

## Colour

On a terminal the output uses the sixteen standard terminal colours, each with one meaning
everywhere: green for a boost, a healthy check or a running engine, magenta for a cut,
yellow for a warning or a device on the default profile, red for a failure. `eq` and the
other curve-printing commands add a spark row of block glyphs above the band labels, so the
curve's shape reads at a glance. Piped or redirected output has no colour and no spark row,
so it keeps the three-line shape above; `NO_COLOR` or `TERM=dumb` turn colour off on a
terminal too. `eq watch` and `eq tui` go further where the terminal can: 24-bit or 256 colours,
with these sixteen as the fallback (see [Looks](tui.md#looks)).

`eq --help` is grouped into look, tune and setup, with commands bold, flags cyan and
placeholders such as `DEVICE` yellow; descriptions wrap inside their column at the terminal's
width, and below 60 columns each description moves under its command. `eq <command> --help`
shows one command, and a usage error shows only the command it is about. `--json` on a
terminal is coloured like `jq`; piped, it is the same bytes as before, and `eq stream` is never
coloured. `NO_COLOR` turns all of it off.
