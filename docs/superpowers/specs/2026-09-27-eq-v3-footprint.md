# eq v3 — footprint: below the grass

Date: 2026-09-27. Status: approved in chat. Deltas on top of the v1/v2 specs.

## Why

The daemon should be invisible: no CPU you can see, no memory you can feel, no disk it
wears, nothing left behind. v2 already has a small physical footprint; what remains is
mostly what it *does* every few seconds and what it leaves on disk.

## Baseline (2026-09-27, v2026.09.27.1, Bluetooth playback on BE-RCA, 44.1 kHz)

| Metric | Value | How measured |
| --- | --- | --- |
| physical footprint | 6.5 MB (RSS 20 MB incl. shared libs; dirty 718 KB) | `vmmap -summary` |
| CPU while playing | 0.3 % | `top -l 3 -s 5 -pid` |
| context switches | ≈ 180 /s | `top … -stats csw` over 5 s — the IO callbacks at 256 frames / 44.1 kHz (≈ 172 /s) |
| threads | 6 | `top` |
| status.json writes | 12 /min, always (5 s timer) | code |
| log growth | 46 lines in 2 h; no rotation | `wc -l cron/logs/eq.log` |
| on disk | app 776 KB; cache 836 KB (AutoEq index); config 4 KB | `du` |
| after `brew uninstall --zap` | cache and config trashed; the LaunchAgent stays loaded and pointing at a missing binary | cask |

## Changes

1. **Status only when something changed, plus a slow heartbeat.** The daemon writes
   `status.json` on every state/device/profile/error change and otherwise every
   `heartbeat = 30 s`. `Status.isFresh` default max age becomes 90 s. The CLI's "current
   device" trusts a status whose pid is alive (`isAlive`), not a 15 s freshness. The
   watchdog keeps its 5 s tick but only reads `engine.callbacks` in memory; the tick writes
   nothing. Writes drop from 720/h to ≤ 120/h.
2. **`SIGUSR1` = write status now.** `eq doctor`'s audio check sends `SIGUSR1` to the daemon
   pid, waits for `updatedAt` to change (≤ 2 s), waits 1 s, sends it again, compares
   `callbacks`. No more 6 s polls, no dependence on the heartbeat.
3. **IO buffer measured, then chosen.** `EQ_IO_FRAMES` env (daemon only) overrides
   `requestedIOBufferFrames` so 256 vs 512 can be measured on this Mac: CPU %, context
   switches/s and latency. Decision rule: adopt 512 as the default if it halves context
   switches and CPU while playing (end-to-end latency ≈ 21 ms at 48 kHz, still under the
   ~40 ms lip-sync threshold); keep 256 otherwise. The measurement and the decision are
   recorded in README "How it works".
4. **Timer leeway.** The 5 s timer gets `leeway: .seconds(1)` so the kernel can coalesce
   its wakeups with others.
5. **LaunchAgent hygiene.** `LowPriorityIO` true in the plist (the process's disk IO is
   status/log only; the audio thread does no disk IO). Cask gains
   `uninstall launchctl: "com.servitola.eq"` so `brew uninstall` unloads the agent, and
   `zap trash` adds `~/Library/LaunchAgents/com.servitola.eq.plist` (the symlink).
6. **Log discipline.** The daemon logs state changes, device changes, reloads and errors
   only; the per-attempt "rebuild n/5" lines collapse into one line when the sequence
   ends. `cleanup_all.sh` (dotfiles) truncates `cron/logs/eq.log` to its last 500 lines
   when it exceeds 1 MB — the user's existing self-maintenance convention.
7. **Nothing else.** No new dependencies, no frameworks dropped (Foundation is the floor;
   the physical footprint is already 6.5 MB), no change to the audio path beyond the
   buffer size.

## Targets (after)

| Metric | Target |
| --- | --- |
| status.json writes | ≤ 120 /h while running (2 /min) |
| context switches while playing | ≤ 100 /s if 512 frames adopted, else unchanged |
| CPU while playing | ≤ 0.2 % (512) or unchanged |
| physical footprint | ≤ 7 MB (unchanged) |
| `brew uninstall --zap` | no process, no agent, no files under `~/.cache/eq`, `~/.config/eq`, `~/Library/LaunchAgents` |

## Testing

- Unit: `Status.isFresh` default 90 s; `DaemonPolicy.heartbeat = 30`; a pure
  `DaemonPolicy.shouldWriteStatus(changed:sinceLastWrite:) -> Bool`; doctor audio check with
  injected `signal` probe (sends, then the fixture flips `updatedAt`); CLI `currentDevice`
  prefers an alive status regardless of age; `EQ_IO_FRAMES` parsing (ignored unless
  64…4096).
- Smoke: unchanged pass; plus a count of `status.json` mtime changes over 60 s while playing
  must be ≤ 3.
- Measurement script `scripts/footprint.sh <pid> [seconds]`: prints footprint, CPU, csw/s,
  status writes/min, log lines — used for the before/after table in the README.
