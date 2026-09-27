# Foreign EQ preset/config file formats: import & export

Current state: `Sources/eq/Import/AutoEqParser.swift` parses two grammars only — AutoEq/Equalizer-APO
parametric text (`Preamp:` + `Filter N: ON <TYPE> Fc.. Gain.. Q|BW Oct..`, types PK/LS(C)/HS(C)/LP/HP/BP/NO,
`AP` explicitly skipped with a warning) and `GraphicEQ:` (semicolon-separated freq/gain pairs, log-interpolated
onto our fixed 10 bands). `Sources/eq/Config/Config.swift` models a profile as `preamp: Double` + `bands: [Double]`
(10 fixed peaking bands at 32/64/125/250/500/1k/2k/4k/8k/16k Hz, Q 1.41) + `filters: [Filter]` (arbitrary
`{type, frequency, gain, q}`, up to `Config.maxFilters = 32`, engine types in `EQBand.FilterType`:
`peak, lowShelf, highShelf, lowPass, highPass, notch, bandPass`). This doc surveys what else is worth
importing/exporting and how each format actually works, each claim backed by a real fetched sample.

For the headphone-*database* side (AutoEq vs OPRA vs peqdb.com vs squig.link, licensing, target curves),
see [`03-headphone-data.md`](03-headphone-data.md) — this doc is about *file formats*, that one is about
*data sources*. Where the two overlap (OPRA, peqdb.com) this doc defers to `03-headphone-data.md`'s more
thorough live-probed findings and just adds the on-disk schema detail.

## Format landscape at a glance

| Format | Grammar | Filter types | Q or BW? | Preamp field? | License of spec/samples | Import? | Export? |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Equalizer APO config | line-based text | PK,LP(Q),HP(Q),BP,LS/LSC/LS N dB,HS/HSC/HS N dB,NO,AP,IIR | both (Q native, `BW Oct` alt) | `Preamp:` (sums) | doc example, unstated | **yes** (partial today) | **yes — recommended lingua franca** |
| AutoEq `ParametricEQ.txt`/`FixedBandEQ.txt` | same grammar, PK/LSC/HSC only | PK, LSC, HSC | Q only | `Preamp:` | MIT | **yes** (already, refine) | derive from APO exporter |
| AutoEq `GraphicEQ.txt` | `GraphicEQ: f g; ...` | curve, no discrete type | n/a | baked into gains | MIT | **yes** (already) | **yes** (127-pt grid) |
| AutoEq CSV | `frequency,raw,smoothed,...` | n/a (curve, not filters) | n/a | n/a | MIT | no (not filter data) | no |
| autoeq.app JSON | `POST /equalize` response | `PEAKING`,`LOW_SHELF`,`HIGH_SHELF` | Q | `preamp` (+0.1 dB margin vs `.txt`) | MIT (same repo) | optional | no |
| Peace `.peace` | INI wrapping APO lines + GUI metadata | via `[Filters]` type index 1–7 | Q (APO's) | via wrapped `Preamp:` | unclear, sample not directly verified | maybe (medium confidence) | maybe |
| REW filter export | same line grammar as APO (Generic) or literal APO export mode | PK,LP,HP,LS,HS,NO,AP (+legacy `PA`/`BW/60`) | both | none emitted | doc/GPL-3.0 sample | **yes** (~free, same parser as APO) | n/a |
| Generic CSV freq,gain(,Q) | no real standard | implied PK | Q if 3rd col | none | n/a | best-effort only | no |
| Wavelet (Android) | consumes `GraphicEQ:` text verbatim, no format of its own | n/a | n/a | none (auto-normalized) | doc, unstated | via GraphicEQ export | **yes** (127-pt grid) |
| Poweramp preset | JSON, array-wrapped | 0=low-shelf,1=high-shelf,2=peak (by position) | Q (peak only) | `preamp` | MIT-ish sample repo | **yes** | maybe |
| JamesDSP `.conf` | INI key=value | embeds literal `GraphicEQ:` string; legacy 15-band `tone_eq` | n/a / n/a | n/a | GPL-3.0 | via GraphicEQ | via GraphicEQ |
| EasyEffects preset | JSON | Bell,Hi/Lo-pass,Hi/Lo-shelf,Bandpass,Ladder-pass/brick,Resonance,Notch,Allpass | Q native | `input-gain`/`output-gain` | GPL-3.0 (app), sample repo unstated | **yes** | maybe |
| Qudelix-5K | — | — | — | — | — | **no export exists** — skip | skip |
| FiiO Control | proprietary, undocumented | ? | ? | ? | unknown | low confidence — skip for now | skip |
| Moondrop Link | proprietary/undocumented; community shares use AutoEq txt | — | — | — | — | via AutoEq txt only | skip |
| eqMac JSON | JSON, reverse-engineered | positional gain array, fixed band grid, no per-band freq | n/a | `gains.global` | MIT (old open tree) | **yes — high priority, our own migration path** | **yes** |
| SoundSource custom HPEQ | plain text, APO-subset | PK,LS,HS,HP,LP | Q | `Preamp:` | official KB doc example | **yes** (near-zero marginal cost) | **yes** |
| CamillaDSP YAML | YAML `filters:`+`pipeline:` | Peaking,Highshelf,Lowshelf,Highpass,Lowpass,Notch,Bandpass,Allpass,Linkwitz*,Butterworth*,Free(raw biquad) | both (`q` or `bandwidth`; shelves also take `slope`) | separate `Gain` filter/mixer, no dedicated preamp key | dual GPLv3/MPL-2.0 | maybe (medium effort) | **yes — good secondary target** |
| Apple `AUNBandEQ` `.aupreset` | XML/binary plist wrapping an opaque `ClassInfo` blob | 11 AU filter-type enum values | `Bandwidth` param, octaves | `GlobalGain` param | Apple headers (public); blob layout undocumented | **no — can't hand-author the blob** | no (same reason) |
| OPRA JSON | JSON, `type:"parametric_eq"` | `low_shelf`,`high_shelf`,`peak_dip` | Q | `parameters.gain_db` | **CC BY-SA 4.0** (see `03-headphone-data.md`) | yes (low effort, clean license) | maybe |
| squig.link / peqdb.com | literal AutoEq-style text (+ optional non-canonical `Channel: L/R` blocks); peqdb.com also serves normalized JSON | PK,LSC,HSC | Q | computed as `-max(fr_eq - fr_raw)` | data license unclear (squig.link); peqdb.com ToS unstated | **yes** (same parser as AutoEq) | n/a |
| Neutron Music Player | undocumented XML `eq_presets.xml`, `<eqp4><preset><band id="LOW/MID1/MID2/HIGH" gain freq Q>` | 4 fixed bands only | Q (attr named `Q`) | none found | unknown, medium-confidence schema | low priority — skip | skip |
| Roon | **no exposed file format** — internal DB only | n/a | n/a | n/a | n/a | **no** — do not target | no |
| Audirvana | **no exposed file format** for its own EQ; relies on hosting AU plugins | n/a | n/a | n/a | n/a | **no** — do not target | no |
| FIR/convolution WAV | binary PCM impulse response | n/a (not parametric) | n/a | n/a | n/a | **out of scope**, note only | out of scope |

## Equalizer APO — the reference grammar

Spec: [Configuration reference](https://sourceforge.net/p/equalizerapo/wiki/Configuration%20reference/).
Every line is `Command: Parameters`; unrecognized or malformed lines and `#`-comments are silently ignored;
decimal separator is `.`. This is the grammar AutoEq, REW, squig.link, SoundSource's headphone-EQ importer,
and Peace all either emit directly or emit a strict subset of — treating it as the canonical superset pays
for itself immediately.

**Filters**, one line each, `Filter <n>: ON <Type> Fc <f> Hz Gain <g> dB [Q <q> | BW Oct <bw>]`:

- `PK` / `Modal` / `PEQ` — peaking (Modal adds `T60 target <ms> ms`, ignorable for us).
- `LP`, `LPQ` — low-pass (`LPQ` takes `Q`, plain `LP` doesn't).
- `HP`, `HPQ` — high-pass, same split.
- `BP` — true band-pass, Q only, **no Gain** (unlike some hardware DCX2496-style band-pass-as-peak).
- `NO` — notch, `Fc` required, `Q` optional.
- `AP` — all-pass, `Fc` **and** `Q` both required. Our parser explicitly skips this with a warning today — keep doing so, there's no biquad-cascade equivalent worth adding for a peaking/shelf EQ.
- `LS` / `HS` — shelf, plain form takes `Gain` only (fixed default Q) **or**, since v1.2.1, an explicit `Q`.
- `LSC <slope dB>` / `HSC <slope dB>` — shelf with an explicit **dB/octave slope** instead of Q (`ON LSC 10.8 dB Fc 300 Hz Gain 5.0 dB`), or, also since 1.2.1, `LSC`/`HSC` with `Q` instead (`ON LSC Fc 300 Hz Gain 5.0 dB Q 0.6473`) — **AutoEq's own output always uses this `Q`-form of `LSC`/`HSC`**, never plain `LS`/`HS` (verified against real AutoEq files below), so a parser that only accepts `LS`/`HS` for shelves is already leaving the *majority* of real-world files unmatched by name even though our code happens to alias `LSC`→`lowShelf` already.
- `LS 6dB`/`LS 12dB`, `HS 6dB`/`HS 12dB` — fixed-slope corner-frequency shelf, **no Q or slope param at all**: `ON LS 6dB Fc 50.0 Hz Gain 7.2 dB`. Four different shelf encodings exist for the same conceptual filter — a robust importer needs all four; an exporter should standardize on the `LSC ... Q ...` form since that's what AutoEq/squig.link already assume downstream tools accept.
- `IIR Order <m> Coefficients <b0> <b1> ... <bm> <a0> <a1> ... <am>` — raw coefficients, v0.9+. Out of scope (not expressible as one of our named filter types without re-deriving type/Fc/Q from coefficients).

**`GraphicEQ:`** (v1.0+): `GraphicEQ: <Freq> <Gain>; <Freq> <Gain>; ...`, gain linearly interpolated **on the log-frequency axis**, flat outside the given range. Official 15-band ISO example:
```
GraphicEQ: 25 6; 40 4.5; 63 3; 100 1.5; 160 0; 250 0; 400 0; 630 0; 1000 0; 1600 0; 2500 0; 4000 0; 6300 1.5; 10000 3; 16000 3
```
Source: [Configuration reference](https://sourceforge.net/p/equalizerapo/wiki/Configuration%20reference/).

**`Preamp: <val> dB`** — multiple `Preamp:` lines applicable to the same channel **sum** (since v0.8); no upper/lower bound stated beyond ours (`Config.preampRange`).

**`Channel: L R C LFE RL RR RC SL SR | <n> | all`** — scopes subsequent `Filter`/`Preamp` lines to named or numbered channels until the next `Channel:` line. We're stereo-linked by design: policy should be "take the first channel block, or the `all`/unscoped block if present; if `L`/`R` blocks differ, import `L` and warn" — never attempt to represent the asymmetry.

**`Include: <file>`** — loads another config file, path relative to the including file, can nest/recurse. Worth supporting only if we ever ship *preset packs* (a main file that includes shared fragments); a single `eq import file.txt` today has no reason to chase includes — document as a known, deliberate gap rather than silently mis-parsing multi-file setups.

**`Device: <pattern1>; <pattern2>; ...`** — words must all appear in `"Device_name Connection_name GUID"`; not a scope block, it gates *everything after it* until the next `Device:` line. Irrelevant to us (we already key profiles by device UID at the `eq` layer, not inside the imported file) — when present, treat as always-matching (`all`) and just take the filters, since the device-gating concept is redundant with our own per-device profile system.

**`Copy:`** (`Target=Factor*Source+...`) and **`Stage: pre-mix|post-mix|capture`** and `If:`/`ElseIf:`/`Else:`/`EndIf:` conditionals — all APO features with no equivalent in a 10-band-peaking + parametric-filters model (channel mixing, pipeline staging, sample-rate conditionals). Parse-and-ignore, don't error on their presence — a real-world `config.txt` a user pastes in will very likely contain some of these around the filters we actually want.

**BW-octave ↔ Q** (needed for the `BW Oct` filter variant, and for REW's `BW/60` legacy form conceptually, though that one is a different hardware-specific parametrization not worth chasing exactly):
```
Q  = 1 / (2 · sinh((ln 2 / 2) · BW))
BW = (2 / ln 2) · asinh(1 / (2 · Q))
```
This is the standard RBJ audio-EQ-cookbook relation our own `AutoEqParser.parseParametric` already implements for the peaking case (`q = sqrt(bw) / (bw - 1)` — note: that's a *different*, simpler approximation than the RBJ formula above; worth checking which one Equalizer APO's own C++ actually uses before calling either "the" conversion — flag as a **verification edge case**, see below).

**Full annotated real example** (official doc, doc-example license/status unstated but this is documentation text, not redistributed third-party data):
```
Device: High Definition Audio Device Speakers; Benchmark
#All lines below will only be applied to the specified device and the benchmark application
Preamp: -6 db
Include: example.txt
Filter  1: ON  PK       Fc     50 Hz   Gain  -3.0 dB  Q 10.00
Filter  2: ON  PEQ      Fc     100 Hz  Gain   1.0 dB  BW Oct 0.167

Channel: L
#Additional preamp for left channel
Preamp: -5 dB
```

## AutoEq's actual output files (ground truth beyond what we already parse)

All confirmed live against `results/oratory1990/over-ear/Sony WH-1000XM4/` and `.../Sennheiser HD 600/`
in [jaakkopasanen/AutoEq](https://github.com/jaakkopasanen/AutoEq) (MIT).

**`ParametricEQ.txt`** — real file:
```
Preamp: -6.1 dB
Filter 1: ON LSC Fc 105 Hz Gain -4.2 dB Q 0.70
Filter 2: ON PK Fc 143 Hz Gain -5.2 dB Q 1.10
Filter 3: ON PK Fc 2289 Hz Gain 6.1 dB Q 1.57
...
Filter 6: ON HSC Fc 10000 Hz Gain -1.0 dB Q 0.70
```
[Source](https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/oratory1990/over-ear/Sony%20WH-1000XM4/Sony%20WH-1000XM4%20ParametricEQ.txt).
Confirms: **type tokens are `PK`/`LSC`/`HSC` only**, never plain `LS`/`HS`, never `NO`/`BP`/`AP`. Filters are
**not** frequency-sorted (optimizer order). `ON`/`OFF` is always `ON` in real files. Preamp = `-compound.max_gain`,
i.e. the negative of the **cascaded/summed response's peak**, not the largest single filter's own gain — overlapping
peaking filters can push the true peak higher than any one filter's `Gain` value, so recomputing preamp from
individual filter gains (rather than trusting the file's `Preamp:` line, or evaluating the real cascade) will
sometimes be wrong. Known **0.1 dB discrepancy**: the raw `.txt` writer uses no headroom margin, while the
per-headphone `README.md` table and the `autoeq.app` JSON API both subtract an *extra* 0.1 dB
(`-compound.max_gain - 0.1`) — don't be surprised if a "recomputed" preamp is 0.1 dB more conservative than
the shipped file's own value; trust the file.

**`FixedBandEQ.txt`** — same exact text grammar, generated from a **fixed 10-band config** (`31.25 * 2**i`
Hz, i.e. 31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 — almost exactly our own
`Config.bandFrequencies`), **all `PK`, Q locked at `sqrt(2) ≈ 1.41` for every band** (only gain is optimized
per band, clamped ±12 dB):
```
Preamp: -5.8 dB
Filter 1: ON PK Fc 31 Hz Gain -4.3 dB Q 1.41
Filter 2: ON PK Fc 62 Hz Gain -1.8 dB Q 1.41
...
Filter 10: ON PK Fc 16000 Hz Gain -2.2 dB Q 1.41
```
**This is the one foreign format that maps onto our 10-band graphic model almost losslessly** — same band
count, same Q (our engine's own graphic bands already use `q: 1.41`, see `Profile.engineBands`), band centers
off by rounding only (31 vs 32 Hz etc., negligible). Worth a dedicated fast path: detect "10 PK filters at
these exact centers, Q 1.41" and import straight into `bands: [Double]` instead of the generic `filters:`
parametric array.

**`GraphicEQ.txt`** — **not** an ISO 1/3-octave grid. It's AutoEq's own fixed ~127-point geometric series,
`f = 20 * 1.0563^n`, integer-truncated and deduplicated, 20 Hz → ~19871 Hz:
```
GraphicEQ: 20 -9.9; 21 -10.0; 22 -10.1; 23 -10.2; 24 -10.3; 26 -10.3; 27 -10.3; 29 -10.3; ...
```
No `Preamp:` line — normalization bakes preamp into the curve itself (peak pinned to −0.2 dB headroom, then
an optional extra offset), plus a guard zeroing any residual positive gain at the very lowest bin. Our
importer's log-interpolation approach already handles an arbitrary point list correctly on *import*; the
127-point grid only matters when we start *exporting* to this format, because **Wavelet rejects a
`GraphicEQ.txt` whose frequency list isn't this exact canonical grid** (see Wavelet section) — so an exporter
must reproduce `f = 20 * 1.0563^n` exactly, not just "some log-spaced points."

**CSV** — `frequency,raw,smoothed,error,error_smoothed,equalization,parametric_eq,fixed_band_eq,equalized_raw,equalized_smoothed,target`, 2-decimal Hz, continuous curve data (not discrete filter parameters) — not import material for us; the per-filter table only exists as a Markdown table inside each headphone's `README.md` (`#, Type, Fc (Hz), Q, Gain (dB)`), not a standalone CSV.

**autoeq.app** is not a separate project — it's `webapp/` in the same MIT repo, a FastAPI backend re-running the same Python library on demand. Its `POST /equalize` JSON response uses **long enum strings** (`LOW_SHELF`/`HIGH_SHELF`/`PEAKING`) instead of `LSC`/`HSC`/`PK`, full-precision floats instead of pre-rounded text, and the 0.1 dB preamp margin mentioned above. No separate shareable-preset JSON format exists beyond this API shape — not worth targeting unless we want live recomputation against arbitrary targets later (see `03-headphone-data.md`'s caution about this endpoint being unverified/unstable).

## REW filter export

[Room EQ Wizard](https://www.roomeqwizard.com/) "Export Filter Settings as Text" with equalizer type
**Generic** writes the *same* line grammar as Equalizer APO's Q-variant, by design:
```
Filter Settings file

Room EQ V5.18
Dated: Jul 5, 2018 12:03:08 PM

Notes:

Equaliser: Generic
Jul 5 12:01:46
Filter  1: ON  PK       Fc    7515 Hz  Gain  -9.7 dB  Q  1.00
Filter  2: ON  PK       Fc    1911 Hz  Gain  -3.1 dB  Q  1.00
```
[Source](https://github.com/hifiberry/hifiberry-dsp/blob/master/doc/rew-basics.md) (GPL-3.0 repo, doc quoting REW's own output). Newer REW versions also have a literal "Equalizer APO" export mode that writes straight `config.txt`-compatible text, no header cruft. **No `Preamp:` line is ever emitted** by the plain-text export — REW keeps level/target settings in its own binary state. A legacy hardware-target mode ("FBQ2496") uses a different, non-APO notation (`Filter 1: ON PA Fc 129.1Hz ( 125 +2 ) Gain -18.5dB BW/60 4.0`, filter type `PA`, bandwidth as `BW/60`) — not worth chasing precisely, since it's tied to specific outboard hardware and the mainstream "Generic"/"Equalizer APO" modes already cover the interop need. **Net: REW support falls almost entirely out of doing Equalizer APO's grammar properly** — same parser, same filter-type token set, just no `Preamp:` to read.

## Generic CSV — there isn't really a standard

No single spec exists across the ecosystem. What's actually out there: AutoEq's own 2-column
`frequency,raw` measurement CSVs (curve data, not filter params), and per-headphone Markdown filter tables.
**Recommendation: don't build a dedicated "generic CSV" importer as a first-class format.** If we want a
CSV fallback at all, treat it as best-effort: 2 columns → `freq,gain` at default Q 1.41/type peak; 3 columns
→ add `Q`; 4 columns → add an explicit type token if present. Document it as unsupported/undefined behavior
rather than a real target — the actual interop need this would serve is already met by AutoEq/APO text, which
every tool in this space either emits or accepts.

## FIR/convolution WAV — out of scope, noted only

AutoEq and similar tools also emit convolution targets as impulse-response `.wav` files (e.g.
[`Sennheiser HD 600 minimum phase 44100Hz.wav`](https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/oratory1990/over-ear/Sennheiser%20HD%20600/Sennheiser%20HD%20600%20minimum%20phase%2044100Hz.wav)).
This is raw PCM time-domain data, not a parametric/graphic curve — applying it needs a real-time
block-convolution engine (FFT overlap-add/save), not a biquad cascade, and it cannot be losslessly reduced
to our filter model. Permanently out of scope for a peaking-biquad EQ; don't attempt it.

## Peace GUI presets (`.peace`)

[Peace](https://sourceforge.net/p/peace-equalizer-apo-extension/wiki/Home/) is a GUI shell around Equalizer
APO — it has **no independent filter-math grammar of its own**. A saved `.peace` file is an INI-style
container wrapping the actual APO `Filter N:`/`Preamp:` lines it writes into `peace.txt` (which the user's
`config.txt` includes), plus GUI-only metadata: a `[Filters]` section mapping band index → filter-type
dropdown index (1–7, values at default are omitted from the file), slider positions, and optionally custom
Equalizer APO commands entered through Peace's "Commands" window. Curated real preset repos exist —
[`Tal0na/Equalizer-Profiles`](https://github.com/Tal0na/Equalizer-Profiles) and
[`rhahermann/peace-preset-generator`](https://github.com/rhahermann/peace-preset-generator) (whose own
`docs/PEACE_FORMAT.md` documents the structure) — but a literal byte-exact `.peace` file wasn't fetched in
this pass (SourceForge preset archives ship zipped). **Medium confidence on exact section/key names — pull
one real `.peace` file from the SourceForge Configurations folder and diff it against this description
before writing an importer**, rather than coding purely from the secondary description above.

## Mobile apps

**Wavelet** (Android) has no export format of its own for headphone correction — it only *consumes* the
literal `GraphicEQ:` text (Equalizer-APO/AutoEq convention) under its AutoEQ import menu, per
[Wavelet's own docs](https://github.com/Pittvandewitt/Wavelet/blob/master/docs/Import.md). It **requires the
exact canonical 127-point AutoEq grid** — rejects files with added/removed/reordered points — and
auto-normalizes gain on import (no `Preamp:` concept). This is the format we'd need to reproduce exactly if
we ever export "take this curve to your phone." No separate Wavelet-native preset format exists to import
*from*.

**Poweramp** preset — real files confirmed via
[`Bronya-Rand/PA-CEQ`](https://raw.githubusercontent.com/Bronya-Rand/PA-CEQ/master/PA-CEQ%203.0-3.01/PA-CEQ%203.0%20%5B7_29_21%201_33%20AM%5D.json)
(MIT-ish):
```json
[{
	"name": "PA-CEQ 3.0",
	"preamp": 0.0,
	"parametric": false,
	"bands": [
		{ "type": 0, "channels": 0, "frequency": 90, "q": 0.0, "gain": 0.0, "color": 0 },
		{ "type": 1, "channels": 0, "frequency": 10000, "q": 0.0, "gain": 0.0, "color": 0 },
		{ "type": 2, "channels": 0, "frequency": 31, "q": 0.0, "gain": 0.0, "color": 0 },
		{ "type": 2, "channels": 0, "frequency": 62, "q": -0.5534720420837402, "gain": 0.0, "color": 0 }
	]
}]
```
Array-wrapped single object. `type` is **positional, not just labeled**: 0 = low-shelf (must be the
lowest-frequency band), 1 = high-shelf (must be the highest-frequency band), 2 = peaking/bell (every interior
band); `q` is only meaningful for type 2, `0.0` in "graphic" (`"parametric": false`) mode. `channels`: `0`
observed everywhere in samples (stereo-linked); non-zero L/R-specific values are implied by forum discussion
but not directly observed — treat `channels != 0` as unsupported/warn-and-skip rather than guessing its
semantics. **Gotcha**: Poweramp's own import is picky about float formatting precision (community reports of
scripted JSON silently failing to import) — when *exporting* to this format, match Poweramp's own
high-precision float style rather than rounding to 1-2 decimals.

**JamesDSP** (Android + [JDSP4Linux](https://github.com/Audio4Linux/JDSP4Linux), GPL-3.0): its config is a
flat `key=value` file. The only part relevant to us is `graphiceq_param`, which embeds the **literal**
`GraphicEQ: freq gain; ...` string verbatim (interoperable with APO/Wavelet with zero reformatting):
```ini
graphiceq_enable=false
graphiceq_param="GraphicEQ: 25 0; 40 0; 63 0; 100 0; 160 0; 250 0; 400 0; 630 0; 1000 0; 1600 0; 2500 0; 4000 0; 6300 0; 10000 0; 16000 0"
```
[Source](https://github.com/Audio4Linux/JDSP4Linux/blob/master/resources/assets/default.conf). A legacy
15-band `tone_eq` array and a `liveprog_file` pointing to an external EEL2 script (a full mini-DSP program,
not a filter-parameter format) also exist — out of scope; convolver/DDC likewise point to external WAV
files, same FIR out-of-scope reasoning as above. **Net: JamesDSP support is free once GraphicEQ export/import
exists** — just read/write the `graphiceq_param=` line as one more place the same string can live.

**EasyEffects** (Linux, GPL-3.0) preset JSON, `output.equalizer.left/right.band0..N`:
```json
{
  "output": {
    "equalizer": {
      "input-gain": -2.0, "output-gain": 0.0, "mode": "IIR", "num-bands": 10, "split-channels": false,
      "left": { "band0": {
        "frequency": 32.0, "gain": 4.0, "mode": "RLC (BT)", "mute": false,
        "q": 1.504760237537245, "slope": "x1", "solo": false, "type": "Bell"
      } },
      "right": { "...": "mirrors left when split-channels=false" }
    },
    "plugins_order": ["equalizer"]
  }
}
```
[Source](https://raw.githubusercontent.com/JackHack96/EasyEffects-Presets/master/Perfect%20EQ.json).
`type` vocabulary (LSP-plugin-derived): `Bell` (peak), `Hi-shelf`/`Lo-shelf`, `Hi-pass`/`Lo-pass`,
`Bandpass`, `Notch`, `Allpass`, plus `Ladder-pass`/`Ladder-brick`/`Resonance` with no equivalent in our
filter set (skip/warn on those, map the rest 1:1). `q` is a real Q, no conversion needed. `split-channels:
false` means `right` is redundant — exactly our stereo-linked case, read `left` only.

**Qudelix-5K**: confirmed **no PEQ export/import exists at all** — a
[standing feature request](https://forum.qudelix.com/post/feature-request-importexport-peq-profile-with-equalizer-apo-format-12509424)
for Equalizer-APO-text export is still open; users retype values by hand. Nothing to build. **FiiO
Control**: does let users export/share an "EQ parameter file" cross-compatible with FiiO's own web PEQ tool,
but the exact schema isn't published anywhere findable — would need to actually export one and inspect it
before committing to support; low confidence, don't build blind. **Moondrop Link**: no native export format
found; community PEQ sharing for Moondrop IEMs uses plain AutoEq-style `ParametricEQ.txt`
(e.g. [`oiwyn/PEQ`](https://github.com/oiwyn/PEQ/blob/main/ok-peq-moondrop-starfield.txt)), which we already
cover — nothing Moondrop-specific to add.

## macOS/desktop

**eqMac** — this tool's own honorable predecessor (mentioned in our own README: *"I had one curve in
eqMac..."*). Current [`bitgapp/eqMac`](https://github.com/bitgapp/eqMac) public repo is frozen at v1.3.2
(MIT); newer versions are closed-source, so there's no first-party preset schema in the open tree. The
schema below is **reverse-engineered but independently verified interoperable** by
[`indiependente/autoEqMac`](https://pkg.go.dev/github.com/indiependente/autoEqMac) (a real tool whose stated
purpose is producing JSON eqMac can import):
```json
{
  "id": "a1b2c3d4",
  "name": "Sennheiser HD 650",
  "isDefault": false,
  "gains": { "global": -4.9, "bands": [2.1, 1.0, 0.0, -1.5, -2.0, 0.5, 1.2, 0.0, -0.8, 1.1] }
}
```
`gains.bands` is a **positional array on the app's fixed band grid — no per-band frequency stored in the
preset at all**. This is our highest-value/lowest-effort target precisely because it's this project's own
migration path (people moving off eqMac onto `eq`), even though the format itself is small and slightly
lossy (10 fixed bands, no arbitrary parametric filters) — export is a 1:1 mapping from our own `bands`+`preamp`.

**SoundSource** (Rogue Amoeba): the main 10-band EQ's own presets have **no documented file format**
(closed/proprietary, save/load is app-internal only — treat as out of scope). Separately, SoundSource ≥5.3
exposes a genuinely open plain-text import for **custom headphone EQ profiles**, documented at
[Rogue Amoeba's KB](https://rogueamoeba.com/support/knowledgebase/?showArticle=SoundSource-Custom-HPEQ):
```
Preamp: -7.9 dB
Filter 1: ON PK Fc 210 Hz Gain -4.9 dB Q 0.46
```
Up to 32 filters (matches our own `Config.maxFilters = 32` — a nice sign we're not out of step with the
field), types `PK`/`LS`/`HS`/`HP`/`LP` only, filename becomes the profile's display name. This is a strict
subset of Equalizer APO's grammar — supporting APO export means we already write files SoundSource's HPEQ
importer accepts verbatim.

**CamillaDSP** ([HEnquist/camilladsp](https://github.com/HEnquist/camilladsp), dual GPLv3/MPL-2.0) config is
YAML. `filters:` is a map of arbitrary names to typed filter specs:
```yaml
filters:
  peak_100:
    type: Biquad
    parameters: { type: Peaking, freq: 100, gain: -7.3, q: 0.5 }
  exampleshelf:
    type: Biquad
    parameters: { type: Highshelf, freq: 1000, gain: -12, slope: 6 }   # dB/octave, alt to q
  hp_80:
    type: Biquad
    parameters: { type: Highpass, freq: 80, q: 0.5 }
```
Peaking/Notch/Bandpass/Allpass take `freq` + either `q` or `bandwidth` (octaves); shelves take `freq`+`gain`
and either `slope` (dB/octave) or `q`. `BiquadCombo` covers `Butterworth{High,Low}pass`/
`LinkwitzRiley{High,Low}pass` (`freq`+`order`) and `LinkwitzTransform`; `Free` takes raw `a1,a2,b0,b1,b2`
coefficients directly (not derivable back into our named-filter model, skip on import). **`pipeline:` is the
real channel-handling mechanism** — an ordered list of `Filter` steps (`channel: <index>`, `names: [...]`)
and `Mixer` steps:
```yaml
pipeline:
  - { type: Filter, channel: 0, names: [gainexample_dB] }
  - { type: Mixer, name: ExampleMixer }
```
For stereo-linked EQ (our case), the natural export is two `Filter` steps, `channel: 0` and `channel: 1`,
each listing the *same* filter names — that's literally how CamillaDSP expresses "same curve on both
channels" vs. independent L/R (different names per channel). [Source](https://github.com/HEnquist/camilladsp/blob/master/README.md).
Worth an export target: clean, documented, well-specified, and the power-user/measurement crowd already
building CamillaDSP pipelines is a real adjacent audience.

**Apple `AUNBandEQ` `.aupreset`** — parameter IDs are public
(`AudioUnitParameters.h`, mirrored at [phracker/MacOSX-SDKs](https://github.com/phracker/MacOSX-SDKs)):
`GlobalGain=0`, `BypassBand=1000+i`, `FilterType=2000+i`, `Frequency=3000+i`, `Gain=4000+i`,
`Bandwidth=5000+i` (octaves, 0.05–5.0), filter-type enum 0=Parametric…10=ResonantHighShelf. **But a real
on-disk `.aupreset` doesn't expose these as plist floats** — it wraps an opaque, undocumented `ClassInfo`
binary blob (base64-encoded), confirmed against a real sample:
[`pierreaubert/AUpresetConverter`](https://github.com/pierreaubert/AUpresetConverter/blob/main/examples_aupreset/Sennheiser%20HD%20650%20ParametricEq.aupreset)
```xml
<dict>
	<key>data</key>
	<data>AAAAAAAAAAAAAABRAAAAAMEJpEoAAAPoAAAAAAAAA+kAAAAAAAAD6gAAAAAAAAPr...</data>
	<key>manufacturer</key><integer>1634758764</integer>
	<key>subtype</key><integer>1851942257</integer>
	<key>type</key><integer>1635083896</integer>
</dict>
```
`type`/`subtype`/`manufacturer` are 4-char OSTypes packed as big-endian int32 (`aufx`/`nbeq`/`appl`). The
byte layout inside `data` is Apple-internal and was never published — generating a valid preset really
requires driving a live `AUNBandEQ` instance via `AudioUnitSetParameter` + reading back
`kAudioUnitProperty_ClassInfo`, not hand-writing plist values. **Recommendation: skip both import and export
for this format** — it's binary-proprietary in exactly the way the FIR-WAV case is, just wrapped in XML that
looks deceptively editable.

## OPRA and the squig.link/peqdb text ecosystem

OPRA's licensing/status is already the subject of live verification in `03-headphone-data.md` (**CC BY-SA
4.0**, GitHub-hosted JSON, Roon Labs-backed at `opra.roon.app`) — trust that over anything below. The JSON
shape itself, from a real fixture surfaced in [`opra-project/OPRA` issue #94](https://github.com/opra-project/OPRA/issues/94):
```json
{
  "type": "parametric_eq",
  "parameters": {
    "gain_db": 0.7,
    "bands": [
      { "type": "low_shelf", "frequency": 100, "gain_db": 3, "q": 0.71 },
      { "type": "peak_dip",  "frequency": 1000, "gain_db": 0, "q": 1.41 }
    ]
  }
}
```
`parameters.gain_db` is the preamp-equivalent field, `bands[].type` ∈ `low_shelf`/`high_shelf`/`peak_dip`
(and presumably pass types, unconfirmed) — a clean 1:1 mapping onto our `Filter` struct. Low effort, best
license in the whole list — worth adding as a second source alongside AutoEq, exactly as `03-headphone-data.md`
already recommends.

**squig.link** confirmed, by reading its own live `graphtool.js`/`equalizer.js`, to export **literal
AutoEq-style text**, byte-for-byte the same grammar:
```
Preamp: -3.6 dB
Filter 1: ON LSC Fc 105 Hz Gain -1.1 dB Q 0.70
...
Filter 9: OFF PK Fc 0 Hz Gain 0.0 dB Q 0.000
Filter 10: OFF PK Fc 0 Hz Gain 0.0 dB Q 0.000
```
([Moondrop Aria sample via AutoEq's mirror](https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/Super%20Review/in-ear/Moondrop%20Aria/Moondrop%20Aria%20ParametricEQ.txt),
MIT; disabled-slot padding confirmed independently via
[`lokiedev/topamp`](https://github.com/lokiedev/topamp)'s README). Notable: squig.link's own JS pads a fixed
10-slot layout with `OFF ... Fc 0 Hz Gain 0.0 dB Q 0.000` placeholders — our existing `guard fc > 0` already
skips these correctly, but it's worth a dedicated fixture/regression test locking that in rather than relying
on incidental behavior. squig.link's export uses **CRLF** line endings (vs. AutoEq's GitHub files, which are
LF-only) — our `components(separatedBy: .newlines)` already normalizes both, but again worth a fixture.
squig.link also has a non-canonical **optional multi-channel extension** (`Channel: L` / `Channel: R` blocks,
each with its own `Preamp:`+filters) not part of AutoEq's own grammar — same stereo-linked policy as APO's
`Channel:` applies (take one side, warn if they differ). **peqdb.com**'s real API
(`GET /opt-v3/lists`, `POST /opt-v3/preset`, confirmed live in `03-headphone-data.md`) returns normalized
`{type,f0,gain,Q}` JSON *and* pre-rendered Equalizer-APO/Wavelet/Poweramp text — so peqdb.com support is
free once APO-text and Poweramp-JSON import both exist; it's an alternate *source*, not a new *format*.

## Confirmed dead ends — don't build these

- **Neutron Music Player**: undocumented proprietary `eq_presets.xml` (`<eqp4><preset><band id="LOW/MID1/MID2/HIGH" gain freq Q>`, 4 fixed bands only), reconstructed only from forum-shared XML, no export/import dialog existed for years (per a Neutron moderator's own [forum post](https://forum.neutroncode.com/viewtopic.php?t=7217)). Tiny relevant overlap with a macOS system EQ's userbase. Skip.
- **Roon**: DSP presets are internal-database-only; a documented "Generic IIR" op takes manually-typed biquad coefficients in the UI, but there is **no file-based import/export** — repeatedly confirmed by Roon's own community forum threads asking for exactly this and being told no. Do not target.
- **Audirvana**: same verdict — its built-in Studio EQ has app-internal save/load only, no external-file import; the actual interop path users rely on is hosting a third-party AU plugin (e.g. `AUNBandEQ`) inside Audirvana instead, which routes back to the already-out-of-scope `.aupreset` binary format.
- **foobar2000 `.feq`**: proprietary/undocumented binary, Windows-only niche, low priority.
- **Sonarworks `.snr`**: proprietary correction-curve format for a different problem (room/headphone *calibration* correction, not user-tunable filter presets) — different domain, skip.
- **MiniDSP biquad-coefficient text**: REW's "Save Filter Coefficients to File" output, scoped to a specific MiniDSP hardware model/sample-rate — a narrower, hardware-specific sibling of the generic REW export already covered; not worth chasing separately.

## What OnlyEQ already covers (vendor more of it)

Fetched [`zollans/OnlyEQ`](https://github.com/zollans/OnlyEQ)'s
`Sources/OnlyEQ/Models/PresetImporter.swift` (Unlicense — same terms as the audio engine we already vendor
from this project). It already detects and parses, by content-sniffing rather than file extension:
**AutoEq, Equalizer APO, REW, peqdb, Qudelix-labeled parametric text, `GraphicEQ:` lines, Poweramp JSON, OPRA
JSON, eqMac JSON, Peace INI, and its own native JSON** — a strict superset of our current AutoEq+APO+GraphicEQ
coverage. Its filter-line regex is structurally identical to ours (same `PK`/`LS`/`HS`/`LP`/`HP`/`BP`/`NOTCH`
token set, same `Q`/`BW Oct` split); its JSON-format disambiguation works by checking each format's
characteristic keys (Poweramp's `bands` array shape vs. OPRA's `parameters.bands` vs. eqMac's `gains.bands`
vs. peqdb's filter-def shape). **Concretely worth lifting from it, in order of value**: the Peace INI parser
(saves us from reverse-engineering `.peace` from scratch, since it already ships a working
dropdown-index→filter-type mapping), the Poweramp/OPRA/eqMac JSON format detectors (same schemas documented
above — OnlyEQ's code is a second, independent confirmation of each), and its overall content-sniffing
dispatch strategy (probably cleaner than adding an explicit `--format` flag to `eq import`, since none of
these formats have a reserved file extension).

## Unified internal model

Keep the existing two-tier `Profile` shape — it already matches the field almost everywhere:

- **Graphic tier** (`bands: [Double]`, our fixed 10 centers, always type peak, Q 1.41) is exactly AutoEq's
  `FixedBandEQ.txt`, matches eqMac's schema shape (minus per-preset arbitrary frequency), and is a
  reasonable reduction target for any curve-only format (`GraphicEQ:`, EasyEffects with `split-channels:
  false`, arbitrary CSV).
- **Parametric tier** (`filters: [Filter]`, arbitrary `{type, frequency, gain, q}`, capped at
  `Config.maxFilters = 32`) is exactly AutoEq's `ParametricEQ.txt`, squig.link's export, SoundSource's HPEQ,
  OPRA's `bands[]`, EasyEffects' per-band objects, and Poweramp's `"parametric": true` mode — the dominant
  shape across the entire ecosystem is `{type ∈ peak/low-shelf/high-shelf(/pass/notch), freq, gain, Q}` plus
  a scalar preamp. Nothing here argues for a bigger model.

**Additions worth making**:
1. **Shelf-slope normalization at parse time.** Four APO/AutoEq shelf encodings (`LS`/`HS` default-Q, `LSC
   x dB`/`HSC x dB` explicit-slope, `LS 6dB`/`LS 12dB` fixed-slope, `LSC`/`HSC` with explicit `Q`) all need
   to collapse into one `Filter{type: .lowShelf/.highShelf, q}` — convert dB/octave "slope" forms to Q via
   the RBJ cookbook's shelf-slope relation (`Q = 1 / sqrt((A + 1/A)·(1/S − 1) + 2)`, `A = 10^(gain/40)`,
   `S` the cookbook's dimensionless shelf-slope parameter — note APO's `LSC x dB` slope is a *literal
   dB/octave corner slope*, not directly `S`; treat this conversion as approximate/best-effort and say so in
   a parser warning rather than silently asserting exactness).
2. **BW-octave↔Q as a shared utility**, not duplicated per-parser: `Q = 1/(2·sinh((ln2/2)·BW))` and its
   inverse — check this against what `AutoEqParser.swift` currently does (`q = sqrt(bw)/(bw-1)`, a different
   and simpler approximation) before consolidating; they may diverge at extreme BW values (see edge cases).
3. **A shared "recompute preamp from a filter set" helper**, implementing AutoEq/squig.link's convention
   (`preamp = -max(0, peak of the cascaded/summed response)`), for formats that don't carry an explicit
   preamp (`GraphicEQ:`, EasyEffects, Poweramp graphic mode) — our `parseGraphic` already does an
   approximation of this (`-(max(0, bands.max))`); generalize it to also run over an arbitrary parametric
   filter set, not just the 10-band case.
4. **One explicit stereo-link policy for every multi-channel format**, applied uniformly: if the format
   exposes per-channel scoping at all (APO `Channel:`, squig.link's optional `Channel: L/R` blocks,
   CamillaDSP `pipeline:` per-channel filter lists, Poweramp's `channels` field) and the channels differ,
   import the first/`L`/`channel 0` and emit a warning (reusing the existing `Result.warnings` mechanism) —
   never silently average or silently pick one without saying so.
5. **A fast path for "10 fixed-center peaking filters, Q 1.41" → straight into `bands: [Double]`** instead
   of the generic parametric array — covers `FixedBandEQ.txt` and any 10-band graphic-shaped JSON (eqMac,
   Poweramp `"parametric": false` mode) with an exact, lossless import instead of going through
   frequency-matching heuristics.

## Recommended priority order

**Import** (user base × effort, highest first):
1. Equalizer APO full grammar (all shelf/slope variants, `LP/HP/BP/NO`, `BW Oct`) — the lingua franca; low-medium effort as an extension of what exists.
2. AutoEq `FixedBandEQ.txt` fast path into `bands:` directly (near-zero marginal effort, exact fit).
3. squig.link / peqdb.com / community PEQ-share text — zero marginal effort once #1 exists (same grammar); this is the largest active headphone-tuning community.
4. REW filter export (Generic + native APO mode) — zero marginal effort once #1 exists.
5. **eqMac JSON** — small effort, but this is *our own* predecessor and migration path; bump above its format-complexity would otherwise suggest.
6. GraphicEQ.txt from any source (AutoEq, Wavelet-compatible files, JamesDSP's embedded string) — already done, just recognize it can arrive from more places.
7. Poweramp JSON — moderate effort, sizable Android audience, well-specified from real samples.
8. OPRA JSON — low effort, cleanest license (CC BY-SA 4.0) of any secondary source.
9. SoundSource custom HPEQ text — trivial once #1 exists (strict subset).
10. EasyEffects preset JSON — moderate effort, smaller but well-documented Linux-desktop audience.
11. Peace `.peace` INI — moderate effort, needs one real byte-exact sample before implementing; vendor OnlyEQ's existing parser rather than starting from zero.
12. CamillaDSP YAML — medium-high effort (YAML + `Free`-biquad awareness + pipeline model), worth it mainly as an *export* target for the power-user crowd (see below).

**Do not build**: Qudelix (no export exists), FiiO Control / Moondrop Link (undocumented proprietary,
unverifiable without live capture), Neutron (undocumented, thin overlap), Roon / Audirvana (no file format
exists), Apple `.aupreset` (opaque binary blob, not hand-authorable), foobar2000 `.feq` / Sonarworks `.snr`
(proprietary, narrow), FIR/convolution WAV (wrong DSP model entirely).

**Export**, in priority order:
1. **Equalizer APO text** (`Preamp:` + `Filter N: PK/LSC/HSC` lines) as the default/lingua-franca export —
   directly consumable by APO itself, Peace, REW's import, SoundSource's HPEQ import, and matches the shape
   AutoEq/squig.link already emit, so round-trips cleanly through the whole ecosystem with one code path.
2. **GraphicEQ.txt**, reproducing AutoEq's exact 127-point grid (`f = 20 · 1.0563^n`, deduped integers,
   20–19871 Hz) — required for Wavelet compatibility (it rejects any other point set) and doubles as the
   JamesDSP `graphiceq_param=` value and generic APO GraphicEQ import.
3. **eqMac JSON** — cheap, symmetric with the import side, serves this project's own predecessor's users
   directly.
4. **CamillaDSP YAML** — clean, well-documented, moderate effort, reaches the measurement/power-user crowd
   who might chain our curve into a different playback pipeline.
5. Peace `.peace` / OPRA JSON — nice-to-have, build only once the corresponding import side already exists
   (symmetric effort, lower urgency since #1 already satisfies most of the same audience).

## Edge cases and test fixtures

Real sample files worth keeping as fixtures (attribute the source in the fixture's own comment/header; none
of these should be assumed freely redistributable beyond fair-use test-fixture scope unless the license says
otherwise):

| Fixture | Source | License |
| --- | --- | --- |
| Sony WH-1000XM4 `ParametricEQ.txt`/`FixedBandEQ.txt`/`GraphicEQ.txt` (oratory1990) | [AutoEq](https://github.com/jaakkopasanen/AutoEq/tree/master/results/oratory1990/over-ear/Sony%20WH-1000XM4) | MIT |
| Moondrop Aria `ParametricEQ.txt` (padded `OFF Fc 0` slots, CRLF-from-squig.link variant) | [AutoEq mirror](https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/Super%20Review/in-ear/Moondrop%20Aria/Moondrop%20Aria%20ParametricEQ.txt) | MIT |
| APO doc example (`Device:`/`Channel:`/`Include:`/`BW Oct`) | [Configuration reference](https://sourceforge.net/p/equalizerapo/wiki/Configuration%20reference/) | doc example, unstated license — low risk, attribute |
| REW Generic export sample | [hifiberry-dsp docs](https://github.com/hifiberry/hifiberry-dsp/blob/master/doc/rew-basics.md) | GPL-3.0 (repo) |
| Poweramp `PA-CEQ 3.0` preset (high-precision floats) | [Bronya-Rand/PA-CEQ](https://raw.githubusercontent.com/Bronya-Rand/PA-CEQ/master/PA-CEQ%203.0-3.01/PA-CEQ%203.0%20%5B7_29_21%201_33%20AM%5D.json) | MIT-ish (repo) |
| EasyEffects "Perfect EQ.json" | [JackHack96/EasyEffects-Presets](https://raw.githubusercontent.com/JackHack96/EasyEffects-Presets/master/Perfect%20EQ.json) | unstated — attribute, don't assume redistribution rights |
| SoundSource custom HPEQ sample | [Rogue Amoeba KB](https://rogueamoeba.com/support/knowledgebase/?showArticle=SoundSource-Custom-HPEQ) | doc example |
| CamillaDSP README YAML snippet | [HEnquist/camilladsp README](https://github.com/HEnquist/camilladsp/blob/master/README.md) | dual GPLv3/MPL-2.0 |
| OPRA fixture JSON | [opra-project/OPRA issue #94](https://github.com/opra-project/OPRA/issues/94) | CC BY-SA 4.0 — **requires attribution if redistributed** |

Specific behaviors to lock in with tests, not just "it happened to work once":

1. **All four shelf encodings** (`LS`/`HS` plain, `LSC x dB`/`HSC x dB` slope, `LS 6dB`/`HS 12dB` fixed-slope, `LSC`/`HSC` with `Q`) must resolve to the same `Filter.type`, and the slope→Q conversion should be flagged in a warning as approximate, not silent.
2. **BW-Oct↔Q formula reconciliation**: our current `AutoEqParser` uses `q = sqrt(bw)/(bw-1)` for the peaking case; the RBJ cookbook relation is `Q = 1/(2·sinh((ln2/2)·BW))`. Compare both at a few BW values (0.5, 1, 2, 4 octaves) — if they diverge by more than rounding, decide deliberately which one Equalizer APO's real engine implements and standardize on it, rather than having two silently different conversions in the codebase.
3. **Disabled-filter padding**: squig.link's `OFF ... Fc 0 Hz Gain 0.0 dB Q 0.000` placeholder pattern must be skipped (already true via the existing `fc > 0` guard, but not yet covered by an explicit regression fixture).
4. **kHz-suffix path**: current regex handles `k?Hz` but real generators almost always write plain Hz even for large frequencies (`10000 Hz`, not `10 kHz`) — the less-common `"10 kHz"` spelling should get its own explicit fixture so the multiply-by-1000 branch isn't only exercised by accident.
5. **Decimal comma**: a hand-edited, European-locale APO config (`Gain -3,5 dB`) — already handled by `parseNumber`'s comma→dot replace, worth a dedicated fixture.
6. **Preamp trust vs. recompute**: when a file's own `Preamp:` line and a recomputed "safe" preamp (from the filter cascade) disagree by more than ~0.1 dB (the documented AutoEq `.txt`-vs-`README`/webapp margin), always trust the file's stated value and don't silently override it.
7. **Exact GraphicEQ grid on export**: verify the exported point list matches `f = 20 · 1.0563^n` (dedup'd integers) byte-for-byte against a real AutoEq `GraphicEQ.txt`, since Wavelet's importer is strict about this.
8. **Multi-channel divergence**: construct one fixture each for APO `Channel: L`/`Channel: R` with *different* filters, and one where they're identical — confirm the "take one side + warn only if they differ" policy from the unified-model section actually branches correctly.
9. **Poweramp positional-type validation**: a malformed file where band 0 isn't the lowest frequency (breaking the type-0-must-be-lowest assumption) should be rejected with a clear error, not silently misinterpreted.
10. **Line-ending mix**: one LF fixture (AutoEq GitHub files) and one CRLF fixture (squig.link's own export, and Windows-authored APO configs) — confirm both parse identically.
11. **Filter cap alignment**: `Config.maxFilters = 32` already matches Equalizer APO's and SoundSource's real-world ceiling (32 filters) — no change needed, just a passing note that we're not out of step with the field here.
