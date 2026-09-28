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
| `eqMac Advanced presets.json` | Written for eq's tests in the shape eqMac exports (`/presets/export` in [bitgapp/eqMac](https://github.com/bitgapp/eqMac) 1.3.2: an array of `{id, name, isDefault, gains: {global, bands}}`) and [autoEqMac](https://github.com/indiependente/autoEqMac) writes; no real export is published. Gains are AutoEq's Sony WH-1000XM4 FixedBandEQ (MIT) and eqMac's built-in "Bass Booster" | eq's MIT; eqMac is Apache-2.0 (GitHub), autoEqMac MIT |
| `eq profile.json` | Written for eq's tests in the shape `eq export --format json` writes | eq's MIT |
| `eqMac Expert presets.json` | Written for eq's tests in the Expert-equaliser shape [ncnetsec/eqmac-backup](https://github.com/ncnetsec/eqmac-backup) reads from eqMac's preferences (`global`, `bands[{frequency, gain, bandwidth, type, bypass}]`); frequencies and gains from AutoEq's Sony WH-1000XM4 ParametricEQ (MIT), bandwidths invented | eq's MIT |
| `Poweramp PA-CEQ 3.0.json` | [Bronya-Rand/PA-CEQ](https://github.com/Bronya-Rand/PA-CEQ), `PA-CEQ 3.0-3.01/PA-CEQ 3.0 [7_29_21 1_33 AM].json`, a Poweramp export | GPL-3.0 (the repository, checked 2026-09-28) |
| `EasyEffects Perfect EQ.json` | [JackHack96/EasyEffects-Presets](https://github.com/JackHack96/EasyEffects-Presets), `Perfect EQ.json` | MIT (the repository, checked 2026-09-28) |
| `Peace Bass Boost 2.peace`, `Peace Equalizer 15 Band with HPF and LPF.peace`, `Peace Tilt filter 10 dB down.peace`, `Peace Chu Moy Crossfeed Simulation (by commands).peace` | Configurations shipped with Peace, from [mchampanis/peace-equalizer-apo-extension](https://github.com/mchampanis/peace-equalizer-apo-extension) (a mirror of Peace's SourceForge source), `Peace/Configurations/` | GPL-2.0 (Peace) |
| `CamillaDSP all_biquads.yml` | [HEnquist/camilladsp](https://github.com/HEnquist/camilladsp), `exampleconfigs/all_biquads.yml` | GPL-3.0 or MPL-2.0, at the user's choice (CamillaDSP's README) |
| `CamillaDSP headless-camilladsp config.yml` | [bkutasi/headless-camilladsp](https://github.com/bkutasi/headless-camilladsp), `config.yml` | GPL-3.0 (the repository, checked 2026-09-28) |
| `SoundSource Sample-Profile.txt` | Rogue Amoeba's sample custom Headphone EQ profile, `SampleProfile.zip` from the [knowledge-base article](https://rogueamoeba.com/support/knowledgebase/?showArticle=SoundSource-Custom-HPEQ) | Documentation sample, licence unstated; kept as a short quotation with this attribution |
