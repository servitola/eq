# Shaping the curve

Beyond the ten bands: presets ([Commands](commands.md#presets)), app rules, parametric filters, tone shelves, dynamics. The instrument knobs, `eq boost`, are under [Instruments](tui.md#instruments).

## Curve per app (experimental)

An app rule gives an app its own preset while it plays:

```sh
eq app set Spotify favourite     # a name, or a bundle ID: com.spotify.client
eq app set com.google.Chrome flat
eq app on                        # off by default
```

The rules sit in `eq.json` in order, and the feature stays off until `"experimental": {"apps":
true}` is there, which `eq app on` writes:

```json
"apps": [{"app": "com.spotify.client", "preset": "favourite"}, {"app": "com.google.Chrome", "preset": "flat"}],
"experimental": {"apps": true}
```

While an app with a rule plays, the daemon plays the rule's preset instead of the device's curve,
as `eq preset use` would, and goes back to the device's curve a second after the app stops. The
switch lives only in the daemon: `eq.json` keeps the device's own curve, and nothing lands in undo
or history. `eq`, `eq status` and `eq watch` say `app: Spotify → favourite` while it lasts, `eq
events` sends `{"event":"app","app":"com.spotify.client","name":"Spotify","preset":"favourite"}`,
and `"preset":null` when the device's curve comes back. The `profile` event and the hooks stay
about the device's curve. An edit to the curve while an app plays goes to the device's curve as
always and is heard at once; the rule rests until that app stops, and applies again the next time
it plays.

The daemon learns what plays from Core Audio's list of audio clients, through listeners and without
polling; with the feature off it does not listen at all. Browsers and Electron apps play from a
helper process, which counts as the app whose bundle holds it: Chrome's helper is Chrome. Safari and
other WebKit apps play from WebKit's shared `com.apple.WebKit.GPU` service, which names no app; a
rule for that bundle ID catches all of them. When two apps with rules play at once, the one macOS
shows as now playing wins if `/opt/homebrew/bin/nowplayingseek` is
installed, and the first rule otherwise.

The honest limit: there is one curve for the whole system at a time. When two apps play together,
both are heard through the winner's curve. `eq doctor` has an `apps` row while this is on.

## Filters

Besides the ten bands a curve holds up to 32 parametric filters. `eq filter add <type> <freq>
<gain> [q]` adds one at the end: the type is `peak`, `lowshelf`, `highshelf`, `lowpass`,
`highpass`, `notch` or `bandpass`; the frequency is `3k`, `250hz` or `1000`; the gain is in dB
(`-30`…`+30`, ignored by the pass, notch and bandpass types); Q is `0.1`…`30` and defaults to
1.41 for peak, notch and bandpass, 0.707 for shelves and passes. `eq filter set <n>
freq=… gain=… q=… type=…` changes any of them, `eq filter rm <n>` or `rm all` removes. Every
command takes `--device DEVICE`. Numbers are the ones `eq` and `eq filter` show; a filter that
would ring at 48 kHz is refused, like one in a hand-edited config.

`eq` lists a `source` for each filter: `import` for the ones an import brought in, `hand` for
yours. They live in one list and a hand edit of an imported filter keeps it `import`. A new
import replaces only the imported filters and puts yours after them; `eq import --clear` drops
only the imported ones. A config from before this marks its filters `import` when the profile
names an import, else `hand`.

## Bass, treble and tilt

A third layer sits on top of the bands and filters, taken from AutoEq's own preference
settings so the numbers mean the same thing as its `--bass-boost`, `--treble-boost` and
`--tilt`: `eq bass <gain>` is a low shelf at 105 Hz, `eq treble <gain>` a high shelf at
10 kHz, both Q 0.7 and −12…+12 dB; `eq tilt <slope>` slopes the whole curve by that many dB per
octave around 632 Hz (the middle of 20 Hz–20 kHz on a log scale), −1.2…+1.2, positive
brighter. A straight slope is not something a biquad can do, so tilt runs as four shelves that
stay within 0.25 dB per dB/octave of AutoEq's line from 20 Hz to 20 kHz and level off outside
it. All three take `--device DEVICE`; `0` removes that part, and only the parts that are set
cost any processing. `eq` shows a `preference:` line when any is set, the config stores them
as `"preference"` on the profile, presets carry them, and `eq flat` drops them. A boost adds
gain the preamp does not take back; the limiter catches peaks, or lower the preamp yourself.

## Compression and colour

Two stages sit after the whole curve and before the limiter, in this order: a compressor and a
colour. Each is off until you turn it on, and one that is off is skipped entirely. Both take
`--device DEVICE`; the config stores them per profile as `"dynamics": {"comp": "gentle",
"color": {"kind": "tape", "amount": 0.3}}`, presets carry them, `eq flat` drops them, and undo
and history see them like any edit. `eq` shows a `dynamics:` line when either is on. A mode or
kind this eq does not know, from a newer version or a hand edit, does not reject the file: it
runs nothing, stays in the file, is logged once by the daemon and flagged by `eq doctor`, and
`eq comp` or `eq color` replaces it.

`eq comp gentle|night|off` (or `none`, in any case) is a feed-forward compressor, linked across channels so the stereo
image stays put: the loudest channel sets one gain for all, so dialogue on the centre of 5.1
alone is compressed as it would be on both sides of stereo. Its detector listens the way a
loudness meter does, through ITU-R BS.1770's K-weighting (a high-pass at 38 Hz and +4 dB above
1.7 kHz), so the bass your curve boosts counts towards the level instead of being ignored. It
measures RMS, over 50 ms for `gentle` and 2.5 ms for `night`, and smooths the gain in dB with the
attack and release below, over a soft knee. A steady 40 Hz tone at −10 dBFS does not pump the
gain: it moves by 0.001 dB (`gentle`) and 0.06 dB (`night`) over each cycle.

Makeup gain is automatic. `gentle` gives back the reduction it has averaged over the last 3
seconds, up to 6 dB, so a song ends up as loud as without it and only its dynamics within a
phrase are tighter; a pause does not count, so the next song starts with the makeup the last one
had. `night` adds a fixed makeup that gives back exactly what it takes from film dialogue at
−24 dBFS RMS, so quiet dialogue comes up.

| Mode | Ratio | Threshold | Knee | Attack | Release | Makeup | For |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `gentle` | 2:1 | −18 dBFS | 6 dB | 30 ms | 250 ms | follows the reduction, 3 s, up to +6 dB | glue on music |
| `night` | 4:1 | −30 dBFS | 10 dB | 5 ms | 400 ms | +4.5 dB (level at −24 dBFS RMS, film dialogue) | quiet dialogue up, explosions down |

The RMS window and the attack add up on a step: `gentle` reaches 63 % of its reduction in
about 65 ms, `night` in 6 ms.

What `gentle` does to a whole mix, on the `favourite` curve, measured offline by
`CompressorBalanceTests` against the same chain with the compressor off:

| Material | Loudness | Bass (32–125 Hz) against mids (0.5–2 kHz) | Widest gap between octave bands | Reduction on loud parts |
| --- | --- | --- | --- | --- |
| music at −14 LUFS | −0.3 LU | −0.1 dB | 0.3 dB | 3.6 dB |
| music at −20 LUFS | −0.0 LU | +0.0 dB | 0.3 dB | 0.9 dB |
| pink noise swinging 12 dB | −0.7 LU | −0.0 dB | 0.1 dB | 0.9 dB (mean) |

`eq color tape|tube <amount>` shapes the waveform. `tape` is a symmetric soft clip,
`tanh(k·x)/k`, which adds odd harmonics only; `tube` biases the same curve off centre, which
adds even harmonics too, with a DC blocker at 5 Hz on what the curve adds. The drive `k` is twice the amount,
and dividing by it keeps a quiet signal exactly as loud; at −12 dBFS the level moves less than
1 dB at any amount. At −12 dBFS and amount 1, tape measures 2 % THD, tube 11 %; at 0.3, 0.2 %
and 1.1 %. `eq color tape 0` removes it like `off`.

Switching either one on or off, or changing the mode, the kind or the amount, glides instead of
jumping: the compressor's gain over 10 ms, or over its attack when that is longer, so switching
it on never swells before it compresses, and the colour's drive over 10 ms, so the curve and the
tube's DC come in without a click. A stage switched off stops running once it has glided out.

There is no oversampling, so the harmonics of high notes fold back below Nyquist. The drive is
capped at amount 1 to keep that low: at 48 kHz a 10 kHz tone at −12 dBFS folds its 3rd harmonic
to 18 kHz at −34 dB (tape) or −42 dB (tube) under the tone, and its 5th to 2 kHz at −66 dB or
−81 dB. Anything below 8 kHz has no 3rd harmonic to fold, and real music has far less energy
up there than a test tone.

`eq status` shows the compressor's reduction, `comp: -3.2 dB`, as of the daemon's last status
write, and `--json` carries it as `compReductionDB`. `eq watch` shows it live in the header,
`night comp -3.2`, followed by the colour, `tape 0.3`; `eq stream` frames carry it as `comp`.
`eq export` writes both only in eq's own `json`: every other format has no place for them, so it
says so on stderr and exports the EQ alone.
