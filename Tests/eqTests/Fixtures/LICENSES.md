# Fixture sources and licences

Every file here is test input only.

| File | Source | Licence |
| --- | --- | --- |
| `Sony WH-1000XM4 ParametricEQ.txt`, `Sony WH-1000XM4 GraphicEQ.txt`, `Sony WH-1000XM4 FixedBandEQ.txt` | [AutoEq](https://github.com/jaakkopasanen/AutoEq), `results/oratory1990/over-ear/Sony WH-1000XM4/` (measurements by oratory1990) | MIT |
| `INDEX.md` | Excerpt of AutoEq's `results/INDEX.md` | MIT |
| `REW Generic filters.txt` | Room EQ Wizard V5.18 "Export filter settings as text" (equaliser Generic), as quoted in [hifiberry-dsp `doc/rew-basics.md`](https://github.com/hifiberry/hifiberry-dsp/blob/master/doc/rew-basics.md); the lines between the code fences | MIT (the hifiberry-dsp repository, checked 2026-09-28) |
| `APO config reference example.txt` | The example in Equalizer APO's [Configuration reference](https://sourceforge.net/p/equalizerapo/wiki/Configuration%20reference/), from `Device:` to the last `Filter:` line | Documentation example, licence unstated; Equalizer APO itself is GPL-2.0. Kept as a short quotation with this attribution |
| `opra.jsonl` | Excerpt of OPRA's `database_v1.jsonl` ([opra-project/OPRA](https://github.com/opra-project/OPRA)) | CC BY-SA 4.0 |
| `opra-malformed.jsonl` | Written for eq's tests in OPRA's shape; the vendor `acme` is invented | eq's MIT |
| `golden-full.json`, `golden-peak1k.json` | Impulse responses rendered by eq's own engine | eq's MIT |
