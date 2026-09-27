# Round A — reliability (from docs/research/00-roadmap.md "Round A")

Evidence: docs/research/05-quality-and-core.md §1 (engine) and §2 (DSP); 01-landscape.md (#4 doctor probes).
Repo rules as always: main, gitea, never push from a task, warnings are errors, comments only "why", no new dependencies, **do not link AppKit** (footprint round removed it; sleep/wake via IOKit `IORegisterForSystemPower`, not NSWorkspace). 243 tests at start.

### A1 — device and power events (Daemon/Engine)
1. Sample-rate change handling: rebuild only when the new nominal rate is **> 0**; debounce 150 ms (a rate of 0 mid-negotiation is skipped and re-read after the debounce); treat any rate < 44100 as "call mode" and log it once (`device in call mode at N Hz`) — still rebuild, the EQ must follow.
2. Sleep/wake: `IORegisterForSystemPower` on the daemon's queue (via `IONotificationPortSetDispatchQueue`); on `kIOMessageSystemWillSleep` acknowledge (`IOAllowPowerChange`) and stop the engine; on `kIOMessageSystemHasPoweredOn` rebuild(attempt: 1) after 1 s. Log both.
3. One debounced reconciliation: device-list, default-output and sample-rate events all schedule a single `reconcile()` 150 ms later (coalescing bursts); `reconcile()` compares the *engine's actual* target device and rate against the current default and nominal rate and rebuilds only on a real difference. Keeps the existing `rebuilding` gate semantics.
4. Tests: pure policy functions (`DaemonPolicy.shouldRebuildForRate(old:new:)`, a `Debouncer` with an injected clock) — rate 0 skipped, 48k→24k rebuilds, burst of 5 events → one reconcile.
Commit: `Coalesce device events, skip transient rates, follow sleep and wake`.

### A2 — DSP safety (Engine/Config)
1. Denormal flush: after each block, zero any biquad `z1/z2` (and meter envelopes) with magnitude below `Float.leastNormalMagnitude` — independent of the silence gate. Test: a decaying tail fed for 2 s ends with exact zeros, and processing time does not blow up (just assert zeros).
2. Stability guard: `BiquadCoefficients.isStable` (`|a2| < 1 && |a1| < 1 + a2`); `Config.validate` rejects a filter whose coefficients at 48 kHz are unstable (`ConfigError.filterUnstable(key, index)`), and `eq import` reports it clearly. Tests with a pathological Q/frequency.
3. Golden impulse-response tests: render a unit impulse through (a) one peak +6 dB @1 kHz Q 1.41 and (b) the full screenshot curve + 22 imported filters, at 48 kHz, through the real `EQProcessor.process`; compare the first 64 samples against golden arrays stored in `Tests/eqTests/Fixtures/golden-*.json` (generate once from the current code, commit, then the test guards regressions within 1e-6).
Commit: `Flush denormals, reject unstable filters, pin the impulse response`.

### A3 — observability (after A1)
1. Latency in `eq status`: engine computes `device latency + stream latency + safety offset + buffer frames` for the output device (and the tap aggregate's input side) in frames → ms at the nominal rate; `Status.latencyMs: Double?` (decodeIfPresent); text `latency 11.6 ms`; README "~10 ms" claim replaced by "shown in `eq status`; Bluetooth adds the headset's own latency".
2. Doctor probes: (a) **output with zero streams** — the default output device reports 0 output streams/channels (multi-output device misconfigured) → failure with a hint; (b) **permission revoked while running** — daemon state `running` but callbacks advance while the tap delivers only exact-zero frames for > 10 s *and* the system's other audio is playing is not detectable…: implement as the daemon setting `Status.tapSilentSeconds` (seconds since the last non-zero tap frame while callbacks advance); doctor warns when > 30 with "no audio reached the tap for N s — if something is playing, check System Audio Recording permission".
3. Tests for both probes with injected values; `Status` compat.
Commit: `Show latency; doctor checks zero-stream outputs and a silent tap`.
