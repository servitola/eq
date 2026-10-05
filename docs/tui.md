# The terminal UI

```
 ◉ BE-RCA  44.1 kHz │ preamp -4.8 dB │ ◆ favourite*                peak -6.0 dB
  Meter  Tune Instruments Presets Devices Filters Apps System History Events
  ╭ level dBFS ───────────────────── meter ────────────────────────── EQ dB ╮
  │  0 ┤ ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈├+12 │
  │ -6 ┤       ▔ ▔ ▔                                                        │
  │-12 ┤ ┈┈┈┈┈┈▃┈█┈▆┈▔┈┈┈▔┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈     │
  │          ●    ⢀● ▇ ▂   ▔       ▔                                        │
  │        ⣠⠞⠙⠳⢦⡴⠞⠋⠙⠳⢦⡴⠞⠛●⣄▄ ▔ ▔     ▔ ▔     ▔     ▔   ▔               ├+6  │
  │-24 ┤ ⢀⡴⠃┈ ┈ ┈ ┈ ┈ ┈ ┈ ⠈⠛⠶⠶⢦●⡀▃┈▅┈▇┈▄┈▔┈▃┈┈┈▔┈▔┈▆┈▄┈┈┈┈┈⢀⣤●⡀┈┈┈⢀┈┈┈┈     │
  │      ⠋                     ⠈⠙⢦⣀      █     ▆       ▇ ⣀⡴⠋ ▔⠙⢦⣤⣤⠞●⡀       │
  │      ▃┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ⠉⠛⠶●⣀ ┈ ┈ ┈ ┈⢀⣀●⣤⣤⠶⠶⠶●⠛⠉┈▇┈▃┈▔┈▔┈┈⠳⠶⠶├ 0  │
  │-36 ┤  ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ⠉⠛⢦⡀┈ ⢀⡴⠞⠋⠉ ┈ ┈ ┈ ┈ ┈ ┈ ┈▆┈┈┈┈┈┈┈     │
  │                                      ⠙⠳●⠋                    ▇ ▔        │
  │                                                                ▅        │
  │-48 ┤  ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈┈┈├-6  │
  │                                                                  ▃      │
  │                                                                         │
  │-60 ┤                                                               ├-12 │
  ╰─────────────────────────────────────────────────────────────────────────╯
            -9    -8    -11   -15   -19   -17   -22   -26   -29   -37
           32Hz  64Hz  125Hz 250Hz 500Hz 1kHz  2kHz  4kHz  8kHz  16kHz
           +4.8  +4.0  +4.2  +2.3   0.0  -3.1   0.0   0.0  +3.1  +2.4

 1…0  band   ⇧  down   z  zones off   i  instruments   ?  keys   q  quit
```

`eq tui` is the terminal UI: ten views of one program, the keys on a bar at the bottom that never
goes, `?` for all of them. `eq watch` is its Meter view, and draws the output live at ~30 fps, in one of two looks (above as text).
**studio**, the default, puts a spectrum analyser in a panel: 31 bars, the third octaves from
20 Hz to 20 kHz, two or three columns apart as the width allows, each painted by height, green
below −18 dBFS, amber up to −6, red above, rising at once and falling at 20 dB a second, with a
tick `▔` holding each one's peak for 1.5 s before it falls at the IEC Type I rate (20 dB in
1.7 s). A daemon from before the spectrum, or in driver mode an EQ driver from before it (build
16 and older), sends none; the panel then draws the ten bands' bars, with `░` where the input
reaches above the output (a cut). Over the bars the EQ's response is a solid braille line from
the band gains, as the daemon runs them (peaking filters, Q 1.41, at the device's rate), with a
dot at each band's centre in its gain's colour and the band just edited a ring with its gain
beside it; a preset switch or an edit moves the line to the new curve over 300 ms. Nothing is
painted between the line and 0 dB, and a bar it crosses keeps its own colour. Faint lines
mark 0, −12, −24, −36 and −48 dBFS; the level scale at the left is in the bars' colours under
`level dBFS`, the curve's at the right in its colour under `EQ dB`. Under the panel come each
band's level in dBFS (`·` when silent), its label, and its gain as a chip. At 110 columns and wider a column of gauges sits beside it: output peak and limiter,
compressor reduction and colour, bass, treble and tilt, and the eight instrument knobs.
**console** draws a mixing desk instead: a channel strip per band with a paper label, an LED
ladder whose unlit segments stay faintly lit (where the strip is wide enough and the spectrum
comes, three narrow ones: the band's third octaves), an amber readout and a fader whose cap sits
at the band's gain; SOLO, BYPASS and LIMIT are lamps in the header rail, and at 110 columns a master
section shows the compressor's gain reduction as a needle in a backlit window, with its lamps,
the peak, the preamp and a knob for tone and each instrument. `y` switches the look, `Y` the
palette, and both are remembered.

Below 60 columns or 12 rows both looks fall back to compact rows in their own colours: narrower
bars and short labels first, then the highest bands drop off with a note to widen the window.
Resizing the terminal redraws the whole frame for the new size. `eq stream` is the same numbers as
JSON lines instead, for anyone who wants to draw their own. Both need a running daemon; `watch`
needs a TTY and exits on `q` or Ctrl-C.

## Looks

| Setting | Flag (`eq watch`, `eq tui`) | `eq.json` | Values | Default |
| --- | --- | --- | --- | --- |
| look | `--look LOOK` | `tui.look` | `studio`, `console` | `studio` |
| palette | `--palette PALETTE` | `tui.palette` | `auto`, `ink`, `paper`, `brass` | `auto`: `ink` for studio, `brass` for console |
| colours | `--colors DEPTH` | `tui.colors` | `auto`, `24bit`, `256`, `16`, `none` | `auto` |
| meter | `--meter STYLE` | `tui.meter` | `auto`, `bars`, `leds` | the look's: bars in studio, LEDs in console |
| response curve | `--curve`, `--no-curve` | `tui.curve` | `true`, `false` | on in studio, off in console |
| scales | `--scale`, `--no-scale` | `tui.scale` | `true`, `false` | on |
| peak hold | `--peaks`, `--no-peaks` | `tui.peaks` | `true`, `false` | on |
| ground | `--background GROUND` | `tui.background` | `terminal`, `theme` | `terminal` |

A flag holds for that run, `eq.json` holds until changed, and `y` (`н`) and `Y` (`Н`) write
`tui.look` and `tui.palette` there as `m` writes `tui.mouse`. `auto` colours means: `NO_COLOR`
or `TERM=dumb` give none, `COLORTERM=truecolor` (or `24bit`, which tmux sets in every pane and
then converts itself for an older terminal) gives 24-bit, a `TERM` ending in `-direct` too, a
`TERM` with `256color` gives 256, anything else the terminal's sixteen. Each palette colour has a
hand-picked stand-in at sixteen colours rather than a conversion: green still means a boost,
magenta a cut, yellow a warning, red a failure. With no colour at all the look stays and reverse
video carries what colour did: the bars, the chips, the flags. `NO_COLOR` and `TERM=dumb` win over
any flag. The default ground is the terminal's own, so a translucent terminal stays translucent
and only panels, chips and tints are painted; `--background theme` paints the palette's ground
under everything, which the light `paper` palette needs on a dark terminal.

## Views

Under the status bar a row of tabs names the views, the current one a solid chip and each other
one with its letter underlined; `g` and that letter goes there, and a small menu over the keybar
lists the letters after `g` (`п`, then `ь`, `е`, `ш`, `з`, `в`, `а`, `ф`, `ы`, `р` or `у` on a Russian layout). `Esc` with nothing
left to cancel goes back to the view before. `eq tui VIEW` opens on one (`eq tui events`); `eq
watch` is the meter. Below 14 rows the tabs give their row to the meter, and below 60 columns only
the current one shows.

- **Meter** (`g m`): the screen above.
- **Tune** (`g t`): the curve to edit, laid out as a panel. On top, the response of the whole
  chain (bands, filters, tone, tilt and knobs, as the daemon runs them at the device's rate) in
  braille, the Meter's line, with a node on each band and the selected one marked;
  `! clips +1.9 dB` in its title when the curve with the preamp lifts some frequency over 0 dBFS.
  Under it the ten bands as vertical sliders from −12 to +12 dB, each with its gain and a live
  mini-meter, and beside them (under them below 110 columns) the chain: preamp, bass, treble,
  tilt, the compressor's mode, the colour's kind and amount, and the output: peak, limiter,
  headroom. `←`/`→` select a band or a control, `↑`/`↓` step it 0.5 dB (the tilt 0.1 dB/octave,
  the amount 0.1, a mode to the next), `⇧↑`/`⇧↓` or `PgUp`/`PgDn` 3 dB, `Alt↑`/`Alt↓` 0.1 dB,
  `0`, `Backspace` or `Del` set it to 0 or off, `Enter` types an exact value (`-3,5`, `night`,
  `tape`), `Tab` jumps between the bands, the chain and the dynamics. Arrows are the same on
  every layout, so any band goes up and down from a Russian one without Shift. Every change is
  saved at once and belongs to the session's one undo step, as on the meter; `u` walks back.
  `d` and `D` switch the curve being edited to the next or previous device, playing or not, with
  its name in the response panel's title; leaving Tune goes back to the playing device's.
  In console the sliders are faders on channel strips with a tape label and an amber readout,
  the response a backlit window, and the chain a master section of faders, knobs and lamps.
- **Instruments** (`g i`, or `i` on the meter): `eq zones` and `eq boost` as one table, each
  instrument in its colour with its knob as a centre-zero gauge, a live mini-meter of its loudest
  band, its ranges in Hz, where each sits on a 20 Hz–20 kHz map and the bands each touches, and
  the ten bands as they sound now under it. `↑`/`↓` choose, `←`/`→` turn the chosen knob,
  `l` listens to it alone, `Enter` focuses it on the meter.
- **Presets** (`g p`): every preset, the current device's marked `◆` and with a yellow `*` once
  the curve has moved away from it, each with its ten gains as a spark and its preamp; beside
  them the chosen one's curve as a braille line, and its layers: preamp,
  bass, treble and tilt, knobs, compressor and colour, filters. `Enter` plays it on the current
  device (`eq preset use`), `s` saves the current curve as a new one (`eq preset save`), `r`
  renames it with devices and app rules following (`eq preset rename`), `d` deletes it
  (`eq preset rm`) once `y` answers the question in the message row, which first says which
  devices keep its curve unmarked and how many app rules will match nothing; any other key keeps
  it. `v` compares it with the current device's curve: both drawn, the current one faint, and
  each band, the preamp and each layer that differs listed as `32 Hz +4.8 → +3.0`.
- **Devices** (`g d`): the outputs connected now, then the devices with a profile of their own
  that are not, as `eq device list` lists them: `◉` on the one whose curve plays, a glyph for how
  each is connected (`■` built-in, `▪` USB, `◇` Bluetooth, `□` HDMI or DisplayPort, `○` AirPlay,
  `◆` Thunderbolt, `·` offline), whether it has its own curve and its preset; beside them the
  chosen one's curve and layers. `Enter` makes it the system's output (`eq device use`); `c`
  copies the playing device's curve to it (`eq device copy --to`); `e` opens Tune on its curve,
  whether it plays or not; `x` makes it silent, or not (`eq device silence|unsilence`), and a
  silent one says `silent` after its name. While the output is silent, the top bar says `SILENT`. In driver mode the EQ device heads the list as the system's output and
  the device it plays on, and is never one to pick: `Enter` on a real device sets the system's
  output to it, and the daemon, as for a pick in the Sound menu, points the EQ device at it and
  takes the output back.
- **Filters** (`g f`): the current device's parametric filters as `eq filter list` numbers them,
  with type, frequency, gain, Q and whether an import or a hand added each; under them the
  filters' combined response, a dot on each, the chosen one's own response lit. `Enter` (or `→`)
  changes a filter in place: `←`/`→` pick the type, frequency, gain or Q, `↑`/`↓` step it (the
  next type, a sixth of an octave, 0.5 dB, Q 0.1), `⇧↑`/`⇧↓` an octave, 3 dB or Q 1, `Alt↑`/`Alt↓`
  a 24th of an octave, 0.1 dB or Q 0.01, each step saved at once (`eq filter set`); `=` or a digit
  types the field's value in the message row instead, read as `eq filter set` reads it (`3k`,
  `-2,5`, `0.7`, `lowshelf`); `Esc` goes back to moving between filters. `a` opens a row under the
  others for a new filter, set the same way, which `Enter` adds (`eq filter add`); `d` removes one
  (`eq filter rm`) once `y` answers.
- **Apps** (`g a`): the app rules (`eq app list`), each with its preset, the one heard now marked
  `◉` and said so, a rule whose preset is gone in yellow; under them the apps with audio open now,
  each with its rule or none. `a` adds a rule: pick an app with audio open (typing narrows the
  list, and an app that is not playing is taken as typed, as a bundle ID or an installed app's
  name), then its preset (`eq app set`); `Enter` gives a rule another preset; `d` removes it once
  `y` answers (`eq app rm`); `o` follows the rules or not (`eq app on`, `eq app off`). The status
  bar and the mark follow the daemon's `app` events. When eq.json has routes, they show under the
  rest as the daemon plays them (the outputs in order, where the app plays now, and why), read
  only, since no command edits them yet; in driver mode the note says that no route runs there.
- **System** (`g s`): the daemon (`eq status`): its state and pid, the mode eq.json asks for and
  the one it runs, the device, rate and latency, slips, the compressor, the app heard, this eq's
  version and the daemon's, the launch agent; in driver mode the driver's health beside it
  (`eq driver status`): target, IO, EQ, slips, clock, whether it is the default output, and the
  writer check. Beside them `eq doctor`, run as a child when the view opens and again on `r`,
  each check as `✓`, `!` or `✗` with its detail, the chosen one's whole text under the list. `o`
  switches to the other mode: `eq mode … --dry-run` says first what it would do, `y` then runs
  `eq mode` with its output in the command pane. A switch that would install or update the driver
  asks macOS for an administrator password, so the TUI says so and leaves it to a shell.
- **History** (`g h`): `eq history` for the current device: each saved version with its time, its
  ten gains as a spark, its preamp and preset, the live one marked `◉`; beside them the chosen
  one's curve over the live one's, faint, and what differs. `Enter` makes it the live config by
  stepping `eq undo` or `eq redo` as many times as it takes, so the chain ends as the commands
  leave it and nothing is lost; `←` and `→` step one version, as `eq undo` and `eq redo` do.
- **Events** (`g e`): the daemon's `eq events` as a log, newest at the bottom, each kind in its
  colour: device, rate, preset, bypass, solo, app, mode. `Space` pauses it while events keep
  arriving (the panel counts them), `/` filters by kind or text, `PgUp`/`PgDn`/`Home`/`End`
  scroll. The status bar follows these events on every view.

On Presets, Devices, Apps and System `/` jumps to the first row that has what you type, `Enter`
stays there and `Esc` goes back to where it was; in the key list `/` shows only the keys that
have it. `Esc` goes back to the view before only when there is one, and the keybar offers it only
then.

The meter connection is held only while a view that draws levels is on screen, or a solo sounds:
on the Events view the daemon stops its meter work, and the status bar leaves out the peak and
LIMIT, which only meter frames carry. The events connection stays open from start to end.

`;` (`ж` on a Russian layout, the same key) or Ctrl-P opens the command palette in the message
row: every `eq` command form from the help, and the screen's own actions by name (`go events`,
`zones`, `look`, `listen`), fuzzy-matched as you type, with the best match marked. Once a command's
words are typed its operand completes from the same values the shell completions use: presets,
devices, instruments, bands, formats, apps. `Tab` takes a suggestion into the line, `↑`/`↓`
choose, `Enter` runs it; with the line empty the last commands run come first (the last 100 are
kept in `~/.cache/eq/tui-history`). An `eq` command runs as a child process beside the screen,
which keeps drawing; a one-line answer shows in the message row, a longer one in a panel over the
view with its colours kept, laid out for the panel's width, where `Ctrl-C` stops it and `Esc`
closes it. The status bar is read again when it ends, so `: preset use favourite` shows the preset
at once. Commands that stream (`watch`, `stream`, `events`, `tui`) point at the view that does
the same instead. `eq …` in front names the command when a screen action has the same name
(`eq zones`).

## Keys

| Key | Russian | Where | Action |
| --- | --- | --- | --- |
| `g` | `п` `П` | every view | go to a view: m meter, t tune, i instruments, p presets, d devices, f filters, a apps, s system, h history, e events; a menu lists them |
| `;` `Ctrl-P` | `ж` | every view | the command palette: any eq command, run beside the screen |
| `u` | `г` `Г` | every view | undo the last change made in this session, back to how it started |
| `m` | `ь` `Ь` | every view | mouse on and off, remembered as tui.mouse in eq.json; on, a click on a tab opens it, a click on a band or a control in Tune or on a list's row selects it, a second click on the chosen row is its Enter, and the wheel scrolls a list or steps what it is over |
| `?` `h` | `р` `Р` | every view | the list of every key; ?, Esc or q closes it |
| `q` | `й` `Й` | every view | quit |
| `Ctrl-C` |  | every view | quit, from the lists too |
| `Ctrl-Z` |  | every view | suspend to the shell; fg brings the screen back as it was |
| `y` `Y` | `н` `Н` | every view | next look: studio → console / next palette: ink → paper → brass; saved as tui.look and tui.palette |
| `1` … `9` `0` |  | Meter | raise band 32 Hz … 16 kHz by 0.5 dB (0 is the tenth band, 16 kHz) |
| `⇧1` … `⇧0` | `"` `№` `:` | Meter | lower it by 0.5 dB: ! @ # $ % ^ & * ( ) on a US layout |
| `+` `-` |  | Meter | preamp ±0.5 dB (= and _ work too, no Shift needed) |
| `b` `B` `t` `T` | `и` `И` `е` `Е` | Meter | bass / treble shelf +0.5 dB, with Shift −0.5 dB |
| `p` `↓` `↑` | `з` `З` | Meter | next preset (p, ↓) / previous one (↑), alphabetically, wrapping round |
| `c` | `с` `С` | Meter | compressor: off → gentle → night → off |
| `v` `V` | `м` `М` | Meter | colour: off → tape → tube → off, starting at 0.3 / raise the amount by 0.1, from 1 back to 0.1 |
| `s` | `ы` `Ы` | Meter | save the curve as a preset: type a name, Enter saves, Esc cancels |
| `z` | `я` `Я` | Meter | the instrument strip, on and off |
| `i` | `ш` `Ш` | Meter | the Instruments view: ranges in Hz, the bands each touches, knob gains, levels; Esc comes back |
| `]` `Tab` `[` | `ъ` `Ъ` `х` `Х` | Meter | focus the next / previous instrument |
| `→` `←` | `ю` `Ю` `б` `Б` | Meter | the focused instrument's knob ±0.5 dB (. and , work too, no Shift needed) |
| `l` | `д` `Д` | Meter | listen to the focused instrument alone, and back |
| `Esc` |  | Meter | leave the focus (and stop listening); with no focus, back to the view before |
| `←` `→` |  | Tune | select the band, or the preamp, bass, treble, tilt, compressor, colour and its amount after them |
| `↑` `↓` `k` `j` | `л` `о` | Tune | the selected control ±0.5 dB (tilt ±0.1 dB/octave, amount ±0.1, a mode the next one); lowers a band on any layout |
| `⇧↑` `⇧↓` `PgUp` `PgDn` |  | Tune | ±3 dB (tilt ±0.5, amount ±0.3) |
| `Alt↑` `Alt↓` |  | Tune | ±0.1 dB (tilt ±0.05, amount ±0.05) |
| `Enter` |  | Tune | type the selected control's value in the message row: -3, 2.5, night, tape |
| `0` `Backspace` `Del` |  | Tune | the selected control back to 0, a mode or the colour off |
| `Tab` `⇧Tab` |  | Tune | the next / previous group: bands, chain (preamp, tone, tilt), dynamics; each keeps its selection |
| `1` … `9` |  | Tune | raise band 32 Hz … 8 kHz by 0.5 dB, as on the meter; 0 resets here, so 16 kHz goes up with ↑ |
| `⇧1` … `⇧0` | `"` `№` `:` | Tune | lower band 32 Hz … 16 kHz by 0.5 dB, as on the meter |
| `s` | `ы` `Ы` | Tune | save the curve as a preset |
| `d` `D` | `в` `В` | Tune | edit the next / previous device's curve, playing or not; the playing one comes first |
| `Esc` |  | Tune | back to the view before |
| `↑` `↓` `j` `k` | `л` `о` | Instruments | move between the instruments |
| `Home` `End` |  | Instruments | the first / the last instrument |
| `Enter` |  | Instruments | focus the instrument on the meter |
| `→` `←` | `ю` `Ю` `б` `Б` | Instruments | its knob ±0.5 dB (. and , work too) |
| `l` | `д` `Д` | Instruments | listen to it alone, and back; it becomes the meter's focus |
| `Esc` |  | Instruments | back to the view before |
| `↑` `↓` `j` `k` | `л` `о` | Presets | move between the presets |
| `PgUp` `PgDn` `Home` `End` |  | Presets | a page up / down, the first / the last |
| `Enter` |  | Presets | play it on the current device, as eq preset use does |
| `s` | `ы` `Ы` | Presets | save the current device's curve as a preset: type its name in the message row, Enter saves |
| `r` | `к` `К` | Presets | rename it; devices and app rules that name it follow |
| `d` | `в` `В` | Presets | delete it once y answers the question in the message row; devices that used it keep the curve |
| `v` | `м` `М` | Presets | compare it with the current device's curve: both drawn, and what differs listed |
| `/` | `.` | Presets | jump to the first preset whose name has what you type |
| `Esc` |  | Presets | back to the view before |
| `↑` `↓` `j` `k` | `л` `о` | Devices | move between the outputs and the profiles of devices not connected |
| `PgUp` `PgDn` `Home` `End` |  | Devices | a page up / down, the first / the last |
| `Enter` |  | Devices | make it the system's output, as eq device use does; in driver mode the EQ device plays on it instead |
| `c` | `с` `С` | Devices | copy the current device's curve to it, as eq device copy --to does |
| `e` | `у` `У` | Devices | edit its curve in Tune, whether it plays or not |
| `x` | `ч` `Ч` | Devices | silent or not: a silent output plays nothing, whatever the volume, as eq device silence and unsilence do |
| `/` | `.` | Devices | jump to the first device whose name has what you type |
| `Esc` |  | Devices | back to the view before |
| `↑` `↓` `j` `k` | `л` `о` | Filters | move between the filters |
| `PgUp` `PgDn` `Home` `End` |  | Filters | a page up / down, the first / the last |
| `Enter` `→` |  | Filters | change the filter in place: ← → pick its type, frequency, gain or Q, ↑ ↓ change it |
| `a` | `ф` `Ф` | Filters | add a filter: a row under the others to set its type, frequency, gain and Q, Enter adds it |
| `d` | `в` `В` | Filters | remove it once y answers the question in the message row |
| `Esc` |  | Filters | back to the view before |
| `←` `→` |  | a filter's fields | the type, the frequency, the gain or Q |
| `↑` `↓` `k` `j` | `л` `о` | a filter's fields | change it, saved at once: the next type, a sixth of an octave, 0.5 dB, Q 0.1 |
| `⇧↑` `⇧↓` `PgUp` `PgDn` |  | a filter's fields | an octave, 3 dB, Q 1 |
| `Alt↑` `Alt↓` |  | a filter's fields | a 24th of an octave, 0.1 dB, Q 0.01 |
| `Enter` `Esc` |  | a filter's fields | done: ↑ ↓ move between the filters again |
| `=` `0` … `9` | `ю` | a filter's fields | type the field's value in the message row, as eq filter set takes it: 3k, -2.5, 0.7, lowshelf; Enter sets it |
| `←` `→` `Tab` |  | new filter | the type, the frequency, the gain or Q |
| `↑` `↓` `k` `j` | `л` `о` | new filter | change it: the next type, a sixth of an octave, 0.5 dB, Q 0.1 |
| `⇧↑` `⇧↓` `Alt↑` `Alt↓` |  | new filter | coarse: an octave, 3 dB, Q 1; fine: a 24th of an octave, 0.1 dB, Q 0.01 |
| `=` `0` … `9` | `ю` | new filter | type the field's value: 3k, -2.5, 0.7, lowshelf |
| `Enter` |  | new filter | add it, as eq filter add does |
| `Esc` |  | new filter | cancel |
| `↑` `↓` `j` `k` | `л` `о` | Apps | move between the app rules |
| `PgUp` `PgDn` `Home` `End` |  | Apps | a page up / down, the first / the last |
| `Enter` |  | Apps | give the app another preset: pick one, Enter sets it, as eq app set does |
| `a` | `ф` `Ф` | Apps | add a rule: pick an app with audio open, or type its bundle ID or an installed app's name, then its preset |
| `d` | `в` `В` | Apps | remove the rule once y answers the question in the message row, as eq app rm does |
| `o` | `щ` `Щ` | Apps | follow the rules or not, as eq app on and eq app off do (experimental) |
| `/` | `.` | Apps | jump to the first rule whose app or preset has what you type |
| `Esc` |  | Apps | back to the view before |
| `Enter` |  | an app or preset to pick | take the chosen one; letters typed narrow the list, and an app not in it is taken as typed |
| `↑` `↓` |  | an app or preset to pick | choose |
| `Esc` |  | an app or preset to pick | cancel |
| `↑` `↓` `j` `k` | `л` `о` | System | move between the doctor's checks; the chosen one's whole text shows under them |
| `PgUp` `PgDn` `Home` `End` |  | System | a page up / down, the first / the last |
| `r` | `к` `К` | System | read the daemon's status again and run eq doctor again, beside the screen |
| `o` | `щ` `Щ` | System | switch to the other mode, as eq mode tap or eq mode driver does, once y answers what a dry run says; a switch that must install the driver first is left to a shell, where its password prompt belongs |
| `/` | `.` | System | jump to the first check whose name or text has what you type |
| `Esc` |  | System | back to the view before |
| `↑` `↓` `j` `k` | `л` `о` | History | move between the saved versions, newest first |
| `PgUp` `PgDn` `Home` `End` |  | History | a page up / down, the newest / the oldest |
| `Enter` |  | History | make it the live config: eq undo or eq redo as many times as it takes, so nothing is lost and → comes back |
| `←` `→` |  | History | one version older / newer, as eq undo / eq redo do |
| `Esc` |  | History | back to the view before |
| `↑` `↓` `j` `k` | `л` `о` | Events | scroll the log |
| `PgUp` `PgDn` `Home` `End` |  | Events | a page up / down, the oldest / the newest |
| `Space` |  | Events | pause the log and go on; events keep arriving underneath, the panel counts them |
| `/` | `.` | Events | show only events whose kind or text has what you type |
| `Esc` |  | Events | clear the filter, then back to the view before |
| `g` `m` | `ь` | after g | the meter |
| `g` `t` | `е` | after g | the curve to edit: bands as sliders, preamp, tone, dynamics |
| `g` `i` | `ш` | after g | the instruments, their knobs and levels |
| `g` `p` | `з` | after g | the presets: apply, save as, rename, delete, compare |
| `g` `d` | `в` | after g | the outputs and their curves: use one, copy the curve to one, edit one |
| `g` `f` | `а` | after g | the current device's parametric filters: add, change, remove |
| `g` `a` | `ф` | after g | the app rules: which preset plays while an app does, and the routes |
| `g` `s` | `ы` | after g | the daemon, the mode and the driver's health, and eq doctor |
| `g` `h` | `р` | after g | the saved versions of eq.json: restore one, step with undo and redo |
| `g` `e` | `у` | after g | the daemon's events as they happen |
| `Esc` |  | after g | stay; any other key does too |
| `Enter` |  | palette | run the chosen line: an eq command as a child process, or a screen action |
| `Tab` |  | palette | take the chosen suggestion into the line |
| `↑` `↓` |  | palette | choose a suggestion; with the line empty, the last commands run come first |
| `Esc` |  | palette | close it |
| `↑` `↓` `j` `k` | `л` `о` | command output | scroll |
| `Ctrl-C` |  | command output | stop the command |
| `Esc` `q` | `й` `Й` | command output | close it; a command still running is stopped |
| `↑` `↓` `j` `k` | `л` `о` | the key list | scroll |
| `/` | `.` | the key list | show only the keys whose name or text has what you type |
| `?` `Esc` `q` | `,` `р` `Р` `й` `Й` | the key list | close |

The bottom row is the keybar: the keys of the view on screen, then those every view shares,
most useful first, whole entries dropped from the right when the terminal is narrow, `? keys` and
`q quit` always kept. It never hides. The row above it holds the save-as prompt, the palette's
line and the notes that last two seconds, and stays reserved when empty, so a note never moves the
meter. Below ten rows the two share one row and the keybar is only `? keys  q quit`. `z` shows its
state on the keybar (`z zones on`), and while an instrument is focused its knob, `l listen` and
`Esc unfocus` join it.

`?` or `h` opens the list of every key over the view, grouped: the view's own keys first, then
those of every view, `g`'s letters, the palette's and the command output's. It stays until `?`,
`Esc` or `q` closes it; `↑`/`↓` (`j`/`k`) scroll it when it is taller than the terminal, and `/`
keeps only the keys that have what you type. Keys under it do nothing to the curve. `m` turns mouse reporting on and remembers it as
`"tui": {"mouse": true}` in eq.json; it is off by default because it takes plain drag-to-select
away from the terminal; on, a click on a tab opens that view, a click on a band or a control in
Tune or on a list's row selects it, a second click on the row already chosen does what `Enter`
does (a terminal reports presses, not double clicks), and the wheel scrolls the lists and steps
whatever it is over in Tune. The table above is generated from the same key table the TUI reads
its keys from, and so is the KEYS section of `eq man`; tests keep all three equal.

Ctrl-Z hands the terminal back to the shell and `fg` brings the screen back as it was. The
terminal is put back the same way when the TUI is closed with `kill`, loses its terminal, or
crashes, so the shell is left usable. When the daemon goes away `eq watch` ends with exit 1;
`eq tui` says "daemon gone — reconnecting" in the message row and picks the meter up again once
the daemon is back.

Each frame writes only the cells that changed since the last one, in a single write wrapped in
synchronized-update brackets (`ESC [?2026h` … `ESC [?2026l`), so a terminal that knows them never
shows half a frame; one that answers that it does not know the mode gets no brackets. Levels that
stand still cost no output at all.

A step edits the current device's profile — the same one `eq set` would: the daemon's device,
else the default output — clamps to ±12 dB (preamp −30…+12), and saves at once; the daemon
picks it up and the curve moves on the next frame, while the band's gain chip turns solid for
half a second (the console's fader cap lights up). When the edit cannot be saved (no config yet,
say), the reason shows in the message row behind a `✗` for two seconds. Every letter key works from the same physical key on a Russian
layout, as the table's middle column shows. Three keys collide there, and the US meaning wins:
Shift+7 types `?`, the key list, so band 7 (2 kHz) is lowered from a US layout; Shift+4 types
`;`, the palette's key, so band 4 (250 Hz) is too; and the key that types `?` on a US layout
types `,`, which turns the knob down, so `h` (`р`) opens the key list there.

The header names the device's preset after the preamp, with the yellow `*` once the curve has
moved away from it. Bass, treble and tilt follow it when set: `bass +3 treble -2`, then the
instrument knobs that are set, each behind a dot in its colour, and the focused one even at 0:
`● voice +3.0`, then the compressor with its live reduction and the colour:
`night comp -3.2 │ tape 0.3`. The peak sits at the right edge, and SOLO, BYPASS and LIMIT as solid
flags after it; LIMIT stays lit a third of a second after the limiter lets go, so a one-frame
limit is seen. `p` applies the presets in turn, as `eq preset use` would. `u` walks back
through this session's steps, preset changes included, one per press, until the curve is as it
was when the session started; it does not reach past the session — that is `eq undo`. `s`
turns the message row into `save as: ▏`; while it is open every key types into it, digits
included, Backspace deletes, and a bad name shows its error in the same line for two seconds.

## Instruments

`z` (or `eq watch --zones`) opens a strip under the gain chips (in the compact rows, directly
above the level row): one row per instrument — kick, bass, snare, guitar, piano, voice, cymbals, air — with each of its
ranges drawn as a `━` span on the same frequency axis as the bars. A bar stands for the octave
around its band, so a range that starts at 85 Hz begins between the 64 Hz and 125 Hz bars, not
on either. Neighbouring ranges of one instrument are kept apart by a gap, and a range's name
(`F1`, `thump`, `sibilance`) is written into its span when it fits. Each instrument has its own
colour, warm to cool from kick to air, the same in the strip, the bracket, the knobs and the
instrument table; a row is in full colour while any of its bands is above −20 dBFS and faded
otherwise. The strip takes its rows from the meter; on a short terminal the lowest instruments
drop.
`eq zones` prints the same table in Hz with the bands each range touches.

```
 ◉ BE-RCA  44.1 kHz │ preamp -4.8 dB │ ◆ favourite* │ ● voice +3.0 │ focus: voice (85 Hz–9 kHz)     peak -6.0 dB  SOLO
╭─ meter ─────────────────────────────────────────────────────────────────── dBFS · gain dB ╮╭─ output ────────────────╮
│                    ┌────────────┐ ┌─── F1 ────┐ ┌── F2 ──┐ ┌──────┐ ┌────┐                ││ peak ███████████·▏  -6.0│
               ...
         -9      -8      -11     -15     -19     -17     -22     -26     -29     -37
        32Hz    64Hz    125Hz   250Hz   500Hz   1kHz    2kHz    4kHz    8kHz    16kHz
        +4.8    +4.0    +4.2    +2.3     0.0    -3.1     0.0     0.0    +3.1    +2.4
 vox                 ━━━━━━━━━━━━━━ ━━━━ F1 ━━━━━ ━━━ F2 ━━━ ━━━━━━━━ ━━━━━━
 ! listening to voice alone: 85 Hz–9 kHz — l again or Esc to stop
```

`]` or `Tab` focuses the next instrument, `[` the previous one, `Esc` lets go. While focused,
the header says `focus: voice (85 Hz–9 kHz)`, a bracket row above the bars marks each of its
ranges in the instrument's colour — the character range bright, the rest faded — the bars,
labels and gains of bands it does not touch fade toward the ground, its level numbers turn bold,
and the panel's border and the instrument's knob row light up. The strip, when open, shows only that instrument. Digit keys still name all ten
bands, but a band outside the focus is refused with `outside voice — Esc to unfocus` in the
message row, so tuning stays on the instrument. A band belongs to the focus when any of the
instrument's ranges overlaps the octave around the band's centre, which is why voice reaches
down to the 64 Hz band.

`l` listens to the focus alone: the daemon adds a steep high-pass and low-pass at the edges
of the instrument's character range (voice is heard at 2–5 kHz, not across its whole
85 Hz–9 kHz, which isolates little), and the header shows a yellow `SOLO` flag for as long as the daemon reports
it. Switching focus moves the solo to the new instrument. `l` again, `Esc` and `q` switch it
off; so does the watch going away in any other way, since the daemon drops a solo the moment
the client that asked for it disconnects. At a rate too low for the focus (air on a headset
in call mode) the message row says `can't listen to air at this rate` and nothing plays solo until
the focus moves to an instrument the rate can carry. A solo asked for while the device is
still settling at 0 Hz is asked for again once the rate arrives. A solo is never saved and never reaches `eq.json`.
It is the curve you hear through, not a second curve: the EQ stays one curve per device.

Each instrument has a knob for what the watch's focus only shows: `eq boost voice +3` (or `→`
while voice is focused) adds one peak filter at the geometric centre of the instrument's
character range, the range a mixing engineer reaches for to bring it forward, with a Q as wide
as that range; `−12`…`+12` dB, `0` removes it, and an unset knob costs nothing.

| Instrument | Character range | Why this one |
| --- | --- | --- |
| kick | thump 50–100 Hz | the weight you feel; the click shares 2–5 kHz with snare and guitar |
| bass | growl 700 Hz–1.2 kHz | what makes a bass line heard on small speakers; its low end is `eq bass` |
| snare | crack 4–6 kHz | cuts through; the body sits on the bass fundamental |
| guitar | bite 2–5 kHz | pick attack; the body spans four octaves |
| piano | brightness 4–8 kHz | hammer attack and clarity; the fundamental is most of the keyboard |
| voice | presence 2–5 kHz | intelligibility, where the ear is most sensitive |
| cymbals | shimmer 6–16 kHz | its only range |
| air | sparkle 10–20 kHz | its only range |

The knobs live as `"instruments": {"voice": 3}` on the profile next to `"preference"` and run
after it; presets carry them, `eq flat` drops them, `eq export` writes them as peak filters
(eqMac's format has no room for them and refuses), and undo and history see them like any
edit. `eq` prints `boost: voice +3 kick -2` when any is set; `eq boost` alone lists every
instrument with its range and gain. A name eq does not know, typed into `eq.json` by hand, is
ignored and logged by the daemon. A knob cannot split instruments that share a range: boosting
kick thump also lifts the bass there, and guitar bite and voice presence are the same knob.
