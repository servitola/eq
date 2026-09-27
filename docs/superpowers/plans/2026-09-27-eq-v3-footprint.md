# eq v3 Footprint Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the daemon write, wake and leave behind as little as possible without touching how it sounds; measure before and after.

**Architecture:** Status writes become event-driven with a 30 s heartbeat and a `SIGUSR1` "write now" hook that `doctor` uses; the 5 s watchdog tick stays in memory. The IO buffer size gets an env override so 256 vs 512 can be measured on this Mac and the winner becomes the default. LaunchAgent/cask hygiene and log truncation live in the dotfiles/tap repos.

**Tech Stack:** unchanged. A new `scripts/footprint.sh` (zsh) for measurement.

Spec: `docs/superpowers/specs/2026-09-27-eq-v3-footprint.md`.

## Global Constraints

- Repo `/Volumes/SanDisk/projects/eq`, branch `main`, origin = gitea; never push from a task. Commit per task.
- Warnings are errors; language mode 5; no dependencies. 105 tests at the start.
- No change to the audio render path except the buffer size default (Task 3, after measurement).
- Constants: `DaemonPolicy.heartbeat = 30`, `Status.isFresh` default `maxAge = 90`, watchdog tick stays `statusInterval = 5`, `stallTicks = 2`; timer `leeway: .seconds(1)`.
- `EQ_IO_FRAMES`: integer 64…4096, else ignored with one log line.
- Comments only "why"; no banners; no TODOs.

---

### Task 1: Status on change + heartbeat; `SIGUSR1`; CLI trusts a live pid

**Files:** `Sources/eq/Daemon/Daemon.swift`, `Sources/eq/Daemon/Status.swift`, `Sources/eq/CLI/CLI.swift`; tests `DaemonPolicyTests`, `StatusTests`, `CLITests`.

**Interfaces:** `DaemonPolicy.heartbeat: TimeInterval = 30`; `static func shouldWriteStatus(changed: Bool, sinceLastWrite: TimeInterval) -> Bool` (`changed || sinceLastWrite >= heartbeat`); `Status.isFresh(now:maxAge: = 90)`.

- [ ] **Step 1: Tests**
  - DaemonPolicyTests: `testHeartbeatDecision` — `shouldWriteStatus(changed: true, sinceLastWrite: 0)` true; `(false, 29)` false; `(false, 30)` true; `heartbeat == 30`.
  - StatusTests: `testFreshnessDefaultIsNinetySeconds` — a status 60 s old is fresh, 91 s old is not (adjust the existing `testFreshnessAndLiveness` which asserts 16 s is stale → now stale at 91 s; keep the alive/pid assertions).
  - CLITests: `testShowUsesAliveStatusEvenWhenOld` — write a status with `updatedAt = Date().addingTimeInterval(-60)`, pid `getpid()`, device `BT-1`; `runCLI()` shows `JBL Big`. And `testShowIgnoresDeadPidStatus` — same but pid `2_000_000_000` → falls back to `defaultOutput` (`MacBook Pro Speakers`).
- [ ] **Step 2: Implement**
  - `Daemon`: `private var lastStatusWrite = Date.distantPast`; `writeStatus()` always writes (event path) and records `lastStatusWrite`; the 5 s timer handler runs the watchdog as today, then calls `writeStatus()` only if `DaemonPolicy.shouldWriteStatus(changed: false, sinceLastWrite: Date().timeIntervalSince(lastStatusWrite))`. `lastCallbacks` still refreshes every tick. Timer: `schedule(deadline:repeating:leeway: .seconds(1))`.
  - `SIGUSR1`: in `installSignalHandlers`, add a `DispatchSource.makeSignalSource(signal: SIGUSR1, queue: queue)` whose handler calls `writeStatus()` (after `signal(SIGUSR1, SIG_IGN)`).
  - `Status.isFresh` default 90; `CLI.currentDevice` uses `status.isAlive()` instead of `isFresh()`.
  - Where the daemon already calls `writeStatus()` on events (setState, applyProfile, reload, config error) nothing changes — those are the "changed" path.
- [ ] **Step 3:** `swift test` → 109. **Commit:** `Write status on change and every 30 s; SIGUSR1 writes it now`

### Task 2: Doctor audio check via `SIGUSR1`

**Files:** `Sources/eq/CLI/Doctor.swift`; `Tests/eqTests/DoctorTests.swift`.

**Interfaces:** `DoctorProbes.signalStatus: (pid_t) -> Bool` (live: `kill(pid, SIGUSR1) == 0`).

- [ ] **Step 1: Tests** — update the `probes(...)` fixture: `signalStatus: { _ in true }`; the `readStatus` closure flips `updatedAt` forward on each read after the first (so the "wait for a fresh sample" loop terminates immediately) and applies `callbacksLater` on the third read. Add `testAudioCheckSendsSignal` (a counter in `signalStatus` reaches 2) and `testAudioCheckWhenSignalFails` (`signalStatus: { _ in false }` → warning "could not signal the daemon").
- [ ] **Step 2: Implement** — audio row: `s0 = readStatus()`; `signalStatus(pid)`; poll `readStatus()` every 0.1 s up to 2 s until `updatedAt > s0.updatedAt` → `s1`; `sleep(1)`; `signalStatus(pid)`; poll again → `s2`; compare `s2.callbacks > s1.callbacks`. Warnings: signal failed; "status not refreshed after SIGUSR1 — daemon predates v3? restart it: launchctl kickstart -k gui/$UID/com.servitola.eq"; both zero → the existing predates-v2 hint. The `sleep` probe handles all waits (tests keep it a no-op).
- [ ] **Step 3:** `swift test` → 111. **Commit:** `Ask the daemon for a fresh status instead of waiting for the heartbeat`

### Task 3: Measure 256 vs 512 and choose

**Files:** `Sources/eq/Engine/ProcessTapEngine.swift` (or `Daemon.swift` where the engine is created), `scripts/footprint.sh`, `README.md`; test `DaemonPolicyTests` (env parsing).

**Interfaces:** `DaemonPolicy.ioFrames(from env: [String: String]) -> Int?` — `EQ_IO_FRAMES` parsed, valid only in 64…4096; the daemon sets `engine.requestedIOBufferFrames` from it at start and logs `IO buffer requested: N frames`.

- [ ] **Step 1: Test** `testIOFramesEnv`: `["EQ_IO_FRAMES": "512"]` → 512; `"7"` → nil; `"abc"` → nil; `[:]` → nil.
- [ ] **Step 2: `scripts/footprint.sh <pid> [seconds=30]`** (zsh, `set -euo pipefail`): prints a table: physical footprint (`vmmap -summary` "Physical footprint"), RSS (`ps`), CPU % (average of `top -l 3 -s 5` samples), context switches per second (`top -stats csw` first/last over the window), status.json mtime changes over the window (poll `stat -f %m` each second), threads, log line count. Pure measurement; no writes.
- [ ] **Step 3: Measure** on this Mac with music playing (the user's daemon): (a) baseline: `scripts/footprint.sh $(pgrep -f 'MacOS/eq daemon') 30`; (b) `launchctl bootout gui/$UID/com.servitola.eq`, run `EQ_IO_FRAMES=512 .build/release/eq daemon` in the background against the real config (`EQ_CONFIG` default) for the measurement, footprint it, kill it, `launchctl bootstrap` the agent back. Record both tables in the report. Requires audio playing: start the same tone loop as the smoke (`afplay -v 0.2` loop) and stop it after.
- [ ] **Step 4: Decide** per the spec rule; set `requestedIOBufferFrames` default accordingly; write the numbers into README "How it works" (one short paragraph: buffer, latency, csw/s, CPU). **Commit:** `Measure the IO buffer and set the default from the numbers`

### Task 4: LaunchAgent, cask and log hygiene (dotfiles + tap)

**Files:** `~/projects/dotfiles/launchagents/com.servitola.eq.plist`, `~/projects/dotfiles/macos_cleanup/cleanup_all.sh`, `~/projects/homebrew-tap/Casks/eq.rb`; in eq: `Sources/eq/Daemon/Daemon.swift` (log collapsing).

- [ ] plist: add `<key>LowPriorityIO</key><true/>`; `plutil -lint`; reload: `launchctl bootout gui/$UID/com.servitola.eq; launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.servitola.eq.plist`; `eq status` running.
- [ ] cask: `uninstall launchctl: "com.servitola.eq"` and `zap trash` add `"~/Library/LaunchAgents/com.servitola.eq.plist"`; `brew style`.
- [ ] `cleanup_all.sh`: add, next to the other log maintenance, a block that truncates `~/projects/dotfiles/cron/logs/eq.log` to its last 500 lines when larger than 1 MB (`tail -n 500 file > tmp && mv tmp file`); `zsh -n`.
- [ ] Daemon log: the sync-failure path logs `rebuild n/5 failed: why` per attempt; keep the first and log one summary line when the sequence ends (`rebuild failed 5 times: why` or `running after n attempts`). Watchdog/verification lines unchanged. Tests unaffected (log is stderr).
- [ ] Commits: dotfiles `launchagents: eq low-priority IO; cleanup: cap eq.log`; tap `eq: unload the agent on uninstall, zap the plist link`; eq `Log one line per rebuild sequence`.

### Task 5: Smoke + before/after table + changelog

**Files:** `scripts/smoke.sh`, `README.md`, `CHANGELOG.md`.

- [ ] smoke: during the existing tone phase, count `status.json` mtime changes over 20 s (poll each second): must be ≤ 2 (one heartbeat could land, plus the reload after `eq set`). Print `status writes N/20s` in the `smoke ok` line.
- [ ] README: a "Footprint" section with the before/after table from Task 3 and the targets met; mention `NO_COLOR`-style env `EQ_IO_FRAMES` as an escape hatch (not a feature).
- [ ] CHANGELOG `Unreleased`: Changed (status writes, heartbeat, SIGUSR1, buffer decision, log lines, LowPriorityIO, cask unload). **Commit:** `Smoke-test the status write rate; document the footprint`
