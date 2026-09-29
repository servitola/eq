# 08 — A full terminal UI for eq: research

Date: 2026-09-29. Question: how do the best terminal UIs structure themselves, and what of that
does eq need to turn `eq watch` into `eq tui` without a dependency? Spec:
`docs/superpowers/specs/2026-09-29-eq-tui.md`.

Evidence levels: **[code]** read in eq at `85f1bac` or in a clone at the commit named;
**[measured]** run on this Mac (macOS 26, Swift 6.3.3, arm64); **[inferred]** our reasoning.
`trusted-sources.md` has no terminal-UI section; the primary sources here are the projects'
own repositories, cloned shallow and read, not articles about them.

Clones: bubbletea `ff51ba4` (v2 line, HEAD), bubbles `0a69b19`, lipgloss `6a419c6`, lazygit
`a3fae72`, k9s `b77c8c2`, btop `7b1f128`, htop `bb3ee0a`; ratatui, crossterm, textual, gitui,
bottom and the Swift libraries in §3–§5 at the commits named there.

## 1. What eq has today

### 1.1 Files and sizes [code]

| File | Lines | What |
| --- | --- | --- |
| `CLI/Watch.swift` | 557 | `WatchLayout.fit`, `Watch.frame` (pure, `[String]` with SGR), header dropping rules, `overlay` for the box, prompt step, solo request, `Watch.run` loop, `LiveTerminal` (termios, size, drain, emit) |
| `CLI/WatchKeys.swift` | 196 | `WatchAction`, `WatchKeys.action(for:)` (US + Russian letters by hand), CSI/SS3 parser, `KeyBuffer` (split reads, lone Esc), `HintBox` (box + compact line) |
| `CLI/Strip.swift` | 143 | the instrument strip on the log-frequency axis, bracket row |
| `CLI/Zones.swift` | 138 | `Instruments.all` with ranges, `InstrumentTable` (what `eq zones` prints) |
| `CLI/MeterClient.swift` | 101 | blocking socket reader; `poll` on socket + stdin, 0.1 s idle wake-up; `send` |
| `CLI/Paint.swift` | 66 | sixteen inks, `NO_COLOR`/`TERM=dumb`/TTY rule |
| `CLI/Table.swift` | 145 | labels/gains rows, profile tables |
| `CLI/Tuning.swift` | 248 | `filter`, bass/treble/tilt, `boost`, `comp`, `color` commands |
| `CLI/CLI.swift` 666–830 | ~170 | `eq watch` wiring, hint marker, `WatchSession` (edits, session undo, one backup per session) |
| Tests | 1 381 | `WatchTests` 306, `WatchKeysTests` 424, `WatchLoopTests` 139, `FocusTests` 270, … |

### 1.2 Every key the watch handles [code: `WatchKeys.action(for:)`, `actions(for:)`]

| Action | Keys (US) | Russian twins |
| --- | --- | --- |
| band n +0.5 | `1`…`9`, `0` | same |
| band n −0.5 | `! @ # $ % ^ & * ( )` | `! " № ; % : ? * ( )` (7 = `?` is lost to help) |
| preamp ±0.5 | `+ =` / `- _` | same |
| bass ±0.5 | `b` / `B` | `и` / `И` |
| treble ±0.5 | `t` / `T` | `е` / `Е` |
| next / previous preset | `p P ↓` / `↑` | `з З` |
| undo in session | `u U` | `г Г` |
| save as preset (prompt) | `s S` | `ы Ы` |
| zones strip | `z Z` | `я Я` |
| help box | `h H ?` | `р Р` |
| hide box for good | `x X` | `ч Ч` |
| quit | `q Q` Ctrl-C | `й Й` |
| focus next / previous instrument | `] Tab` / `[` | `ъ Ъ` / `х Х` |
| unfocus | `Esc` | — |
| listen (solo) | `l L` | `д Д` |
| knob ±0.5 | `→ . >` / `← , <` | `ю Ю` / `б Б` |
| compressor cycle | `c C` | `с С` |
| colour cycle / amount | `v` / `V` | `м` / `М` |

Other state the loop carries: `strip`, `focus`, `listening`, `dismissed`, `hintLeft`, `flash`,
`note`, `prompt`, `shown` (header snapshot, refreshed after an edit and every 30 frames),
`last` frame, `requestedAt` (rate the solo was asked at). 13 captured `var`s, 8 nested
functions, all inside one `source.lines` callback (`Watch.run`, L333–495).

### 1.3 Why the legend disappears [code]

- `hintFrames = 240` (L282): 8 s at 30 frames a second; counted per *frame*, so it also lasts
  forever when the daemon sends no frames.
- `handle(_:)` starts with `hintLeft = 0` (L420): **any** key, including `z` or a band step, hides
  it at once. This is the main cause: a user who presses a key to try it loses the legend.
- The compact one-line hint is the same state (`hint && !boxFits`, L147), so on a narrow
  terminal it goes too.
- `h` brings it back for another 8 s or until the next key — the next key being the one the user
  looked it up for.

### 1.4 Terminal handling today [code]

- Raw mode clears only `ICANON | ECHO`; `ISIG` stays so Ctrl-C reaches `SIGINT`
  (`LiveTerminal.enterRaw`). `SIGINT`/`SIGTERM` → `restoreTerminalAndExit` (termios + leave
  alternate screen + `_exit(0)`).
- No `SIGTSTP`/`SIGCONT`: Ctrl-Z stops the process with the alternate screen up and the terminal
  raw (BACKLOG). No `SIGHUP`. No crash handler: `Watch.padded` exists because "a trap bypasses
  every terminal-restore path".
- No `SIGWINCH`: the size is read every frame; a resize while frames stop is not seen until the
  next key.
- Every frame writes every line in full: `ESC[H`, each line + `ESC[K`, then `ESC[J`
  (`draw()`, L416) and a full `ESC[2J` after a resize. No synchronized output.
- Lone Esc: decided when the next read brings nothing; with frames that is the next frame
  (≤ 33 ms), without frames the 0.1 s idle wake-up.
- Mouse, bracketed paste, focus events: none.

### 1.5 What the rest of the CLI gives a TUI for free [code]

- `CommandHelp.all` (`Help.swift`) is the one table behind `--help`, the man page and the zsh,
  bash and fish completions; `Completions.forms` and `Completions.Kind` name every command path
  and what each operand completes to (devices, outputs, presets, instruments, bands, types,
  formats, apps). A command palette needs exactly this.
- `CLI.run(_:context:)` returns `(exitCode, output, isError, streamed)`; every command has a
  `--json` report struct (`DevicesReport`, `PresetsReport`, `FiltersReport`, `AppsReport`,
  `DoctorReport`, `HistoryReport`, …). Views can read these.
- `WatchSession.apply` already turns an action into a saved edit with session undo and one backup
  per session.
- The daemon socket speaks two kinds of client: meter (frames at 30/s, solo requests) and
  events (`{"subscribe":"events"}`, state changes only); at most eight clients together
  (README "Instruments").
- No colour forcing: `Paint.enabled` is false when stdout is not a TTY, so a child `eq` run from
  the palette prints plain unless the TUI gives it a pty or eq learns `CLICOLOR_FORCE`.

## 2. Go and C: Bubble Tea, Bubbles, Lip Gloss, lazygit, k9s, btop, htop

### 2.1 Event loop: everything becomes a message in one queue [code]

- **Bubble Tea**: input reader, renderer, SIGWINCH, SIGINT/TERM and every `Cmd` run on their own
  goroutines and all send into one `msgs` channel, drained by a single `select` in `eventLoop`
  (`tea.go:754-891`). Outside code injects with `Program.Send(msg)` (`tea.go:1194-1199`).
  `Cmd = func() Msg`; `Batch`/`Sequence` (`tea.go:902-968`); `Tick` wraps a timer
  (`commands.go:154-164`).
- **btop**: one main thread waits in `pselect(stdin, timeout)` (`btop_input.cpp:96-119`); a second
  thread collects and draws (`btop.cpp:455,1067`). Signal handlers set flags; resize does
  `kill(getpid(), SIGUSR1)` to interrupt the `pselect` (`btop_input.cpp:174`).
- **htop**: ncurses `halfdelay()` + blocking `getch()` (`ScreenManager.c:279`, `CRT.c:1208`);
  ncurses turns SIGWINCH into a `KEY_RESIZE` key (`ScreenManager.c:407-411`).
- Common to all three: **a signal only records that it happened; the loop does the work.** For eq,
  with one thread and `poll`, the self-pipe is the direct translation.

### 2.2 Rendering [code]

- **Bubble Tea HEAD has no line renderer any more.** `standardRenderer` is gone; the default is
  `cursedRenderer` (`tea.go:1064-1088`), a cell buffer with touched-cell tracking from the
  `ultraviolet` package, on its own goroutine at 60 fps by default, 120 max
  (`renderer.go:10-15`). The flagship Go TUI moved from line diffing to cell diffing.
- **Synchronized output (DEC 2026)**: Bubble Tea probes for it and otherwise hides the cursor around
  the write, "the best effort we can do" (`cursed_renderer.go:550-560`); btop wraps every frame
  unconditionally (`btop_tools.cpp:768-769`) and emits the frame as one buffered write
  (`btop.cpp:718-721`). Unconditional wrapping costs nothing on terminals that ignore the mode.
- lazygit avoids flicker above the terminal layer: it keeps old view content across panel swaps
  and skips a "loading…" placeholder when the new content is equal (`main_panels.go:45-51`,
  `tasks.go:355-358`). k9s shipped a fix for "flickering/jumping … in context suggestions caused
  by inconsistent spacing" (`change_logs/release_v0.50.10.md:70`): suggestion rows need a fixed
  height and width.

### 2.3 Terminal lifecycle [code]

- Bubble Tea: raw mode via `term.MakeRaw`/`Restore` (`tty_unix.go:15-19`); `shutdown` is
  `sync.Once` and runs on quit and from the panic recovery, which restores the terminal before
  printing the panic (`tea.go:1296-1330`). Suspend: `SuspendMsg` → release terminal, send
  `SIGTSTP` to the process group, wait for `SIGCONT`, restore (`tty.go:12-22`,
  `tty_unix.go:39-47`). Mouse is always SGR 1006 plus 1002 or 1003; bracketed paste on by default;
  focus reporting opt-in (`cursed_renderer.go:140-151`).
- btop: `Term::init`/`restore` (`btop_tools.cpp:141,176`) called from `clean_quit`, from
  `atexit` (`btop.cpp:1048`) and from the crash handler before re-raising (`btop.cpp:280-286`).
- **htop is the reference for crash safety**: `sigaction` with `SA_RESETHAND | SA_NODEFER` on
  SEGV/FPE/ILL/BUS/ABRT (`CRT.c:1088-1089`); `CRT_handleSIGSEGV` (`CRT.c:1436`) restores the
  terminal first, then writes its diagnostic with raw `write()` only.

### 2.4 Keymap as data [code]

- **Bubbles** `key.Binding{keys, help, disabled}` (`key/key.go:43-47`): `key.Matches` dispatches
  (`key/key.go:130-140`) and `help.KeyMap{ShortHelp, FullHelp}` renders from the same values
  (`help/help.go:18-27,128,171`); disabling a binding removes it from both at once. Short help is
  one line, full help is columns — the keybar and the `?` overlay.
- **lazygit** `types.Binding{Keys, Handler, Description, Tooltip, DisplayOnScreen, Alternative,
  Tag, OpensMenu, GetDisabledReason}` (`pkg/gui/types/keybindings.go:11-49`). The options bar is
  built from the focused context's bindings plus the global ones *whose key the context does not
  shadow*, filtered by `DisplayOnScreen && !IsDisabled()` (`pkg/gui/options_map.go:40-60`). `?`
  turns the same bindings into a filterable menu, with `@` to filter by key instead of text
  (`pkg/gui/controllers/options_menu_action.go:17-92`, `context/menu_context.go:100-108`). The docs cheatsheet is
  generated from the same bindings and checked by a test (`pkg/cheatsheet/generate.go`,
  `generate_test.go`) — the README-from-table pattern eq already uses for commands.
- **k9s** `KeyAction{Description, Action, Opts{Visible, Shared, Dangerous}}`
  (`internal/ui/action.go:24-46`): `Visible` hides a live key from the hint header, `Shared` keys
  (on every view) are left out of per-view hints (`action.go:192-220`), `Dangerous` ones are
  dropped in read-only mode (`action.go:165`). The hint header (`ui/menu.go:79-149`) is always
  on screen.
- **htop** `FunctionBar`: three parallel arrays — labels, key names, key codes
  (`FunctionBar.h:14-21`) — drawn by one loop (`FunctionBar.c:98-110`) and reverse-mapped for
  mouse clicks from the same arrays. Always visible.

### 2.5 Command prompt, panels, focus [code]

- k9s `:`: suggestions from a pluggable function; empty input shows history (`MaxHistory = 20`,
  `internal/model/history.go`), otherwise aliases and subcommands (`internal/config/alias.go:85-107`).
- lazygit has no `:` line but a type-to-filter menu (`context/filtered_list_view_model.go`).
- lazygit `ContextMgr` (`pkg/gui/context.go:18-171`): one stack of contexts, `Push`/`Pop`; a popup
  is pushed and closing it is `Pop`, nothing else to remember. k9s uses an observable page stack
  with breadcrumbs as a second listener (`internal/model/stack.go:35-44`, `ui/crumbs.go`); worth
  it only with several regions that react to navigation.
- htop's ScreenManager: a fixed row of panels and one focus index (`ScreenManager.c`).
- k9s recovers a panicking command and re-renders the last good view
  (`internal/view/command.go:352-367`) — the palette should likewise report a failed command in
  its pane and leave the TUI running (a child process gets that for free).

### 2.6 Width and colour [code]

- Bubble Tea and Lip Gloss measure through `ansi.StringWidth`/`GraphemeWidth` (external `ansi`
  package), `uniseg` only for border runes (`lipgloss/borders.go:11,547`); colour profile and
  `NO_COLOR` are delegated to `colorprofile.Detect` (`tea.go:1090`). Lesson: keep width and
  capability logic in one small unit, not spread through drawing code.

## 3. Rust and Python: ratatui, crossterm, Textual, gitui, bottom

Clones: ratatui `7767679`, crossterm `f6cb075`, ratatui-website `1659a28`, textual `06dbeef`,
gitui `2fa693c`, bottom `048deff`, termbox2 `cdf62e9`, notcurses `b26048e`.

### 3.1 Buffer, diff, double buffering [code]

- `Buffer{area, content: Vec<Cell>}`, row-major (`ratatui-core/src/buffer/buffer.rs:67-72`).
  `Cell{symbol: Option<CompactString>, fg, bg, diff_option}`: the symbol is a whole grapheme
  cluster (`buffer/cell.rs:38-73`).
- `Buffer::diff` yields only changed `(x, y, &Cell)`; unchanged cells cost a compare
  (`buffer/diff.rs:87-90,148-151`). Wide glyphs: the trailing column is skipped
  (`diff.rs:103-106`); a style-only change on a wide glyph repaints the whole glyph when the old
  style was visible on blanks (reverse, underline, background) (`diff.rs:40-41,158-172`);
  "uncertain width" symbols such as VS16 emoji get their trailing cells cleared defensively
  (`diff.rs:176-187`).
- `Terminal{buffers: [Buffer; 2], current}`: render into one, diff against the other, swap; no
  allocation per frame (`terminal/buffers.rs:97-124`). The app redraws the whole frame into the
  buffer every call; only the diff reaches the terminal (`terminal/render.rs:81-189`).
- **Synchronized output**: crossterm has `BeginSynchronizedUpdate`/`EndSynchronizedUpdate`
  (`crossterm/src/terminal.rs:433-490`) but ratatui's draw path never emits them; an app must.

### 3.2 Layout and widgets [code]

- Layout is a Cassowary solver (`kasuari`, ratatui's fork), solved on every `split`
  (`ratatui-core/src/layout/layout.rs:10-11,800,1248-1272`). More than eq needs: our screens
  are a stack of fixed rows around one flexible body.
- `Widget::render(self, area, buf)` consumes a throwaway value (`widgets/widget.rs:70-73`);
  `StatefulWidget` takes `&mut State` owned by the app — selection and scroll live in the model
  (`widgets/stateful_widget.rs:124-133`). This maps onto a pure `view(Model)`.
- The ratatui site documents two app patterns, the Elm architecture (one model, a message enum,
  pure update and view) and components (each with private state)
  (`ratatui-website: concepts/application-patterns/the-elm-architecture.md`,
  `component-architecture.md:20-38`). For eq the Elm form wins: the meter, the header and every
  view read the same profile, and golden tests need one value to render from.

### 3.3 Event loop and input [code]

- crossterm on Unix: one `mio::Poll` (kqueue) over the TTY, a SIGWINCH pipe and a waker
  (`event/source/unix/mio.rs:25-90`); leftover timeout tracked across wake-ups
  (`event/timeout.rs:5-38`). Same shape as `poll` over fds plus a self-pipe.
- bottom: three threads into one `mpsc` channel, main thread blocks on `recv`
  (`src/lib.rs:146,218,324,403`); input polled every 20 ms, wheel events debounced to 20 ms
  (`lib.rs:163,195`).
- **Lone Esc is decided by byte availability, not a clock**, in crossterm (bare `ESC` with more
  bytes already read → wait, else `Esc`; `event/sys/unix/parse.rs:26-42`, `mio.rs:198-209`),
  termbox2 (mode flags, no delay; `termbox2.h:314-320,540-558`) and notcurses (automaton resolves
  when input stops; `src/lib/in.c`). eq's `KeyBuffer` already follows this rule; the TUI only needs
  the "next read" to come at once (a zero-timeout re-poll) instead of at the next frame.
- Kitty keyboard protocol (crossterm `KeyboardEnhancementFlags`, CSI-u;
  `event.rs:266-291,501-593`) would tell Shift+6 from `:` on any layout, but only in terminals
  that implement it; not relied on.
- Textual: a message queue per node, superseding messages (resize floods) coalesced before
  dispatch (`message_pump.py:634-693`); reactive attributes refresh only what they flag
  (`reactive.py:316-369`). The coalescing idea carries over (keep only the last meter frame of a
  wake-up); the actor-per-widget model does not.

### 3.4 Restore [code]

- `ratatui::restore()`: raw mode off, then leave the alternate screen (`init.rs:622-627`);
  `set_panic_hook` wraps the existing hook so restore runs first (`init.rs:634-640`). crossterm
  keeps the original termios in a global and restores exactly that
  (`terminal/sys/unix.rs:108-160,300`), as `LiveTerminal` does.

### 3.5 One binding list, two projections [code]

- **gitui** `CommandInfo{text, enabled, quick_bar, available, order}`
  (`src/components/command.rs:39-51`); every component answers `commands(out, force_all)`,
  returning `Blocking` to stop propagation under a modal. The bottom bar filters `quick_bar`
  (`src/cmdbar.rs:119`); the help popup calls with `force_all = true` and groups
  (`src/popups/help.rs:100-121`). Keys are user-configurable (`src/keys/key_list.rs:37-246`).
- **Textual** `Binding{show, priority, key_display}` (`binding.py:64-76`); priority bindings are
  checked top-down before the focused widget, then the rest bottom-up from the focus
  (`app.py:3966-3988`). The `Footer` is derived from the active bindings. The command palette
  (`ctrl+p`) collects from `Provider`s and ranks with a fuzzy matcher
  (`command.py:179,532`, `fuzzy.py:155,192`).

## 4. Width on Darwin [measured]

A 10-line Swift program (`wcwidth(wchar_t(scalar.value))`), swiftc 6.3.3, macOS 26:

| Glyph | Before `setlocale` | After `setlocale(LC_CTYPE, "UTF-8")` |
| --- | --- | --- |
| `a` | 1 | 1 |
| `é` U+00E9 | −1 | 1 |
| `Й` | −1 | 1 |
| `中` | −1 | 2 |
| `█` `⇧` | −1 | 1 |
| `🎧` U+1F3A7 | −1 | 2 |
| U+0301 combining acute | −1 | 0 |

- **Without `setlocale` Darwin's `wcwidth` returns −1 for everything outside ASCII.** eq never
  calls `setlocale` today. `setlocale(LC_CTYPE, "")` follows the environment and fails the same
  way under `env -i` (no `LANG`); `setlocale(LC_CTYPE, "UTF-8")` works with an empty
  environment. The TUI sets `LC_CTYPE` explicitly at start.
- `wcwidth` is per scalar, so sequences are wrong: `❤️` (U+2764 U+FE0F) sums to 1 but terminals
  draw 2; ZWJ families sum too high. Swift gives `Unicode.Scalar.Properties.isEmojiPresentation`,
  `isEmoji`, `generalCategory` but no East Asian Width (the compiler rejects
  `properties.eastAsianWidth`). Rule used: iterate `Character`s (grapheme clusters); ASCII → 1;
  a cluster containing U+FE0F or whose first scalar `isEmojiPresentation` → 2; otherwise
  `wcwidth` of the first scalar, clamped to 0…2, −1 → 1. ratatui adds the same kind of hand-fixes
  on top of Rust's `unicode-width` (`cell_width.rs:42-60`).
- Everything eq draws itself is width 1. The rule matters only for device, preset and app names.

## 5. Swift prior art, and whether to depend on it [code]

| Library | Size | State | Model | Verdict |
| --- | --- | --- | --- | --- |
| rensbreur/SwiftTUI `5371330` | ~4.4k lines | no commits since 2024-07 | SwiftUI-style view tree; diffs at write time against a `[[Cell?]]` cache (`Renderer.swift:64-69`); `DispatchSource` read source on stdin + signal source for SIGWINCH (`RunLoop/Application.swift:60-90`) | a declarative view tree fights a 30 fps model pushed from a socket; unmaintained |
| migueldeicaza/TermKit `2cdfc96` | ~23.7k lines | active (2026-01) | gui.cs port, curses/terminfo driver, redraw throttled by `asyncAfter(1/60)` (`Core/Application.swift:648-654`) | 6× eq's whole CLI; windowing toolkit look |
| pakLebah/ANSITerminal `95f7cf1` | 815 lines | no commits since 2020 | escape helpers and a `readKey()` decoder | saves less than `WatchKeys` already does |

None clears the bar the zero-dependency decision set. The hard, eq-specific parts (decoder with
Russian twins and split reads, solo lifecycle, restore) are already written and tested here.

## 6. What eq takes, and what it leaves

| Pattern | Seen in | eq |
| --- | --- | --- |
| one loop, every source becomes a message | Bubble Tea `eventLoop`, bottom, crossterm | yes: `poll` + self-pipe, one thread |
| pure update returning effects | Bubble Tea `Cmd`, ratatui TEA | yes: `update(inout Model, Msg) -> [Cmd]` |
| cell buffer + diff + double buffer | ratatui, Bubble Tea HEAD `cursedRenderer` | yes: one diff pass, ≈150 lines; the meter redraws 30×/s and most of the screen is static |
| synchronized output, unconditional | btop | yes; ratatui leaves it to the app, Bubble Tea probes |
| one write per frame | btop | yes |
| Cassowary layout | ratatui | no: fixed rows + one flexible body; a one-pass splitter |
| binding = keys + help + bar flag + enabled | Bubbles, lazygit, k9s, gitui, Textual | yes, plus the Russian twin derived from a layout table |
| bar from focused context + unshadowed globals | lazygit `options_map.go:40-60` | yes |
| `?` overlay from the same list, filterable | lazygit, gitui | yes |
| docs generated from bindings, checked by a test | lazygit cheatsheet | yes: README keys, man KEYS |
| context stack for popups | lazygit `ContextMgr` | yes: modal stack + view stack |
| `:` prompt with history and completion | k9s | yes, but its grammar is `CommandHelp.all` + `Completions.Kind`, already in eq |
| fuzzy palette over providers | Textual | yes: two providers (eq commands, named actions) |
| crash handler restores first | htop, btop | yes: `sigaction` on TRAP/ILL/SEGV/BUS/ABRT |
| suspend: release, SIGTSTP, restore on SIGCONT | Bubble Tea `suspend()` | yes |
| Esc by byte availability | crossterm, termbox2, notcurses | yes (already); re-poll at once |
| Kitty keyboard protocol | crossterm | no: not portable to Terminal.app; revisit if layout collisions hurt |
| colour profile detection | Bubble Tea `colorprofile` | no: sixteen colours only; `Paint.enabled` rule stays |
| per-widget actors, reactive CSS | Textual | no |

Where the Go research disagreed: it judged a cell-diff renderer "massive machinery for a handful
of redraws per second". eq is not that case — the meter redraws 30 times a second while the
header, labels, gains, tabs and keybar stay put, and every non-meter view should cost nothing
when idle. The diff itself is small; the machinery Bubble Tea carries is its goroutine renderer
and terminal probing, which eq skips.

## 7. The user's terminal [measured]

`$TERM_PROGRAM` is `tmux` (3.7c, `escape-time 10`) inside Zap, a Warp fork (dotfiles
`cron/scripts/zap-sync.sh`). tmux's 10 ms escape-time already splits a lone Esc from a sequence
before eq sees it. Synchronized output, SGR mouse and focus events through tmux into Zap are
unverified; M2 checks them on this stack.

## 8. Baseline, measured in M1 [measured]

Method: a release build (`swift build -c release`) of `eq watch` on a pseudo-terminal of 120×40
(Python `pty.fork`, `TIOCSWINSZ`, `TERM=xterm-256color`, so colour is on), 2 s of warm-up, then
60 s. CPU is the process's own CPU time from `ps -o time=` at the start and end of the 60 s,
divided by wall time, cross-checked by `ps -o %cpu` once a second; bytes are everything read
from the pty master, frames the count of `ESC [H` in it. Two sources: the live daemon (driver
mode, BE-RCA, 44.1 kHz; nothing was playing, so every level sat at the −60 floor) and a fake
meter socket (`EQ_STATUS` in a scratch directory) sending 30 frames a second of levels moving
between −60 and −1 dBFS, which draws what music draws without touching audio. The harness is
not in the repo; it is 50 lines around `ps` and `select`.

| Build | Source | CPU | Frames/s | Bytes/frame | KiB/s |
| --- | --- | --- | --- | --- | --- |
| before M1 (`350cfd6`) | live, silent | 99.5 % | 23.7 | 6 384 | 148 |
| before M1 (`350cfd6`) | fake, moving | 99.8 % | 16.2 | 7 703 | 122 |
| `Paint` fix only | live, silent | 3.4 % | 30.0 | 4 446 | 130 |
| `Paint` fix only | fake, moving | 5.2 % | 30.0 | 7 631 | 224 |
| M1 (keybar, overlays) | live, silent | 3.7 % | 30.0 | 4 553 | 134 |
| M1 (keybar, overlays) | fake, moving | 5.7 % | 30.0 | 7 597 | 223 |

The first measurement found the watch taking a whole core and falling behind the daemon's 30
frames. `sample` put most of it in `Paint.enabled`: every `Paint.ink` call read
`ProcessInfo.processInfo.environment`, which builds a dictionary of the whole environment, and a
120×40 frame paints several hundred spans. Reading `NO_COLOR` and `TERM` with `getenv` took it to
3–6 %; the byte counts before the fix are lower only because frames were dropped. The keybar
costs about 0.3 % and ~100 bytes a frame. The M2 budget is set against the M1 rows: CPU no higher
than 5.7 % with moving levels, and at most 60 % of 7.6 KB, ~4.5 KB, a frame.
