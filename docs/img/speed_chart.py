#!/usr/bin/env python3
# speed_chart.py: writes README's chart of BendKV's speed against Redis 8.10.2,
# speed-light.svg and speed-dark.svg beside it, from the yardstick of
# docs/PERFORMANCE.md, section 94: each command's requests a second on one
# core, BendKV's as a share of Redis 8.10.2's, with a pipeline of 16 and
# without one. The numbers are copied from that section; when it is measured
# again, change them here and rerun:
#
#   python3 docs/img/speed_chart.py
import os

# command, BendKV / Redis 8.10.2 with a pipeline of 16, and without one
RATIOS = [
    ("SET", 1.40, 1.17),
    ("GET", 1.47, 1.23),
    ("INCR", 1.11, 1.08),
    ("LPUSH", 0.65, 1.12),
    ("LPOP", 0.86, 1.15),
    ("SADD", 0.58, 1.17),
    ("HSET", 0.49, 1.04),
    ("ZADD", 0.38, 0.56),
    ("XADD", 0.12, 0.39),
]

THEMES = {
    # halo: the page behind the chart (GitHub's light and dark), around a
    # value's label so that the line at 1 does not cross it
    "light": {"text": "#0b0b0b", "text2": "#52514e", "muted": "#898781",
              "grid": "#e1e0d9", "bar": "#2a78d6", "halo": "#ffffff"},
    "dark": {"text": "#f0efec", "text2": "#c3c2b7", "muted": "#898781",
             "grid": "#2c2c2a", "bar": "#3987e5", "halo": "#0d1117"},
}

FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"
LABELS = 56          # the commands' column
PLOT = 300           # a panel's plot, 0 to TOP
TOP = 1.6
ROOM = 34            # past the plot, for the last value
GAP = 34             # between the panels
ROW = 28
BAR = 16
Y0 = 96              # the first row's top
W = LABELS + 2 * (PLOT + ROOM) + GAP
H = Y0 + ROW * len(RATIOS) + 40


def bar(x, y, w, h, r):
    # a bar from the baseline x, its data end rounded
    r = min(r, w, h / 2)
    return (f"M{x:.1f},{y:.1f}h{w - r:.1f}a{r},{r} 0 0 1 {r},{r}v{h - 2 * r:.1f}"
            f"a{r},{r} 0 0 1 {-r},{r}h{-(w - r):.1f}z")


def panel(c, x0, title, col):
    sx = PLOT / TOP
    out = [f'<text x="{x0}" y="{Y0 - 22}" font-size="13" font-weight="600" fill="{c["text"]}">{title}</text>']
    y1 = Y0 + ROW * len(RATIOS)
    for t in (0.5, 1.5):
        x = x0 + t * sx
        out.append(f'<line x1="{x:.1f}" y1="{Y0 - 4}" x2="{x:.1f}" y2="{y1}" stroke="{c["grid"]}" stroke-width="1"/>')
    for t in (0, 0.5, 1, 1.5):
        x = x0 + t * sx
        out.append(f'<text x="{x:.1f}" y="{y1 + 16}" font-size="11" text-anchor="middle" fill="{c["muted"]}">{t:g}</text>')
    out.append(f'<line x1="{x0}" y1="{Y0 - 4}" x2="{x0}" y2="{y1}" stroke="{c["muted"]}" stroke-width="1"/>')
    labels = []
    for i, row in enumerate(RATIOS):
        v = row[col]
        y = Y0 + i * ROW + (ROW - BAR) / 2
        out.append(f'<path d="{bar(x0, y, v * sx, BAR, 4)}" fill="{c["bar"]}"><title>{row[0]}: {v:.2f}</title></path>')
        labels.append(f'<text x="{x0 + v * sx + 5:.1f}" y="{y + BAR - 4}" font-size="11" fill="{c["text2"]}" '
                      f'stroke="{c["halo"]}" stroke-width="3" stroke-linejoin="round" paint-order="stroke">{v:.2f}</text>')
    x = x0 + sx
    out.append(f'<line x1="{x:.1f}" y1="{Y0 - 8}" x2="{x:.1f}" y2="{y1}" stroke="{c["text2"]}" stroke-width="1.5" stroke-dasharray="4 3"/>')
    out.append(f'<text x="{x:.1f}" y="{Y0 - 11}" font-size="11" text-anchor="middle" fill="{c["text2"]}">Redis 8.10.2 = 1</text>')
    return out + labels


def svg(c):
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="{FONT}">',
           "<title>BendKV's requests a second, as a share of Redis 8.10.2's</title>",
           "<desc>One core each, redis-benchmark with 20 clients and 100,000 keys; docs/PERFORMANCE.md, section 94.</desc>",
           f'<text x="0" y="20" font-size="15" font-weight="600" fill="{c["text"]}">BendKV\'s requests a second, Redis 8.10.2 = 1</text>',
           f'<text x="0" y="40" font-size="12" fill="{c["text2"]}">one core each, redis-benchmark with 20 clients and 100,000 keys</text>']
    for i, row in enumerate(RATIOS):
        y = Y0 + i * ROW + ROW / 2 + 4
        out.append(f'<text x="{LABELS - 10}" y="{y}" font-size="12" text-anchor="end" fill="{c["text"]}">{row[0]}</text>')
    out += panel(c, LABELS, "Pipeline of 16", 1)
    out += panel(c, LABELS + PLOT + ROOM + GAP, "No pipeline", 2)
    out.append("</svg>")
    return "\n".join(out) + "\n"


def main():
    d = os.path.dirname(os.path.abspath(__file__))
    for name, c in THEMES.items():
        with open(os.path.join(d, f"speed-{name}.svg"), "w") as f:
            f.write(svg(c))


if __name__ == "__main__":
    main()
