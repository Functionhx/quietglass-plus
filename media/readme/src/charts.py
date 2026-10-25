#!/usr/bin/env python3
"""Generates the README's SVG charts (dark and light): measured power and a replay
of real Sony WF-1000XM6 head-tracking data. Run from the repository root."""
import math, os

OUT = os.path.join(os.path.dirname(__file__), "..")
FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"
MONO = "ui-monospace, SFMono-Regular, Menlo, monospace"
THEMES = {
    "dark": dict(bg="#0d1117", ink="#e6edf3", muted="#8b949e", grid="#21262d", before="#30363d", a="#a78bfa", b="#f0aee8", c="#7dd3fc", band="#f0aee8"),
    "light": dict(bg="#ffffff", ink="#1f2328", muted="#59636e", grid="#eaeef2", before="#d0d7de", a="#7c5cff", b="#c04fb6", c="#1f9bd6", band="#c04fb6"),
}

# Measured on a MacBook Air (M4); see README.
POWER = [
    ("Camera sensor rate", "fps", 30, 15),
    ("cameracaptured CPU", "%", 21, 10),
    ("SFace embedding", "ms", 4.5, 0.85),
    ("Screen recording while monitoring", "fps", 30, 0),
    ("App CPU while head tracking", "%", 29, 1),
]

def power(theme):
    t = THEMES[theme]
    w, row, top, left, barw = 880, 62, 56, 300, 390
    h = top + row * len(POWER) + 20
    s = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" font-family="{FONT}">',
         f'<defs><linearGradient id="g" x1="0" x2="1"><stop offset="0" stop-color="{t["a"]}"/><stop offset="1" stop-color="{t["b"]}"/></linearGradient></defs>',
         f'<rect width="{w}" height="{h}" rx="14" fill="{t["bg"]}"/>',
         f'<rect x="{left}" y="20" width="12" height="8" rx="4" fill="{t["before"]}"/><text x="{left+18}" y="28" font-size="13" fill="{t["muted"]}">QuietGlass 0.1.2</text>',
         f'<rect x="{left+150}" y="20" width="12" height="8" rx="4" fill="url(#g)"/><text x="{left+168}" y="28" font-size="13" fill="{t["muted"]}">QuietGlass Plus</text>']
    for i, (label, unit, before, after) in enumerate(POWER):
        y = top + i * row
        scale = barw / max(before, after)
        fmt = (lambda v: f"{v:g}")
        s.append(f'<line x1="24" x2="{w-24}" y1="{y+row-8}" y2="{y+row-8}" stroke="{t["grid"]}"/>')
        s.append(f'<text x="24" y="{y+26}" font-size="15" font-weight="600" fill="{t["ink"]}">{label}</text>')
        s.append(f'<rect x="{left}" y="{y+10}" width="{max(3, before*scale):.1f}" height="11" rx="5.5" fill="{t["before"]}"/>')
        s.append(f'<rect x="{left}" y="{y+27}" width="{max(3, after*scale):.1f}" height="11" rx="5.5" fill="url(#g)"/>')
        s.append(f'<text x="{w-24}" y="{y+30}" font-size="14" font-family="{MONO}" text-anchor="end" fill="{t["muted"]}">{fmt(before)} → <tspan fill="{t["b"]}" font-weight="700">{fmt(after)}</tspan> {unit}</text>')
    s.append("</svg>")
    return "\n".join(s)

# [seconds, yaw°, pitch°] from `QuietGlass --headphone-check` after the 12 s warm-up,
# re-centered on the resting pose: a right turn, then looking down at the keyboard.
REPLAY = [(0,0,0),(.5,-.1,.5),(1,0,.2),(2,0,0),(3,0,0),(3.7,-.6,1),(4.2,-.4,.4),(4.7,-40.8,-9.5),(5.3,-50.3,-4.5),(5.8,-49.5,-3.5),
          (6.3,-57.8,.9),(6.8,-52.2,1.8),(7.3,-52.2,1.2),(7.9,-52.9,1.4),(8.4,-53.6,.5),(8.9,-53.3,.3),(9.4,-52.9,.6),(10,1.2,-7.3),
          (10.5,-.4,-5.5),(11.1,-2.5,-6),(12.1,-2.3,-6.1),(13.1,-1.3,-3.5),(13.7,-.5,-2.9),(14.7,-.5,-2.8),(15.2,-.5,-16.7),(15.8,1.9,-20.1),
          (16.3,4.2,-20.3),(16.8,4.6,-20.2),(17.4,1.9,-19),(17.9,1.1,-18.5),(18.4,-3,-18.8),(18.9,-2.4,-18.3),(19.4,.4,-17.1),(20,1.8,-17.6),
          (20.5,-1.6,-2.4),(21,-.9,.9),(22,-.9,.5),(23.6,-.3,-.2),(25,0,0)]

def earbuds(theme):
    t = THEMES[theme]
    w, h, l, r, top, bottom = 880, 320, 64, 24, 44, 40
    pw, ph = w - l - r, h - top - bottom
    T = REPLAY[-1][0]
    X = lambda s: l + s / T * pw
    Y = lambda d: top + (65 - d) / 130 * ph          # -65..65 degrees
    s = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" font-family="{FONT}">',
         f'<rect width="{w}" height="{h}" rx="14" fill="{t["bg"]}"/>']
    # covered spans (total rotation past 15°, cleared under 12°)
    covered, start = False, None
    spans = []
    for sec, yaw, pitch in REPLAY:
        angle = math.hypot(yaw, pitch)
        if not covered and angle > 15: covered, start = True, sec
        elif covered and angle < 12: covered = False; spans.append((start, sec))
    for a, b in spans:
        s.append(f'<rect x="{X(a):.1f}" y="{top}" width="{X(b)-X(a):.1f}" height="{ph}" fill="{t["band"]}" opacity=".12"/>')
        s.append(f'<text x="{(X(a)+X(b))/2:.1f}" y="{top+16}" font-size="12" text-anchor="middle" fill="{t["b"]}" font-weight="600">screen covered</text>')
    s.append(f'<rect x="{l}" y="{Y(15):.1f}" width="{pw}" height="{Y(-15)-Y(15):.1f}" fill="{t["grid"]}" opacity=".9"/>')
    for d in (-60, -30, 0, 30, 60):
        s.append(f'<line x1="{l}" x2="{w-r}" y1="{Y(d):.1f}" y2="{Y(d):.1f}" stroke="{t["grid"]}"/>')
        s.append(f'<text x="{l-10}" y="{Y(d)+4:.1f}" font-size="12" text-anchor="end" fill="{t["muted"]}" font-family="{MONO}">{d:+d}°</text>')
    s.append(f'<text x="{l+8}" y="{Y(15)+16:.1f}" font-size="12" fill="{t["muted"]}">±15° comfort range</text>')
    for sec in range(0, int(T) + 1, 5):
        s.append(f'<text x="{X(sec):.1f}" y="{h-18}" font-size="12" text-anchor="middle" fill="{t["muted"]}" font-family="{MONO}">{sec} s</text>')
    for idx, color, name in ((1, t["a"], "yaw"), (2, t["c"], "pitch")):
        pts = " ".join(f"{X(p[0]):.1f},{Y(p[idx]):.1f}" for p in REPLAY)
        s.append(f'<polyline points="{pts}" fill="none" stroke="{color}" stroke-width="2.5" stroke-linejoin="round" stroke-linecap="round"/>')
    s.append(f'<circle cx="{w-190}" cy="22" r="5" fill="{t["a"]}"/><text x="{w-180}" y="26" font-size="13" fill="{t["muted"]}">yaw (turn)</text>')
    s.append(f'<circle cx="{w-92}" cy="22" r="5" fill="{t["c"]}"/><text x="{w-82}" y="26" font-size="13" fill="{t["muted"]}">pitch (nod)</text>')
    s.append(f'<text x="{l}" y="26" font-size="13" font-weight="600" fill="{t["ink"]}">Sony WF-1000XM6 · 25 Hz · real data</text>')
    s.append("</svg>")
    return "\n".join(s)

for theme in THEMES:
    with open(os.path.join(OUT, f"power-{theme}.svg"), "w") as f: f.write(power(theme))
    with open(os.path.join(OUT, f"earbuds-{theme}.svg"), "w") as f: f.write(earbuds(theme))
print("charts written")
