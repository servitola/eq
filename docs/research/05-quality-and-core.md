# Quality and core: what it takes to be the industry-standard system EQ

Scope: what `eq` would need to become the reference implementation in its niche —
headless, driver-free, per-device system EQ on macOS process taps. Covers the audio
engine (Core Audio taps), DSP correctness, engineering/distribution maturity, and
licensing. Grounded in the current code (`Sources/eq/Engine/ProcessTapEngine.swift`,
`EQProcessor.swift`, `BiquadFilter.swift`, `Package.swift`, `scripts/`, `.github/workflows/test.yml`,
`LICENSE`, `README.md`, `CHANGELOG.md`) plus external research, with links inline.
Method note: several claims below are explicitly flagged as *inferred* where Apple's
own reference pages are empty stubs (a real, citable fact about this API surface, not
a research gap) — treat those as reasoned inference, not documented fact.

## 1. Core Audio engine

### Where `eq` already stands

The engine (vendored from [OnlyEQ](https://github.com/zollans/OnlyEQ) @ `6569655`,
Unlicense) already does several things the field treats as hard-won correctness:
excludes its own PID from the global tap so re-rendered audio isn't re-captured;
`isPrivate` taps and aggregates; `kAudioSubTapDriftCompensationKey: true`; excludes
the physical device's input side from the aggregate specifically to avoid a spurious
microphone-permission prompt when a Bluetooth headset connects; waits for the IO
callback to actually fire before calling a Bluetooth device switch "running" (not just
device-list membership); a 10s stall watchdog; a silence gate that resets filter/limiter
state after ~1s of continuous digital silence; and a sample-rate-change listener that
restarts the engine (biquad coefficients are baked for one rate). This list matches
almost exactly the class of bugs other tap projects have hit and fixed — evidence the
current design is not naive.

### Apple's own documentation is thin, and there is no dedicated WWDC session

Checked the full WWDC23 and WWDC24 session listings — no session titled around "tap,"
"process tap," or "aggregate device" exists in either year (checked, not exhaustive
back to 2013). The primary source for the API shape is Apple's sample project
[Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps),
which states a minimum of **macOS 14.2**, not 14.4 — worth checking whether `eq`'s 14.4
floor is a real constraint or an inherited, more conservative claim from OnlyEQ.
[`CATapDescription`](https://developer.apple.com/documentation/coreaudio/catapdescription),
[`AudioHardwareCreateProcessTap`](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:)),
[`kAudioSubTapDriftCompensationKey`](https://developer.apple.com/documentation/coreaudio/kaudiosubtapdriftcompensationkey),
[`kAudioDevicePropertyLatency`](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertylatency),
and [`kAudioHardwarePropertyDevices`](https://developer.apple.com/documentation/coreaudio/kaudiohardwarepropertydevices)
all exist and are current, but each doc page is a bare member declaration with **zero
discussion text** — no firing semantics, no units, no guidance. DRM/protected-content
exclusion from taps — the assumption baked into `eq`'s design — has **no primary-source
confirmation anywhere in Apple's docs**; it is community-repeated inference. `eq`'s
own docs should say so explicitly rather than assert it as documented Apple behavior.

### Known bugs from other tap projects (cite-by-issue)

FineTune (`ronitsingh10/FineTune`) and iQualize (`dariuscorvus/iqualize`) have large,
active issue trackers (450+ and 210+ issues) well past OnlyEQ's own maturity. Findings
directly applicable to `eq`:

- **Bluetooth HFP/SCO rate thresholds**: [FineTune #86](https://github.com/ronitsingh10/FineTune/issues/86)
  and [#324](https://github.com/ronitsingh10/FineTune/issues/324) — a call-mode switch
  drops the device to 8–16kHz (classic HFP) or **24kHz** (wideband SCO), which a naive
  `rate <= 16000` check misses. They use `rate < 44100`. Also: the device can report
  `rate == 0` mid-negotiation; rebuilding on that is what causes crackling — skip and
  debounce (~150ms) instead.
- **Tapping a call app breaks echo cancellation**: [FineTune #413](https://github.com/ronitsingh10/FineTune/issues/413)
  (fixing #113/#404) — re-rendering a process that's also doing input capture (FaceTime,
  Zoom) adds latency that desyncs macOS's AEC reference signal, ducking call audio.
  `eq` taps globally, not per-app, so it can't selectively release one app's tap, but
  this is worth a manual test: run a FaceTime/Zoom call while `eq` is active and listen
  for AEC degradation.
- **Aggregate teardown cost**: [iqualize #178](https://github.com/dariuscorvus/iqualize/issues/178) —
  every output-device change triggering a full tap+aggregate+graph rebuild costs ~100ms
  of silence per switch; open question upstream on which changes need a full rebuild vs.
  in-place reconfiguration.
- **AirPlay is an unsolved problem class, not just an `eq` gap**: five-plus open FineTune
  issues with no merged fixes — [#334](https://github.com/ronitsingh10/FineTune/issues/334)
  (can't connect to AirPlay while the tap app runs), [#188](https://github.com/ronitsingh10/FineTune/issues/188)
  (headphone-jack + AirPlay combo), [#285](https://github.com/ronitsingh10/FineTune/issues/285)
  (sample-rate issues when the Mac is itself an AirPlay *receiver*). Nobody in this
  niche has this solved; `eq` should test and document known-bad behavior rather than
  imply it's handled.
- **HDMI/multichannel channel-index trap**: [OnlyEQ #25](https://github.com/zollans/OnlyEQ/issues/25) —
  fixed silence on an Audient iD4 MKII where the renderer assumed the tap's channels
  were at a fixed index in the aggregate's input buffers; the fix (already in `eq`'s
  `TapInputSelection.select`) is to locate the stream by matching the tap's declared
  format, not by channel-index assumption. Relevant if `eq` ever supports pro-audio
  multichannel interfaces beyond stereo.
- **Topology races on device disappearance**: [OnlyEQ #28](https://github.com/zollans/OnlyEQ/issues/28)
  (muted tap kept running with no valid default output — must tear down and rebuild
  once topology settles) and [OnlyEQ #23](https://github.com/zollans/OnlyEQ/issues/23)
  (device-list notification firing before default-output notification, causing a stale
  comparison — fixed by coalescing both into one debounced reconciliation against the
  engine's actual target device ID, not cached state).
- **Watchdog CPU cost from unconditional state mutation**: [OnlyEQ #17](https://github.com/zollans/OnlyEQ/issues/17) —
  a periodic timer reassigning an observed property every tick even when unchanged
  triggered avoidable UI-layer work. `eq`'s 10s stall watchdog and 30s status heartbeat
  should be audited for the same pattern (only write `status.json` / log on actual change).
- **Bluetooth latency far exceeds the documented flat estimate**: [FineTune #424](https://github.com/ronitsingh10/FineTune/issues/424) —
  users report ~0.5s A/V desync on A2DP vs. a documented ~10–13ms tap latency,
  unresolved, plausibly from a 44.1kHz/48kHz mismatch forcing extra resampling. `eq`'s
  README states "about 10 ms of latency" unconditionally — this should be qualified as
  measured on built-in/wired output, not asserted for Bluetooth.

### Drift compensation and clock source

Apple's own page for `kAudioSubTapDriftCompensationKey` has no discussion text, so this
is inferred from working code, not documented behavior. [FineTune #324](https://github.com/ronitsingh10/FineTune/issues/324)
found the opposite of "always leave it on": when a Bluetooth output is its own clock
master, drift comp was evaluating to `true` incorrectly and inserting/deleting a sample
every ~0.7s to correct a 50ppm offset that didn't need correcting — audible clicks. Their
fix gated drift comp off when the BT device is the clock master. `eq` taps and renders
back to the *same* physical device, so tap and output normally share one clock domain
already — drift comp exists for the case of two independent clocks drifting apart. Worth
empirically testing whether disabling drift compensation specifically for Bluetooth
outputs reduces clicking; there is no Apple documentation to settle this analytically.

### Latency reporting

No project surveyed (AudioCap, OnlyEQ, FineTune, iQualize) computes and displays a live
latency number — all use a static estimate in docs, and FineTune #424 shows that
estimate can be wrong by ~50x for Bluetooth. `eq` could differentiate itself here:
sum `kAudioDevicePropertyLatency` + `kAudioStreamPropertyLatency` + IO buffer frames for
tap and output device, convert to ms, and expose it live via `eq status`. This would be
a genuine improvement over the field's current practice, not a gap to close relative to
a competitor — nobody else does it.

### Per-app EQ feasibility

Confirmed feasible at the API level: `CATapDescription(processes:deviceUID:stream:)` and
its `.processes: [AudioObjectID]` / `.bundleIDs: [String]` properties exist per the
reference doc. The path is: translate a PID to an `AudioObjectID` via
`kAudioHardwarePropertyTranslatePIDToProcessObject` (already used in `eq` to exclude its
own PID), then build a tap from a specific process list instead of
`stereoGlobalTapButExcludeProcesses`. Two real unknowns, neither documented anywhere:
CPU cost of N simultaneous per-app taps vs. one global tap (no project publishes this),
and the AEC-interference bug above, which shows per-app tapping is not transparent to
the tapped app. Per-app EQ is architecturally a plausible large feature, not a quick
extension — treat it as its own spec, not a side effect of this research pass.

### Sleep/wake and output churn

`NSWorkspace.didWakeNotification`/`willSleepNotification` must be registered via
`NSWorkspace.shared.notificationCenter`, not `NotificationCenter.default` — a real,
silent-failure gotcha. `eq` currently reacts to default-output changes and sample-rate
changes but has no explicit sleep/wake listener; Apple gives no documented recovery
procedure for audio graphs across sleep, so this is a defensive addition, not a
bug-driven one.

### Recommendations

| # | Recommendation | Effort | Risk | Source |
|---|---|---|---|---|
| 1 | Tighten Bluetooth sample-rate rebuild trigger to `rate < 44100` (catches 24kHz wideband SCO, not just legacy 8–16kHz HFP); skip/debounce rebuild on `rate == 0` | S | Low | FineTune [#86](https://github.com/ronitsingh10/FineTune/issues/86), [#324](https://github.com/ronitsingh10/FineTune/issues/324) |
| 2 | Test disabling `kAudioSubTapDriftCompensationKey` when the target device is Bluetooth (suspected click source); keep on for wired/built-in | S | Low–Med, unverified for `eq` | FineTune #324 (inferred, no Apple doc) |
| 3 | Add `NSWorkspace.willSleepNotification`/`didWakeNotification` via the correct notification center as an explicit rebuild trigger | S | Low | [Apple doc](https://developer.apple.com/documentation/appkit/nsworkspace/didwakenotification); defensive |
| 4 | Coalesce `kAudioHardwarePropertyDevices` + default-output-change notifications into one debounced reconciliation against the engine's actual target device, not cached state | M | Med (real race elsewhere) | OnlyEQ [#23](https://github.com/zollans/OnlyEQ/issues/23) |
| 5 | Manually test AirPlay (both sending and Mac-as-receiver) with `eq` running; document known-bad behavior instead of implying it's handled | M (investigation) | Med, unsolved class-wide | FineTune [#334](https://github.com/ronitsingh10/FineTune/issues/334), [#188](https://github.com/ronitsingh10/FineTune/issues/188), [#285](https://github.com/ronitsingh10/FineTune/issues/285) |
| 6 | Qualify the README's flat "~10ms latency" claim as measured on built-in/wired output only | S (doc) | Low | FineTune [#424](https://github.com/ronitsingh10/FineTune/issues/424) |
| 7 | Audit the 10s stall watchdog / 30s heartbeat for unconditional writes on unchanged state | S | Low | OnlyEQ [#17](https://github.com/zollans/OnlyEQ/issues/17) |
| 8 | Add live latency reporting (`kAudioDevicePropertyLatency` + `kAudioStreamPropertyLatency` + buffer frames, summed, in ms) to `eq status` | M | Low | Differentiator — no project surveyed does this today |
| 9 | Explicitly test a FaceTime/Zoom call while `eq` runs, watching for AEC/echo regressions | S (investigation) | Low today (global tap only) | FineTune [#413](https://github.com/ronitsingh10/FineTune/issues/413) |
| 10 | Per-app EQ: real feature, not a quick add — scope separately if pursued | L | Med (AEC interaction, unknown multi-tap CPU cost) | Apple [sample doc](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps) |

Explicitly unconfirmed, inferred rather than documented: DRM/protected-content
exclusion behavior; the meaning of `CATapDescription.isProcessRestoreEnabled` and
`isExclusive`; per-app tap CPU scaling; whether a dedicated WWDC session on this API
genuinely never existed (only WWDC23/24 checked).

## 2. DSP quality

### Where `eq` already stands

Coefficients are RBJ Audio-EQ-Cookbook formulas computed in **Double**, narrowed to
**Float32** only at the final normalized value (`Float(b0 / a0)`, etc.) — the
numerically favorable order (round once, late, not early). Per-sample state is
**Transposed Direct Form II**, Float32, per channel, cascaded serially across up to 32
enabled filters. No oversampling. No explicit denormal handling beyond the "reset state
after 1s of continuous digital silence" gate. No dithering anywhere. The limiter is a
single global envelope follower, instant attack, ~80ms decay, ceiling −1 dBFS by
default, not an oversampled/true-peak design. Existing tests validate the *closed-form*
transfer function (`magnitudeDB(at:sampleRate:)`) per filter, not the actual rendered
signal through `BiquadState.process`.

### Verdict: most of this is already correct, not a gap

**TDF-II at Float32 is the right choice, not a compromise.** [CCRMA's numerical
robustness note](https://ccrma.stanford.edu/~jos/filters/Numerical_Robustness_TDF_II.html)
credits TDF-II specifically for filters needing near pole-zero cancellation close to the
unit circle — the high-Q-near-Nyquist case. Production precedent is split but instructive:
[LSP's DSP core](https://github.com/lsp-plugins/lsp-dsp-lib) (backs every EasyEffects/LSP
EQ, shipped at scale) is **Float32-only, unconditionally**. CamillaDSP defaults to
Float64 but ships an explicit `32bit` build feature as a speed/memory tradeoff, not a
correctness requirement ([DOCS.md](https://github.com/HEnquist/camilladsp/blob/master/DOCS.md)).
[Earlevel Engineering](https://www.earlevel.com/main/2003/02/28/biquads/) — a widely
cited practitioner reference — flags **low frequencies**, not high ones, as where Double
precision starts to matter (`cos(ω0) → 1` clustering); a 16kHz/Q>5/44.1kHz band is only
moderately close to Nyquist, not the pathological case. RBJ's own cookbook frames
precision as a **fixed-point** concern, not floating-point. **Do not move `BiquadState`
to Double** — no cited evidence shows audible degradation at ≤32 cascaded Float32 bands,
and it would touch every per-sample hot-path call site for a benefit nobody has measured.

**Oversampling the EQ chain itself: skip it, concrete verdict.** Biquads are LTI — they
cannot generate new spectral content at any Q or frequency, so there is no aliasing
mechanism for oversampling to fix. The bilinear-transform frequency warping near Nyquist
is an exact, intentional property of the digital design ([CCRMA — frequency
warping](https://ccrma.stanford.edu/~jos/filters/Frequency_Warping.html)), not an
approximation error. LSP scopes oversampling (2×–8×) specifically to its **nonlinear**
limiter's peak-detection path, never to its parametric EQ modules — exactly where
nonlinearity exists and nowhere else ([LSP Limiter Mono manual](https://lsp-plug.in/?page=manuals&section=limiter_mono)).
`eq` has no saturation stage, so this doesn't apply.

**True-peak/lookahead limiting: leave the limiter as-is; consider only a small
lookahead if complaints ever surface.** ITU-R BS.1770-5 Annex 2 requires 4× oversampling
through a defined FIR filter for *broadcast loudness compliance*
([spec PDF](https://www.itu.int/dms_pubrec/itu-r/rec/bs/R-REC-BS.1770-5-202311-I!!PDF-E.pdf)) —
a different bar than a listening EQ. Tellingly, CamillaDSP's own shipped limiter is a
**bare per-sample cubic soft-clipper with zero lookahead and zero oversampling**
([`limiter.rs`](https://github.com/HEnquist/camilladsp/blob/master/src/filters/limiter.rs)) —
simpler than `eq`'s own envelope follower. LSP's mastering-grade limiter does offer real
lookahead and optional true-peak mode, but as an opt-in advanced layer for a different
product category (mastering, not playback correction). `eq`'s design already matches
the reference project's philosophy; the one real, cheap gap is that zero lookahead means
gain reduction can only start after a transient has begun overshooting. If clipping
complaints on hot/brickwalled masters ever surface, add 2–5ms of lookahead (matching
LSP's `attack ≤ lookahead` model) — don't build full BS.1770 oversampled true-peak
detection, that remains the wrong tool here.

**Dithering: documented non-issue.** Dither masks quantization noise from *bit-depth
truncation*. `eq`'s pipeline is Float32 in, Float32 processing, Float32 out — it never
truncates; DAC quantization happens downstream in Core Audio/hardware, outside its
control. CamillaDSP's own dither module ([`dither.rs`](https://github.com/HEnquist/camilladsp/blob/master/src/filters/dither.rs))
is applied specifically at its optional fixed-point/integer output stage — exactly the
boundary where it becomes relevant, and nowhere else. Revisit only if `eq` ever adds a
fixed-point or 16-bit output/export path; a one-line code comment noting why is enough
for now.

**Denormals: the silence gate has a real, named gap.** A decaying reverb tail or long
delay feedback ringing toward zero is exactly the "quiet but not zero" case denormal
literature calls out by name — [EarLevel's writeup](https://www.earlevel.com/main/2019/04/19/floating-point-denormals/)
notes the *decay*, not silence, produces the CPU spike, and the gate only helps once the
signal has *already reached* digital zero. JUCE ships `ScopedNoDenormals`, an
unconditional per-block flush-to-zero RAII guard, precisely because subnormal floats
"can cause significant CPU slowdowns" ([JUCE docs](https://docs.juce.com/master/classjuce_1_1ScopedNoDenormals.html));
LSP brackets every processing block with FTZ/DAZ enable/disable in `dsp::start()`/`finish()`
([lsp-dsp-lib](https://github.com/lsp-plugins/lsp-dsp-lib)). Apple Silicon nuance,
flagged honestly as unresolved: NEON on AArch32 was always flush-to-zero, but AArch64
controls FTZ per-thread via `FPCR.FZ` rather than hardwired — no primary-source citation
found confirming macOS's default for a Swift scalar loop on Apple Silicon; don't assume
immunity without measuring. Cheapest fix that works regardless of platform: flush
`BiquadState.z1`/`z2` to zero whenever their magnitude drops below
`Float.leastNormalMagnitude` after each render block — a two-line change, no
platform-conditional toggle needed.

**Validation: the real coverage gap.** `magnitudeDB(at:sampleRate:)` validates the
*formula*, independent of how `BiquadState.process` is actually coded — it cannot catch
a state-update ordering bug, a sign error, or a Float32-narrowing mistake in the render
path itself. CamillaDSP's own test suite runs a literal golden-value impulse response
through the real `process_waveform` call and asserts against precomputed values at tight
tolerance ([`biquad.rs`](https://github.com/HEnquist/camilladsp/blob/master/src/filters/biquad.rs)) —
lightweight (an offline-computed array, pinned as a fixture), not full sweep/WAV
infrastructure. Room EQ Wizard's sine-sweep-and-FFT approach ([REW help](https://www.roomeqwizard.com/help/help_en-GB/html/gettingstarted.html))
is the right tool for measuring an unknown *physical* system, not for unit-testing a
known-coefficient digital filter where the golden reference can be precomputed once.

### Recommendations

| # | Recommendation | Effort | Risk/benefit | Source |
|---|---|---|---|---|
| 1 | Add golden-value impulse-response render tests (single band + full 32-band worst-case cascade) through the real `BiquadState.process`, alongside the existing closed-form test | S–M | Low risk, highest benefit here — closes the one real coverage gap | CamillaDSP [`biquad.rs`](https://github.com/HEnquist/camilladsp/blob/master/src/filters/biquad.rs) |
| 2 | Flush `BiquadState.z1`/`z2` to zero when below `Float.leastNormalMagnitude`, independent of the silence gate; verify empirically on Apple Silicon whether it changes measured per-block CPU under a slow-decay test signal | S | Low risk, real benefit — closes a documented gap the silence gate misses | JUCE [`ScopedNoDenormals`](https://docs.juce.com/master/classjuce_1_1ScopedNoDenormals.html), EarLevel |
| 3 | Add a stability guard (`\|a2\| < 1`) on imported/user-supplied parametric filters before accepting them | S | Cheap insurance against untrusted input (imports, hand-edited config) | CamillaDSP `is_stable()` |
| 4 | One-line comment noting dithering is architecturally N/A unless a fixed-point/16-bit output path is added later | S | Informational only | — |
| 5 | Small (2–5ms) limiter lookahead | M | Conditional — only if real clipping complaints surface on brickwalled content; don't build speculatively | LSP [Limiter Mono manual](https://lsp-plug.in/?page=manuals&section=limiter_mono) |
| 6 | Move `BiquadState` to Float64 | — | **Don't.** LSP ships Float32 at scale; no cited evidence of audible degradation at ≤32 bands | — |
| 7 | Oversample the EQ/biquad path | — | **Don't.** No aliasing mechanism exists for a linear filter | CCRMA frequency warping |
| 8 | Full BS.1770 4×-oversampled true-peak limiting | — | **Don't.** Broadcast-compliance bar, not a listening-tool bar; CamillaDSP's reference limiter is simpler than `eq`'s own | ITU-R BS.1770-5 |
| 9 | Dithering anywhere in the pipeline | — | **Don't.** No bit-depth truncation occurs today | CamillaDSP `dither.rs` |
| 10 | Full REW sine-sweep/WAV-null-test infrastructure | L, skip | Only worth it if `eq` adds REW file-format import/export as a feature | REW docs |

## 3. Engineering and distribution

### Where `eq` already stands

Single SwiftPM executable target (`eq`), one test target, ~190 XCTests, no third-party
dependencies, `-warnings-as-errors`. Ships as `EQ.app` (`LSUIElement`, no Dock icon) so
the System Audio Recording TCC grant sticks to a stable bundle identity. Build script
produces either an ad-hoc signature pinned via an explicit designated requirement (local
dev) or a real Developer ID signature with hardened runtime (`--options runtime
--timestamp`) for releases — **not currently notarized**. Distributed via a personal tap
(`servitola/tap/eq`), not homebrew-core or homebrew-cask. CI (`.github/workflows/test.yml`,
`macos-26`) runs `swift test`, a `zsh -n` syntax check, and `plutil -lint` — no linter, no
release automation, no SBOM, no notarization step, no crash reporting. Versioning is
CalVer-with-same-day-counter (`2026.09.27.4`), not SemVer. CLI parsing is a hand-rolled
676-line parser, no swift-argument-parser.

### Notarization: cheap to add, but check one thing first

Apple's notarization requirement ([Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
[Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow))
is keyed to the Developer ID signature, not to what the binary does at runtime — no
carve-out for daemons/LaunchAgents or CLI-in-app-bundle shapes. Given the build already
uses `--options runtime --timestamp`, the pipeline is one CI step away:
`xcrun notarytool submit EQ.zip --keychain-profile eq-notary --wait && xcrun stapler staple EQ.app`,
with a one-time `notarytool store-credentials` setup and no extra Apple fee. But verify
first whether Homebrew's `curl`-based downloader actually sets `com.apple.quarantine` on
the installed `.app` — plain `curl` (unlike Safari/Chrome/Mail's LaunchServices download
path) does not set that xattr by default, and neither `open EQ.app` nor
`launchctl bootstrap` (which never goes through LaunchServices) triggers Gatekeeper's
interactive assessment without it. Check with `xattr -l` on a fresh `brew install`
before treating this as urgent rather than hygiene.

### Homebrew core/cask: personal tap remains correct, confirmed against Homebrew's own docs

[Acceptable Formulae](https://docs.brew.sh/Acceptable-Formulae) states no
popularity/stars threshold, but explicitly: **native macOS `.app` bundles are
ineligible** for homebrew-core — that alone disqualifies `eq`'s current shape,
independent of the fact that a formula installing a LaunchAgent and requiring a TCC
grant is exactly the kind of stateful background-service software homebrew-core
maintainers are known to push back on. [Acceptable Casks](https://docs.brew.sh/Acceptable-Casks)
requires apps to pass Homebrew's Gatekeeper checks — not phrased as an explicit
"must be notarized" line, but in practice a quarantined, unnotarized Developer-ID app
fails `spctl --assess`, so it functions as a de facto notarization bar once the artifact
is quarantined; [Cask Cookbook](https://docs.brew.sh/Cask-Cookbook) confirms casks
support `launchctl:` entries in `uninstall`/`zap` stanzas for exactly the
LaunchAgent-cleanup case `eq` needs, so the shape itself isn't unprecedented in
cask-land, but a cask still expects a normally-notarized app. **Verdict: the personal
tap is the only channel that accommodates "unnotarized-for-now, TCC-gated,
LaunchAgent-driven, `.app`-wrapped CLI" without fighting either project's stated bar —
nothing to change here**, though notarizing anyway (above) removes that friction if `eq`
ever wants to move toward homebrew-cask.

### CalVer, release automation, SBOM, crash reporting

CalVer (`2026.09.27.4`) compares correctly component-wise and Homebrew's `livecheck`
strategies are pattern/regex-driven, not semver-locked ([Brew Livecheck](https://docs.brew.sh/Brew-Livecheck)) —
add an explicit `livecheck` regex block to the tap formula (`/(\d{4}\.\d{2}\.\d{2}\.\d+)/`)
rather than relying on strategy auto-detection guessing right. The actual weak point
today is the **absence of release automation**, not notarization or SBOM: a
tag-triggered GitHub Actions workflow that builds, signs, creates the GitHub Release,
and bumps the tap formula (`brew bump-formula-pr` or a scripted commit) removes the one
place a hand-edited formula can silently drift from the built artifact. For
provenance, [GitHub Artifact Attestations](https://docs.github.com/en/actions/security-guides/using-artifact-attestations-to-establish-provenance-for-builds)
(`actions/attest-build-provenance`, three workflow permissions, ~10 lines of YAML) is
the proportionate stop on the SLSA ladder for a solo project — full SBOM generation
(syft/CycloneDX) for a zero-third-party-dependency SwiftPM package produces a
near-content-free SBOM (you, the Swift toolchain, done); skip it unless the
no-dependencies policy changes. For crash reporting, macOS already writes `.ips` reports
to `~/Library/Logs/DiagnosticReports/` for any crashing process with zero code and zero
network calls — the correct local-only answer for a project whose value is "no
telemetry." A thin `eq doctor`/`eq crashes` subcommand globbing that directory and/or
shelling to `log show --predicate 'process == "eq"'` is the right shape; do not add a
crash-reporting SDK (even in local-only mode), it would contradict the
zero-dependency stance for a problem Apple's own tooling already solves.

### CI test strategy for audio software: what `eq` already does is the known-correct pattern

GitHub Actions macOS runners have no interactively-granted TCC permissions and cannot
exercise a live Core Audio process tap — a widely-hit constraint for any macOS audio
project on CI, not one specific to `eq`. The fix isn't a CI trick, it's architectural:
put tap/aggregate-device creation behind a seam, unit-test everything above it (DSP,
config, CLI, daemon state machine) with fakes, and leave the seam to manual/on-device
verification (which `scripts/smoke.sh` already does). `eq`'s ~190 XCTests already follow
this pattern; the only real recommendation is to write down, in README or CONTRIBUTING,
which boundary CI stops at and why — so a future contributor doesn't try to mock Core
Audio globally or skip testing the DSP layer under the mistaken belief that "it's audio,
it's untestable."

### Module split and swift-argument-parser: both premature for this project's size

At ~3000 source / ~2600 test LOC for a single maintainer, splitting Engine/Config/CLI/Daemon
into separate SwiftPM library targets would buy marginal (likely seconds, not minutes)
build-time parallelism, at real cost: `Package.swift` boilerplate for 4–5 targets,
`@testable import` friction spreading across the existing 190 tests, and
`public`/`internal` access-control churn. The one benefit with real teeth — enforcing
that Engine never imports CLI — is achievable today with a one-line CI grep check
instead of a package restructure. **Don't split modules; write the grep check if
dependency direction is the actual worry.** For argument parsing,
[swift-argument-parser](https://github.com/apple/swift-argument-parser) is
Apple-maintained and used internally by swift-format/swift-package-manager, but it is
still a normal SwiftPM dependency that lands in `Package.resolved` and gets
version-pinned like any other — not literally part of the toolchain. Its strongest
concrete win is free shell-completion generation for zsh/bash/fish, which `eq` currently
lacks entirely. Given the existing 676-line parser works and is covered by tests, a
wholesale migration is churn without an urgent forcing function; if the completion gap
matters, hand-write a static completion script for the current parser first (S effort)
and revisit swift-argument-parser only if the subcommand surface grows enough that
extending the hand-rolled switch becomes the more expensive path.

### Recommendations

| # | Recommendation | Effort | Risk | Source |
|---|---|---|---|---|
| 1 | Tag-triggered release workflow: build, sign, GitHub Release, bump tap formula | M | Low | Standard pattern for tap-distributed Swift CLIs |
| 2 | Add explicit `livecheck` regex block to the tap formula for the CalVer scheme | S | Low | [Brew Livecheck](https://docs.brew.sh/Brew-Livecheck) |
| 3 | Notarize releases via `notarytool` + `stapler`, after confirming quarantine actually applies to tap-installed artifacts | S (given existing Developer ID signing) | Low | [Apple notarization docs](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) |
| 4 | `eq doctor`/`eq crashes`: read Apple's own `.ips` reports / `log show`, no crash SDK | S | Low | Apple `DiagnosticReports`, "no telemetry" is a stated value |
| 5 | Add GitHub Artifact Attestations (`actions/attest-build-provenance`) to the release workflow | S | Low | [GitHub docs](https://docs.github.com/en/actions/security-guides/using-artifact-attestations-to-establish-provenance-for-builds) |
| 6 | Document the CI test boundary explicitly (README/CONTRIBUTING): why CI stops at the tap/aggregate-device seam | S | None | Widely-hit constraint across macOS audio projects |
| 7 | Hand-write a static zsh/bash/fish completion script for the existing parser | S | Low | Closes the one concrete swift-argument-parser win without adding a dependency |
| 8 | Full SBOM generation (syft/CycloneDX) | — | **Skip.** Zero-dependency SwiftPM package produces a content-free SBOM | — |
| 9 | Split into separate SwiftPM library targets (Engine/Config/CLI/Daemon) | — | **Skip for now.** Real benefit (dependency direction) achievable via a CI grep check instead | — |
| 10 | Migrate to swift-argument-parser | — | **Skip for now.** Real but non-urgent; revisit only if the subcommand surface grows | [apple/swift-argument-parser](https://github.com/apple/swift-argument-parser) |

## 4. Licensing

### Unlicense → MIT vendoring: clean, standard practice

The [Unlicense](https://unlicense.org/) is a two-layer instrument: a public-domain
dedication plus a fallback permissive grant for jurisdictions that don't recognize full
copyright waiver. [choosealicense.com](https://choosealicense.com/licenses/unlicense/)
confirms it imposes **zero conditions**, not even attribution — so wrapping the
redistributed combined work in the *more* restrictive MIT license (which `eq` does) is
squarely permitted; it's a strict subset of what the Unlicense already allows. The one
real wrinkle: not every jurisdiction recognizes full public-domain dedication, which is
exactly why the Unlicense's own text includes the fallback grant — best practice is to
keep that fallback text **physically present** in whatever file carries the notice, not
just a link to `zollans/OnlyEQ`.

### AutoEq is MIT, not GPL — corrected assumption, verify periodically

Checked directly (`github.com/jaakkopasanen/AutoEq` API license field and raw `LICENSE`
file): AutoEq is **MIT-licensed**, copyright Jaakko Pasanen, repo-wide (no separate data
license carving out `results/`). This substantially simplifies the picture: MIT has no
copyleft/derivative-work propagation, and its only condition — preserving the copyright
notice "in all copies or substantial portions of the Software" — doesn't attach to a
runtime HTTP fetch that parses a handful of numeric filter parameters out of one text
file into `eq`'s own DSP structs. That's neither "the Software" nor a "substantial
portion" of it. Because this is a live upstream that could relicense, `eq` should note
the license and the date verified, and re-check periodically
(`curl -s https://api.github.com/repos/jaakkopasanen/AutoEq | grep license`).

One genuinely gray point, not a legal guarantee either way: AutoEq's own README credits
third-party originators (oratory1990, crinacle, Rtings, Innerfidelity, legacy
headphone.com) for the underlying measurements, and no documented permission chain from
those originators to AutoEq's MIT grant is visible publicly. That's AutoEq's exposure to
carry, not something `eq` needs to re-litigate before consuming a well-known, actively
maintained project's own affirmative license statement — but it's honest to name as
unresolved-in-principle rather than pretend the chain of title is airtight.

### squig.link and similar measurement sites: no license, don't extend the fetch pattern there

Checked `squig.link/robots.txt` directly: it carries only the generic Cloudflare
"Content Signals" boilerplate with no site-specific signals actually set — per that
policy's own text, absence of an explicit signal means the operator "neither grants nor
restricts permission." That's silence, not a license. If `eq` ever wants squig.link-style
data, prefer sourcing through AutoEq's own index (confirmed MIT) over hitting an
individual measurement site directly with no stated reuse terms.

### Recommendations

| # | Recommendation | Effort | Risk |
|---|---|---|---|
| 1 | Add a `NOTICE`/`THIRD-PARTY-NOTICES.md` naming OnlyEQ, the Unlicense, the pinned commit, and reproducing the **full** Unlicense fallback-grant text verbatim (not just a link) | S | None — closes the jurisdiction wrinkle at zero legal cost |
| 2 | State explicitly that `eq`'s MIT license governs its own code and the redistributed combined work, while vendored files remain under the original Unlicense per their header comments | S | None |
| 3 | Add a one-sentence disclaimer on `eq import`: it performs a user-initiated runtime fetch, caches 7 days, extracts only numeric filter parameters, and does not vendor or redistribute AutoEq's dataset | S | None — true today, forecloses any incorporation-by-reference misreading |
| 4 | Note AutoEq's current license (MIT) and verification date; re-check periodically since it's a live, independently-relicensable upstream | S | None |
| 5 | Do not extend the `eq import` fetch pattern to squig.link or individual measurement sites without an explicit written permission or published reuse license; prefer AutoEq's own index when the same data is available there | M (policy, not code) | Avoids relying on ToS/robots.txt silence as if it were a grant |

## Cross-cutting top priorities

Ranked by (impact × how cheap it is to close), across all four sections:

1. **Golden-value impulse-response render tests** (DSP §2, S–M) — the single highest-leverage
   test gap; nothing today exercises the actual per-sample recursion.
2. **Denormal flush on `BiquadState`, independent of the silence gate** (DSP §2, S) —
   closes a real, named class of bug at near-zero cost.
3. **NOTICE file + Unlicense fallback text + AutoEq disclaimer** (Licensing §4, S) —
   closes real legal hygiene gaps for free.
4. **Bluetooth sample-rate threshold fix (`< 44100`, debounce `rate == 0`)** (Core Audio §1, S) —
   a specific, already-reported bug class in the exact code path `eq` shares lineage with.
5. **Tag-triggered release automation + tap formula bump** (Distribution §3, M) — the
   actual weak point in the release pipeline, ahead of notarization or SBOM.
6. **Notarize releases**, after confirming quarantine actually applies (Distribution §3, S) —
   cheap given existing Developer ID signing; removes friction if the tap ever needs to
   interoperate with cask-adjacent expectations.
7. **AirPlay manual testing + documentation of known-bad behavior** (Core Audio §1, M) —
   unsolved industry-wide, but currently undocumented for `eq` specifically.

Everything tagged "don't" above (Float64 biquads, oversampling the EQ path, full BS.1770
true-peak limiting, dithering, SwiftPM target split, swift-argument-parser migration,
full SBOM) is a deliberate exclusion, not an oversight — each would add real complexity
against no cited evidence of a corresponding problem at `eq`'s current scale.
