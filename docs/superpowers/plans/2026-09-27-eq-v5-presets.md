# eq v5 presets + undo — plan

Spec: `docs/superpowers/specs/2026-09-27-eq-v5-presets.md`. Repo rules as before (main, gitea, never push from a task, warnings are errors, comments only "why"). ~185 tests at start.

### Task 1: config + store + CLI
- `Config.presets: [String: Profile]` (decodeIfPresent → nil means "never seeded"), `Profile.preset: String?`; `Config.seedPresetsIfNeeded() -> Bool` adds `favourite` + `flat` when `presets == nil`; validation of names and preset profiles; case-insensitive lookup helper.
- `ConfigStore.save(_:backup: Bool = true)` rotates `eq.json.1…10` (rename chain, oldest dropped) before the atomic write; `backups() -> [(URL, Date)]`; `restore(index:)` swaps.
- Daemon: seed on start (save once, no backup) and name-refresh saves with `backup: false`.
- CLI: `eq preset [save|use|show|rm|rename]`, `eq undo [--list]`; `eq`/`set`/… show `favourite (modified)` in the header when relevant; usage lines; `--json`.
- Tests: seeding once; round-trip v4 config; backup rotation (11 saves → 10 files, `.1` newest); undo twice = redo; preset save/use/rm/rename/case-insensitive; modified marker.
- Commit `Presets and undo`.

### Task 2: watch keys + docs
- `p` cycle presets, `u` session undo, `s` save-as prompt on the footer; header preset name; hint box lines; key mapping incl. Russian letters on the same keys (`з` p, `г` u, `ы` s).
- README (Presets, Undo sections; watch keys table), CHANGELOG Unreleased.
- Tests: `p` cycles and wraps; `u` restores the start state after two edits; `s` + typed name + Enter calls save with that name; Esc cancels.
- Commit `Presets and undo in watch`.
