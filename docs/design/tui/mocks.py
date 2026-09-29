#!/usr/bin/env python3
"""Mock screens for the eq TUI looks: writes the .ans files, preview.html and the byte table.

    python3 docs/design/tui/mocks.py            # mocks + preview.html
    python3 docs/design/tui/mocks.py --bytes    # also the per-frame byte simulation

A design aid, not production code: the layouts here are what the spec's "Visual design"
section describes, drawn with made-up but plausible levels.
"""
import cmath
import json
import math
import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BANDS = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
LABELS = ["32Hz", "64Hz", "125Hz", "250Hz", "500Hz", "1kHz", "2kHz", "4kHz", "8kHz", "16kHz"]
SHORT = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
FLOOR = -60.0
SOLID_AS_BACKGROUND = True

INSTRUMENTS = [
    ("kick", "kck", [("thump", 50, 100), ("beater click", 2000, 5000)], "thump"),
    ("bass", "bas", [("fundamental", 40, 250), ("growl/attack", 700, 1200)], "growl/attack"),
    ("snare", "snr", [("body", 150, 250), ("crack", 4000, 6000)], "crack"),
    ("guitar", "gtr", [("body", 80, 1200), ("bite", 2000, 5000)], "bite"),
    ("piano", "pno", [("fundamental", 27, 4200), ("brightness", 4000, 8000)], "brightness"),
    ("voice", "vox", [("fundamental", 85, 255), ("F1", 300, 1000), ("F2", 900, 2800),
                      ("presence", 2000, 5000), ("sibilance", 5000, 9000)], "presence"),
    ("cymbals", "cym", [("shimmer", 6000, 16000)], "shimmer"),
    ("air", "air", [("sparkle", 10000, 20000)], "sparkle"),
]



def hex_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


Q2C = [0x00, 0x5F, 0x87, 0xAF, 0xD7, 0xFF]


def to_6cube(v):
    if v < 48:
        return 0
    if v < 114:
        return 1
    return (v - 35) // 40


def nearest256(rgb):
    """tmux's colour_find_rgb (colour.c): the real xterm cube levels, and the grey ramp when closer."""
    r, g, b = rgb
    qr, qg, qb = to_6cube(r), to_6cube(g), to_6cube(b)
    cr, cg, cb = Q2C[qr], Q2C[qg], Q2C[qb]
    if (cr, cg, cb) == (r, g, b):
        return 16 + 36 * qr + 6 * qg + qb
    grey_avg = (r + g + b) // 3
    grey_idx = 23 if grey_avg > 238 else max(grey_avg - 3, 0) // 10
    grey = 8 + 10 * grey_idx
    d = (cr - r) ** 2 + (cg - g) ** 2 + (cb - b) ** 2
    if (grey - r) ** 2 + (grey - g) ** 2 + (grey - b) ** 2 < d:
        return 232 + grey_idx
    return 16 + 36 * qr + 6 * qg + qb


class C:
    """One colour at every depth: 24-bit, the 256 index, and the 16-colour SGR it falls back to.

    `f16` is the foreground SGR at 16 colours (a colour code, and/or 1 bold / 2 dim); `b16` the
    background code there, or None when that surface simply is not painted at 16 colours.
    """
    __slots__ = ("rgb", "c256", "f16", "b16")

    def __init__(self, rgb, f16="", b16=None, c256=None):
        self.rgb = hex_rgb(rgb) if isinstance(rgb, str) else rgb
        self.c256 = nearest256(self.rgb) if c256 is None else c256
        self.f16 = f16
        self.b16 = b16

    def hex(self):
        return "#%02x%02x%02x" % self.rgb


def mix(a, b, t):
    """a blended toward b by t (0 = a)."""
    ar, br = a.rgb, b.rgb
    return tuple(round(ar[i] + (br[i] - ar[i]) * t) for i in range(3))


def fade(c, toward, t, f16=None):
    return C(mix(c, toward, t), c.f16 if f16 is None else f16, c.b16)



def palette(base):
    p = {k: C(*v) if isinstance(v, tuple) else C(v) for k, v in base.items()}
    return p


INK = palette({
    "bg": ("#24262b",),
    "surface": ("#1d2026",),
    "status": ("#1b1e25",),
    "chip": ("#2f3544", "", 100),
    "chip_hi": ("#39425a", "1", 100),
    "sel": ("#2f3d63", "", 104),
    "border": ("#4a5368", "2"),
    "border_hi": ("#7282a6", ""),
    "grid": ("#3d4454", "2"),
    "text": ("#dde2ea",),
    "text2": ("#a2abbc",),
    "text3": ("#7c859a", "2"),
    "title": ("#eef1f6", "1"),
    "accent": ("#8aa8ff", "36"),
    "boost": ("#63d99e", "32"),
    "cut": ("#f27fbc", "35"),
    "curve": ("#f3e9cf", "1"),
    "ghost": ("#3a4356", "2"),
    "warn": ("#f2c14e", "33"),
    "danger": ("#ff4d5e", "31"),
    "ok": ("#63d99e", "32"),
    "solo": ("#ffd166", "93"),
    "key_bg": ("#343c4d",),
    "key_fg": ("#eef1f6", "1"),
    "on_chip": ("#10131a", "", None),
    "kick": ("#ff7a59",), "bass": ("#ffae57",), "snare": ("#ffd966",), "guitar": ("#b5e36b",),
    "piano": ("#4fd6c4",), "voice": ("#6cb6ff",), "cymbals": ("#b99cff",), "air": ("#f590d6",),
})
INK_METER = [(-60, "#1b5e57"), (-36, "#1f8f6b"), (-18, "#4cc873"), (-10, "#d9c84e"),
             (-6, "#f2a33a"), (-3, "#f2663a"), (0, "#ff3f63")]

PAPER = palette({
    "bg": ("#f6f3ec",),
    "surface": ("#fbf9f4",),
    "status": ("#ece7dc",),
    "chip": ("#e2dccf", "", 47),
    "chip_hi": ("#d6cfbf", "1", 47),
    "sel": ("#dfe6fb", "", 47),
    "border": ("#cbc3b3", "2"),
    "border_hi": ("#9a917f", ""),
    "grid": ("#e2dccf", "2"),
    "text": ("#20242d",),
    "text2": ("#4a5264",),
    "text3": ("#8b909d", "2"),
    "title": ("#15181f", "1"),
    "accent": ("#3552cc", "34"),
    "boost": ("#1d9457", "32"),
    "cut": ("#bd2f79", "35"),
    "curve": ("#262a33", "1"),
    "ghost": ("#dcd6c9", "2"),
    "warn": ("#b7860b", "33"),
    "danger": ("#cf1f3a", "31"),
    "ok": ("#1d9457", "32"),
    "solo": ("#a86d00", "33"),
    "key_bg": ("#e2dccf",),
    "key_fg": ("#15181f", "1"),
    "on_chip": ("#fbf9f4", "", None),
    "kick": ("#d4502f",), "bass": ("#c97a12",), "snare": ("#a88a00",), "guitar": ("#5d8f16",),
    "piano": ("#0f8f80",), "voice": ("#2f6fd0",), "cymbals": ("#7453d6",), "air": ("#c0469d",),
})
PAPER_METER = [(-60, "#9cc9bb"), (-36, "#4fae84"), (-18, "#2c9a55"), (-10, "#c29a14"),
               (-6, "#e07b1f"), (-3, "#e0501f"), (0, "#d61f45")]

BRASS = palette({
    "bg": ("#12110f",),
    "surface": ("#1c1a17",),
    "status": ("#23201c",),
    "chip": ("#2e2a24", "", 100),
    "chip_hi": ("#3a352d", "1", 100),
    "sel": ("#3a3226", "", 100),
    "border": ("#3a352d", "2"),
    "border_hi": ("#6b6254", ""),
    "grid": ("#2a2621", "2"),
    "groove": ("#0c0b09", "2"),
    "text": ("#ece3cf",),
    "text2": ("#b9ae97",),
    "text3": ("#7e7564", "2"),
    "title": ("#f4ecd8", "1"),
    "accent": ("#f0a24a", "33"),
    "boost": ("#86e0a6", "32"),
    "cut": ("#f58cc3", "35"),
    "curve": ("#f4ecd8", "1"),
    "ghost": ("#2d2a25", "2"),
    "warn": ("#f5c647", "33"),
    "danger": ("#ff4b3e", "31"),
    "ok": ("#3ddc74", "32"),
    "solo": ("#ffcf4a", "93"),
    "key_bg": ("#34302a",),
    "key_fg": ("#f4ecd8", "1"),
    "on_chip": ("#16140f", "", None),
    "tape_bg": ("#e6dabd", "", 47),
    "tape_fg": ("#2a251c", "30"),
    "lcd_bg": ("#0b0a07",),
    "lcd_fg": ("#ffb547", "33"),
    "window_bg": ("#0b2c63", "", 44),
    "window_fg": ("#8fd3ff", "96"),
    "needle": ("#fbf8ef", "97"),
    "cap": ("#d8d1c2", ""),
    "cap_sel": ("#f0a24a", "33"),
    "track": ("#3b362e", "2"),
    "lamp_off": ("#3a2320", "2"),
    "kick": ("#ff7a59",), "bass": ("#ffae57",), "snare": ("#ffd966",), "guitar": ("#b5e36b",),
    "piano": ("#4fd6c4",), "voice": ("#6cb6ff",), "cymbals": ("#b99cff",), "air": ("#f590d6",),
})
LED = [(-18, "#3ddc74", "32"), (-6, "#f5d547", "33"), (1, "#ff4b3e", "31")]
LED_OFF = {"#3ddc74": "#12301d", "#f5d547": "#352f10", "#ff4b3e": "#3a1512"}

# The 16-colour look: the terminal's own sixteen, as eq paints today.
CLASSIC = palette({
    "bg": ("#000000",), "surface": ("#000000",), "status": ("#000000",),
    "chip": ("#555555", "", None), "chip_hi": ("#555555", "1", None), "sel": ("#555555", "", None),
    "border": ("#555555", "2"), "border_hi": ("#aaaaaa", ""), "grid": ("#555555", "2"),
    "text": ("#cccccc",), "text2": ("#cccccc",), "text3": ("#777777", "2"), "title": ("#ffffff", "1"),
    "accent": ("#00aaaa", "36"), "boost": ("#00aa00", "32"), "cut": ("#aa00aa", "35"),
    "curve": ("#ffffff", "1"), "ghost": ("#555555", "2"), "warn": ("#aaaa00", "33"),
    "danger": ("#aa0000", "31"), "ok": ("#00aa00", "32"), "solo": ("#ffff55", "93"),
    "key_bg": ("#000000",), "key_fg": ("#ffffff", "1"), "on_chip": ("#000000",),
    "kick": ("#cccccc",), "bass": ("#cccccc",), "snare": ("#cccccc",), "guitar": ("#cccccc",),
    "piano": ("#cccccc",), "voice": ("#cccccc",), "cymbals": ("#cccccc",), "air": ("#cccccc",),
})


def zone16(db):
    return "32" if db < -18 else ("33" if db < -6 else "31")


def gradient(stops, db, bright=0.0, toward=None):
    db = max(min(db, stops[-1][0]), stops[0][0])
    for (d0, h0), (d1, h1) in zip(stops, stops[1:]):
        if d0 <= db <= d1:
            t = (db - d0) / (d1 - d0) if d1 > d0 else 0
            a, b = hex_rgb(h0), hex_rgb(h1)
            rgb = tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))
            break
    c = C(rgb, zone16(db), int(zone16(db)) + 10)
    if bright:
        c = C(mix(c, C("#ffffff"), bright), c.f16, c.b16)
    if toward is not None:
        c = C(mix(c, toward, 0.72), "2", None)
    return c


def led(db, lit):
    for top, hexv, code in LED:
        if db < top:
            return C(hexv, code, int(code) + 10) if lit else C(LED_OFF[hexv], "2;" + code, None)
    return C(LED[-1][1], "31", 41)



class Cell:
    __slots__ = ("ch", "fg", "bg", "bold", "dim", "ul", "rev")

    def __init__(self):
        self.ch, self.fg, self.bg, self.bold, self.dim, self.ul, self.rev = " ", None, None, False, False, False, False


class Canvas:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.cells = [[Cell() for _ in range(w)] for _ in range(h)]

    def put(self, x, y, s, fg=None, bg=None, bold=False, dim=False, ul=False, rev=False):
        if not 0 <= y < self.h:
            return x
        for ch in s:
            if 0 <= x < self.w:
                c = self.cells[y][x]
                c.ch, c.fg, c.bold, c.dim, c.ul, c.rev = ch, fg, bold, dim, ul, rev
                if bg is not None:
                    c.bg = bg
            x += 1
        return x

    def fill(self, x, y, w, h, bg):
        for yy in range(y, y + h):
            for xx in range(x, x + w):
                if 0 <= xx < self.w and 0 <= yy < self.h:
                    self.cells[yy][xx].bg = bg

    def box(self, x, y, w, h, border, title=None, title_fg=None, right=None, right_fg=None):
        self.put(x, y, "╭" + "─" * (w - 2) + "╮", border)
        for yy in range(y + 1, y + h - 1):
            self.put(x, yy, "│", border)
            self.put(x + w - 1, yy, "│", border)
        self.put(x, y + h - 1, "╰" + "─" * (w - 2) + "╯", border)
        if title:
            self.put(x + 2, y, " " + title + " ", title_fg, bold=True)
        if right:
            self.put(x + w - 3 - len(right), y, " " + right + " ", right_fg)

    def dim_all(self, toward, t=0.68):
        for row in self.cells:
            for c in row:
                if c.fg is not None:
                    c.fg = C(mix(c.fg, toward, t), "2", None)
                elif c.ch != " ":
                    c.dim = True
                if c.bg is not None:
                    c.bg = C(mix(c.bg, toward, t), "", None)
                c.bold = False



def sgr_state(cell, depth, default_fg):
    """The terminal pen a cell needs: (fg, bg, bold, dim, ul, rev) as SGR parameter strings."""
    fg = cell.fg if cell.fg is not None else default_fg
    bold, dim, rev = cell.bold, cell.dim, False
    f = b = None
    if depth == "tc":
        f = "38;2;%d;%d;%d" % fg.rgb if fg is not None else None
        b = "48;2;%d;%d;%d" % cell.bg.rgb if cell.bg is not None else None
    elif depth == "256":
        f = "38;5;%d" % fg.c256 if fg is not None else None
        b = "48;5;%d" % cell.bg.c256 if cell.bg is not None else None
    else:
        if fg is not None and fg.f16:
            for part in fg.f16.split(";"):
                if part == "1":
                    bold = True
                elif part == "2":
                    dim = True
                elif depth == "16":
                    f = part
        if cell.bg is not None and cell.bg.b16 is not None and depth == "16":
            b = str(cell.bg.b16)
        elif cell.rev:
            rev = True
        if depth == "16" and b is not None and f is None and fg is not None and fg.f16 == "":
            f = None
    return (f, b, bold, dim and not bold, cell.ul, rev)


def transition(cur, new):
    if cur == new:
        return ""
    f, b, bold, dim, ul, rev = new
    cf, cb, cbold, cdim, cul, crev = cur
    need_reset = (cbold and not bold) or (cdim and not dim) or (cul and not ul) or (crev and not rev) \
        or (cf is not None and f is None) or (cb is not None and b is None)
    parts = []
    if need_reset:
        parts.append("0")
        cf = cb = None
        cbold = cdim = cul = crev = False
    if bold and not cbold:
        parts.append("1")
    if dim and not cdim:
        parts.append("2")
    if ul and not cul:
        parts.append("4")
    if rev and not crev:
        parts.append("7")
    if f != cf and f is not None:
        parts.append(f)
    if b != cb and b is not None:
        parts.append(b)
    return "\x1b[" + ";".join(parts) + "m" if parts else ""


EMPTY = (None, None, False, False, False, False)


def emit(cv, depth, default_fg=None):
    """Whole screen as lines, the pen carried between cells so only changes are written."""
    out = []
    for row in cv.cells:
        last = max((i for i, c in enumerate(row) if c.ch != " " or c.bg is not None or c.rev), default=-1)
        line, pen = "", EMPTY
        for c in row[:last + 1]:
            st = sgr_state(c, depth, default_fg)
            line += transition(pen, st) + c.ch
            pen = st
        if pen != EMPTY:
            line += "\x1b[0m"
        out.append(line)
    return "\n".join(out) + "\n"



def peaking_db(f, f0, gain, q=1.41, fs=44100.0):
    if gain == 0:
        return 0.0
    a = 10 ** (gain / 40)
    w0 = 2 * math.pi * f0 / fs
    alpha = math.sin(w0) / (2 * q)
    cw = math.cos(w0)
    b = (1 + alpha * a, -2 * cw, 1 - alpha * a)
    den = (1 + alpha / a, -2 * cw, 1 - alpha / a)
    z = cmath.exp(-1j * 2 * math.pi * f / fs)
    h = (b[0] + b[1] * z + b[2] * z * z) / (den[0] + den[1] * z + den[2] * z * z)
    return 20 * math.log10(abs(h))


def response(f, gains):
    return sum(peaking_db(f, f0, g) for f0, g in zip(BANDS, gains))


def freq_at(x, centres):
    """Log-frequency interpolation between band centres, the edge octave's slope beyond them."""
    logs = [math.log2(f) for f in BANDS]
    k = len(centres) - 2
    for i in range(len(centres) - 1):
        if x <= centres[i + 1]:
            k = i
            break
    a, b = centres[k], centres[k + 1]
    return 2 ** (logs[k] + (logs[k + 1] - logs[k]) * (x - a) / (b - a))


def col_of(f, centres):
    logs = [math.log2(v) for v in BANDS]
    l = math.log2(max(f, 1))
    k = len(logs) - 2
    for i in range(len(logs) - 1):
        if l <= logs[i + 1]:
            k = i
            break
    a, b = centres[k], centres[k + 1]
    return a + (b - a) * (l - logs[k]) / (logs[k + 1] - logs[k])


BRAILLE_BITS = [[0x01, 0x02, 0x04, 0x40], [0x08, 0x10, 0x20, 0x80]]


def curve_cells(gains, x0, width, top, rows, centres, span=12.0):
    """Braille dots of the response over [x0, x0+width) × rows: 2×4 dots a cell, joined vertically."""
    dots = {}
    total = rows * 4 - 1
    prev = None
    ys = []
    for dx in range(width * 2):
        x = x0 + (dx + 0.5) / 2
        g = max(min(response(freq_at(x, centres), gains), span), -span)
        dy = round((span - g) / (2 * span) * total)
        ys.append(dy)
        lo, hi = (dy, dy) if prev is None else (min(prev, dy), max(prev, dy))
        if prev is not None and hi - lo > 1:
            lo, hi = (prev + 1, dy) if dy > prev else (dy, prev - 1)
        for y in range(lo, hi + 1):
            cx, cy = x0 + dx // 2, top + y // 4
            dots[(cx, cy)] = dots.get((cx, cy), 0) | BRAILLE_BITS[dx % 2][y % 4]
        prev = dy
    return {k: chr(0x2800 + v) for k, v in dots.items()}, ys



def base_state():
    return dict(
        device="BE-RCA", rate="44.1", preamp=-4.8, preset="favourite", modified=True,
        knobs={"voice": 3.0}, comp=("night", -2.1), colour=("tape", 0.3), peak=-6.0,
        limiting=False, solo=False, bypass=False, bass=1.0, treble=-0.5, tilt=0.0,
        gains=[4.8, 4.0, 4.2, 2.3, 0.0, -3.1, 0.0, 0.0, 3.1, 2.4],
        out=[-9.0, -7.5, -11.0, -15.0, -19.0, -17.0, -22.0, -26.0, -29.0, -37.0],
        inp=[-7.0, -6.0, -9.5, -14.0, -19.0, -14.5, -22.0, -26.0, -31.0, -39.0],
        peaks=[-4.2, -3.1, -7.0, -11.5, -15.0, -13.2, -18.0, -21.5, -25.0, -31.0],
        focus=None, zones=False, flash=None, message=None, message_kind=None, view="Meter", mouse=False,
    )


TABS = ["Meter", "Tune", "Instruments", "Filters", "Presets", "Devices", "Apps", "System", "Events", "History"]


def fmt(v, digits=1):
    return ("%+." + str(digits) + "f") % v if v != 0 else ("%." + str(digits) + "f") % 0


def gain_ink(p, g):
    return p["boost"] if g > 0 else (p["cut"] if g < 0 else p["text3"])


def instrument(name):
    return next(i for i in INSTRUMENTS if i[0] == name)


def touched_bands(inst):
    out = set()
    for _, lo, hi in inst[2]:
        for i, f in enumerate(BANDS):
            if lo < f * 2 ** 0.5 and hi > f / 2 ** 0.5:
                out.add(i)
    return out



def status_bar(cv, y, st, p, look):
    """Segments drop from the right until the line fits beside the peak and the flags, as Watch.header does."""
    W = cv.w
    cv.fill(0, y, W, 1, p["status"])
    segs = [[(" " + st["rate"] + " kHz", p["text2"], False)],
            [("preamp ", p["text3"], False), (fmt(st["preamp"]), gain_ink(p, st["preamp"]), False), (" dB", p["text3"], False)],
            [("◆ ", p["accent"], False), (st["preset"], p["text"], True)] + ([("*", p["warn"], True)] if st["modified"] else [])]
    knobs = [(n, v) for n, v in st["knobs"].items()]
    if st["focus"] and st["focus"] not in st["knobs"]:
        knobs.append((st["focus"], 0.0))
    if knobs:
        seg = []
        for i, (n, v) in enumerate(knobs):
            seg += [((" " if i else "") + "● ", p[n], False), (n + " ", p["text"], False), (fmt(v), gain_ink(p, v), False)]
        segs.append(seg)
    tone = [(n, st[n]) for n in ("bass", "treble", "tilt") if st[n] != 0]
    if tone:
        seg = []
        for i, (n, v) in enumerate(tone):
            seg += [((" " if i else "") + n + " ", p["text3"], False), ("%+g" % v, gain_ink(p, v), False)]
        segs.append(seg)
    if st["comp"]:
        mode, gr = st["comp"]
        segs.append([(mode, p["accent"], False), (" comp ", p["text3"], False), ("%.1f" % gr, p["warn"], False)])
    if st["colour"]:
        segs.append([(st["colour"][0], p["accent"], False), (" %g" % st["colour"][1], p["text2"], False)])
    flags = []
    if st["solo"]:
        flags.append((" SOLO ", p["solo"]))
    if st["bypass"]:
        flags.append((" BYPASS ", p["warn"]))
    if st["limiting"]:
        flags.append((" LIMIT ", p["danger"]))
    right_w = len(" peak ") + len(fmt(st["peak"])) + len(" dB ") + sum(len(f) + 1 for f, _ in flags)
    head = " ◉ " + st["device"] + " "
    width = lambda: len(head) + sum(sum(len(t) for t, _, _ in seg) + 3 for seg in segs)
    while width() > W - right_w and len(segs) > 3:
        segs.pop()
    x = cv.put(0, y, " ◉ ", p["accent"], p["chip_hi"])
    x = cv.put(x, y, st["device"] + " ", p["title"], p["chip_hi"], bold=True)
    for i, seg in enumerate(segs):
        if i:
            x = cv.put(x, y, " │ ", p["border"])
        for text, ink, bold in seg:
            x = cv.put(x, y, text, ink, bold=bold)
    xx = cv.put(W - right_w, y, " peak ", p["text3"])
    xx = cv.put(xx, y, fmt(st["peak"]), gradient(INK_METER if p is not PAPER else PAPER_METER, st["peak"]))
    xx = cv.put(xx, y, " dB ", p["text3"])
    for text, ink in flags:
        xx = cv.put(xx, y, text, p["on_chip"], ink, bold=True, rev=True)
        xx += 1


def tab_row(cv, y, active, p, compact=False):
    x = 1
    for t in TABS:
        is_active = t == active
        if is_active:
            x = cv.put(x, y, " " + t[0], p["on_chip"], p["accent"], bold=True, rev=True)
            x = cv.put(x, y, t[1:] + " ", p["on_chip"], p["accent"], bold=True, rev=True)
        else:
            x = cv.put(x, y, "" if compact else " ", None)
            x = cv.put(x, y, t[0], p["accent"], ul=True)
            x = cv.put(x, y, t[1:] + ("" if compact else " "), p["text3"])
        x += 1
    hint = "g go  ; cmd"
    if cv.w - len(hint) - 1 > x + 2:
        cv.put(cv.w - len(hint) - 1, y, "g", p["accent"], bold=True)
        cv.put(cv.w - len(hint), y, " go  ", p["text3"])
        cv.put(cv.w - len(hint) + 5, y, ";", p["accent"], bold=True)
        cv.put(cv.w - len(hint) + 6, y, " cmd", p["text3"])


def keybar(cv, y, entries, p, keycaps=True):
    x = 0
    pinned = [("?", "keys"), ("q", "quit")]
    extra = 5 if keycaps else 3
    room = cv.w - sum(len(k) + len(t) + extra for k, t in pinned)
    fitted = []
    for k, t in entries:
        need = len(k) + len(t) + extra
        if sum(len(a) + len(b) + extra for a, b in fitted) + need > room:
            break
        fitted.append((k, t))
    for k, t in fitted + pinned:
        if keycaps:
            x = cv.put(x, y, " " + k + " ", p["key_fg"], p["key_bg"], bold=True)
        else:
            x = cv.put(x, y, k, p["key_fg"], bold=True)
        x = cv.put(x, y, " " + t + "  ", p["text3"])


def message_row(cv, y, st, p, x=1):
    if not st["message"]:
        return
    ink = {"ok": p["ok"], "warn": p["warn"], "err": p["danger"]}.get(st["message_kind"], p["text3"])
    mark = {"ok": "✓ ", "warn": "! ", "err": "✗ "}.get(st["message_kind"], "")
    x = cv.put(x, y, mark, ink, bold=True)
    cv.put(x, y, st["message"], p["text2"])


METER_KEYS = [("1…0", "band"), ("⇧", "down"), ("z", "zones"), ("i", "instruments"), ("[ ]", "focus"),
              ("+−", "preamp"), ("p", "preset"), ("u", "undo"), ("s", "save"), ("y", "look")]
FOCUS_KEYS = [("1…0", "band"), ("⇧", "down"), ("z", "zones on"), ("[ ]", "focus"), ("← →", "knob"),
              ("l", "listen on"), ("Esc", "unfocus"), ("i", "instruments"), ("y", "look")]



def gauge(cv, x, y, w, frac, ink, track):
    cells = frac * w
    full = int(cells)
    part = " ▏▎▍▌▋▊▉"[int((cells - full) * 8)]
    cv.put(x, y, "█" * full, ink)
    if full < w:
        cv.put(x + full, y, part if part != " " else "·", ink if part != " " else track)
        cv.put(x + full + 1, y, "·" * (w - full - 1), track)


def bipolar(cv, x, y, w, value, span, p):
    """Centre tick, a bar from the centre to the value, a dot at the value."""
    half = w // 2
    cv.put(x, y, "┄" * w, p["grid"])
    cv.put(x + half, y, "┼", p["border_hi"])
    n = round(abs(value) / span * half)
    ink = gain_ink(p, value)
    if value > 0:
        cv.put(x + half + 1, y, "━" * max(n - 1, 0), ink)
        cv.put(x + half + n, y, "●", ink)
    elif value < 0:
        cv.put(x + half - n + 1, y, "━" * max(n - 1, 0), ink)
        cv.put(x + half - n, y, "●", ink)


def side_panel(cv, x, y, w, h, st, p, stops):
    by = y
    cv.box(x, by, w, 4, p["border"], "output", p["text2"])
    cv.put(x + 2, by + 1, "peak ", p["text3"])
    frac = (st["peak"] - FLOOR) / -FLOOR
    gw = w - 14
    for i in range(gw):
        db = FLOOR + (i + 0.5) / gw * -FLOOR
        on = i < int(frac * gw)
        cv.put(x + 7 + i, by + 1, "▮" if False else ("█" if on else "·"), gradient(stops, db) if on else p["grid"])
    cv.put(x + 7 + int(frac * gw) + 1, by + 1, "▏", p["title"])
    cv.put(x + w - 6, by + 1, "%5.1f" % st["peak"], p["text"])
    cv.put(x + 2, by + 2, "limit ", p["text3"])
    lit = st["limiting"]
    cv.put(x + 8, by + 2, "●", p["danger"] if lit else p["grid"])
    cv.put(x + 10, by + 2, "limiting" if lit else "idle", p["danger"] if lit else p["text3"])
    by += 4
    cv.box(x, by, w, 5, p["border"], "dynamics", p["text2"])
    mode, gr = st["comp"]
    cv.put(x + 2, by + 1, "comp  ", p["text3"])
    cv.put(x + 8, by + 1, mode, p["accent"], bold=True)
    cv.put(x + 2, by + 2, "GR    ", p["text3"])
    gw = w - 15
    n = round(min(abs(gr), 12) / 12 * gw)
    cv.put(x + 8, by + 2, "·" * (gw - n), p["grid"])
    cv.put(x + 8 + gw - n, by + 2, "█" * n, p["warn"])
    cv.put(x + w - 6, by + 2, "%5.1f" % gr, p["warn"])
    kind, amount = st["colour"]
    cv.put(x + 2, by + 3, "colour", p["text3"])
    cv.put(x + 9, by + 3, kind, p["accent"], bold=True)
    gauge(cv, x + 14, by + 3, w - 21, amount, p["accent"], p["grid"])
    cv.put(x + w - 5, by + 3, "%4.1f" % amount, p["text"])
    by += 5
    cv.box(x, by, w, 5, p["border"], "tone", p["text2"])
    for i, n in enumerate(("bass", "treble", "tilt")):
        cv.put(x + 2, by + 1 + i, n, p["text3"])
        bipolar(cv, x + 9, by + 1 + i, w - 17, st[n], 6, p)
        cv.put(x + w - 6, by + 1 + i, "%5s" % fmt(st[n]), gain_ink(p, st[n]))
    by += 5
    rows = min(len(INSTRUMENTS), h - (by - y) - 2)
    cv.box(x, by, w, rows + 2, p["border"], "knobs", p["text2"])
    for i, (name, *_rest) in enumerate(INSTRUMENTS[:rows]):
        v = st["knobs"].get(name, 0.0)
        focused = st["focus"] == name
        cv.put(x + 2, by + 1 + i, "●", p[name])
        cv.put(x + 4, by + 1 + i, name, p["title"] if focused or v else p["text2"], bold=focused)
        bipolar(cv, x + 12, by + 1 + i, w - 20, v, 12, p)
        cv.put(x + w - 6, by + 1 + i, "%5s" % fmt(v), gain_ink(p, v))
        if focused:
            cv.fill(x + 1, by + 1 + i, w - 2, 1, p["sel"])


def studio_layout(W, H, st):
    side_w = 27 if W >= 110 else 0
    panel_w = W - side_w
    cell = max(4, min(8, (panel_w - 2 - 11) // 10))
    bw = 5 if cell >= 7 else (3 if cell >= 4 else 1)
    inner = 11 + cell * 10
    pad = max((panel_w - 2 - inner) // 2, 0)
    px = pad
    gx = px + 1
    x0 = gx + 6
    tabs = H >= 14
    top = 2 if tabs else 1
    zone_list = []
    if st["zones"]:
        zone_list = [instrument(st["focus"])] if st["focus"] else list(INSTRUMENTS)
    zrows = min(len(zone_list), max(H - 22, 0))
    bracket = 1 if st["focus"] else 0
    meter_rows = H - top - 1 - 1 - 3 - zrows - 2 - bracket
    centres = [x0 + i * cell + (cell - bw) // 2 + bw // 2 for i in range(10)]
    return dict(side_w=side_w, panel_w=panel_w - (1 if side_w else 0), cell=cell, bw=bw, px=px, gx=gx, x0=x0,
                top=top, tabs=tabs, zones=zone_list[:zrows], M=meter_rows, bracket=bracket, centres=centres,
                panel_inner_w=inner + 2)


def draw_segments(cv, y, inst, centres, x_lo, x_hi, ink, name_ink, stroke="━", ends=None, char_ink=None):
    spans = []
    for name, lo, hi in sorted(inst[2], key=lambda r: r[1]):
        a = max(round(col_of(lo, centres)), x_lo)
        b = min(round(col_of(hi, centres)), x_hi)
        if b < x_lo or a > x_hi:
            continue
        if spans and a <= spans[-1][2] + 1:
            cut = (spans[-1][2] + a) // 2
            spans[-1][2] = min(spans[-1][2], cut - 1)
            a = max(a, cut + 1)
        if a <= b:
            spans.append([name, a, b])
    for name, a, b in spans:
        n = b - a + 1
        is_char = name == inst[3]
        k = char_ink if (is_char and char_ink) else ink
        cv.put(a, y, stroke * n, k)
        if ends and n >= 2:
            cv.put(a, y, ends[0], k)
            cv.put(b, y, ends[1], k)
        if len(name) + 4 <= n:
            at = a + (n - len(name)) // 2
            cv.put(at - 1, y, " " + name + " ", k if is_char else name_ink, bold=is_char)


def studio_meter(W, H, st, p, stops, dark=True, paint_bg=False):
    cv = Canvas(W, H)
    if paint_bg:
        cv.fill(0, 0, W, H, p["bg"])
    L = studio_layout(W, H, st)
    status_bar(cv, 0, st, p, "studio")
    if L["tabs"]:
        tab_row(cv, 1, st["view"], p, compact=W < 100)
    M, x0, cell, bw, centres = L["M"], L["x0"], L["cell"], L["bw"], L["centres"]
    top = L["top"]
    pw = L["panel_inner_w"]
    focus = instrument(st["focus"]) if st["focus"] else None
    inside = touched_bands(focus) if focus else set(range(10))
    body_top = top + 1 + L["bracket"]
    cv.box(L["px"], top, pw, M + 2 + L["bracket"], p["border_hi"] if focus else p["border"], "meter", p["text2"],
           right="dBFS · gain dB", right_fg=p["text3"])
    if focus:
        draw_segments(cv, top + 1, focus, centres, x0, x0 + cell * 10 - 1, p[focus[0]],
                      fade(p[focus[0]], p["bg"], 0.35), stroke="─", ends=("┌", "┐"), char_ink=p[focus[0]])
    for db in (0, -6, -12, -24, -36, -48, -60):
        b = min(int((db - FLOOR) / -FLOOR * M), M - 1)
        r = body_top + M - 1 - b
        cv.put(L["gx"], r, "%3d" % db, p["text3"])
        cv.put(L["gx"] + 4, r, "┤", p["border"])
    ax = x0 + cell * 10
    for g in (12, 6, 0, -6, -12):
        r = body_top + round((12 - g) / 24 * (M - 1))
        cv.put(ax, r, "├", p["border"])
        cv.put(ax + 1, r, ("%+d" % g if g else " 0"), p["curve"] if g == 0 else p["text3"])
    curve, ys = curve_cells(st["gains"], x0, cell * 10, body_top, M, centres)
    zero_row = body_top + round((M * 4 - 1) / 2) // 4
    fb = C(mix(p["boost"], p["bg"], 0.84), "", None, 22)
    fc = C(mix(p["cut"], p["bg"], 0.84), "", None, 53)
    for cx in range(cell * 10):
        dy = (ys[cx * 2] + ys[cx * 2 + 1]) / 2
        crow = body_top + int(dy // 4)
        lo, hi = sorted((crow, zero_row))
        for r in range(lo, hi + 1):
            if r != crow:
                cv.fill(x0 + cx, r, 1, 1, fb if crow < zero_row else fc)
        cv.put(x0 + cx, zero_row, "┈", p["grid"])
    dim_to = p["bg"]
    for i in range(10):
        bx = x0 + i * cell + (cell - bw) // 2
        out_h = (st["out"][i] - FLOOR) / -FLOOR * M
        in_h = (st["inp"][i] - FLOOR) / -FLOOR * M
        pk = min(int((st["peaks"][i] - FLOOR) / -FLOOR * M), M - 1)
        full = int(out_h)
        frac = out_h - full
        outside = i not in inside
        for b in range(M):
            r = body_top + M - 1 - b
            db = FLOOR + (b + 0.5) / M * -FLOOR
            ink = gradient(stops, db, toward=dim_to if outside else None)
            if b < full and SOLID_AS_BACKGROUND:
                cv.put(bx, r, " " * bw, None, ink, rev=True)
            elif b < full:
                cv.put(bx, r, "█" * bw, ink)
            elif b == full and frac > 0.12:
                cv.put(bx, r, "▁▂▃▄▅▆▇█"[min(int(frac * 8), 7)] * bw, ink)
            elif b == pk and pk > full:
                cv.put(bx, r, "▔" * bw, gradient(stops, db, bright=0.35, toward=dim_to if outside else None))
            elif b < in_h:
                cv.put(bx, r, "░" * bw, p["ghost"])
    for (cx, cy), ch in curve.items():
        cell_ = cv.cells[cy][cx]
        under = cell_.fg if cell_.ch in "█▁▂▃▄▅▆▇" else (cell_.bg if cell_.rev else None)
        cv.put(cx, cy, ch, p["curve"], under, rev=under is not None)
    y = top + M + 2 + L["bracket"]
    for i in range(10):
        c = centres[i]
        db = st["out"][i]
        t = "·" if db <= FLOOR + 0.5 else "%d" % round(db)
        outside = i not in inside
        cv.put(c - len(t) // 2, y, t, gradient(stops, db, toward=dim_to if outside else None) if db > FLOOR else p["text3"])
        lab = LABELS[i] if cell >= 6 else SHORT[i]
        cv.put(c - len(lab) // 2, y + 1, lab, p["text3"] if outside else p["text2"], bold=st["flash"] == i)
        g = st["gains"][i]
        t = fmt(g)
        ink = gain_ink(p, g)
        chip = None if g == 0 else C(mix(ink, p["bg"], 0.72), "", None, 22 if g > 0 else 53)
        if outside:
            ink, chip = p["text3"], None
        if st["flash"] == i:
            cv.put(c - len(t) // 2 - 1, y + 2, " " + t + " ", p["on_chip"], ink, bold=True, rev=True)
        else:
            cv.put(c - len(t) // 2 - 1, y + 2, " " + t + " ", ink, chip)
    y += 3
    for inst in L["zones"]:
        name, short = inst[0], inst[1]
        loud = max((st["out"][b] for b in touched_bands(inst)), default=FLOOR) > -20
        hue = p[name] if (loud or focus) else fade(p[name], p["bg"], 0.55)
        cv.put(L["gx"], y, short, hue, bold=bool(focus))
        draw_segments(cv, y, inst, centres, x0, x0 + cell * 10 - 1, hue, p["text3"], char_ink=p[name] if focus else None)
        y += 1
    if L["side_w"]:
        side_panel(cv, W - L["side_w"], top, L["side_w"], H - top - 2, st, p, stops)
    message_row(cv, H - 2, st, p, x=L["gx"])
    keybar(cv, H - 1, FOCUS_KEYS if focus else METER_KEYS, p)
    return cv



def studio_instruments(W, H, st, p, stops):
    cv = Canvas(W, H)
    status_bar(cv, 0, st, p, "studio")
    tab_row(cv, 1, "Instruments", p)
    rows = sum(len(i[2]) for i in INSTRUMENTS)
    bx, bw = 1, W - 2
    cv.box(bx, 2, bw, rows + 4, p["border"], "instruments", p["text2"], right="8 instruments · 15 ranges",
           right_fg=p["text3"])
    cols = dict(name=bx + 4, knob=bx + 14, val=bx + 26, rng=bx + 35, hz=bx + 51, map=bx + 64, bands=bx + 98)
    hy = 3
    map_w = 30
    l0, l1 = math.log2(20), math.log2(20000)
    for key, text in (("name", "instrument"), ("val", " knob"), ("rng", "range"), ("hz", "Hz"), ("bands", "bands")):
        cv.put(cols[key], hy, text, p["text3"])
    for f, lab in ((32, "32"), (250, "250"), (2000, "2k"), (16000, "16k")):
        cv.put(cols["map"] + round((math.log2(f) - l0) / (l1 - l0) * (map_w - 1)) - len(lab) // 2, hy, lab, p["text3"])
    y = hy + 1
    for inst in INSTRUMENTS:
        name, short, ranges, character = inst
        v = st["knobs"].get(name, 0.0)
        selected = name == (st["focus"] or "voice")
        for k, (rname, lo, hi) in enumerate(ranges):
            if selected:
                cv.fill(bx + 1, y, bw - 2, 1, p["sel"])
                if k == 0:
                    cv.put(bx + 2, y, "▸", p["accent"], bold=True)
            if k == 0:
                cv.put(cols["name"] - 2, y, "●", p[name])
                cv.put(cols["name"], y, name, p["title"] if selected else p["text"], bold=selected)
                bipolar(cv, cols["knob"], y, 11, v, 12, p)
                cv.put(cols["val"], y, "%5s" % fmt(v), gain_ink(p, v))
            is_char = rname == character
            cv.put(cols["rng"] - 2, y, "◆" if is_char else " ", p[name])
            cv.put(cols["rng"], y, rname, p["text"] if is_char else p["text2"], bold=is_char)
            hz = lambda f: ("%gk" % (f / 1000)) if f >= 1000 else "%d" % f
            cv.put(cols["hz"], y, hz(lo) + "–" + hz(hi), p["text2"])
            a = round((math.log2(lo) - l0) / (l1 - l0) * (map_w - 1))
            b = round((math.log2(hi) - l0) / (l1 - l0) * (map_w - 1))
            cv.put(cols["map"], y, "┈" * map_w, p["grid"])
            for t in (math.log2(32), math.log2(250), math.log2(2000), math.log2(16000)):
                cv.put(cols["map"] + round((t - l0) / (l1 - l0) * (map_w - 1)), y, "┊", p["border"])
            cv.put(cols["map"] + a, y, "━" * (b - a + 1), p[name] if (is_char or selected) else fade(p[name], p["bg"], 0.45))
            bands = sorted(i for i, f in enumerate(BANDS) if lo < f * 2 ** 0.5 and hi > f / 2 ** 0.5)
            text = " ".join(SHORT[i] for i in bands) if len(bands) <= 4 else "%s … %s  (%d)" % (SHORT[bands[0]], SHORT[bands[-1]], len(bands))
            cv.put(cols["bands"], y, text, p["text2"] if selected else p["text3"])
            y += 1
    y = H - 6
    cv.box(bx, y, bw, 4, p["border"], "now", p["text2"])
    cell = (bw - 4) // 10
    for i in range(10):
        c = bx + 2 + i * cell + cell // 2
        db = st["out"][i]
        h = (db - FLOOR) / -FLOOR * 8
        cv.put(c - 2, y + 1, "▁▂▃▄▅▆▇█"[min(max(int(h) - 1, 0), 7)] * 5, gradient(stops, db))
        cv.put(c - len(LABELS[i]) // 2, y + 2, LABELS[i], p["text3"])
    keybar(cv, H - 1, [("↑↓", "move"), ("Enter", "focus in meter"), ("← →", "knob"), ("l", "listen"),
                       ("/", "filter"), ("y", "look")], p)
    return cv



HELP = [
    ("Tune", [("1 … 9 0", "raise band 32 Hz … 16 kHz by 0.5 dB"), ("⇧1 … ⇧0", "lower it by 0.5 dB"),
              ("+ -", "preamp ±0.5 dB"), ("b B t T", "bass / treble shelf ±0.5 dB"),
              ("p ↓ ↑", "next / previous preset"), ("c", "compressor off → gentle → night"),
              ("v V", "colour off → tape → tube / amount"), ("u", "undo this session's last change"),
              ("s", "save the curve as a preset")]),
    ("Instruments", [("z", "the instrument strip, on and off"), ("i", "the instrument table"),
                     ("] Tab [", "focus next / previous instrument"), ("→ ←", "the focused knob ±0.5 dB"),
                     ("l", "listen to the focused instrument alone"), ("Esc", "leave the focus")]),
    ("Look", [("y", "next look: studio → console → classic"), ("Y", "next palette of this look"),
              ("", "saved as tui.look and tui.palette")]),
    ("Screen", [("g + letter", "go to a view"), ("; Ctrl-P", "command palette"), ("m", "mouse on / off"),
                ("? h", "this list; ?, Esc or q closes it"), ("q Ctrl-C", "quit")]),
]


def studio_help(W, H, st, p, stops):
    cv = studio_meter(W, H, st, p, stops)
    cv.dim_all(p["bg"])
    for x in range(W):
        cv.cells[H - 1][x] = Cell()
        cv.cells[H - 2][x] = Cell()
    bw = min(W - 6, 112)
    bx = (W - bw) // 2
    by = 3
    bh = H - 6
    cv.fill(bx, by, bw, bh, p["surface"])
    for yy in range(by, by + bh):
        for xx in range(bx, bx + bw):
            cv.cells[yy][xx].ch = " "
            cv.cells[yy][xx].fg = None
    cv.box(bx, by, bw, bh, p["border_hi"], "keys", p["title"], right="/ filter", right_fg=p["text3"])
    colw = (bw - 6) // 2
    columns = [HELP[:2], HELP[2:]]
    for ci, groups in enumerate(columns):
        x = bx + 3 + ci * (colw + 2)
        y = by + 2
        for title, items in groups:
            cv.put(x, y, title, p["accent"], bold=True)
            cv.put(x + len(title) + 1, y, "─" * (colw - len(title) - 2), p["border"])
            y += 1
            for k, text in items:
                if k:
                    cv.put(x, y, " " + k + " ", p["key_fg"], p["key_bg"], bold=True)
                cv.put(x + 14, y, text[:colw - 15], p["text2"] if k else p["text3"])
                y += 1
            y += 1
    keybar(cv, H - 1, [("↑↓", "scroll"), ("/", "filter"), ("Esc", "close")], p)
    return cv



def studio_tune(W, H, st, p, stops):
    cv = Canvas(W, H)
    status_bar(cv, 0, st, p, "studio")
    tab_row(cv, 1, "Tune", p)
    sel = 5
    ch = 8
    cv.box(1, 2, W - 2, ch + 2, p["border"], "response", p["text2"], right="+12 … -12 dB", right_fg=p["text3"])
    cell = 8
    x0 = 8
    centres = [x0 + i * cell + 3 for i in range(10)]
    curve, ys = curve_cells(st["gains"], x0, cell * 10, 3, ch, centres)
    zero_row = 3 + round((ch * 4 - 1) / 2) // 4
    fb = C(mix(p["boost"], p["bg"], 0.8), "", None)
    fc = C(mix(p["cut"], p["bg"], 0.8), "", None)
    for cx in range(cell * 10):
        dy = (ys[cx * 2] + ys[cx * 2 + 1]) / 2
        crow = 3 + int(dy // 4)
        lo, hi = sorted((crow, zero_row))
        for r in range(lo, hi + 1):
            if r != crow:
                cv.fill(x0 + cx, r, 1, 1, fb if crow < zero_row else fc)
        cv.put(x0 + cx, zero_row, "┈", p["grid"])
    for (cx, cy), chh in curve.items():
        cv.put(cx, cy, chh, p["curve"])
    for i, g in enumerate(st["gains"]):
        r = 3 + ys[(centres[i] - x0) * 2] // 4
        cv.put(centres[i], r, "◉" if i == sel else "●", p["accent"] if i == sel else gain_ink(p, g), bold=i == sel)
    for g, lab in ((12, "+12"), (0, "  0"), (-12, "-12")):
        cv.put(3, 3 + round((12 - g) / 24 * (ch - 1)), lab, p["text3"])
    sy = 2 + ch + 3
    sh = H - sy - 7
    cv.box(1, sy - 1, 90, sh + 5, p["border"], "bands", p["text2"])
    for i in range(10):
        c = centres[i]
        g = st["gains"][i]
        if i == sel:
            cv.fill(c - 3, sy, 7, sh + 3, p["sel"])
        for k in range(sh):
            gv = 12 - k * 24 / (sh - 1)
            ink = p["border"]
            glyph = "│"
            if abs(gv) < 1e-6:
                glyph = "┼"
                ink = p["border_hi"]
            if (g > 0 and 0 < gv <= g) or (g < 0 and g <= gv < 0):
                glyph, ink = "┃", gain_ink(p, g)
            cv.put(c, sy + k, glyph, ink)
            for mark in (12, 6, 0, -6, -12):
                if i == 0 and k == round((12 - mark) / 24 * (sh - 1)):
                    cv.put(c - 5, sy + k, "%+3d" % mark if mark else "  0", p["text3"])
        cap = sy + round((12 - g) / 24 * (sh - 1))
        cv.put(c - 1, cap, "▐█▌", p["accent"] if i == sel else p["text"], bold=True)
        lab = LABELS[i]
        if i == sel:
            cv.put(c - len(lab) // 2 - 1, sy + sh, " " + lab + " ", p["on_chip"], p["accent"], bold=True, rev=True)
        else:
            cv.put(c - len(lab) // 2, sy + sh, lab, p["text2"])
        cv.put(c - 2, sy + sh + 1, "%5s" % fmt(g), gain_ink(p, g))
        db = st["out"][i]
        cv.put(c - 2, sy + sh + 2, "▁▂▃▄▅▆▇█"[min(max(int((db - FLOOR) / -FLOOR * 8) - 1, 0), 7)] * 5, gradient(stops, db))
    rx = 93
    cv.box(rx, sy - 1, W - rx - 1, sh + 5, p["border"], "chain", p["text2"])
    items = [("preamp", fmt(st["preamp"]), st["preamp"]), ("bass", fmt(st["bass"]), st["bass"]),
             ("treble", fmt(st["treble"]), st["treble"]), ("tilt", fmt(0), 0)]
    y = sy + 1
    for name, text, v in items:
        cv.put(rx + 2, y, name, p["text3"])
        bipolar(cv, rx + 10, y, 9, v, 12 if name == "preamp" else 6, p)
        cv.put(rx + 20, y, text, gain_ink(p, v))
        y += 2
    cv.put(rx + 2, y, "comp", p["text3"])
    cv.put(rx + 10, y, "‹ ", p["text3"])
    cv.put(rx + 12, y, st["comp"][0], p["accent"], bold=True)
    cv.put(rx + 18, y, " ›", p["text3"])
    y += 2
    cv.put(rx + 2, y, "colour", p["text3"])
    cv.put(rx + 10, y, "‹ ", p["text3"])
    cv.put(rx + 12, y, st["colour"][0], p["accent"], bold=True)
    cv.put(rx + 16, y, " › %g" % st["colour"][1], p["text3"])
    st2 = dict(st, message="1 kHz selected — ↑↓ 0.5 dB, ⇧↑↓ 3 dB, Enter types a value", message_kind=None)
    message_row(cv, H - 2, st2, p, x=2)
    keybar(cv, H - 1, [("← →", "select"), ("↑ ↓", "±0.5"), ("⇧↑↓", "±3"), ("Enter", "exact"), ("Del", "reset"),
                       ("u", "undo"), ("y", "look")], p)
    return cv



def console_meter(W, H, st, p):
    cv = Canvas(W, H)
    cv.fill(0, 0, W, H, p["surface"])
    focus = instrument(st["focus"]) if st["focus"] else None
    inside = touched_bands(focus) if focus else set(range(10))
    master_w = 30 if W >= 110 else 0
    strip_w = 8 if W - master_w - 6 >= 80 else 7
    sx0 = 5
    cv.fill(0, 0, W, 1, p["status"])
    x = 1
    for label, value, ink in (("DEVICE", st["device"], p["title"]), ("RATE", st["rate"] + "k", p["text"]),
                              ("PRESET", st["preset"] + ("*" if st["modified"] else ""), p["title"])):
        x = cv.put(x, 0, label + " ", p["text3"])
        x = cv.put(x, 0, value, ink, bold=True)
        x += 3
    if st["knobs"] and W >= 100:
        for n, v in st["knobs"].items():
            x = cv.put(x, 0, n.upper() + " ", p["text3"])
            x = cv.put(x, 0, fmt(v), gain_ink(p, v), bold=True)
            x += 3
    lamps = [("SOLO", st["solo"], p["solo"]), ("BYPASS", st["bypass"], p["warn"]), ("LIMIT", st["limiting"], p["danger"])]
    rx = W - sum(len(n) + 4 for n, _, _ in lamps)
    for n, on, ink in lamps:
        cv.put(rx, 0, "●", ink if on else p["lamp_off"])
        cv.put(rx + 2, 0, n, p["title"] if on else p["text3"], bold=on)
        rx += len(n) + 4
    if H >= 14:
        x = 1
        for t in TABS if W >= 100 else TABS[:6]:
            active = t == st["view"]
            label = " " + t.upper() + " "
            if active:
                x = cv.put(x, 1, label, p["on_chip"], p["accent"], bold=True, rev=True)
            else:
                x = cv.put(x, 1, label, p["text2"], p["chip"])
            x += 1
    top = 2 if H >= 14 else 1
    fader_rows = 9 if H >= 30 else 5
    zrows = 0
    zone_list = []
    if st["zones"]:
        zone_list = [focus] if focus else list(INSTRUMENTS)
        zrows = min(len(zone_list), max(H - 26, 1))
    led_rows = H - top - 1 - 1 - 1 - fader_rows - 1 - zrows - 2 - (1 if focus else 0)
    y_tape = top + (1 if focus else 0)
    y_led = y_tape + 1
    y_lcd = y_led + led_rows
    y_zone = y_lcd + 1
    y_fader = y_zone + zrows
    y_gain = y_fader + fader_rows
    centres = [sx0 + i * strip_w + strip_w // 2 for i in range(10)]
    if focus:
        draw_segments(cv, top, focus, centres, sx0, sx0 + strip_w * 10 - 2, p[focus[0]],
                      fade(p[focus[0]], p["surface"], 0.35), stroke="─", ends=("┌", "┐"), char_ink=p[focus[0]])
    for db in (0, -6, -18, -30, -42, -60):
        b = min(int((db - FLOOR) / -FLOOR * led_rows), led_rows - 1)
        cv.put(1, y_led + led_rows - 1 - b, "%3d" % db, p["text3"])
    for i in range(10):
        x = sx0 + i * strip_w
        outside = i not in inside
        cv.fill(x, top, strip_w - 1, H - top - 2, p["surface"])
        for yy in range(y_tape, y_gain + 1):
            cv.put(x + strip_w - 1, yy, "│", p["groove"])
        lab = " " + SHORT[i] + ("" if strip_w < 8 else " Hz"[:max(strip_w - 2 - len(SHORT[i]), 0)]) + " "
        lab = lab[:strip_w - 1].center(strip_w - 1)
        cv.put(x, y_tape, lab, p["tape_fg"], fade(p["tape_bg"], p["surface"], 0.55) if outside else p["tape_bg"],
               bold=True)
        lit_h = (st["out"][i] - FLOOR) / -FLOOR * led_rows
        pk = min(int((st["peaks"][i] - FLOOR) / -FLOOR * led_rows), led_rows - 1)
        lw = 3 if strip_w >= 7 else 2
        lx = x + (strip_w - 1 - lw) // 2
        for b in range(led_rows):
            db = FLOOR + (b + 0.5) / led_rows * -FLOOR
            on = b < round(lit_h) or b == pk
            ink = led(db, on and not outside) if not (on and outside) else C(mix(led(db, True), p["surface"], 0.6), "2", None)
            cv.put(lx, y_led + led_rows - 1 - b, "▆" * lw, ink)
        t = "%5.1f" % st["out"][i] if st["out"][i] > FLOOR else "  -∞ "
        cv.put(x + (strip_w - 1 - 5) // 2, y_lcd, t, p["lcd_fg"] if not outside else p["text3"], p["lcd_bg"])
        g = st["gains"][i]
        fc = x + (strip_w - 1) // 2
        for k in range(fader_rows):
            gv = 12 - k * 24 / (fader_rows - 1)
            ink = p["track"]
            glyph = "│"
            if abs(gv) < 1e-6:
                cv.put(fc - 2, y_fader + k, "╶─", p["text3"])
                cv.put(fc + 1, y_fader + k, "─╴", p["text3"])
            if (g > 0 and 0 <= gv <= g) or (g < 0 and g <= gv <= 0):
                glyph, ink = "┃", gain_ink(p, g)
            cv.put(fc, y_fader + k, glyph, ink)
        cap = y_fader + round((12 - g) / 24 * (fader_rows - 1))
        cap_ink = p["cap_sel"] if st["flash"] == i else (p["cap"] if not outside else p["track"])
        cv.put(fc - 2, cap, "▐███▌", cap_ink)
        t = fmt(g)
        cv.put(fc - len(t) // 2, y_gain, t, gain_ink(p, g) if not outside else p["text3"], bold=True)
    for k, inst in enumerate(zone_list[:zrows]):
        loud = max((st["out"][b] for b in touched_bands(inst)), default=FLOOR) > -20
        hue = p[inst[0]] if (loud or focus) else fade(p[inst[0]], p["surface"], 0.5)
        cv.put(1, y_zone + k, inst[1], hue, bold=bool(focus))
        draw_segments(cv, y_zone + k, inst, centres, sx0, sx0 + strip_w * 10 - 2, hue, p["text3"],
                      char_ink=p[inst[0]] if focus else None)
    if master_w:
        mx = W - master_w
        my = top
        cv.fill(mx - 1, top, master_w + 1, H - top - 2, p["surface"])
        cv.box(mx, my, master_w - 1, H - top - 2, p["border"], "MASTER", p["text2"])
        ix = mx + 2
        iw = master_w - 5
        wy = my + 2
        cv.fill(ix, wy, iw, 4, p["window_bg"])
        scale = [20, 10, 6, 3, 1, 0]
        for j, v in enumerate(scale):
            cv.put(ix + 1 + round(j * (iw - 3) / (len(scale) - 1)), wy, str(v), p["window_fg"])
        cv.put(ix + 1, wy + 1, "╷" + "┈" * (iw - 4) + "╷", p["window_fg"])
        mode, gr = st["comp"]
        pos = ix + 1 + round((1 - min(abs(gr), 20) / 20) ** 2 * (iw - 3))
        cv.put(pos, wy + 1, "┃", p["needle"], bold=True)
        cv.put(pos, wy + 2, "┃", p["needle"], bold=True)
        cv.put(ix + 1, wy + 3, "GR", p["window_fg"], bold=True)
        cv.put(ix + iw - 6, wy + 3, "%5.1f" % gr, p["needle"], bold=True)
        y = wy + 5
        cv.put(ix, y, "COMP", p["text3"])
        for j, m in enumerate(("off", "gentle", "night")):
            on = m == mode
            lx = ix + (5, 10, 18)[j]
            cv.put(lx, y, "●", p["accent"] if on else p["lamp_off"])
            cv.put(lx + 1, y, m, p["title"] if on else p["text3"], bold=on)
        y += 2
        cv.put(ix, y, "LIMIT", p["text3"])
        cv.put(ix + 6, y, "●", p["danger"] if st["limiting"] else p["lamp_off"])
        cv.put(ix + 12, y, "PEAK", p["text3"])
        cv.put(ix + 17, y, " %5.1f " % st["peak"], p["lcd_fg"], p["lcd_bg"])
        y += 2
        cv.put(ix, y, "PREAMP", p["text3"])
        tw = iw - 14
        pos = round((st["preamp"] + 12) / 24 * (tw - 1))
        cv.put(ix + 7, y, "─" * tw, p["track"])
        cv.put(ix + 7 + tw // 2, y, "┼", p["text3"])
        cv.put(ix + 7 + pos, y, "█", p["cap"])
        cv.put(ix + 8 + tw, y, "%5s" % fmt(st["preamp"]), gain_ink(p, st["preamp"]), bold=True)
        y += 2
        arrows = "↙←↖↑↗→↘"

        def knob(x, yy, label, v, span, hue=None, sel=False):
            k = arrows[round((max(min(v, span), -span) + span) / (2 * span) * 6)]
            cv.put(x, yy, " " + k + " ", p["title"] if v == 0 else gain_ink(p, v), p["chip_hi"] if sel else p["chip"], bold=True)
            cv.put(x + 4, yy, label, hue or p["text3"], bold=sel)
            cv.put(x, yy + 1, "%5s" % fmt(v), gain_ink(p, v))

        knob(ix, y, "BASS", st["bass"], 6)
        knob(ix + 9, y, "TREB", st["treble"], 6)
        knob(ix + 18, y, "TILT", st["tilt"], 6)
        y += 3
        cv.put(ix, y, "INSTRUMENT KNOBS", p["text3"])
        y += 1
        for j, inst in enumerate(INSTRUMENTS):
            name = inst[0]
            v = st["knobs"].get(name, 0.0)
            kx = ix + (j % 3) * 9
            ky = y + (j // 3) * 3
            if ky + 1 >= H - 3:
                break
            knob(kx, ky, inst[1].upper(), v, 12, hue=p[name], sel=st["focus"] == name)
        y += 9
        if y < H - 4:
            cv.put(ix, y, "COLOUR", p["text3"])
            kind, amount = st["colour"]
            cv.put(ix + 7, y, kind.upper(), p["accent"], bold=True)
            cv.put(ix + 13, y, "▆" * round(amount * 10), p["accent"])
            cv.put(ix + 13 + round(amount * 10), y, "▆" * (10 - round(amount * 10)), p["lamp_off"])
    message_row(cv, H - 2, st, p, x=1)
    keybar(cv, H - 1, FOCUS_KEYS if focus else METER_KEYS, p)
    return cv



def classic_meter(W, H, st, p):
    cv = Canvas(W, H)
    focus = instrument(st["focus"]) if st["focus"] else None
    inside = touched_bands(focus) if focus else set(range(10))
    cell = min(max((W - 2) // 10, 4), 8)
    bw = 3 if cell >= 7 else (2 if cell >= 5 else 1)
    tw = cell * 10
    zone_list = ([focus] if focus else list(INSTRUMENTS)) if st["zones"] else []
    zrows = min(len(zone_list), max(H - 11 - (1 if focus else 0), 0))
    indent = (W - tw) // 2 if not zone_list else max((W - tw) // 2, 9)
    bracket = 1 if focus and H >= 11 else 0
    M = max(4, H - 7 - zrows - bracket)
    head = "%s · %s kHz · preamp %s dB · %s%s · voice +3.0 · peak %s dB" % (
        st["device"], st["rate"], fmt(st["preamp"]), st["preset"], "*" if st["modified"] else "", fmt(st["peak"]))
    if focus:
        head = head.replace(" · peak -6.0 dB", " · focus: voice (85 Hz–9 kHz)")
    hx = max(indent + (tw - len(head)) // 2, 0)
    x = cv.put(hx, 0, st["device"], p["title"], bold=True)
    x = cv.put(x, 0, " · %s kHz · preamp " % st["rate"])
    x = cv.put(x, 0, fmt(st["preamp"]), gain_ink(p, st["preamp"]))
    x = cv.put(x, 0, " dB · ")
    x = cv.put(x, 0, st["preset"], p["accent"])
    x = cv.put(x, 0, "* · voice ", p["warn"] if False else None)
    x = cv.put(x, 0, "+3.0", p["boost"])
    if focus:
        x = cv.put(x, 0, " · focus: ")
        x = cv.put(x, 0, "voice", p["title"], bold=True)
        x = cv.put(x, 0, " (85 Hz–9 kHz)")
        if st["solo"]:
            cv.put(x + 1, 0, "SOLO", p["solo"])
    else:
        cv.put(x, 0, " · peak -6.0 dB")
    if H >= 14:
        x = indent
        for t in TABS[:6] if W < 100 else TABS:
            if t == st["view"]:
                x = cv.put(x, 1, t, p["title"], bold=True, ul=True, rev=True)
            else:
                x = cv.put(x, 1, t[0], p["accent"])
                x = cv.put(x, 1, t[1:], p["text3"])
            x += 2
    top = 2 if H >= 14 else 1
    centres = [indent + i * cell + cell - bw + (bw - 1) // 2 for i in range(10)]
    if bracket:
        draw_segments(cv, top, focus, centres, indent, indent + tw - 1, p["text3"], p["text3"], stroke="─",
                      ends=("┌", "┐"), char_ink=p["title"])
    body = top + bracket
    for i in range(10):
        g = st["gains"][i]
        bx = indent + i * cell + cell - bw
        outside = i not in inside
        hot = st["out"][i] >= -6
        ink = p["text3"] if outside else (gain_ink(p, g) if g != 0 else (None if hot else p["text3"]))
        mark = min(max(round((12 - g) / 24 * (M - 1)), 0), M - 1)
        out_h = (st["out"][i] - FLOOR) / -FLOOR * M
        in_h = (st["inp"][i] - FLOOR) / -FLOOR * M
        for r in range(M):
            b = M - 1 - r
            y = body + r
            if r == mark:
                cv.put(bx, y, "▬" * bw, p["text3"] if outside else gain_ink(p, g))
            elif b < int(out_h):
                cv.put(bx, y, "█" * bw, ink)
            elif b == int(out_h) and out_h % 1 > 0.12:
                cv.put(bx, y, "▁▂▃▄▅▆▇█"[int(out_h % 1 * 8)] * bw, ink)
            elif b < in_h:
                cv.put(bx, y, "░" * bw, p["text3"])
    y = body + M
    for inst in zone_list[:zrows]:
        cv.put(indent - 8, y, inst[0] if focus else inst[1], p["title"] if focus else p["text3"], bold=bool(focus))
        draw_segments(cv, y, inst, centres, indent, indent + tw - 1, None if focus else p["text3"], p["text3"])
        y += 1
    for i in range(10):
        c = indent + i * cell
        outside = i not in inside
        db = st["out"][i]
        cv.put(c + cell - len("%d" % db), y, "%d" % db, p["text3"] if outside or db < -6 else None)
        lab = LABELS[i] if cell >= 6 else SHORT[i]
        cv.put(c + cell - len(lab), y + 1, lab, p["text3"] if outside else None)
        g = st["gains"][i]
        cv.put(c + cell - len(fmt(g)), y + 2, fmt(g), p["text3"] if outside else gain_ink(p, g))
    message_row(cv, H - 2, st, p, x=0)
    keybar(cv, H - 1, FOCUS_KEYS if focus else METER_KEYS, p, keycaps=False)
    return cv



def focus_state():
    st = base_state()
    st.update(focus="voice", zones=True, solo=True, flash=5,
              message="listening to voice alone: 85 Hz–9 kHz — l again or Esc to stop", message_kind="warn")
    return st


def zones_state():
    st = base_state()
    st.update(zones=True, message="saved: band 1 kHz -3.0 dB", message_kind="ok", flash=5)
    return st


MOCKS = [
    # (file stem, look, palette, view, W, H, state)
    ("studio-meter-120x36", "studio", "ink", "meter", 120, 36, base_state),
    ("studio-meter-80x24", "studio", "ink", "meter", 80, 24, base_state),
    ("studio-zones-120x36", "studio", "ink", "meter", 120, 36, zones_state),
    ("studio-focus-120x36", "studio", "ink", "meter", 120, 36, focus_state),
    ("studio-focus-80x24", "studio", "ink", "meter", 80, 24, focus_state),
    ("studio-instruments-120x36", "studio", "ink", "instruments", 120, 36, base_state),
    ("studio-help-120x36", "studio", "ink", "help", 120, 36, base_state),
    ("studio-tune-120x36", "studio", "ink", "tune", 120, 36, base_state),
    ("studio-paper-meter-120x36", "studio", "paper", "meter", 120, 36, base_state),
    ("console-meter-120x36", "console", "brass", "meter", 120, 36, base_state),
    ("console-meter-80x24", "console", "brass", "meter", 80, 24, base_state),
    ("console-focus-120x36", "console", "brass", "meter", 120, 36, focus_state),
    ("console-zones-120x36", "console", "brass", "meter", 120, 36, zones_state),
    ("classic-meter-120x36", "classic", "terminal", "meter", 120, 36, base_state),
    ("classic-meter-80x24", "classic", "terminal", "meter", 80, 24, base_state),
    ("classic-focus-120x36", "classic", "terminal", "meter", 120, 36, focus_state),
]

PALETTES = {"ink": (INK, INK_METER), "paper": (PAPER, PAPER_METER), "brass": (BRASS, INK_METER),
            "terminal": (CLASSIC, INK_METER)}


def render(look, pal, view, W, H, st):
    p, stops = PALETTES[pal]
    if look == "studio":
        f = {"meter": studio_meter, "instruments": studio_instruments, "help": studio_help, "tune": studio_tune}[view]
        cv = f(W, H, st, p, stops)
        if pal == "paper":
            for row in cv.cells:
                for c in row:
                    if c.bg is None:
                        c.bg = p["bg"]
        return cv
    if look == "console":
        return console_meter(W, H, st, p)
    return classic_meter(W, H, st, p)


def default_fg(pal):
    return PALETTES[pal][0]["text"] if pal != "terminal" else None


def main():
    mocks = []
    for stem, look, pal, view, W, H, make in MOCKS:
        st = make()
        st["view"] = {"meter": "Meter", "instruments": "Instruments", "help": "Meter", "tune": "Tune"}[view]
        cv = render(look, pal, view, W, H, st)
        fg = default_fg(pal)
        depths = ["16", "mono"] if look == "classic" else ["tc", "16", "mono"]
        variants = {d: emit(cv, d, fg) for d in depths}
        (HERE / (stem + ".ans")).write_text(variants[depths[0]])
        mocks.append(dict(stem=stem, look=look, palette=pal, view=view, w=W, h=H, variants=variants,
                          bg="#f6f3ec" if pal == "paper" else None))
    for d in ("256", "16", "mono"):
        cv = render("studio", "ink", "meter", 120, 36, dict(base_state(), view="Meter"))
        (HERE / ("studio-meter-120x36-%s.ans" % d)).write_text(emit(cv, d, default_fg("ink")))
    template = (HERE / "preview.template.html").read_text()
    (HERE / "preview.html").write_text(template.replace("/*MOCKS*/[]", json.dumps(mocks, ensure_ascii=False)))
    print("wrote %d mocks" % len(mocks))
    if "--bytes" in sys.argv:
        byte_table()



def cup(y, x):
    return "\x1b[%d;%dH" % (y + 1, x + 1)


def frame_bytes(prev, cur, depth, fg, strategy):
    """Bytes a diff renderer writes to turn `prev` into `cur`.

    naive: every changed cell is a cursor move, a full reset + SGR and the glyph.
    runs: a cursor move per run of changed cells, the pen carried across the frame.
    runs+: runs, and within a row the gap to the next run is either rewritten or skipped with
    a relative move (CUF), whichever is fewer bytes.
    """
    out = []
    pen = EMPTY
    for y in range(cur.h):
        prow, crow = prev.cells[y] if prev else None, cur.cells[y]
        keys = [(c.ch, sgr_state(c, depth, fg)) for c in crow]
        pkeys = [(c.ch, sgr_state(c, depth, fg)) for c in prow] if prev else None
        changed = [pkeys is None or keys[x] != pkeys[x] for x in range(cur.w)]
        x = 0
        cursor = None
        while x < cur.w:
            if not changed[x]:
                x += 1
                continue
            if strategy == "naive":
                ch, st = keys[x]
                out.append(cup(y, x) + transition(EMPTY, st).replace("\x1b[", "\x1b[0;", 1) if st != EMPTY else cup(y, x) + "\x1b[0m")
                out.append(ch)
                x += 1
                continue
            if cursor is not None and cursor[0] == y and strategy == "runs+":
                gap = x - cursor[1]
                fill, fpen = "", pen
                for gx in range(cursor[1], x):
                    ch, st = keys[gx]
                    fill += transition(fpen, st) + ch
                    fpen = st
                move = "\x1b[%dC" % gap
                if len(fill.encode()) < len(move):
                    out.append(fill)
                    pen = fpen
                else:
                    out.append(move)
            else:
                out.append(cup(y, x))
            while x < cur.w and changed[x]:
                ch, st = keys[x]
                out.append(transition(pen, st) + ch)
                pen = st
                x += 1
            cursor = (y, x)
    body = "".join(out)
    return len(("\x1b[?2026h" + body + "\x1b[0m\x1b[?2026l").encode())


def simulate(look, pal, depth, W, H, frames=300, stress=False, seed=7):
    rng = random.Random(seed)
    st = base_state()
    base = [-10, -8, -12, -16, -20, -18, -23, -27, -30, -38]
    shown = list(st["out"])
    peaks = list(st["peaks"])
    held = [0] * 10
    prev = None
    fg = default_fg(pal)
    totals = {"naive": 0, "runs": 0, "runs+": 0}
    first = None
    for n in range(frames + 1):
        for i in range(10):
            if stress:
                target = rng.uniform(-60, -1)
                shown[i] = target
            else:
                beat = 6 * max(0.0, math.sin(n / 30 * 2 * math.pi * 2)) ** 4 if i < 3 else 0
                target = base[i] + beat + rng.gauss(0, 3)
                shown[i] = target if target > shown[i] else max(target, shown[i] - 20 / 30 * 3)
            if shown[i] >= peaks[i]:
                peaks[i], held[i] = shown[i], 45
            elif held[i] > 0:
                held[i] -= 1
            else:
                peaks[i] -= 11.8 / 30
        st["out"] = [max(v, FLOOR) for v in shown]
        st["inp"] = [min(v + 1.5, -0.5) for v in st["out"]]
        st["peaks"] = list(peaks)
        st["peak"] = round(max(st["out"]), 1)
        cv = render(look, pal, "meter", W, H, st)
        if prev is None:
            first = frame_bytes(None, cv, depth, fg, "runs")
        else:
            for s in totals:
                totals[s] += frame_bytes(prev, cv, depth, fg, s)
        prev = cv
    return first, {s: v // frames for s, v in totals.items()}


def byte_table():
    global SOLID_AS_BACKGROUND
    rows = []
    SOLID_AS_BACKGROUND = False
    for stress in (False, True):
        first, per = simulate("studio", "ink", "tc", 120, 40, frames=150, stress=stress)
        rows.append(("studio, █ bars", "tc", "stress" if stress else "music", first, per["naive"], per["runs"], per["runs+"]))
    SOLID_AS_BACKGROUND = True
    for look, pal, depth in (("classic", "terminal", "16"), ("studio", "ink", "16"), ("studio", "ink", "256"),
                             ("studio", "ink", "tc"), ("console", "brass", "tc")):
        for stress in (False, True):
            first, per = simulate(look, pal, depth, 120, 40, frames=150, stress=stress)
            rows.append((look, depth, "stress" if stress else "music", first, per["naive"], per["runs"], per["runs+"]))
    print("| look | depth | motion | full frame | naive diff | runs | runs + gap fill |")
    print("| --- | --- | --- | --- | --- | --- | --- |")
    for r in rows:
        print("| %s | %s | %s | %d | %d | %d | %d |" % r)


if __name__ == "__main__":
    main()
