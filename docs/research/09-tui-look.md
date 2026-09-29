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
