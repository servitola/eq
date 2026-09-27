# eq roadmap — distilled from the five research reports

Date: 2026-09-27. Sources: `01-landscape.md`, `02-file-formats.md`, `03-headphone-data.md`,
`04-cli-design.md`, `05-quality-and-core.md`. Each item names the report it comes from.

Where two reports disagree, the call is made here and the reason given once.

## Position

A headless, scriptable, per-device system EQ for macOS that reads and writes every
common EQ format. Out of scope on purpose (01, 05): a GUI, per-app EQ, and any
virtual-driver fallback. Those are exactly the choices that made the 2026 wave of tap-based
tools leave eqMac and SoundSource behind.

## Round A — correctness first (small, high value)

1. **Bluetooth sample-rate rebuild threshold.** Rebuild when the rate drops below
   44 100 (catches 24 kHz wideband SCO, not only 8–16 kHz HFP), and debounce `rate == 0`
   (05 §1.1, FineTune #86/#324).
2. **Sleep/wake as an explicit rebuild trigger** via the workspace notification centre (05 §1.3).
3. **One debounced reconciliation** of device-list and default-output events against the
   engine's real target (05 §1.4, OnlyEQ #23).
4. **Denormal flush** of biquad state independent of the silence gate (05 §2.2).
5. **Stability guard** `|a2| < 1` on imported or hand-edited filters (05 §2.3).
6. **Golden impulse-response tests** through the real render path (05 §2.1).
7. **`eq doctor` gains two silent-failure probes:** a multi-output device with zero
   streams, and permission revoked while running (01 #4).
8. **Latency in `eq status`**, measured from device, stream and buffer latency. No surveyed
   tool shows this (05 §1.8). Also qualify the README's "~10 ms" claim.

## Round B — tuning that people expect (01, 03)

1. **Parametric filters by hand:** `eq filter add|set|rm|list`, and in `eq watch` a filter
   view. Every serious competitor has this (01 #2).
2. **Preference layer:** bass shelf, treble shelf and tilt as three named knobs on top of
   the correction and the bands, with AutoEq's defaults (03 #5).
3. **Smarter AutoEq search:** variant tags (`ANC on/off`, `transparency`), fuzzy matching,
   aliases (03 #6).
4. **OPRA** as a second, CC BY-SA source; peqdb as an opt-in experimental source only (03 #2/#4).
5. **`eq undo`, `eq redo` and `eq history`** as three commands instead of "undo twice"
   (04). A small change on top of v5.

## Round C — formats: bring your curve, take it with you (02)

- **Import, in order:**
  1. Full Equalizer APO grammar (all shelf and slope variants, `BW Oct`, `Channel:`,
     `Include:` resolved relative to the file).
  2. AutoEq `FixedBandEQ.txt`, which fits our 10 bands directly.
  3. squig.link / peqdb / REW text.
  4. eqMac JSON (the migration path for people like us).
  5. Then Poweramp, OPRA, SoundSource, EasyEffects, Peace and CamillaDSP YAML.

  Vendor more of OnlyEQ's importer (Unlicense) rather than rewriting it.
- **Export:** `eq export --format apo|graphiceq|eqmac|camilla` (APO is the default,
  and the lingua franca).
- **Fixtures:** keep a real file per format, with licence noted, as test fixtures. Add a
  regression test for AutoEq's 0.1 dB preamp margin discrepancy.
- **Skip:** Qudelix, FiiO, Moondrop, Neutron, Roon, Audirvana, `.aupreset`, FIR/WAV.

## Round D — CLI shape and automation (04, with 05 overruling one point)

1. **Noun groups:** `eq device …`, `eq preset …`, `eq import …`, `eq filter …`; keep
   `set/preamp/flat/on/off` top-level. Rename the `Q` device placeholder to `DEVICE`.
   Align `copy --to` with `--device`.
2. **`eq events`:** a JSON-lines stream of state changes. Add `hooks` in `eq.json` to run a
   command on device change or preset change.
3. **JSON envelope** `{schemaVersion, command, data}`, versioned independently of the app.
4. **`eq://` URL scheme** on `EQ.app` for Shortcuts.app. **`--dry-run`** on state-changing
   commands. An **`eq debug`** namespace.
5. **Coloured `--help`, grouped, fitted to the terminal**, and colour on every output. This
   is already in `docs/superpowers/BACKLOG.md`.
6. **Completions and man page:** hand-written zsh/bash/fish completion scripts and a man
   page generated from the same command table.
   - **Decision:** do *not* adopt swift-argument-parser (04 wanted it; 05 argues against).
   - Zero dependencies is a stated value, and the static completion scripts buy the one
     concrete win.

## Round E — release and trust (05)

1. **Release automation:** a tag-triggered workflow does build, sign, release and cask
   bump. It keeps the smoke on this Mac: CI cannot get the TCC grant.
2. **Notarization** with `notarytool` + `stapler`, once it is confirmed that
   tap-installed artifacts are quarantined at all.
3. **Build provenance** attestations, a NOTICE file with the full Unlicense text for the
   vendored code, and AutoEq attribution.
4. **Test boundary** documented in CONTRIBUTING: CI stops at the tap/aggregate seam, and the
   smoke covers the rest.
5. **Skip:** SBOM (zero dependencies), a SwiftPM target split (enforce dependency direction
   with a CI grep instead), Float64 biquads, oversampling, BS.1770 true-peak, dithering.

## Order

A → B → C → D → E. Colour everywhere (D5) can slot in anywhere; it touches only text
output.
