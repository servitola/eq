# CLI design for eq v-next

Research base: [clig.dev](https://clig.dev/), [CamillaDSP](https://github.com/HEnquist/camilladsp) ([websocket API](https://henquist.github.io/0.5.0/websocket.html)), [PipeWire `wpctl`](https://pipewire.pages.freedesktop.org/wireplumber/man/wpctl.html)/[`pw-dump`](https://docs.pipewire.org/page_man_pw-dump_1.html), [EasyEffects](https://github.com/wwmm/easyeffects/discussions/1337), [JamesDSP/JDSP4Linux](https://github.com/timschneeb/JDSP4Linux), [PulseAudio `pactl`](https://man.archlinux.org/man/pactl.1.en), [SwitchAudioSource](https://github.com/deweller/switchaudio-osx), [nowplaying-cli](https://github.com/kirtan-shah/nowplaying-cli) / [media-control](https://github.com/ungive/media-control), [SoX](https://manpages.org/sox)/[ffmpeg `superequalizer`](https://ayosec.github.io/ffmpeg-filters-docs/8.0/Filters/Audio/superequalizer.html)/[`firequalizer`](https://ayosec.github.io/ffmpeg-filters-docs/3.1/Filters/Audio/firequalizer.html), [Rogue Amoeba scripting](https://rogueamoeba.com/support/manuals/audiohijack/?page=scripting) ([SoundSource Shortcuts](https://sixcolors.com/post/2022/05/soundsource-5-5-adds-shortcuts-support-for-full-mac-audio-automation/)), [blueutil](https://github.com/toy/blueutil), [`gh`](https://cli.github.com/manual/gh_help_formatting), [`kubectl`](https://kubernetes.io/docs/reference/kubectl/), [Tailscale CLI](https://tailscale.com/kb/1080/cli), [launchctl bootstrap/kickstart notes](https://gist.github.com/masklinn/a532dfe55bdeab3d60ab8e46ccc38a68), [Swift ArgumentParser completions](https://github.com/apple/swift-argument-parser/blob/main/Sources/ArgumentParser/Documentation.docc/Articles/InstallingCompletionScripts.md).

Current `eq` state, for reference: `Sources/eq/CLI/CLI.swift:40-65` (usage text), `Sources/eq/CLI/Output.swift` (per-command report structs), `README.md` command table, `CHANGELOG.md`. No `swift-argument-parser` dependency — argument parsing and the usage string are hand-rolled (`Package.swift` has zero dependencies).

## What the best tools actually do

- **Validate, then apply, as two different verbs.** CamillaDSP's `ValidateConfig` type-checks and fills defaults with *no side effect*; `SetConfig`/`PatchConfig` apply, and apply is a **diff against the running graph**, not tear-down/rebuild — a biquad coefficient swap is inaudible, only a structural change clicks. `kubectl apply --dry-run=server` runs the same validation/admission path as a real apply and discards the result. Lesson: an `eq` config write should get the same treatment — validate the JSON before it hits the file the daemon watches, and let `eq set` be phrased, internally, as "patch this device's profile," not "replace the file."
- **One JSON dump + a `--monitor`/`--watch` diff stream is the whole automation story**, done once, well. `pw-dump --monitor` streams incremental JSON diffs of the entire graph on change — this is what scripts hook into instead of polling. `pactl subscribe` is the ancestor: it works, but it's plain text with no JSON option even in 2026, and volume/mute JSON output only landed in 2025 — a cautionary tale about deciding JSON for *every* surface (including the event stream) up front rather than retrofitting it per-command.
- **A stream tags what's actually new.** `media-control stream` (the actively maintained now-playing daemon successor to `nowplaying-cli`) emits one JSON object per line with a `diff:false` flag marking the first line of a genuinely new state, so consumers filter noise from real change with a one-line `jq` clause instead of hand-rolled debouncing.
- **A daemon-behind-a-socket CLI needs a liveness verb with a boring, scriptable exit code.** JamesDSP's `--is-connected` returns non-zero if the backend is down — nothing fancier. Tailscale's `tailscaled`/`tailscale` split puts all client commands behind a local socket (`--socket=<path>` override) so `tailscale status --json` never touches the network layer directly.
- **`--json` is a first-class, uniform contract, not per-command JSON-as-afterthought.** `gh`'s model: `--json <fields>` picks the shape, `--jq <expr>` filters it in-process (no external `jq` needed, though piping to real `jq` is the documented common case), `--template` renders it to text when JSON isn't the point. `kubectl -o json|yaml|jsonpath|custom-columns` is the same idea with more formats. Both keep keys **stable and sorted**, which is what makes them pipe cleanly.
- **Hide diagnostics, don't invent new top-level nouns for them.** `tailscale debug <subcommand>` bundles internal diagnostics (derp map, component logs, prefs dump, packet capture) under one namespace, deliberately unlisted in normal `--help` — a healthy escape hatch (cf. `gh api`) that doesn't clutter the primary command tree.
- **Fixed, addressable band indices beat free-form expressions for a scriptable multi-band tool.** ffmpeg's `superequalizer` (18 fixed named bands, `b1=1.5:b8=0.8`) is trivially scriptable; `firequalizer`'s `gain_entry='entry(freq,dB); ...'` expression string is powerful but nobody hand-writes it. SoX's repeated `equalizer freq width gain` clauses are elegant for unbounded ad-hoc bands but have no addressable identity — you can't say "band 3," only resupply everything. `eq`'s ten fixed bands (`32hz…16khz`) already sit in the good camp; keep it that way when parametric filters grow a CLI surface.
- **macOS automation increasingly means Shortcuts.app actions, not AppleScript.** SoundSource dropped its AppleScript dictionary entirely in favor of 17 Shortcuts actions; Audio Hijack exposes a JS automation API plus Shortcuts actions and lifecycle hooks (`sessionWillStart`, `fileDidEnd`, …). Only legacy Airfoil still ships a classic AppleScript dictionary. blueutil's `--wait-connect`/`--wait-disconnect` (a blocking poll, documented as flaky) is the counter-example: a real event push beats a "block until" flag.
- **Config precedence and location are a solved problem.** clig.dev: flags → env → project config → user config → system config, XDG paths (`~/.config`), ask before touching a file your program doesn't own. `eq.json` under `~/.config/eq/` is already correct.

## Anti-patterns in `eq` today (cited)

1. **Flat, ungrouped top-level namespace mixing nouns and verbs.** `CLI.swift:40-63` lists `set`, `preamp`, `flat`, `copy`, `import`, `devices`, `on`, `off`, `status`, `doctor`, `stream`, `watch`, `zones`, `preset`, `undo` all at the same level. `preset` is the only noun that groups its own verbs (`save|use|show|rm|rename`); `devices`, `import`, `copy` are all "device/profile" concerns scattered as siblings instead of grouped the way `preset` already is. clig.dev and `gh`/`kubectl` both converge on consistent noun-verb (or verb-noun) grouping — `eq` is inconsistent about which pattern it uses per command.
2. **`Q` as the device metavariable in usage text** (`CLI.swift:44,47,48`: `[--device Q]`, `copy --to Q`) collides with the domain term "Q" (filter quality factor) that the same tool's `filters` table (README "AutoEq" section, `Filter.q`) uses for something else entirely. A CLI that talks about parametric Q *and* uses `Q` as a device placeholder in its own help text will confuse a user reading both in one screen.
3. **Inconsistent shape for "which device."** `set`/`preamp`/`flat`/`preset` take `--device <name>`; `copy` takes `--to <name>` for the *destination* with no `--device` for the source (source is implicitly "current"), a one-off flag name for a concept every other command spells `--device`.
4. **No `--dry-run` on any state-changing command.** `set`, `preamp`, `flat`, `copy`, `import`, `preset save/use/rm/rename` all write `eq.json` immediately. clig.dev calls dry-run out explicitly for exactly this class of command; `eq import` (fetches and applies an external correction) is the single best candidate — right now the only way to preview an AutoEq import is to apply it and `eq undo` if it's wrong.
5. **`eq undo` overloads repetition as a hidden mode** (`CLI.swift:62`: "restore the config before the last change (twice = redo)"). A command whose *second invocation does something different from its first* is undiscoverable without reading the README — clig.dev's subcommand rule is the opposite: consistent, predictable verbs. `git`'s `undo`/`redo` (or `eq undo`/`eq redo` as two verbs) says the same thing in text instead of in invocation count.
6. **No schema-version field on any JSON payload.** Every `--json` report (`Output.swift:20-68`: `ProfileReport`, `DevicesReport`, `ImportReport`, `UndoReport`, `ErrorReport`, …) is a bare, independently-shaped struct with no `schemaVersion`/envelope key. `Status.version` (`Status.swift:26`) is the **daemon binary's semver**, reused to infer wire-format generation (see `CHANGELOG.md` 2026.09.27.2: "a daemon on a different version than the `eq` binary is reported as a warning") — conflating "what version of the software is this" with "what shape is this JSON" means a payload-shape change either forces a version bump for an unrelated reason, or ships silently and breaks a `jq` script mid-stream. `gh --json`/`kubectl -o json` consumers rely on stable, versioned shapes for exactly this reason.
7. **No automation hook beyond the meter stream.** `eq stream` (`README.md:65`) covers *level* data at 30 Hz; nothing tells a script "the active device changed," "a profile was edited," or "bypass was toggled" — the only way to react to a device switch today is to poll `eq status --json` or `eq devices --json` in a loop. Every audio tool studied above (PipeWire's `--monitor`, pactl's `subscribe`, Audio Hijack's lifecycle hooks) treats this as core surface, not an add-on.
8. **No shell completions, no man page.** `eq` hand-rolls argument parsing (`Package.swift` has no dependencies) instead of using `swift-argument-parser`, which would have generated `bash`/`zsh`/`fish` completions and a man page for free from the same command declarations that produce `--help`.
9. **Hand-maintained usage string as the single source of truth for the whole command tree.** `CLI.swift:40-65` is one string literal every new command must be added to by hand, with no structural check that it matches what `dispatch()` actually accepts — the source of anti-patterns 1-3 above, since nothing forces consistent shape across entries.

## Proposed command tree

Group by noun, keep verbs consistent across nouns, keep the existing bare `eq` (no args) as the one blessed shortcut — it's the single most common invocation and matches clig.dev's "make current state easy to view."

```
eq                                   current device's curve (unchanged — the whole point of the tool)
eq set <band> <gain>... [--device <name>]
eq preamp <gain> [--device <name>]
eq flat [--device <name>]

eq device list                       -- was `eq devices`
eq device copy --from <name> --to <name>   -- was `eq copy --to`; --from defaults to current
eq device on | eq device off         -- was top-level `eq on` / `eq off`; alias `eq on`/`eq off` kept for muscle memory

eq preset list                       -- was bare `eq preset`
eq preset save|use|show|rm <name> [--device <name>]
eq preset rename <old> <new>

eq import <file|url|name> [--device <name>] [--source <name>] [--keep-bands] [--refresh] [--dry-run]
eq import clear [--device <name>]    -- was `eq import --clear`: a flag standing in for a verb

eq history                           -- was `eq undo --list`
eq undo | eq redo                    -- was `eq undo` / `eq undo eq undo`

eq status [--json]
eq doctor [--json]
eq events [--json]                   -- NEW: see below
eq watch [--zones]
eq stream
eq zones

eq daemon                            -- unchanged, LaunchAgent entry point
eq debug <subcommand>                -- NEW: namespace for internal diagnostics (see below)
eq completion bash|zsh|fish          -- NEW
eq init
```

Renames are additive-compatible: keep every current spelling as a hidden alias for one release cycle (`eq devices`, `eq copy --to`, `eq import --clear`, `eq undo --list` all still work, undocumented in `--help`, removed after a deprecation warning has shipped for one release — clig.dev's "warn before breaking, keep changes additive" rule, and `eq`'s own JSON compatibility precedent already exists for old daemon status fields, `Status.swift:70-88`).

### Naming conventions
- **Noun before verb**, always: `eq device copy`, `eq preset save`, never a bare verb at the top level except the handful that *are* the product's one job (`set`, `preamp`, `flat`, `on`/`off` stay top-level exactly because they're what `eq` is for — clig.dev's own example, `docker container create`, still keeps `docker run` as a top-level shortcut for the same reason).
- **`<device>` as the metavariable everywhere**, never `Q` — resolves anti-pattern 2, and doubles as the thing `--device` always means.
- **`--from`/`--to` only for genuinely two-sided operations** (`device copy`); everything else takes one `--device`.
- Flags to standardize per clig.dev's reserved short flags: `-q/--quiet` for scripting contexts, `-n/--dry-run` wherever a command writes `eq.json` or fetches a network resource (`import`), `--no-input` for `import` when a name matches multiple AutoEq sources and would otherwise prompt.

## Output conventions

- Human output keeps the current three-line/table shape and spark-row colour (`README.md` "Colour" section) — that part is already right: `NO_COLOR`/`TERM=dumb`/non-TTY already turn it off (`CLI.swift`, existing behavior).
- **Every `--json` payload gets an envelope with an explicit, independent schema version**, decoupled from the daemon binary version that already tracks wire-format generation for `Status`:
  ```json
  { "schemaVersion": 1, "command": "device.list", "data": { ... } }
  ```
  `schemaVersion` bumps only when a field is removed or changes meaning (additions don't bump it, matching clig.dev's "keep changes additive"); `command` is fixed per report type and gives a `jq`-able discriminator when multiple `eq --json` outputs are concatenated in a log. This directly fixes anti-pattern 6.
- Keys stay sorted (already true — `JSONEncoder`'s `.sortedKeys`, `CLI.swift:103`) and error shape stays exactly what it is today (`ErrorReport`, exit code convention `0`/`1`/`2` unchanged) — no reason to touch either, they already match `gh`/`kubectl` conventions.
- `--json` remains a global flag usable on any command (current behavior, `CLI.swift:72-73`) rather than `gh`'s per-command opt-in — for a ten-command tool, uniform is simpler and there's no reason to regress that.

## `eq events`: the automation hook

The gap this closes: nothing today tells a script "the output device changed" or "a profile was edited" without polling. Model it directly on PipeWire's `pw-dump --monitor` and pactl's `subscribe`, but JSON from day one (the thing pactl got wrong for a decade):

```
eq events [--json]
```

Blocks, one line per event, until Ctrl-C — same shape as `eq stream` (which stays the meter-only feed; don't conflate levels with state changes). Event types: `device.changed` (default output switched), `profile.changed` (bands/preamp/preset edited on any device, with the device and what changed), `bypass.changed` (`on`/`off`), `daemon.started`/`daemon.stopped`. Each line: `{"schemaVersion":1,"event":"device.changed","at":"...","data":{...}}` — newline-delimited JSON, trivially `jq`-filterable, exactly `media-control stream`'s shape. No text mode needed; this command exists for scripts, not eyes — `--json` here is really "always on," but keep the flag for consistency with every other command rather than special-casing it (contrast with `eq watch`, which correctly *refuses* `--json` today because it has no non-visual meaning, `CLI.swift:75`).

**Hooks**, for the common case of "run a command when X happens" without keeping a process alive to consume `eq events`: an optional `hooks` object in `eq.json` itself, since the daemon already watches that file —
```json
"hooks": { "onDeviceChange": "/path/to/script", "onBypassChange": "/path/to/script" }
```
the daemon runs the script (fire-and-forget, stdout/stderr to its own log) on the matching transition. This is the config-driven equivalent of Audio Hijack's `sessionWillStart`/`fileDidEnd` lifecycle scripts, scoped to what a headless daemon actually knows about (device and bypass state, not arbitrary session semantics) — no new daemon surface, no new IPC, just a field the file-watcher already has to read.

## Shortcuts / URL scheme

`EQ.app` already exists as an `LSUIElement` bundle (README "Install" — it's what carries the System Audio Recording permission grant). That bundle is the natural place to register a custom URL scheme, `eq://`, rather than writing a full Shortcuts Action Extension:

```
eq://set?device=<name>&band=64hz&gain=%2B4
eq://preset?use=<name>&device=<name>
eq://toggle?on=false
```

The app's URL handler shells out to the same `eq` binary it already bundles (`/Applications/EQ.app/Contents/MacOS/eq`) with the equivalent CLI invocation — one code path, two entry points. This gets "run from Shortcuts.app" (Shortcuts' built-in "Open URLs" action) and "run from a keyboard-maestro-style trigger" for free, matching the direction Rogue Amoeba's whole product line moved (Shortcuts over AppleScript) without the cost of an Action Extension target. Skip AppleScript entirely — every tool surveyed that still has an AppleScript dictionary (Airfoil) is explicitly the legacy one in its own product line.

## Diagnostics namespace

`eq debug <subcommand>` (unlisted in top-level `--help`, documented on its own page), mirroring `tailscale debug`: `eq debug config` (raw parsed config + resolved device UIDs), `eq debug tap` (Core Audio tap state dump), `eq debug bugreport` (zips config + recent log + `eq doctor --json` into one file to attach to an issue, à la `tailscale bugreport`). Keeps `eq doctor` as the one health check a normal user runs, and gives issue reports a single boring command instead of "paste your config, your log, and the output of doctor" by hand.

## Completions and man page

Adopt `swift-argument-parser` for the whole CLI (anti-pattern 8/9): declaring the command tree as `ParsableCommand` types is both the fix for the hand-maintained usage string (anti-pattern 9 — the tree becomes the single source of truth `--help`, completions, and dispatch all read from) and gets `--generate-completion-script bash|zsh|fish` and man-page generation for free, matching what `kubectl`, `gh`, and SwiftPM itself ship. `eq completion <shell>` becomes a thin wrapper printing that generated script to stdout, installed the standard way (`eq completion zsh > ~/.zsh/completion/_eq`) — no new mechanism to invent, no hand-maintained completion file to keep in sync as commands change.

## Summary of the delta

| Area | Today | Proposed |
| --- | --- | --- |
| Command tree | flat, mixed noun/verb | grouped under `device`/`preset`/`import`/`debug`, core verbs stay top-level |
| Device placeholder | `Q` | `<device>` |
| Dry-run | none | `--dry-run` on `import`, `set`, `preamp`, `flat`, `preset save` |
| Undo/redo | one command, invocation-count toggles mode | `eq undo` / `eq redo` / `eq history` |
| JSON schema | bare struct per command, no version | `{schemaVersion, command, data}` envelope |
| Automation hook | meter stream only (`eq stream`) | `+ eq events` (state changes) `+ hooks{}` in config |
| macOS automation | none | `eq://` URL scheme via existing `EQ.app` bundle |
| Diagnostics | mixed into `doctor`, ad hoc | `eq debug <subcommand>`, unlisted, `bugreport` |
| Completions/man | none, hand-rolled parsing | `swift-argument-parser`, generated for all three shells |

Net new top-level surface: `device`, `import clear` (verb, not flag), `history`, `redo`, `events`, `debug`, `completion` — seven additions to a ten-command tool, each earning its place by closing a concrete gap found above; everything else is a rename with a compatibility alias, not a rewrite. Stays a headless, file-and-socket tool throughout — no new daemon process, no new IPC transport, no GUI.
