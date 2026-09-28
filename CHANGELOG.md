# Changelog

What changed for someone who uses the tool. Keep the `Unreleased` heading; a release moves
its entries under a dated version.

## Unreleased

### Fixed

- The bundled login item registers on a Mac that once ran the hand-installed
  `com.servitola.eq` agent: macOS refused that label with "Operation not permitted", so the
  bundled job is now `com.servitola.eq.daemon`. eq still never registers it while the legacy
  job is loaded or its plist is in `~/Library/LaunchAgents`, and `eq agent status` names the
  loaded job's label. Restart hints read `launchctl kickstart -k gui/$UID/com.servitola.eq.daemon`.

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
