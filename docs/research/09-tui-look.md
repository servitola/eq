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

## 8. M5 as built: Presets, Devices, Filters [measured]

The three list views in both looks, between Instruments and Events on the tab row. Screens from
the real renderer are in `docs/design/tui/actual/` (`*-presets-*`, `*-devices-*`, `*-filters-*`,
at 120×36 and 80×24), pinned by golden files; every other screen gained the three tabs. There were
no mocks for these views; they reuse the looks' parts: rounded panels, the selection on `sel` with
`▸`, the braille response over boost and cut tints (a backlit window in console), keycaps.

What was decided while building:
- **One edit path.** Every list action is a `WatchAction` the watch session applies through the
  CLI's own functions (`CLI.usePreset`, `renamePreset`, `removePreset`, `copyCurve`, `useDevice`,
  `addFilter`, `setFilter`, `removeFilter`, extracted from the commands without changing their
  output). A test runs each command and each action against two scratch stores and compares
  eq.json. The session's `u` now restores whatever a save changed (device profiles, presets, app
  rules, the default), since a rename or a copy to another device touches more than the playing
  device's profile.
- **Confirm in the message row**: `d` puts the question there with what a dry run would say
  (which devices keep the preset's curve unmarked, how many app rules will match nothing; the
  filter removed, and whether the import label goes with it). `y` or `Enter` (`н` on a Russian
  layout) does it, any other key keeps it. No modal: the spec's list binding set, one row.
- **Device use and driver mode.** `Enter` is `eq device use`: it sets the system's output. In
  driver mode the daemon's `DefaultFollower` already treats a real device picked as the default as
  "play on this", points the EQ device at it and takes the default back, so the TUI does exactly
  what the Sound menu does and needs no path of its own. The EQ device heads the list as the
  system output with the device it plays on, and is never a row to pick; `Enter` on the device
  already playing says so instead of making the default flicker. The spec's confirm before a
  device use was left out: it is undone by picking the old device, and the task asked for Enter.
- **Transport glyphs** from the set the user's font has (§2): `■` built-in, `▪` USB, `◇`
  Bluetooth, `□` HDMI or DisplayPort, `○` AirPlay, `◆` Thunderbolt, `·` offline, with the name
  in a column beside when the list is wide enough.
- **Filters** are edited in place like a spreadsheet: `Enter` or `→` enters the row's fields,
  `←`/`→` move between type, frequency, gain and Q, `↑`/`↓` step with Tune's three sizes (a 24th,
  a sixth of an octave or an octave, rounded to three digits so a step from 1 kHz saves 1120; 0.1,
  0.5 or 3 dB; Q 0.01, 0.1 or 1), each step saved at once; `Esc` goes back to moving between rows.
  `a` opens the same fields on a row under the table, whose type change carries the new type's
  default Q while the Q is still the old default. The response panel draws the filters combined
  with a dot on each and the chosen (or new) one's own response in the accent.
- **Presets diff**: `v` draws the current device's curve faint behind the preset's and lists
  each band, preamp and layer that differs as `before → after`.
- **Tune's device selector**: `d`/`D` in Tune, and `e` on Devices, make the session edit another
  device's curve (as `--device` does); the response title names it and the message row says it is
  not playing. Leaving Tune goes back to the playing device.
- **No meter connection** on the three lists: what they show comes from eq.json, the status file
  and the system's output list, read once when a view opens and again after an edit or a device
  or profile event, never per frame.

### Bytes and CPU

In process (`MeterBenchmarkTests`, release build, 120×40). "stress": 300 meter frames arrive, as
on the meter, and nothing on screen moves (the lists close the meter connection, so in use no
frames come at all); "j k": 300 key presses moving the selection, each redrawing the row, the
preview's curve and layers.

| View | Look | 24-bit | 256 | 16 | none | Full frame, 24-bit |
| --- | --- | --- | --- | --- | --- | --- |
| Presets, j k | studio | 1 328 | 1 084 | 699 | 451 | 8 245 |
| Presets, j k | console | 1 024 | 856 | 688 | 432 | 15 474 |
| Devices, j k | studio | 2 174 | 1 698 | 1 078 | 878 | 8 919 |
| Devices, j k | console | 2 003 | 1 562 | 1 130 | 874 | 15 711 |
| Filters, j k | studio | 1 635 | 1 410 | 1 124 | 582 | 6 682 |
| Filters, j k | console | 1 525 | 1 330 | 1 128 | 764 | 12 465 |
| any list, stress | both | 0 | 0 | 0 | 0 | — |

The meter's own rows are unchanged by M5 (studio 24-bit 1 181 B music and 3 296 B stress, console
386 and 1 916; 0.28–0.32 ms a frame, as at M4).

On a pty, the harness of §6 (release builds, 120×40, a fake meter socket in a scratch directory at
30 frames a second of "music", `EQ_CONFIG`/`EQ_STATUS`/`EQ_CACHE` in the scratch directory, never
the live daemon or ~/.config/eq), 30 s a run, M4 (`03c8a06`) and M5 interleaved on a busy Mac
(load 3–4):

| Build | View | Runs, CPU | Frames/s written | Bytes a frame |
| --- | --- | --- | --- | --- |
| M4 | meter, studio | 5.13, 5.70, 6.20 % | 27.3 | 1 198 |
| M5 | meter, studio | 5.50, 5.93, 6.97 % | 27.4 | 1 200 |
| M5 | Presets, idle | 0.17 % | 0.1 | — |
| M5 | Devices, idle | 0.17 % | 0.1 | — |
| M5 | Filters, idle | 0.13 % | 0.1 | — |
| M5 | Presets, a key a second | 0.20 % | 0.3 | 1 945 |

The list views' CPU is the process starting and reading its config; after that nothing runs.
Each M5 meter run came out a few tenths above the M4 run before it, while the load rose through the
session (each pair above the last); the in-process numbers are the same for both, so the
difference is inside the spread seen in §6 and §7.

## 9. M6 as built: Apps, System, History; the docs [measured]

The last three views in both looks, after Filters on the tab row. Screens from the real renderer are
in `docs/design/tui/actual/` (`*-apps-*`, `*-system-*`, `*-history-*`, at 120×36 and 80×24), pinned
by golden files; every other screen gained the three tabs. No mocks existed; the views reuse the
looks' parts (rounded panels, the `sel` row with `▸`, keycaps, the braille response).

What was decided while building:
- **Letters.** `g a` Apps, `g s` System, `g h` History (`ф`, `ы`, `р`). The spec's table said `g u`
  for History, but every tab underlines its first letter, and History has no `u`; inside the `g`
  menu `h` is free, since the menu takes its own keys before every view's `? h`.
- **Ten tabs** are 94 columns padded. Where they do not fit, the others lose their padding (76
  columns), then shorten to three letters; the current one always keeps its chip, so a click and
  the letter still match what is drawn.
- **Apps** edit through the session like the lists before: `eq app set`, `rm`, `on`, `off` as
  functions of the config, a test comparing each with its command on two scratch stores, `u`
  walking them back with the experimental flags. The picker lists the apps with audio open from the
  same process list `eq __complete apps` reads, and offers what is typed as it is, which `eq app set`
  resolves as a bundle ID or an installed app's name. The rule heard now follows the daemon's `app`
  events, which also set the status bar's app, so the mark moves without a read of the status
  file. Routes have no command, so they are shown read-only from eq.json and the status file,
  with `RoutePolicy.driverNote` in driver mode.
- **System**: the status file is read in process (cheap); `eq doctor --json` runs as a child of its
  own (a second runner beside the palette's, with its own source and reap timer), because its
  audio and driver checks sleep a second or two and must not hold the loop. The report decodes into
  the doctor's own `DoctorReport`. Driver health comes from the status (target, IO, EQ, slips,
  clock, default), the writer check and the launch agent from the doctor's rows.
- **Mode switch (`o`)**: `eq mode X --dry-run --json` runs first as a child; its `install` field
  decides. When the switch would install or update the driver, the TUI refuses and says to run
  `eq mode driver` in a shell: the install asks macOS for an administrator password (a dialog, or
  sudo in the terminal), and the child runs in its own process group with no terminal, where a sudo
  prompt would hang. Otherwise the question says what the dry run said, and `y` runs `eq mode` in
  the command pane; the status and the doctor are read again when it ends. `m` stays the mouse.
- **History**: `Enter` walks `ConfigStore.stepBack`/`stepForward` until the chosen version is live,
  which leaves the chain, the position and the redo stash as that many `eq undo`/`eq redo` would (a
  test runs both); `←`/`→` are one `eq undo`/`eq redo`. After a restore the session's own undo
  starts over, since its steps no longer lead back from the file now live.
- **Cheap items left from §5–§8**: `/` in the key list keeps only the keys that have the text; `/`
  on Presets, Devices, Apps and System jumps to the first row that has it (a jump, not a filter,
  so a row's index stays the one every action uses; `Esc` goes back). On Filters `=` or a digit
  types the field's value, read by the same `key=value` function as `eq filter set`. `Esc back` is
  on the keybar only with a view to go back to. The spec's double click is a second click on the
  chosen row, since SGR mouse reports presses only and the model keeps no clock.
- **Docs**: README "Watch" is "TUI"; `eq man` gains a KEYS section generated from the key table,
  a test holding it to the table as another holds the README's.

### Bytes and CPU

In process (`MeterBenchmarkTests`, release build, 120×40; "j k" as in §8):

| View | Look | 24-bit | 256 | 16 | none | Full frame, 24-bit |
| --- | --- | --- | --- | --- | --- | --- |
| Apps, j k | studio | 594 | 484 | 393 | 58 | 6 108 |
| Apps, j k | console | 634 | 513 | 393 | 58 | 11 460 |
| System, j k | studio | 443 | 359 | 261 | 85 | 8 957 |
| System, j k | console | 479 | 384 | 261 | 85 | 13 644 |
| History, j k | studio | 3 718 | 3 010 | 2 188 | 1 844 | 9 788 |
| History, j k | console | 3 588 | 2 914 | 2 243 | 1 842 | 15 294 |
| any, stress | both | 0 | 0 | 0 | 0 | — |

History costs the most a key: `j` and `k` move between the live version (its layers) and one
that differs (the live curve faint behind, and the differences), so the whole preview changes;
still under 4.5 KB. The meter's rows are unchanged (studio 24-bit 1 181 B music, 3 296 B stress;
console 386 and 1 916; 0.28–0.32 ms a frame).

On a pty, the harness of §6 (release builds, 120×40, a fake meter socket in a scratch directory at
30 frames a second of "music", `EQ_CONFIG`/`EQ_STATUS`/`EQ_CACHE` in it, never the live daemon or
~/.config/eq), 30 s a run after 2.5 s of start-up, M5 (`27766bf`) and M6 interleaved (load 2–4):

| Build | View | Runs, CPU | Frames/s written | Bytes a frame |
| --- | --- | --- | --- | --- |
| M5 | meter, studio | 4.66, 6.23, 5.99 % | 26.9 | 1 014 |
| M6 | meter, studio | 5.86, 6.33, 5.96 % | 26.9 | 1 015 |
| M6 | Apps, idle | 0.00 % | 0 | — |
| M6 | History, idle | 0.00 % | 0 | — |
| M6 | History, a key a second | 0.17 % | 1.0 | 3 323 |
| M5 | Presets, a key a second | 0.13 % | 1.0 | 1 260 |
| M6 | Presets, a key a second | 0.13 % | 1.0 | 1 260 |

Medians 5.99 and 5.96 %: M6 adds nothing to the meter. This run starts measuring after start-up,
so the idle lists show 0 where §8's 0.1–0.2 % was the start. System was not run on the pty: its
doctor child reads the installed driver's health, which this harness keeps away from; in process it
behaves as the other lists.

### What is left of the spec

- `palette auto` picking `paper` from the terminal's answer to OSC 11 (§5): it needs a query and a
  reply read back through tmux into Zap, still unverified on the user's stack.
- Whether Zap under tmux sends Ctrl-P as 0x10 on a Russian layout (spec, Risks); `;` and `ж` do not
  depend on it.
- An `eq route` command; until then routes are read-only in the TUI.

## 10. The spectrum, the curve, the grid [measured]

Asked after M6, from a screenshot of the studio Meter: a real spectrum analyser instead of ten
bars, the curve as a solid glowing line that moves to a new curve instead of jumping, and a
faint grid with each scale in the colour of what it measures. Screens from the real renderer are
in `docs/design/tui/actual/` (`*-meter-120x40`, `*-meter-140x40`, `*-meter-80x24`, and
`*-meter-120x40-bands`, the ten bands drawn when no spectrum comes), pinned by golden files.

### What was built, and why

- **A filter bank in EQCore, not an FFT.** 31 band-pass biquads at the base-ten third octaves
  (1000 × 10^(n/10) Hz, n = −17…13: 19.95 Hz to 19.95 kHz, the values ISO 266 rounds), Q 4.33 so
  neighbours meet 3 dB down, on the output's mono sum, with the band meter's own envelopes (10 ms
  attack, 300 ms release). A sine at a centre reads its level ±1.5 dB, the next band is at least
  6 dB below it (7 dB in theory), the one after at least 11 (12.6); a band at or above 0.49 × the
  rate reads the floor. It runs only while metering runs (a meter client connected, as before) and
  only when asked for (`eqc_set_spectrum`). An FFT would have taken the audio thread off the hook
  but needed a sample ring and a reader thread in the daemon and in the plug-in, which has no
  thread of its own for it (its properties are read on coreaudiod's HAL threads); the bank costs
  what is measured below, and both modes read it exactly as they read the bands.
- **The plug-in's record.** `eqMt` stays the 416-byte version 1 record every eq before this one
  checks for (`size == sizeof(frame) && version == 1`); version 2 is that record with
  `spectrumCount` and 31 doubles after it, on a property of its own, `eqMs`, which also turns the
  plug-in's spectrum on for the next second. eq asks `AudioObjectHasProperty` for `eqMs` before
  each read, so a plug-in without it costs no failed read (nor a line in coreaudiod's log) and
  meters as before. `EQC_BLOB_VERSION`, the settings protocol, is unchanged: nothing about the
  settings changed, and raising it would have made a new eq refuse an old plug-in.
- **Frames** gain `spectrum` (31 values, 0.1 dB), left out when there is none; an older eq's
  decoder ignores the key, and a frame without it decodes as before. A line grows from 306 to 502
  bytes.
- **Studio**: the bars are one pitch apart, 3 columns (2-wide bar and a gap) where the panel has 93
  columns for them, 2 (a 1-wide bar) down to 62, and the ten bands below that; the 31 bars start a
  pitch left of the bands' table so that every third one sits under a band's centre, and the band
  numbers, labels and chips under the panel stay where they were. A bar rises at once and falls at
  20 dB a second, a little slower than the envelope's own release; its tick holds and falls as the
  bands' do. No input ghost: the spectrum is the output's only.
- **The curve** is braille two dots thick, so the dots touch; bold; a dot `●` on each band's centre
  in its gain's colour (the curve's own where it sits on a bar, whose colour it would otherwise
  be), the band just edited `◉` in the accent with its gain on a chip above it for the edit flash's
  24 frames. The boost and cut tints are brightest along the line and fade to the plain tint over
  four rows, which is the glow a terminal can draw: a lighter background behind the braille itself
  showed the cell edges as a grey band. A new curve is reached over 9 frames (300 ms at the
  daemon's 30 a second), cubic ease-out, from wherever the line is drawn, so a second change
  mid-way does not jump; no timer of its own. The chips show the new gains at once.
- **Grid and scales**: `┈` in `grid` on the 0, −12, −24, −36 and −48 dBFS rows, the curve's 0 dB
  line in the curve's colour faded; the level scale's numbers in the bars' gradient at their
  level, lifted 20 % toward the text so −60 still reads, under `level dBFS` in the −18 dBFS
  colour; the gain scale in the curve's colour (0 in full) under `EQ dB`. With `--no-scale`
  neither grid nor labels.
- **Console**: where the strip's ladder is three columns wide (strips of 7 columns and up), the
  columns are the band's three third octaves, each with its own peak LED; 20 Hz, below the first
  strip's, is not shown. The curve, when on, is the same solid line with nodes; the LED scale is
  in the lit LED colours under `dBFS`. No grid: the ladders are one.

### Audio thread

`eqc_process` on 512-frame stereo callbacks of noise at 48 kHz with ten peaking bands and the
limiter, best of 7 runs of 20 000 callbacks, EQCore compiled `-O2` as the plug-in is; the budget
of such a callback is 10 667 µs. The first builds of the two versions differed by 1.4 µs with the
meter off, which moved with code layout alone: built with every function and block aligned to 64
bytes they are the same, so those are the numbers here.

| Meter | Before | After |
| --- | --- | --- |
| off (no meter client) | 13.3 µs | 13.6 µs |
| bands (an older eq, or `eqMt`) | 21.7 µs | 22.1 µs |
| bands and spectrum | — | 33.5 µs |

The spectrum adds 11.4 µs a 512-frame callback, 0.11 % of it (22 ns a frame, 0.7 ns a band and
frame); 128- and 1024-frame callbacks scale with the frames. The plug-in runs the same code.

### Bytes and CPU

In process (`MeterBenchmarkTests`, release build, 300 frames at 120×40; the frames now carry a
spectrum moving like the bands, "music" and "stress" as before):

| Look, colours | M6 bytes a frame (music, stress) | Spectrum (music, stress) | Full frame | ms a frame |
| --- | --- | --- | --- | --- |
| studio, 24-bit | 1 181, 3 296 | 1 243, 1 244 | 20 582 | 0.28 |
| studio, 256 | 895, — | 861, 936 | 15 131 | 0.27 |
| studio, 16 | 692, — | 601, 664 | 9 757 | 0.26 |
| studio, none | 597, — | 457, 494 | 9 053 | 0.26 |
| studio, 24-bit, 140×40 (3-column pitch) | — | 1 367, 1 368 | 22 308 | 0.29 |
| studio, 24-bit, no spectrum | 1 181, 3 296 | 1 257, 3 811 | 16 557 | 0.28 |
| console, 24-bit | 386, 1 916 | 393, 408 | 29 894 | 0.30 |
| console, 24-bit, no spectrum | 386, 1 916 | 386, 1 916 | 29 476 | 0.31 |

With the spectrum the stress case writes less than the bands did: 31 bars one or two columns wide
change fewer cells than ten five columns wide, and a bar falls a partial block a frame rather than
jumping. The ten bands' stress case grew by 0.5 KB: bars moving through the grid rows and the
graded tints rewrite those cells. The full frame (start, resize, `y`) grew by the grid and the
glow, once. All rows are inside 4.5 KB.

On a pty, the harness of §6 (release builds, 120×40, `TERM=xterm-256color`, `COLORTERM=truecolor`,
a fake meter socket in a scratch directory sending 30 frames a second of "music" with the
spectrum, `EQ_CONFIG`/`EQ_STATUS`/`EQ_CACHE` in it, never the live daemon), 30 s a run after 2.5 s
of start-up, M6 (`6af7975`, which ignores the spectrum) and this build interleaved, load 3–4:

| Build | Frames | Runs, CPU | Median | Frames/s written | Bytes a frame |
| --- | --- | --- | --- | --- | --- |
| M6 | with spectrum (ignored) | 6.30, 7.37, 6.90 % | 6.9 % | 30.0 | 1 187 |
| spectrum | with spectrum | 6.60, 7.23, 6.43 % | 6.6 % | 30.0 | 1 244 |
| spectrum | without (fallback) | 6.53, 6.63, 7.60 % | 6.6 % | 30.0 | 1 262 |

The TUI costs what it did; as in §7 the Mac's load, not eq, put every build above the 5.7 %
budget in this session. Frames whose levels, peaks and curve stand still still build no screen,
so silence costs what it did.

### Compatibility

| eq | daemon | plug-in (driver mode) | Meter shows |
| --- | --- | --- | --- |
| this | this | this (build 17 and later) | spectrum |
| this | this | build 16 and older (installed on the user's Macs: 14, 15) | ten bands (`eqMs` absent, `eqMt` read) |
| this | older, still running | any | ten bands (no `spectrum` key) |
| older | this | this | ten bands (the key ignored; `eqMt` unchanged) |
| older | older | this | ten bands (`eqMt` is the same record) |
| this, tap mode | this | — | spectrum |

In driver mode the spectrum needs the plug-in this eq bundles: its revision counts every commit to
the files built into it, and the commit that adds `eqMs` makes it 17, past the installed 15, so
`eq doctor` reports a driver update and `eq mode driver` installs it, with an administrator
password, as for any driver update.
