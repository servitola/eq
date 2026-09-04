# Changelog

What changed for someone who uses the tool. Keep the `Unreleased` heading; a release moves
its entries under a dated version.

## Unreleased

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
