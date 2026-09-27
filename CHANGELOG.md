# Changelog

What changed for someone who uses the tool. Keep the `Unreleased` heading; a release moves
its entries under a dated version.

## Unreleased

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
