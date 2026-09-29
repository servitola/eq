# eq backlog

## Next round (v5): colour everywhere
- `eq --help` / `eq help` / usage on errors painted: command names bold, flags cyan,
  placeholders (`<band>`, `Q`) yellow, descriptions plain, section headings dim; aligned
  columns that fit the terminal width (no wrapping like `…1kh\nz -3`), grouped: look
  (`eq`, `devices`, `status`, `watch`, `zones`, `stream`), tune (`set`, `preamp`, `flat`,
  `copy`, `import`, `on/off`), setup (`init`, `doctor`, `daemon`).
- Every text output painted by the same sixteen-colour rules: `status` (already), `devices`
  (already), `doctor` (already), `import` summaries, `copy`, `init`, `on/off`, error lines
  (`error:` red, the hint after it yellow), `zones` (names dim, spans in band inks).
- `--json` on a terminal is pretty and coloured like `jq`: keys blue, strings green,
  numbers yellow, `true/false` cyan, `null` dim, punctuation dim. Piped or `NO_COLOR` →
  plain JSON exactly as today (scripts and the tests parse it).
- Pipes and `NO_COLOR` stay plain.

## Follow-ups from the v4 review
- Hide zones with no visible band at narrow widths.
- `eq zones` without a config/device; fit it to the terminal width.
- Option C of watch was done as keyboard tuning; arrows for band select + fine steps later.

## Follow-ups from the v7 review
- A same-user connect flood keeps the accept loop busy (accept-and-close until EAGAIN).

## Follow-ups from the Round D release
- `eq --version` (and `-V`) — today only `eq status` and `eq doctor` show the version.
- After a restart on BE-RCA (Bluetooth) with nothing playing, the engine got no IO callbacks for
  ~70 s and rebuilt every ~15 s ("IO stalled for 10 s") until a sound woke the device. Check whether
  a silent Bluetooth output that never starts IO should be waited on instead of rebuilt.
- fish completions are unvalidated (fish is not installed here).
- This Mac still runs the legacy dotfiles plist. Migration to the bundled login item failed here
  only because of my own probe apps: one registered the label `com.servitola.eq.daemon`, and
  background task management kept that record after the probe was deleted. xpcproxy then
  resolved EQ's job to the deleted probe (EX_CONFIG 78), and SMAppService now reports
  `notFound` for EQ.app. Retry `eq agent install --replace-legacy` after a reboot; if it still
  fails, `sfltool resetbtm` (admin, reboot, resets every login item's approval).

## Driver mode (design A) — live trial of Proxy Audio Device v1.1.0b1 (started 2026-09-28 21:28)
- eq's legacy agent booted out; output = Proxy Audio Device → BE-RCA; no Privacy indicator.
- Found: after `killall coreaudiod` the plug-in loaded before the Bluetooth speaker appeared,
  logged "setupTargetOutputDevice could not find output device" and never retried — silent until
  the target was re-selected in its settings. A fork must retarget when the device list changes.
- Watch for: dropouts, crackle, after sleep/wake, BT reconnect, reboot (expect the same silence),
  volume keys; lip sync will be off (Proxy reports 0 latency).
- Restore eq: `launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.servitola.eq.plist` and
  `SwitchAudioSource -t output -s BE-RCA`.
- Driver mode: right after a retarget `eq status` can show the previous target's latency for up
  to 30 s (seen: 46 ms, the speakers', after switching back to BE-RCA; the plug-in itself
  already reported 212 ms). Write status once the plug-in's latency settles after a retarget.
- Overnight 2026-09-28→29 on BE-RCA: 0 underruns/overruns/stalls/start failures; 12 rebuilds
  and 12 resyncs recovered on their own (likely sleep/wake), 17 retargets.
