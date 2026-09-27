# Changelog

What changed for someone who uses the tool. Keep the `Unreleased` heading; a release moves
its entries under a dated version.

## Unreleased

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
