# eq v5 — presets and undo

Date: 2026-09-27. Status: approved in chat. Deltas on top of v1–v4.

## Why

Trying the watch keys changed the user's favourite curve by accident, and there was no way
back but retyping ten numbers. Curves worth keeping need names, and every change needs an
undo.

## Presets

Stored in the config next to the devices (v1–v4 configs load unchanged — `presets` optional):

```json
"presets": {
  "favourite": { "preamp": 0, "bands": [4.8, 4, 4.2, 2.3, 0, -3.1, 0, 0, 3.1, 2.4], "filters": [] },
  "flat":      { "preamp": 0, "bands": [0,0,0,0,0,0,0,0,0,0], "filters": [] }
}
```

- A device profile remembers where it came from: `"preset": "favourite"` (optional). Any
  later edit keeps the name but `eq` shows it as `favourite (modified)` when the profile no
  longer equals the preset (bands, preamp, filters).
- Names: 1–32 chars of letters, digits, `-`, `_`, `.`, space; case-insensitive lookup,
  stored as typed.
- **Seed:** when the config has no `presets` key, the daemon and `eq init` add `favourite`
  (the screenshot curve — `Config.screenshotCurve`) and `flat`. The user's existing config
  gets them on the first v5 run; nothing else changes.

```
eq preset                         list presets; the current device's one marked *
eq preset save <name> [--device Q]   save the current (or Q's) curve as <name>, overwriting
eq preset use <name> [--device Q]    apply <name> to the current (or Q's) device
eq preset show <name>             the curve as the eq table
eq preset rm <name>               delete (the devices that used it keep their curve)
eq preset rename <old> <new>
```

`--json` on all: list → `{"current": name|null, "presets": [{"name", "profile"}]}`;
save/use/show → the usual `ProfileReport` plus `"preset": name`.

## Undo

- `ConfigStore.save` keeps the previous file as `eq.json.1` … `eq.json.10` (rotating: `.1`
  is the newest previous version) before writing — the whole config, so any change (set,
  preamp, import, preset use, watch keys) can be undone.
- `eq undo` restores `eq.json.1` (validated first; the current file becomes the new `.1` so
  `eq undo` twice is a redo), prints what changed for the current device as the eq table.
  `eq undo --list` shows the ten backups with times and a one-line summary of the current
  device's curve in each.
- The daemon's own writes (name refresh) do not create backups (`save(_:backup: false)`).

## In `eq watch`

- `p` cycles presets on the current device (alphabetical, wraps); the header shows
  `· <preset>` or `· <preset>*` when modified.
- `u` undoes the last change made in this watch session (a session stack of profiles for the
  current device, not the file backups), repeatable back to the state at start.
- `s` saves the current curve as a preset: prompts for a name on the footer line
  (typed characters, Enter to save, Esc to cancel).
- The hint box gains `p preset · u undo · s save`.

## Not in scope

Sharing presets as files (`eq import` already reads curves), per-app presets.
