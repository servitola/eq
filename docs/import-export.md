# Import and export

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

## OPRA

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

## Export

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
