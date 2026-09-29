# 09 — What makes a terminal UI look expensive, and what eq takes from it

Date: 2026-09-29. Question: the user's verdict on the M1 screen was "not bad, but too few colours
and too little detail; it needs the feel of a luxury panel", then "the dense graphic look is
great, and a living mixing-desk look is interesting too; make them selectable". What do the
best-looking terminal programs and audio hardware actually do, and what does it cost in bytes
at 30 frames a second? Spec: "Visual design" in `docs/superpowers/specs/2026-09-29-eq-tui.md`.
Mocks: `docs/design/tui/` (open `preview.html`).

Evidence levels as in `08-tui.md`: **[code]** read in a shallow clone at the commit named;
**[measured]** on this Mac; **[doc]** the project's or maker's own documentation;
**[inferred]** our reasoning. Clones (2026-09-29): btop `7b1f128`, cava `2992198`, ncspot
`386b6a9`, spotify-player `7dc9d17`, gping `fad1ee3`, bottom `048deff`, colorprofile `51fafca`,
lipgloss `6a419c6`, glow `6b365ee`, lazygit `a3fae72`, k9s `b77c8c2`, tmux `30e6a55`.

## 1. Terminal programs

### 1.1 btop — gradients, rounded boxes, braille graphs [code]

- **A theme is named tokens, most of them gradient triples.** `Default_theme`
  (`src/btop_theme.cpp:52-101`): `main_bg`, `main_fg`, `title`, `hi_fg`, `selected_bg/fg`,
  `inactive_fg`, `graph_text`, `meter_bg`, `div_line`, four `*_box` border colours, then
  `cpu_start/mid/end`, `temp_*`, `used_*`, `download_*`… — each meter has its own three stops.
  41 theme files ship in `themes/`.
- **Gradients are computed once into 101 ready escape strings.** `generateGradients`
  (`btop_theme.cpp:305-361`) interpolates start→mid→end in two passes of 50 and 51 steps and
  stores the *finished SGR string* for each percent. Drawing a meter never formats a colour.
- **A meter caches its whole rendered string per value.** `Meter::operator()`
  (`src/btop_draw.cpp:403-418`): `cache.at(value)` is returned if present; otherwise each
  cell's colour is `gradient[i*100/width]`, so the colour depends on the *position*, not the
  value — a full meter reads green→red left to right.
- **Graphs colour by row.** `btop_draw.cpp:484`: the colour of a graph line is
  `gradient[100 - (i-1)*100/height]` — one colour per row. This is what makes btop's graphs
  cheap: every cell of a row shares one SGR.
- **Braille for graphs, blocks or shade for low-fi terminals.** `graph_symbols`
  (`btop_draw.cpp:88-125`): `braille_up/down` (2×4 dots a cell), `block_up/down` (quadrants),
  `tty_up/down` (`░▒█`). Rounded corners are an option (`rounded_corners`,
  `btop_draw.cpp:289-294`), off in tty mode.
- **Truecolor first, 256 on request.** `hex_to_color` emits `38;2;r;g;b`, or with `lowcolor`
  (`--low-color`, or `truecolor = false`) converts with `truecolor_to_256`
  (`btop_theme.cpp:156-165`): greys to the 232–255 ramp, else `round(v/51)` into the cube. The
  `TTY_theme` (`btop_theme.cpp:103-151`) is a separate hand-written table of 16-colour codes, not a
  conversion — the same split as lipgloss's `Complete` below.
- **Transparent terminals.** `theme_background` (`btop_config.cpp:79`): "set to False if you
  want terminal background transparency". Painting a background everywhere kills a translucent
  terminal; btop makes it a switch.

### 1.2 cava — vertical and horizontal gradients [doc]

`example_files/config:290-315`: `gradient = 1` with up to 8 `gradient_color_N` stops applied
*by height* (bottom to top), and a separate `horizontal_gradient` across bars; "only hex defined
colors are supported". Smoothing: `monstercat`, `waves`, `noise_reduction = 77` (integral and
gravity filters). The eq daemon already does ballistics; the take-away is the gradient by
height, the same as btop's graphs.

### 1.3 spotify-player, ncspot, gping, bottom [doc, code]

- spotify-player `docs/config.md:64-66`: `border_type` = `Hidden | Plain | Rounded | Double |
  Thick`; `progress_bar_type` = `Rectangle | Line` — the look is parameters, not forks.
- ncspot `doc/users.md:372-384`: a `[theme]` of named roles (`primary`, `secondary`, `title`,
  `playing`, `highlight_bg`, `error_bg`, `statusbar`…), values either names or `#rrggbb`.
- gping `src/main.rs:80`, `plot_data.rs:131-133`: braille markers by default, `--simple-graphics`
  swaps to dots for fonts without braille.
- bottom `docs/.../styling.md`: built-in themes each with a light variant; precedence
  CLI `--theme` > config custom > config built-in > default.

### 1.4 Charm: lipgloss and colorprofile [code]

- **Per-tier colours chosen by hand.** `lipgloss/color.go:235-265`: `Complete(profile)` returns
  a function `(ansi, ansi256, truecolor) -> color` — the author picks the 16- and 256-colour
  value for each token instead of trusting an automatic conversion. `LightDark` picks by
  background (`color.go:163-201`), `HasDarkBackground` queries it (`query.go:69-86`, OSC 11).
  `Blend1D/Blend2D` build gradients (`blending_test.go`). `RoundedBorder()` is `╭╮╰╯`
  (`borders.go:227`).
- **Profile detection.** `colorprofile/env.go`: `NO_COLOR` wins; `TERM=dumb` → no colour
  unless `CLICOLOR_FORCE`; `COLORTERM=truecolor|24bit` → TrueColor (not inside `screen`/`tmux`
  TERMs, line 188); `*256color` → 256; `*-direct` → TrueColor; inside tmux it runs `tmux info`
  and looks for `Tc`/`RGB` (lines 238-262).

### 1.5 lazygit, k9s — the theming surface [doc]

lazygit `docs/Config.md:174-204`: `theme.activeBorderColor`, `inactiveBorderColor`,
`selectedLineBgColor`, `optionsTextColor` (the keybar)… as lists of colour + attribute. k9s
ships 43 skins (`skins/*.yaml`), several with dark/light pairs. Both colour the *focused*
border differently from the rest — the one-glance "where am I" cue eq uses for a focused
instrument.

## 2. tmux, the user's terminal and font [code, measured]

- **tmux tells every pane `COLORTERM=truecolor`** unconditionally (`environ.c:264-270`), so
  inside tmux the variable says nothing about the outer terminal. That is safe anyway: when the
  outer terminal lacks RGB, tmux converts each 24-bit colour to its 256 palette itself
  (`tty.c:2699-2706`, `colour_find_rgb` in `colour.c:137-166`, which uses the real xterm cube
  levels 0/95/135/175/215/255 — more accurate than btop's `round(v/51)`), and to 16 below that
  (`tty.c:2714-2725`). eq can therefore trust `COLORTERM` and skip colorprofile's `tmux info`
  subprocess.
- **tmux answers OSC 11 (background colour query) itself** from the pane's colours
  (`input.c:3117-3130`). Whether that reply reflects Zap's real ground through tmux 3.7c is
  unverified; M2b checks it.
- **This Mac** [measured, inside the tmux the user runs]: `TERM=xterm-256color`,
  `COLORTERM=truecolor`, tmux 3.7c, `terminal-overrides[1] xterm-256color:RGB`
  (dotfiles `tmux/tmux.conf:9`) — 24-bit colour reaches Zap end to end. Zap
  (`dotfiles/zap/settings.toml`): theme `gruvbox_dark` (ground `#282828`, the 16 colours in
  `zap/themes/gruvbox_dark.yaml`), `override_opacity = 67` — a translucent window, so eq must not
  paint the ground by default.
- **Glyph coverage of the user's font**, `JetBrainsMonoNerdFontMono-Regular.ttf` read with
  fontTools [measured]: braille 256/256, block elements 32/32, box drawing 128/128, geometric
  shapes 43/96, arrows 35/112, legacy-computing sextants 0/60. Present: `╭╮╰╯ ┈┄┊ ▁…█ ▔ ▏▕ ▐ ░
  ◆◇ ●○◉ ■□▪▫ ←↑→↓↖↗↘↙ ✓ ‹›`. **Missing: `▬` (U+25AC) — today's slider marker — so the watch
  already draws it from a fallback font**; also `▰▱ ◜◝◞◟ ◐◑ ⬤ ⏵⏸ ♪`. The looks use only the
  present set, and nothing from the Nerd Font private-use area.

## 3. Hardware and plug-in metaphors [doc]

Fetched by a research agent from makers' pages; unverified items are marked.

- **Curve over spectrum, two scales.** FabFilter Pro-Q 4 manual
  (fabfilter.com/downloads/pdf/help/ffproq4-manual.pdf): "the yellow scale corresponds to the EQ
  band curves and overall curve. The gray scale at the far right is used by the spectrum analyzer
  and output level meter"; the overall response is one thick curve; colour codes channels
  (L/R/M/S), not bands. → eq's studio look: levels on a dBFS scale at the left, the response
  curve on a gain scale at the right, one curve colour.
- **Channel-strip colour sections.** Waves SSL E/G-Channel manual
  (assets.wavescdn.com/pdf/plugins/ssl-e-channel.pdf): HF red (G: magenta), HMF green, LMF blue,
  LF black; compressor white, filters white. → colour by *section*, which eq applies to
  instruments (one hue each, low→high warm→cool), not to bands.
- **Backlit meter window.** mcintoshlabs.com: "our iconic blue Watt output meter"; MC611: "large
  8" fast responding blue Watt meter". Peak-hold mode: not verified. → the console look's
  gain-reduction window is a deep blue with a white needle.
- **Four coloured encoders on a flat black screen.** teenage.engineering OP-1: "the four colored
  encoders… designed for easy reading"; exact hues not verified. → knob chips in the instrument
  hues on a dark panel.
- **Ballistics** (en.wikipedia.org/wiki/Peak_programme_meter, …/VU_meter, …/DBFS): IEC 60268-10
  Type I return 20 dB in 1.7 s (≈11.8 dB/s), Type II 24 dB in 2.8 s; VU 300 ms rise/fall; EBU
  alignment −18 dBFS, SMPTE −20 dBFS. No standard names peak-hold time; 1–2 s is convention. →
  peak ticks hold 1.5 s, then fall at 11.8 dB/s; LED zones green < −18, amber −18…−6, red ≥ −6.

## 4. Byte cost of colour [measured by simulation]

`docs/design/tui/mocks.py --bytes` renders 150 frames of the meter at 120×40 with levels moving
("music": a random walk with a kick on the low bands and 20 dB/s fall; "stress": every band
jumps to a random level every frame), and counts what a diff renderer writes between frames
with three encoders: *naive* (every changed cell: cursor move + full SGR + glyph), *runs* (one
cursor move per run of changed cells, the pen carried), *runs + gap* (within a row, rewrite or
skip the gap to the next run, whichever is shorter). Synchronized-update brackets included.

| Look | Colours | Motion | Full frame | Naive | Runs | Runs + gap |
| --- | --- | --- | --- | --- | --- | --- |
| classic | 16 | music | 9 093 | 1 498 | 607 | 543 |
| classic | 16 | stress | 7 381 | 6 229 | 2 342 | 1 979 |
| studio | 16 | music | 10 741 | 2 298 | 752 | 681 |
| studio | 16 | stress | 9 736 | 9 510 | 2 456 | 2 078 |
| studio | 256 | music | 17 838 | 3 665 | 1 005 | 934 |
| studio | 256 | stress | 15 365 | 16 616 | 3 303 | 2 927 |
| studio | 24-bit | music | 25 350 | 5 270 | 1 346 | 1 273 |
| studio | 24-bit | stress | 21 134 | 23 900 | 4 333 | 3 957 |
| studio, bars as `█` | 24-bit | stress | 21 856 | 20 612 | 4 664 | 4 293 |
| console | 24-bit | music | 40 805 | 1 755 | 453 | 378 |
| console | 24-bit | stress | 40 633 | 11 334 | 2 209 | 1 914 |

Reading it:
- The M1 baseline wrote 7.6 KB every frame (research 08 §8) because it rewrote every line. Any
  diff renderer with pen tracking brings even 24-bit studio under the M2 budget (4.5 KB) in the
  worst case, and to ~1.3 KB with music. A naive per-cell encoder does not: 24 KB.
- What makes 24-bit affordable is **one colour per meter row** (btop's graph rule): the ten bars
  of a row share one SGR, so the encoder sets the pen once per row, not once per bar.
- Painting solid bar cells as **spaces on a background colour** instead of `█` saves ~8 % in the
  stress case (a space is 1 byte, `█` is 3) and removes the hairline gaps some fonts leave
  between rows of `█`.
- The console look paints its panel everywhere, so its *full* frame (start, resize, resume) is
  41 KB — once, not per frame; its moving parts only switch LED colours.
- 24-bit SGR is ~19 bytes (`ESC[38;2;255;64;99m`), 256 is ~11, 16 is 5. A per-style cache of
  ready byte strings (btop's precomputed gradient strings) keeps the CPU side flat.

## 5. M2b as built: the renderer against the mocks [measured]

The looks are drawn by `Sources/eq/TUI/` (`StudioView`, `ConsoleView`, `Overlay`, `ShellViews`)
from the tokens in `Theme.swift`; `classic` is gone, its layout kept only as the compact rows
both looks fall back to below 60 columns or 12 rows. Screens from the real renderer, at the same
states as the mocks (`base_state`, `zones_state`, `focus_state`), are in
`docs/design/tui/actual/` as `.ans` files and in `actual/preview.html`, the mocks' own viewer;
`EQ_WRITE_SCREENSHOTS=1 swift test --filter TUILookTests` writes them again. Their text and
styles are pinned by golden files in `Tests/eqTests/Fixtures/tui/` (`studio-*`, `console-*`,
plus 256, 16 and monochrome variants of the meter at 120×40).

Where the built screens differ from the mocks, and why:
- **No tab row.** Tabs belong to M3; the meter takes that row, so the mocks' 120×36 screens are
  one meter row taller when built.
- **The status bar keeps `focus: voice (85 Hz–9 kHz)`**, today's header segment, after the
  knobs; it drops last among the segments, after the peak and then the flags, as the old header
  dropped its focus last. The device chip is followed by a blank, not a `│`, as in the mock.
- **Key list**: the full description of each key from the key table, wrapped under itself,
  instead of the mocks' shortened lines; the groups are split into two columns where their rows
  balance. At 120×36 the list is 30 rows and fits once the box takes the whole body (the mock left
  a blank row above). No `/ filter` yet (M3). `Look` lists `y Y` for two looks, not three.
- **Instrument table** is the M1 overlay over the faded meter, not the M3 view: no "now"
  mini-meter, the selected rows are the focused instrument's (none without a focus), and the
  title counts 17 ranges (the mock said 15, a slip). The `▸` and the hue dot sit two columns
  apart; in the mock the dot overwrote the marker.
- **Compact rows** below 60×12 (both looks) and a console that does not fit (strips narrower
  than 5 columns, fewer than 3 LED rows): the watch's old rows in the palette's colours, bars
  painted by height; no `▬` slider marker, since the gain chips and the curve carry the gain.
- **The flat part of the curve** is drawn on the top dots of the 0 dB row's cells (`⠉`) while the
  guide `┈` is mid-cell; the mocks' dot arithmetic is the same, it only showed less flat curve.
- **Console on `ink` and `paper`**: the spec gives the console-only tokens (tape, LCD, window,
  cap, lamps) for `brass`; `Y` cycles every palette on either look, so `ink` and `paper` carry
  those tokens too, taken from brass where they are the hardware's colours (tape, window, LCD) and
  from their own palette otherwise.
- **Not mocked, built**: `--meter leds` in studio (the LED ladder in the bar columns),
  `--meter bars` and `--curve` in console, `--no-scale`, `--no-peaks`, `--background theme`.
- **Messages** carry their kind: an edit that failed `✗`, a refusal or the reconnect `!`, a look
  switch `✓`. The mocks' "saved: band 1 kHz −3.0 dB" and "listening to voice alone" are sample
  text; the model says neither, and the goldens pass them in as the scene's message.
- **`palette auto`** is the look's own palette. Picking `paper` from the terminal's answer to
  OSC 11 needs a query and a reply read back through tmux, which was not verified on the user's
  stack; left for later.

### Bytes and CPU in process

`MeterBenchmarkTests`, 300 frames at 120×40 through `update`, `view` and the renderer, after a
first full frame; "music" is §4's random walk with a kick on the low bands, "stress" moves every
band to a random level every frame; release build (`swift test -c release -Xswiftc
-enable-testing`). The test fails any row above 4.5 KB a frame.

| Look | Colours | Motion | Bytes a frame | Full frame | ms a frame |
| --- | --- | --- | --- | --- | --- |
| studio | 24-bit | music | 1 197 | 13 479 | 0.27 |
| studio | 24-bit | stress | 3 394 | 12 917 | 0.28 |
| studio | 256 | music | 908 | 10 457 | 0.26 |
| studio | 256 | stress | 2 683 | 10 083 | 0.28 |
| studio | 16 | music | 705 | 7 331 | 0.25 |
| studio | 16 | stress | 2 131 | 7 054 | 0.27 |
| studio | none | music | 609 | 7 011 | 0.24 |
| studio | none | stress | 1 954 | 6 704 | 0.26 |
| console | 24-bit | music | 399 | 29 034 | 0.29 |
| console | 24-bit | stress | 1 985 | 28 959 | 0.31 |
| console | 256 | music | 336 | 23 261 | 0.29 |
| console | 256 | stress | 1 700 | 23 302 | 0.30 |
| console | 16 | music | 262 | 12 670 | 0.29 |
| console | 16 | stress | 1 451 | 12 526 | 0.30 |
| console | none | music | 234 | 10 279 | 0.29 |
| console | none | stress | 1 369 | 10 064 | 0.30 |

The simulation's numbers held: studio at 24 bits writes 1.2 KB a frame with music (simulated
1.3 KB) and 3.4 KB in the stress case (4.0 KB); the full frame is smaller than simulated because
the default ground is the terminal's and only surfaces are painted. The same benchmark at M2
(`269150a`, the classic frame) took 0.14 ms a frame for 1.2 KB. The first build of the looks
took 4 ms a frame in a debug build: every glyph asked the Unicode tables for its width
(`isEmojiPresentation`, then `wcwidth`), every access to the theme copied the palette, and every
blended colour worked out its xterm-256 index whether or not a 256-colour terminal would ask.
Box drawing, blocks, arrows, braille and dashes now count one column without asking, each view
keeps its theme, and the index is worked out on demand.

### CPU on a pty

The harness of research 08 §8 (a release build on a 120×40 pty, a fake meter socket in a scratch
directory at 30 frames a second, `ps -o time=` over the run; never the live daemon), 30 s a run,
the builds interleaved, with §4's "music" levels. The Mac was busy with other work (load 3–12,
and for a while so throttled that every build, M2's included, wrote only 14 of the 30 frames a
second; those runs are left out), so runs of one build spread by several points; the medians are
what compares.

| Build | Look, colours | Runs, CPU | Median | Bytes a frame |
| --- | --- | --- | --- | --- |
| M2 (`269150a`) | classic, 16 | 3.4, 3.5, 2.5, 3.1, 4.1 % | 3.4 % | 962 |
| M2b | studio, 24-bit | 5.4, 2.4, 1.6, 3.6, 5.4 % | 3.6 % | 1 201 |
| M2b | studio, 256 | 6.1, 1.9 % | — | 911 |
| M2b | console, 24-bit | 6.9, 1.9, 2.5, 5.5, 5.5 % | 5.5 % | 396 |
| M2 | silent | 3.4, 1.3 % | — | 0 |
| M2b | studio, silent | 3.6, 1.2 % | — | 0 |

Both looks stay inside the M2 budget (≤ 5.7 % CPU, ≤ 4.5 KB a frame) by median; single console
runs went above it on the loaded machine. With silent levels nothing is written, as at M2, but
the view is still built 30 times a second; skipping an unchanged frame before the view would
bring the silent case toward zero and is the next saving to take.

## 6. M3 as built: the shell [measured]

Tabs, the `g` menu, the command palette with its child processes, and the Instruments and Events
views, in both looks. Screens from the real renderer are in `docs/design/tui/actual/` beside the
earlier ones (`*-instruments-*`, `*-events-120x36`, `*-go-120x36`, `*-palette-120x36`,
`*-output-120x36`), pinned by golden files as before.

Where the built screens differ from the mocks, and why:
- **Three tabs, not ten.** Only the views that exist are named: Meter, Instruments, Events. The
  later milestones add theirs; a tab that leads nowhere would teach the wrong letter.
- **Console tabs** are key caps: the current one an `accent` chip, the others on `key_bg` with
  their letter underlined, all upper case, as the console's engraved labels are.
- **Instruments view**: a `level` column the mock lacks, eight cells of the instrument's loudest
  band (painted by height in studio, LED segments in console), which the spec's "per-instrument
  mini-meters" asked for; the Hz column is three columns narrower so that the map and the bands
  still fit at 120 columns. The selection follows `↑`/`↓`, not the meter's focus, which is marked
  `◉`; a flat knob reads `0.0`. No `/ filter`: eight rows need none. The "now" panel is as mocked.
- **Not mocked, built**: the Events view (a log in a panel, newest at the bottom, time, kind in
  its colour, text; the console's time in the LCD colours), the palette (suggestions in a box over
  the message row, the typed letters in the accent, `▸` on the chosen one), the `g` menu (a box
  over the bottom left) and the command output (a panel over the view, the child's colours kept
  through `AnsiText`).
- **The meter gives the tab row its row**, not the strip: at 120×36 the panel is one row shorter
  than at M2b and the zones strip keeps all eight instruments.

### Bytes and CPU

In process (`MeterBenchmarkTests`, release build, 300 frames at 120×40), against M2b built from
`8996be7` in the same session:

| Look, colours | M2b bytes a frame | M3 bytes a frame | M2b ms a frame | M3 ms a frame |
| --- | --- | --- | --- | --- |
| studio, 24-bit, music | 1 197 | 1 181 | 0.28 | 0.29 |
| studio, 24-bit, stress | 3 394 | 3 296 | 0.30 | 0.30 |
| console, 24-bit, music | 399 | 386 | 0.31 | 0.32 |
| console, 24-bit, stress | 1 985 | 1 916 | 0.32 | 0.33 |
| studio, Instruments view, music | — | 467 | — | 0.30 |
| console, Instruments view, music | — | 128 | — | 0.31 |

On a pty: the harness of research 08 §8 (release build, 120×40, `TERM=xterm-256color`,
`COLORTERM=truecolor`, a fake meter socket in a scratch directory sending 30 frames a second of
§4's "music" with values rounded to 0.1 dB as the daemon sends them and answering the events
subscription; `EQ_CONFIG`, `EQ_STATUS` and `EQ_CACHE` in the scratch directory; never the live
daemon), 30 s a run, M2b and M3 interleaved. The Mac's own state moved the numbers more than the
builds did: two sessions an hour apart gave every build about 1.5 points more in the first.

| Build | View, look | Runs, CPU | Median | Frames/s written | Bytes a frame |
| --- | --- | --- | --- | --- | --- |
| M2b | meter, studio | 6.46, 6.32, 5.53 % | 6.3 % | 30.0 | 1 197 |
| M3 | meter, studio | 6.46, 6.82, 6.82 % | 6.8 % | 30.0 | 1 184 |
| M2b | meter, studio (later) | 4.89, 4.63, 3.76, 4.23, 4.79 % | 4.6 % | 30.0 | 1 197 |
| M3 | meter, studio (later) | 4.93, 5.00, 4.06, 5.00, 4.66 % | 4.9 % | 30.0 | 1 184 |
| M2b | meter, console | 5.89, 5.93 % | — | 30.0 | 397 |
| M3 | meter, console | 6.19 % | — | 29.7 | 391 |
| M3 | Instruments, studio | 5.92, 4.53 % | — | 30.0 | 464 |
| M2b | meter, silent | 4.00, 4.66 % | — | 0 | 0 |
| M3 | meter, silent | 0.83, 1.13, 1.10 % | — | 0 | 0 |
| M3 | Events, music | 0.00, 0.00 % | — | 0 | 0 |

In the later session both builds are inside the budget (≤ 5.7 %, ≤ 4.5 KB a frame); in the first
both were above it, M2b included, so the budget as a fixed number depends on the Mac's state more
than on eq. M3's cost over M2b: 0.01 ms a frame in process and about 0.3 points on the pty,
inside the spread of either build. Two things M3 changed are clear: levels that stand still no
longer build a screen (a frame whose levels, peaks and countdowns are unchanged sets
`needsRedraw` false and the runtime skips the view), which takes the silent case from 4–5 % to
about 1 %; and the Events view closes the meter connection, so the TUI there costs nothing
measurable and the daemon's meter work stops while it is on screen (one frame is taken back after
a `profile` event or a command, for the status bar's preamp and gains).


## 7. M4 as built: Tune [measured]

The Tune view in both looks. Screens from the real renderer are in `docs/design/tui/actual/`
(`*-tune-120x36`, `*-tune-80x24`), pinned by golden files; every other screen gained the Tune tab.

Where the built screen differs from the mock `studio-tune-120x36`, and why:
- **The chain is a column the height of both panels**, and the response panel is as wide as the
  bands panel, not the whole screen. The response is drawn on the sliders' own frequency axis,
  so each band's node sits straight above its slider; a full-width panel would have put the
  nodes elsewhere, or drawn past 20 kHz. The taller column holds what the mock had no room for.
- **The response is the whole chain's**: bands, filters, bass, treble, tilt and instrument knobs
  (`Profile.engineBands`, at the device's rate), not the ten bands alone as on the meter, since
  Tune edits all of them. Nodes are coloured by their band's sign as in the mock; the selected
  one is `◉` in the accent.
- **Headroom, not in the mock**: the chain's loudest point from 20 Hz to 20 kHz (a twelfth-octave
  sweep) plus the preamp. Over 0 dBFS the response title says `! clips +1.9 dB — lower the
  preamp` and the output box shows it; under, how much is spare. With the output peak and the
  limiter lamp under it, that is the clipping and limiter indication.
- **Dynamics are three controls**: the compressor's mode, the colour's kind and its amount, each
  selectable, under a `dynamics` rule; the mock's `‹ tape › 0.3` is two of them on two rows.
- **Below 110 columns** the chain is two rows under the bands, items at fixed places so a click
  lands on the same one whatever the value; the output keeps the headroom and the limiter and
  drops the peak first. Below 18 rows of panel the response takes 5 rows, so the sliders keep 6.
  Under 61 columns or 12 rows the controls are a list.
- **A cap never sits on the 0 dB row for a band that is not flat**: at 80×24 a row is 4.8 dB and
  -3.1 would round onto it.
- **Console**: the sliders are faders on channel strips with grooves, a tape label under each
  (the scribble strip), an amber LCD readout and a row of LEDs; the response a backlit window
  (`window_bg`), no tints; the chain a master section with a preamp fader, knobs for bass,
  treble and tilt, lamps for the compressor and the colour, an LED bar for the amount. Not
  mocked.

Keys follow the table (README "Keys"). Two things decided while building:
- `0` resets the selected control here, as the task asked, so the tenth band goes up with `↑`
  rather than `0`; `1`…`9` and the shifted digits keep their meter meaning. `Backspace` and
  `Del` reset too.
- `⇧↑`/`⇧↓` and `Alt↑`/`Alt↓` are keys of their own where a context binds them (only Tune), and
  plain arrows elsewhere, as every modifier on an arrow was before.

### Bytes and CPU

In process (`MeterBenchmarkTests`, release build, 300 frames at 120×40; "music" and "stress" as
in §5). The Tune view changes little a frame: ten mini-meters, the output peak and the status
bar's peak.

| Look, colours | Tune, music | Tune, stress | Full frame | ms a frame | Meter, music (same run) |
| --- | --- | --- | --- | --- | --- |
| studio, 24-bit | 490 | 510 | 13 129 | 0.25 | 1 181 |
| studio, 256 | 274 | 365 | 10 205 | 0.25 | 895 |
| studio, 16 | 153 | 262 | 7 428 | 0.24 | 692 |
| studio, none | 100 | 209 | 6 478 | 0.24 | 597 |
| console, 24-bit | 125 | 350 | 25 674 | 0.29 | 386 |
| console, 256 | 99 | 264 | 20 537 | 0.30 | 324 |
| console, 16 | 63 | 184 | 9 763 | 0.29 | 253 |
| console, none | 51 | 134 | 8 694 | 0.29 | 225 |

On a pty, the harness of §6 (release build, 120×40, fake meter socket in a scratch directory at
30 frames a second of "music", `EQ_CONFIG`/`EQ_STATUS`/`EQ_CACHE` in the scratch directory, never
the live daemon), 30 s a run, M3 and M4 interleaved, on a busy Mac (load 2–5):

| Build | View, look | Runs, CPU | Median | Frames/s written | Bytes a frame |
| --- | --- | --- | --- | --- | --- |
| M3 | meter, studio | 7.13, 7.43, 7.36 % | 7.4 % | 30.0 | 1 184 |
| M4 | meter, studio | 7.29, 7.39, 7.26 % | 7.3 % | 30.0 | 1 184 |
| M4 | Tune, studio | 6.89, 6.29, 6.26 % | 6.3 % | 30.0 | 486 |
| M4 | Tune, console | 7.36 % | — | 29.8 | 127 |
| M4 | Tune, silent | 1.27 % | — | 0 | 0 |

The meter view costs the same in both builds, so M4 added nothing to it; Tune costs a little
less than the meter. As in §6, the Mac's state put every build above the 5.7 % budget in this
session, M3 included; bytes stay far inside 4.5 KB. The same pty run with keys (`↓`, `→`×5,
`оооо`, `⇧↑`, `Enter -2,5 Enter`, `Tab`, `u`×3) changed the scratch eq.json at each step, wrote
one backup for the whole session, and walked back with `u`.
