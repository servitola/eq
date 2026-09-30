# Changelog

What changed for someone who uses the tool. Keep the `Unreleased` heading; a release moves
its entries under a dated version.

## Unreleased

### Changed

- The response curve on the Meter, in Tune and beside the preset lists is one clean braille line:
  the green and magenta blocks between it and 0 dB are gone, and a level bar it crosses keeps its
  own colour instead of being tinted.

## 2026.09.30.2 — 2026-09-30

### Added

- The Meter is a spectrum analyser: 31 third-octave bars from 20 Hz to 20 kHz with peak ticks,
  rising at once and falling at 20 dB a second. `eq stream` frames carry them as `spectrum`. In
  driver mode they need the EQ driver this eq bundles (`eq mode driver` updates it, with a
  password); an older driver, or an older daemon still running, meters the ten bands as before.

### Changed

- The response curve on the Meter is a solid line with a dot on each band, the band just edited
  labelled with its gain, and it moves to a new preset or edit over 300 ms instead of jumping.
- Faint lines at 0, −12, −24, −36 and −48 dBFS; the level scale is in the bars' colours under
  `level dBFS`, the gain scale in the curve's under `EQ dB`.

## 2026.09.30.1 — 2026-09-30

### Added

- The Apps view (`g a`, or `eq tui apps`): the app rules with their presets, the one heard now
  marked as the daemon's events say, a rule whose preset is gone in yellow, and the apps with
  audio open. `a` adds a rule from a list of those apps (or an app typed by bundle ID or name),
  then a preset; `Enter` gives a rule another preset, `d` removes it after a `y`, `o` turns
  following apps on and off. Routes in eq.json are shown under them, read only, with where each
  app plays now and why, and why none plays in driver mode.
- The System view (`g s`): the daemon's state, the mode asked for and the one running, device,
  rate, latency, slips, versions and the launch agent; in driver mode the driver's health
  (target, IO, EQ, slips, clock, default output, writer). Beside them `eq doctor`, run beside
  the screen when the view opens and on `r`, each check `✓`, `!` or `✗` with the chosen one's
  whole text. `o` switches mode after saying what a dry run says, with `eq mode`'s output in the
  command pane; a switch that must install the driver is left to a shell, where macOS asks for the
  password.
- The History view (`g h`): every saved version of eq.json with its time, curve and preset, the
  live one marked, and the chosen one drawn over the live one with what differs. `Enter` restores
  it the way `eq undo` and `eq redo` would, `←` and `→` step one version.
- `/` jumps to a row on Presets, Devices, Apps and System, and filters the key list.
- With the mouse on, a second click on the chosen row does what `Enter` does.
- On Filters, `=` or a digit types a field's value, read as `eq filter set` reads it (`3k`, `-2,5`).
- `eq man` has a KEYS section, generated from the same table as the key list and the README.

### Changed

- `Esc back` is on the keybar only when there is a view to go back to.
- Where ten tabs do not fit, they lose their padding, then shorten to three letters.

## 2026.09.30 — 2026-09-30

### Added

- The Presets view (`g p`, or `eq tui presets`): every preset with a spark of its ten gains and
  its preamp, the current device's marked, and beside them the chosen one's curve and layers.
  `Enter` applies it, `s` saves the current curve as a new one, `r` renames it, `d` deletes it
  once `y` answers the question in the message row, which says what the delete leaves behind;
  `v` compares it with the current device's curve.
- The Devices view (`g d`): the outputs connected and the devices with a curve of their own, how
  each is connected, which one plays, whose curve it has, and the chosen one's curve. `Enter`
  makes it the system's output (in driver mode the EQ device plays on it instead, and the EQ
  device itself is shown but never offered), `c` copies the playing curve to it, `e` edits its
  curve in Tune whether it plays or not.
- The Filters view (`g f`): the current device's parametric filters as a table, changed in place
  with the arrows (`⇧` coarse, `Alt` fine), a row to add one with `a`, `d` to remove one after a
  `y`; under them the filters' combined response with the chosen one's own lit.
- In Tune, `d` and `D` switch the curve being edited to another device's, playing or not.
- Everything these views change is the change its `eq preset`, `eq device` or `eq filter`
  command makes, saved as part of the session's one undo step; `u` walks back through presets,
  app rules and other devices' curves too.

## 2026.09.29.5 — 2026-09-29

### Added

- The Tune view (`g t`, or `eq tui tune`): the curve to edit. The whole chain's response on top
  with a node per band, the ten bands as sliders with their gains and a live mini-meter each,
  and the chain beside them: preamp, bass, treble, tilt, compressor, colour and its amount, and
  the output (peak, limiter, and how far the curve with the preamp would clip, which the
  response's title says too). `←`/`→` select, `↑`/`↓` step 0.5 dB, `⇧↑`/`⇧↓` or `PgUp`/`PgDn`
  3 dB, `Alt↑`/`Alt↓` 0.1 dB, `0`, `Backspace` or `Del` reset, `Enter` types a value, `Tab`
  jumps between bands, chain and dynamics. Arrows work on any layout, so every band goes up and
  down from a Russian one without Shift. Edits save at once as one undo step for the session;
  `u` walks back. With the mouse on, a click selects a band or a control and the wheel steps it.
  In the console look the sliders are faders on channel strips.

## 2026.09.29.4 — 2026-09-29

### Added

- `eq tui` and `eq watch` have views: a row of tabs under the status bar names them, `g` and a
  letter goes there (a small menu lists the letters after `g`), a click on a tab too with the
  mouse on, and `Esc` goes back. `eq tui instruments` and `eq tui events` open on one.
- The Instruments view (`g i`, or `i` on the meter): every instrument with its knob, a live
  mini-meter of its bands, its ranges in Hz on a frequency map and the bands they touch, and the
  ten bands as they sound now. `←`/`→` turn the chosen knob, `l` listens to it alone, `Enter`
  focuses it on the meter.
- The Events view (`g e`): the daemon's events as a log in colour, `Space` to pause, `/` to
  filter. The status bar follows them on every view.
- The command palette on `;` (`ж`) or Ctrl-P: every `eq` command and the screen's own actions,
  fuzzy-matched, with presets, devices, instruments, bands, formats and apps completed as you
  type. A command runs beside the screen, which keeps drawing; its answer shows in the message
  row, or in a panel with its colours when it is longer, and the status bar is read again after.
  The last 100 lines run are kept in `~/.cache/eq/tui-history`.
- `CLICOLOR_FORCE` makes eq paint when its output is a pipe, and `COLUMNS` sets the width it lays
  out for there.

### Changed

- `i` opens the Instruments view instead of the table over the meter, and `?` lists the keys of
  the view on screen first. The meter is one row shorter at 14 rows and more, for the tabs.
- On the Events view the meter connection is closed, so the daemon's meter work stops; levels
  that stand still no longer rebuild the screen.

## 2026.09.29.3 — 2026-09-29

### Added

- `eq watch` and `eq tui` come in two looks. `studio`, the default: a boxed meter with bars
  painted by height (green, amber, red at −18 and −6 dBFS), peak ticks that hold 1.5 s, the EQ's
  response drawn over the bars in braille with boost and cut tinted, a dBFS and a gain scale,
  gain chips, and at 110 columns a column of gauges (output, compressor, colour, tone, knobs).
  `console`: a mixing desk of channel strips with tape labels, LED ladders, readouts and faders,
  lamps for SOLO, BYPASS and LIMIT, and at 110 columns a master section with a gain-reduction
  needle. Each instrument has one colour everywhere: strip, bracket, knobs, instrument table.
- `y` switches the look and `Y` the palette (`ink`, `paper`, `brass`), remembered in eq.json as
  `tui.look` and `tui.palette`; Russian `н` and `Н` do the same.
- `--look`, `--palette`, `--colors 24bit|256|16|none`, `--meter bars|leds`, `--curve`/`--no-curve`,
  `--scale`/`--no-scale`, `--peaks`/`--no-peaks` and `--background terminal|theme` for one run, and
  the same names under `tui` in eq.json. Colour depth is read from `COLORTERM` and `TERM`;
  `NO_COLOR` and `TERM=dumb` keep the look in monochrome, carried by reverse video.

### Changed

- The watch's screen is new: the `▬` slider marker is gone (the curve and the gain chips show the
  gains), the header is a bar of segments with the peak and flags at its right, the keys on the
  keybar are keycaps, and a note in the message row is marked `✓`, `!` or `✗`. The key list and
  the instrument table open as rounded panels over a faded meter. The keys are unchanged.

- `eq watch` and `eq tui` draw only the cells that changed, each frame in one write wrapped in
  synchronized-update brackets: about 1.2 KB a frame at 120×40 with music instead of 7 KB, and
  nothing at all while the levels stand still. The screen itself is unchanged.
- `eq tui` stays open when the daemon goes away: "daemon gone — reconnecting" shows in the message
  row and it reconnects on its own (after 0.5, 1, 2, then every 4 s). `eq watch` still ends with
  exit 1, as before.

### Fixed

- A lone Esc is read at once even while no frames arrive, instead of on the next 0.1 s wake-up.

## 2026.09.29.2 — 2026-09-29

### Added

- `eq watch` keeps a keybar on its bottom row that never hides: the keys of what is on screen,
  `? keys` and `q quit` always there, `z zones on/off` with its state, and the focused
  instrument's keys while one is focused. The 8-second key box and `x` are gone.
- `?` or `h` opens the list of every key over the meter until `?`, `Esc` or `q` closes it; `i`
  opens the instrument table (ranges, bands, knob gains) the same way.
- `eq tui [meter] [--zones]`: the terminal UI, opened on the meter view, today the same screen as
  `eq watch`.
- `m` turns mouse reporting on and off and remembers it as `tui.mouse` in eq.json; off by default.
  For now the wheel scrolls the two lists. `;` (`ж`) and Ctrl-P are kept for the command palette.

### Fixed

- `eq watch` took a whole CPU core and fell behind the daemon's 30 frames a second; it now takes
  about 5 %.
- Ctrl-Z in `eq watch` left the alternate screen up; now the shell gets its screen back and `fg`
  redraws the watch. `kill`, a lost terminal and a crash put the terminal back too.
- A resize while no frames arrive redraws at once, not on the next key.
- Below ten rows nothing scrolls the screen any more: the notes and the keybar share one row.
- A stray UTF-8 lead byte no longer holds back the key typed after it.
- On a Russian layout Shift+4 types `;`, now the palette's key, so 250 Hz is lowered from a US
  layout, as 2 kHz already was.

## 2026.09.29.1 — 2026-09-29

### Added

- EQ.app carries the driver for driver mode, so one `brew install` is all a Mac needs. The first
  `eq mode driver` installs it into `/Library/Audio/Plug-Ins/HAL` with one administrator prompt
  (sudo in a terminal, a macOS dialog otherwise), restarts coreaudiod and waits for the EQ device;
  `--dry-run` says so first. After an upgrade that carries a newer driver, `eq status`, `eq mode`
  and `eq doctor` say so and `eq mode driver` updates it; the old one keeps playing meanwhile.
- `eq driver uninstall`: tap mode, then the driver removed and coreaudiod restarted.
  `brew uninstall eq` runs it; `brew upgrade` and `brew reinstall` leave the driver in place.

## 2026.09.29 — 2026-09-29

### Added

- Driver mode, experimental: `eq mode driver` plays through the EQ device from `Driver/` instead of
  a process tap, so no recording permission and no Privacy indicator. The daemon keeps the EQ device
  the default output and follows the real device you pick in the Sound menu; `eq mode tap` goes back,
  moving the default output first and never waiting more than 2 s on the plug-in. `eq status`,
  `eq doctor`, `eq watch` and `eq events` cover it. Install the plug-in with `Driver/dev-install.sh`
  for now.

### Fixed

- One NaN or infinite sample from an app no longer leaves eq silent until a long pause resets it.
  It made the filters' and the compressor's history NaN, and every later block with it, and left
  the limiter off; such a sample now plays as 0, and history that overflows anyway is cleared
  within the block it overflowed in.

## 2026.09.28.9 — 2026-09-28

### Fixed

- `eq comp gentle` no longer tilts the mix towards bass. Its detector ignored everything below
  100 Hz, so on a curve that boosts bass it heard the mix as quieter than it is, took little off,
  and its fixed +3 dB makeup then played it up to 3 LU louder than with the compressor off, which
  on such a curve is heard as more bass. The detector now hears through BS.1770's K-weighting,
  and gentle's makeup gives back the reduction it averaged over the last 3 seconds instead of a
  fixed amount: on the `favourite` curve, test music and pink noise now move by less than 1 LU
  and no octave band by more than 0.4 dB against the others. `night` hears bass too now, so explosions
  come down further against dialogue.

## 2026.09.28.8 — 2026-09-28

### Added

- `eq comp none` turns the compressor off, like `eq comp off`; the mode is read in any case.

## 2026.09.28.7 — 2026-09-28

### Added

- Curve per app, experimental and off by default: `eq app set Spotify favourite` makes the
  daemon play that preset while Spotify plays and go back to the device's curve when it stops,
  without writing `eq.json` or history. `eq app list|rm|on|off`; `eq`, `eq status` and
  `eq watch` show `app: Spotify → favourite`; `eq events` sends an `app` event; `eq doctor` has an
  `apps` row while it is on. One curve for the whole system at a time: two apps playing together
  share the winner's.
- `eq comp gentle|night|off`: light compression after the EQ, linked across channels, with a
  detector that ignores deep bass and automatic makeup. `gentle` (2:1 from −18 dBFS) glues
  music; `night` (4:1 from −30 dBFS) brings quiet dialogue up and explosions down.
- `eq color tape|tube <amount>` and `eq color off`: saturation after the compressor, as loud as
  before. `tape` is a symmetric soft clip, `tube` adds even harmonics.
- Switching the compressor or the colour on, off, or to another mode, kind or amount glides
  over about 10 ms, without a click or a jump in level.
- Both are stored per profile as `dynamics`, travel with presets, undo, history and eq's own JSON
  export, and are dropped by `eq flat`. `eq` shows a `dynamics:` line. Other export formats warn
  and export the EQ alone. A mode or kind eq does not know is kept and ignored rather than
  rejecting `eq.json`; the daemon logs it, `eq doctor` warns, and `eq comp` or `eq color` replaces it.
- `eq status` shows the compressor's gain reduction (`compReductionDB` in JSON); `eq watch`
  shows it live in the header and `eq stream` frames carry it as `comp`. In `eq watch`, `c`
  cycles the compressor, `v` the colour and `V` its amount.

## 2026.09.28.6 — 2026-09-28

### Fixed

- When macOS grew the tap's or the output's IO buffer while eq ran, the ring between them
  slipped on nearly every cycle and a third to two thirds of the audio became silence. The ring
  cushion now follows the buffer sizes the two callbacks actually get, up to 4096 frames each.
- The daemon rebuilds the engine when the ring keeps slipping: underruns, overruns or dropped
  buffers rising on three status ticks in a row, about 15 s. Before, only a stalled callback
  triggered a rebuild, and a path that played gaps went on playing them.
- On an output device that also has a microphone, eq checks that the microphone is really off
  for its IO callback and does not start if it is not, instead of starting anyway with a log
  line. The callback also runs only the output stream eq taps.

### Added

- `eq status` and `eq status --json` count `dropouts`: tap or output buffers eq could not take
  and dropped whole. `eq doctor` has a `ring` row that warns once the ring slipped or dropped.

## 2026.09.28.5 — 2026-09-28

### Fixed

- Lip sync over Bluetooth: eq added about one device latency on top of the device's own,
  200–300 ms, which no video player compensates for. The tap now sits alone in its aggregate
  device and a second IO callback plays straight to the output device; a probe of this layout
  added about 13 ms.

### Changed

- The IO buffer is 128 frames instead of 256, on the tap and on the output device.

### Added

- `eq status` splits the latency: `latency 432 ms (device 210, eq adds 23)`. The device share is
  what a video player sees and compensates for; what eq adds, measured from the tap's and the
  output's host timestamps on the same samples, no player can see. `eq status --json` carries
  it as `addedLatencyMs`, beside `deviceLatencyMs`.
- `eq status` shows ring underruns and overruns when the tap and the output slip;
  `eq status --json` carries them as `underruns` and `overruns`.
- `eq doctor` warns when eq adds more than 45 ms, the most sound may trail picture before
  viewers notice (ATSC IS-191).

## 2026.09.28.4 — 2026-09-28

### Fixed

- On a fresh install the first `eq` did not start the daemon: macOS 26 reports a login item
  that was never registered as "not found", which eq read as "this build has no LaunchAgent".
  A not-found service whose plist ships in EQ.app is now registered.
- `eq watch` and `eq stream` without a daemon say so and point at `eq doctor`, instead of
  asking whether the daemon is at least v4.

## 2026.09.28.3 — 2026-09-28

### Fixed

- The bundled login item registers on a Mac that once ran the hand-installed
  `com.servitola.eq` agent: macOS refused that label with "Operation not permitted", so the
  bundled job is now `com.servitola.eq.daemon`. eq still never registers it while the legacy
  job is loaded or its plist is in `~/Library/LaunchAgents`, and `eq agent status` names the
  loaded job's label. Restart hints read `launchctl kickstart -k gui/$UID/com.servitola.eq.daemon`.
- A second eq daemon never starts a second tap: the daemon takes a lock,
  `~/.cache/eq/daemon.lock`, and one that finds it held, or finds itself the bundled daemon
  while the legacy agent is in use, logs why and exits a minute later. Before, only a fresh
  `status.json` kept a second one off.
- `brew upgrade` takes effect without a restart: the daemon notices its binary replaced, logs
  `binary replaced — restarting` and exits, and launchd starts the new one. When the binary is
  gone for a minute (`brew uninstall`), it logs `binary removed — exiting` and stops.
- The cask no longer tries to start the daemon: Homebrew's install steps cannot launch an app
  (`kLSUnknownErr`, -10810), so nothing was registered. The first `eq` you run starts it,
  and still prints the curve. `eq agent uninstall --for-upgrade` is gone with the cask step
  that used it.

## 2026.09.28.2 — 2026-09-28

### Changed

- Works right after `brew install --cask servitola/tap/eq`, with no setup. No config file is
  needed: every command reads the default curve `eq init` would write, and the first change
  writes `~/.config/eq/eq.json`. `eq history` says there is no history yet, `eq doctor` shows
  `config — defaults (no file yet)`, `--dry-run` compares against the defaults, and the daemon
  runs on them without writing anything, picking up the file whenever it appears, even into a
  config directory replaced wholesale. A change that leaves the defaults as they are (`eq on`)
  writes nothing. Deleting `eq.json` now means the defaults again. `eq init` is optional.
- EQ.app carries its own LaunchAgent and registers it as the login item "EQ": the cask does it
  on install, and any `eq` command does it when no daemon runs, printing one dim line the
  first time. The daemon logs to `~/Library/Logs/eq.log`. A hand-installed
  `~/Library/LaunchAgents/com.servitola.eq.plist` keeps working and blocks the bundled one;
  `eq doctor` names the launcher in use, and `eq agent install --replace-legacy` switches.
- While the daemon lacks System Audio Recording, every command says so on stderr and where to
  allow it; while the login item waits for approval, where that is.
- `eq watch` keeps its hide-the-key-box marker in `~/.cache/eq/watch-hint-off`; one already in
  `~/.config/eq` still counts.

### Added

- `eq agent install [--replace-legacy]|uninstall|status`, hidden, for the cask and for
  troubleshooting; `status` reports the SMAppService state (`notRegistered`, `enabled`,
  `requiresApproval`, `notFound`). `uninstall` keeps the daemon off (marker
  `~/.cache/eq/agent-off`) until `install`; the cask's own uninstall step, which also runs on
  upgrade, does not. When `--replace-legacy` fails after moving the old plist to the Trash, the
  error says where it is and how to load it again.

## 2026.09.28.1 — 2026-09-28

### Added

- Instrument knobs: `eq boost voice +3` turns one instrument up or down with a single peak
  filter on its character range (voice presence 2–5 kHz, kick thump 50–100 Hz, snare crack
  4–6 kHz, …), −12…+12 dB, `0` removes it; `eq boost` lists every instrument's range and gain.
  They are stored as `"instruments"` on the profile, carried by presets, dropped by `eq flat`,
  exported as peak filters and read back by `eq import` of eq's own JSON. `eq` prints a
  `boost:` line when any is set.
- `eq watch`: `→`/`←` (or `.`/`,`, `ю`/`б`) turn the focused instrument's knob by 0.5 dB; the
  header shows it, and the focus bracket draws the character range bright.
- `eq events` prints the daemon's state changes as JSON lines until Ctrl-C: `device`, `rate`,
  `profile` (curve, preset or knob), `enabled`, `solo` and `daemon`, each with `t`. The first
  line is the daemon's state now. Events ride the meter socket for clients that write
  `{"subscribe":"events"}`, which never start the meter; `eq stream` and `eq watch` are
  unchanged. It exits 1 when the daemon is not running or predates events.
- Hooks: `"hooks": {"device": "…", "preset": "…"}` in `eq.json` runs a shell command when the
  output or its rate changes, or when the preset does, once per burst, with `EQ_DEVICE`,
  `EQ_PRESET` and `EQ_RATE` set. A hook is killed after 10 s, its output (up to 4 KB) goes to
  the log, and it never affects the audio. `eq doctor` warns about a hook whose program is a
  missing or non-executable absolute path.
- Noun groups: `eq device list|use|copy`, `eq preset list`, `eq filter list`. `eq device use
  AirPods` switches the system output: it picks among connected devices only, an exact name
  wins over a partial one, and a device UID works where two devices share a name.
  `eq device copy` takes `--device` as well as `--to`.
  `eq devices` and `eq copy` still work, as aliases of the new forms.
- `--dry-run` on every command that changes the config (and on `eq device use`): the curve
  before and after, in `eq`'s own form, or `{"before": …, "after": …}` with `--json`, and
  nothing written — no save, no backup, no history entry, not even the import cache. It runs
  the real command against a copy, so it fails where the real run would. A command that
  writes nothing refuses it.
- `eq completions zsh|bash|fish` and `eq man`, generated from the same table as `--help`. The
  scripts complete commands, subcommands, flags, bands and filter types, and ask `eq` for
  device names, presets, instruments and export formats. The cask installs all of them.

### Changed

- `eq --help` groups the commands by what they act on: look, tune, device, preset, filter,
  import, setup. Its footer names `--dry-run` and the old spellings.
- An unknown device points at `eq device list` instead of `eq devices`.
- `l` in `eq watch` listens to the focused instrument's character range instead of its whole
  outer span, so voice is heard at 2–5 kHz rather than 85 Hz–9 kHz.

### Fixed

- `eq watch` keys work while the daemon sends no frames: input and the meter socket are
  waited on together.
- Esc followed quickly by `[` or `O`, with or without digits after it, no longer waits for an
  escape sequence and swallows the next key; an arrow right after it still turns the knob.
- Focusing another instrument while listening and while the device settles at 0 Hz no longer
  leaves the watch listening without a solo: it asks once the rate arrives. A device switch
  keeps the solo without a `can't listen` note.
- Re-importing an `eq export --format json` file restores the bass/treble/tilt layer and the
  instrument knobs exactly, clearing ones set since: the export always writes both, empty
  when unset. A file without them, such as one exported earlier, still leaves them alone.

## 2026.09.28 — 2026-09-28

### Added

- `eq import` reads the whole Equalizer APO grammar: every filter type APO has (the four
  shelf spellings `LS`/`LSC x dB`/`LS 6dB`/`LSC … Q`, pass, band-pass and notch filters),
  `BW Oct`, kHz, several `Preamp:` lines, `Channel:` blocks (the left channel is imported, with
  a warning when the right differs) and `Include:` beside an imported file. Shelves and
  bandwidths get the Q APO itself would build. `Device:`, `Copy:`, `Stage:`, `Eval:`, `If:`
  and the like are named in one warning each instead of silently dropped.
- AutoEq's `FixedBandEQ.txt` sets the ten bands instead of adding ten filters.
- REW's text export (with its header and `ON None` slots) and squig.link's (CRLF, `Channel:
  L`/`R`) import. The README has a new Formats section listing what imports.
- `eq export` writes the curve for another tool: Equalizer APO text by default (also read by
  Peace, REW and SoundSource), `--format graphiceq` (AutoEq's 127-point grid, for Wavelet),
  `eqmac` (ten bands and preamp; refused when the curve has more), `camilla` (CamillaDSP
  `filters:` and a `pipeline:` step with CamillaDSP 3/4's `channels: [0, 1]`) or `json` (eq's own profile). `--device` picks the device,
  `--out FILE` writes atomically and never replaces a file without `--force`, `--json` reports.
- `eq import` reads eqMac's preset export (Advanced presets set the ten bands, Expert presets
  become filters) and Poweramp's preset JSON (graphic sliders or parametric bands).
- `eq import` reads EasyEffects presets (the equaliser plugin, left channel) and Peace `.peace`
  configurations, turned into the Equalizer APO lines Peace itself would write.
- `eq import` reads CamillaDSP configs: the Biquad and Gain filters channel 0 runs in the
  pipeline (a step's `channel: n` of CamillaDSP 2 or `channels:` list of 3 and later), with a
  warning when channel 1 differs. SoundSource's sample Headphone EQ profile is
  a test fixture now; it was already APO text.
- `eq import` reads back eq's own JSON profile (what `eq export --format json` and `eq.json`
  write): the ten bands, the preamp, every filter and, when it is not flat, the bass/treble/tilt
  preference layer — exactly, not fitted or reduced like a borrowed format.

### Changed

- A malformed or out-of-range filter line is skipped with a warning that names its line,
  instead of being imported and refused later or dropped without a word; a total preamp
  outside −30…12 dB refuses the import with that reason. GraphicEQ gains beyond ±12 dB say
  they were limited.
- A `GraphicEQ:` curve (AutoEq's `GraphicEQ.txt`, Peace's graphic mode, `eq export --format
  graphiceq`) is fitted: the ten band gains and the preamp are chosen together to match the
  whole curve, instead of copying the curve's value at each centre. Neighbouring bands no longer
  add up to dBs too much between centres, and the level the curve sits at becomes the preamp
  rather than fading out past 16 kHz. AutoEq's Sony WH-1000XM4 curve is now matched to 0.8 dB
  on average (2.4 dB before), and an exported ten-band curve reads back within 0.5 dB.
- A relative `Include:` no longer leaves the imported file's folder, and only a regular file of
  up to 1 MB is included, so a downloaded config cannot point eq at `/dev/zero` or out of its folder.
- The same guard applies to the file `eq import` is given directly, so `eq import /dev/zero` is
  refused instead of reading forever.

## 2026.09.27.9 — 2026-09-27

### Added

- `eq filter` edits parametric filters by hand: `eq filter` lists them, `eq filter add <type>
  <freq> <gain> [q]` adds one (peak, lowshelf, highshelf, lowpass, highpass, notch, bandpass;
  Q defaults to 1.41 for peak/notch/bandpass, 0.707 otherwise), `eq filter set <n>
  freq=… gain=… q=… type=…` changes one, `eq filter rm <n>|all` removes (removing the last
  imported filter also drops the `imported:` label). All take `--device`
  and `--json`. `eq` shows a `source` column, `import` or `hand`; the config stores it as
  `"origin"` on each filter.
- Bass, treble and tilt on top of the curve, as AutoEq defines them: `eq bass <gain>` (low shelf
  105 Hz, Q 0.7), `eq treble <gain>` (high shelf 10 kHz, Q 0.7), both ±12 dB, and `eq tilt
  <slope>` in dB per octave around 632 Hz (±1.2), each with `--device` and `--json`. `eq` shows
  a `preference:` line when any is set; presets carry them; `eq flat` drops them. In `eq watch`
  `b`/`B` and `t`/`T` (`и`/`И`, `е`/`Е` on a Russian layout) step bass and treble by 0.5 dB, and
  the header shows `bass +3 treble -2`.
- `eq import --search <name>` lists every headphone a name matches, with its variant and
  source, marking with `*` the one `eq import` would apply; `--json` gives the list. Nothing
  is imported.
- OPRA as a second headphone database: `eq import <name>` falls back to it when AutoEq has no
  match, `--source opra` uses it only, and `eq import --search` lists both, AutoEq first. OPRA
  imports print the preset's author and OPRA's CC BY-SA 4.0 credit, also in `--json` as
  `import.attribution`. Its database is cached at `~/.cache/eq/opra` for 7 days. OPRA bands
  outside the filter ranges are skipped with a warning naming the preset, and a name is looked
  up in OPRA even when AutoEq's index cannot be downloaded and none is cached.
- `eq import <name> --variant <tag>` picks a device state such as `anc-on`, `anc-off`,
  `transparency-mode` or `sample-2`. Without it, the untagged entry wins, then ANC on; a
  model with only other variants lists them and asks.
- `eq redo` steps forward again after `eq undo`, and `eq history` lists every saved version
  with its time and a one-line curve summary, `off` when EQ was off and `pref …` when bass,
  treble or tilt were set, marking the current position with `←` (`eq undo --list` is kept as
  an alias). All three take `--json`; history entries carry `enabled`. `eq history` first
  settles a hand edit or an interrupted step the way `eq undo` does, so both are listed.

### Changed

- `eq import --clear` drops only the imported filters and keeps the ones added by hand; a new
  import replaces the imported filters and keeps the hand ones after them. When the hand ones
  leave fewer than 32 slots, the import keeps only its first filters and says so; when they
  leave none, the import is refused (`importRefused` in `--json`) instead of adding nothing.
  An OPRA preset whose preamp is outside −30…12 dB is refused with an error naming it.
- A filter out of range names the allowed range in the error.
- Headphone names match loosely: case, spaces and hyphens are ignored (`wh1000xm4`,
  `airpods pro2`), the brand can be omitted, and `xm4`, `app2` and a few other nicknames
  work. A typo now answers "did you mean" with the closest models instead of "no
  ParametricEQ.txt".
- `eq undo` steps back one saved version at a time — repeat it to keep walking further back —
  instead of toggling between the last two versions. No version is lost: a real edit after
  undoing (`eq set`, `eq watch`, …) ends the redo side but puts the abandoned latest version
  into `eq history` — also for an `eq watch` session still open while `eq undo` ran in another
  terminal; a save that changes nothing (even over a differently formatted version) and the
  daemon's device-name refresh keep it;
  a hand edit of `eq.json` while stepped back becomes the latest version instead of being
  overwritten by the next `eq undo` or `eq redo`.
- **Breaking:** `eq undo --json` now prints `{position, date, device, source, profile}` (plus
  `warning` when the undo state had to be reset) instead of `{restored, device, source,
  profile}`; `device`, `source` and `profile` are omitted when no output device is found.
- **Breaking:** `eq history --json` and `eq undo --list --json` print `{position, entries:
  [{index, path, date, enabled, profile, current}]}` instead of `{backups: [{index, path, date,
  profile}]}`; entry 0 is the latest version.

## 2026.09.27.8 — 2026-09-27

### Added

- `eq watch` focuses on one instrument: `]`/`Tab` and `[` pick it, `Esc` lets go. The header
  names it with its range (`focus: voice (85 Hz–9 kHz)`), a bracket row marks its ranges over
  the bars, bands it does not touch go dim, and a digit key for a band outside it is refused
  with a note instead of editing.
- `l` in `eq watch` listens to the focused instrument alone: the daemon band-limits the output
  to the instrument's span (two high-pass and two low-pass sections) until `l`, `Esc`, a focus
  change (which moves it), quitting or a dropped connection. The header shows `SOLO`. Nothing
  is written to the config. A focus the current rate cannot play (air in call mode) stops the
  solo and says `can't listen to air at this rate`.
- `↑`/`↓` in `eq watch` step to the previous/next preset, like `p` in both directions.
- The meter socket takes requests: a client may send `{"solo":{"low":L,"high":H}}` (with
  `0 ≤ L < H ≤ 100000`) or `{"solo":null}`, one JSON object per line. Only the client that set
  the solo can clear it; a `null` from another client is ignored. At most eight clients connect
  at once. `eq stream` frames carry `"solo"`, `null` when off.

### Fixed

- `eq watch` no longer misreads an arrow key or a Russian letter whose bytes arrive split
  across two reads as Esc, `[` or stray letters.

### Changed

- Instruments are real frequency ranges instead of groups of bands: kick, bass, snare, guitar,
  piano, voice (fundamental, F1, F2, presence, sibilance), cymbals, air. `eq zones` lists them
  in Hz with the bands each range touches; `--json` gives `ranges: [{name, low, high}]`. The old
  sub, mud and sibilance zones are gone (sibilance is now part of voice).
- `z` in `eq watch` toggles the instrument strip on and off, and the strip now sits inside the
  meter above the level row, drawn on the bars' own frequency axis, rather than cycling through
  compact and full band lists under the gains.

After upgrading, restart the daemon (`launchctl kickstart -k gui/$UID/com.servitola.eq`): an
older daemon ignores `l`, and its frames have no `solo`.

## 2026.09.27.7 — 2026-09-27

### Changed

- Device and sample-rate events are coalesced into one check 150 ms after the last of them,
  so a USB DAC plug or a Bluetooth call-mode switch rebuilds once, and a rate of 0 reported
  mid-negotiation is re-read instead of rebuilt on. The log notes when a headset enters call
  mode (below 44.1 kHz).
- The engine stops before the Mac sleeps and rebuilds a second after it wakes.
- Filter state is flushed to zero when it decays into subnormal numbers, so a silent tail no
  longer costs CPU.
- A filter whose coefficients would be unstable at 48 kHz is rejected by `eq import` and by
  config validation, with the filter's number in the message.
- At 96 and 192 kHz some in-range filters below ~14 Hz / ~28 Hz still round to unstable
  coefficients. The daemon now passes such a filter through unchanged, logs
  `profile "X": band N|filter N unstable at R Hz — bypassed` once, and reports it in
  `eq status` and in a new `filters` row of `eq doctor`.

### Added

- `eq status` shows the path latency: the output device's own latency and safety offset, the
  first output stream's latency, the tap's input side, and the IO buffer twice (once in, once
  out).
- `eq doctor` checks the default output (a Multi-Output Device with no members has no streams)
  and warns when no audio has reached the tap for over 30 s.

After upgrading, restart the daemon (`launchctl kickstart -k gui/$UID/com.servitola.eq`) —
latency, the tap check and bypassed filters are reported only by the new daemon. Filters are
now also checked for stability at 48 kHz on load, so a config with an unstable hand-edited
filter is rejected — the daemon falls back to the built-in curve and says so in `eq status`.

## 2026.09.27.6 — 2026-09-27

### Changed

- `eq --help` fits the terminal: grouped into look, tune and setup, in colour, descriptions
  wrapped inside their own column (one column below 60). `eq <command> --help` shows one
  command; a usage error shows only that command's help instead of the whole list.
- The device placeholder is `DEVICE` instead of `Q`, which read like filter Q.
- `--json` on a terminal is coloured like `jq`; piped output is unchanged byte for byte.
- `init`, `on`/`off`, `copy`, `import`, `undo`, `devices`, `status` and `doctor` colour every
  line by the same rules: names bold, paths and labels dim, success green, warnings yellow.

## 2026.09.27.5 — 2026-09-27

### Added

- Presets: named curves any device can use. `eq preset` lists them, `eq preset save|use
  <name>` stores or applies one, `show`, `rm` and `rename` manage them. The config comes with
  `favourite` and `flat`. Headers name the device's preset, `favourite*` once the curve has
  moved away from it.
- Undo: every config save keeps the previous file as `eq.json.1`…`eq.json.10`. `eq undo`
  restores the newest (twice is a redo), `eq undo --list` shows them all.
- `eq watch` keys: `p` cycles presets, `u` undoes the session's last change back to its start,
  `s` saves the curve as a preset from a prompt on the bottom line. The header shows the preset
  name. One watch session is one `eq undo` step.

After upgrading, restart the daemon (`launchctl kickstart -k gui/$UID/com.servitola.eq`) — an
older daemon does not know presets.

## 2026.09.27.4 — 2026-09-27

### Added

- `eq watch` tunes from the keyboard: `1`…`0` raise a band by 0.5 dB, the same keys with
  Shift lower it (US and Russian layouts), `+`/`-` move the preamp. Edits go to the current
  device's profile, clamped, and save at once; the band's label flashes bold.
- `eq watch` shows a key hint in the top-right corner for 8 seconds; `h` brings it back, `x`
  hides it for good (marker `~/.config/eq/watch-hint-off`). Narrow terminals get one line.
- Zones: `z` in `eq watch` (or `eq watch --zones`) shows which bands carry which instruments,
  compact then all; `eq zones` prints them once with the reason for each.

### Changed

- `eq watch` fits any terminal size instead of refusing below 64×16: bars and labels
  narrow first, then the highest bands drop off with a `… widen for all bands` note. The
  frame is centred in a wide terminal, and wider cells get wider bars.
- `eq watch` redraws the whole frame for the new size when the terminal is resized.
- `eq watch` shows a live row under the bars: each band's level in dBFS after the EQ.
- `eq watch` paints a band louder than −6 dBFS in the bright shade of its colour, and a
  bar's top is drawn to an eighth of a row.

## 2026.09.27.3 — 2026-09-27

### Added

- `eq watch`: the ten bands live in the terminal, ~30 fps, in the sixteen colours — input and
  output level per band plus the slider position; `q` or Ctrl-C exits.
- `eq stream`: the same numbers as JSON lines on stdout, 30 a second, for anyone who wants to
  draw their own.
- A meter socket at `~/.cache/eq/meter.sock`, created by the daemon when it starts and removed
  on exit; the band meter and its 30 Hz timer run only while a client is connected.
- the meter socket appears after the daemon restarts (`launchctl kickstart -k gui/$UID/com.servitola.eq`)

## 2026.09.27.2 — 2026-09-27

### Added

- `EQ_IO_FRAMES` env (daemon only, 64…4096) overrides the requested IO buffer size, for
  re-measuring the footprint on hardware where 256 vs 512 frames trades differently.
- `scripts/footprint.sh <pid> [seconds]`: physical footprint, CPU, context switches/s, status
  writes/min, log lines — used for the before/after table in the README.

### Changed

- The daemon writes `status.json` on every state/device/profile/error change and otherwise
  every 30 s (was every 5 s), cutting writes from ~720/h to ≤ 120/h.
- `SIGUSR1` asks the daemon for a fresh status instead of waiting for the heartbeat.
  `eq doctor`'s audio check sends it only to a v3+ daemon (one whose status carries a
  `version`) whose pid still runs an `eq` binary, so an old daemon can no longer be killed by
  the check; a daemon on a different version than the `eq` binary is reported as a warning.
- `eq status` shows `version`.
- Measured the IO buffer: 512 frames roughly halves context switches (191/s → 105/s) but more
  than doubles CPU (0.30 % → ~0.8 %), so the default stays 256 frames.
- The daemon logs one line per rebuild sequence instead of one per attempt.
- The LaunchAgent sets `LowPriorityIO` — the process's disk IO is status/log only.
- `brew uninstall` leaves the LaunchAgent loaded, so an upgrade never loses it;
  `brew uninstall --zap` unloads it and removes the plist symlink.

## 2026.09.27.1 — 2026-09-27

### Added

- `eq import <file|url|"headphone name">` applies an AutoEq correction: parametric filters
  exact, a `GraphicEQ.txt` reduced to the ten bands. Names are looked up in AutoEq's index,
  cached at `~/.cache/eq/autoeq` for 7 days; `--refresh`, `--source`, `--keep-bands`,
  `eq import --clear`.
- `--json` on every command: the answer as one JSON document on stdout, stable keys, exit
  codes unchanged.
- `eq doctor`: one-shot check of macOS version, config, daemon, permission, launch agent,
  binary and audio, exit 0 only when every check passes.
- `eq status` reports `callbacks`, the IO tap's own counter, alongside `framesProcessed`.
- Profiles carry `filters` (peak, low/high shelf, low/high pass, notch, band pass) alongside
  the ten graphic bands; a v1 config with no `filters` still loads.
- `eq` and every command that prints a curve list the imported filters in a table under
  the bands: type, Fc, gain, Q, and where the import came from.
- Colour on a terminal: sixteen terminal colours, one meaning each, plus a spark row that
  draws the curve above the band labels. Piped output stays plain and keeps the v1
  three-line shape; `NO_COLOR` or `TERM=dumb` turn colour off.

### Changed

- The daemon writes `status.json` before the first tap succeeds, so `eq status` says
  `starting` instead of "not running" while the permission prompt is open.
- A device counts as `running` once its IO callback fires, not after frames with signal —
  no more five rebuilds waiting for audio on a silent Mac.
- A stalled IO path (10 s with no new callback) logs and rebuilds instead of running dark.
- A profile holds at most 32 filters, and its preamp may go down to −30 dB (up to +12 dB)
  so an imported curve with a large boost keeps its compensating preamp.
- Imports accept a leading `+` on gains and preamp (`Gain +3.0 dB`, `Preamp: +1 dB`).
- `--json` output writes `/` unescaped, so paths and URLs read as they are.
- Only errors go to stderr; a failing `eq doctor` report prints on stdout with exit 1.

### Fixed

- A sync failure during retry no longer flips the reported state back to `starting`; it stays
  `failed`/`no-permission` until it actually changes.

## 2026.09.27 — 2026-09-27

First release.

- System-wide 10-band equalizer (32 Hz … 16 kHz, ±12 dB, preamp) on Core Audio process taps:
  no driver, no `sudo`, no icon, no window.
- A curve per output device, keyed by the device's Core Audio UID; the daemon follows the
  default output and applies the right curve as macOS switches. Unknown devices get `default`.
- `eq` CLI: `set`, `preamp`, `flat`, `copy`, `devices`, `on`/`off`, `status`, `init`. Edits
  land in `~/.config/eq/eq.json` and reach the daemon within 100 ms.
- Limiter at −1 dBFS with an instant attack, so a boosted transient after silence cannot clip.
- Requests a 256-frame IO buffer (≈ 10 ms end to end); falls back to what the device grants.
- Ships as `EQ.app` (LSUIElement) so the System Audio Recording grant sticks to a bundle;
  installed through `servitola/tap/eq`, run by a LaunchAgent.
