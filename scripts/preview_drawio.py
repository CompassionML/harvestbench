"""Render a (simple) .drawio file to PNG so the layout can be checked.

Only understands the subset of styles used by make_game_diagram.py:
rect / rounded / ellipse / rhombus / text vertices and straight edges.
This is a proofing tool, not a general draw.io renderer.
"""

import html
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Ellipse, FancyBboxPatch, Polygon, Rectangle

SRC = Path(sys.argv[1])
DST = Path(sys.argv[2])


def sval(style, key, default=None):
    m = re.search(rf"(?:^|;){key}=([^;]*)", style or "")
    return m.group(1) if m else default


def label_of(cell):
    v = cell.get("value") or ""
    v = re.sub(r"<br\s*/?>", "\n", v, flags=re.I)
    v = re.sub(r"<[^>]+>", "", v)
    return html.unescape(v).strip()


def main():
    root = ET.parse(SRC).getroot()
    verts, edges = [], []
    for c in root.iter("mxCell"):
        g = c.find("mxGeometry")
        if g is None:
            continue
        st = c.get("style") or ""
        if c.get("edge"):
            pts = {p.get("as"): (float(p.get("x", 0)), float(p.get("y", 0)))
                   for p in g.iter("mxPoint")}
            if "sourcePoint" in pts and "targetPoint" in pts:
                edges.append((pts["sourcePoint"], pts["targetPoint"], st))
        elif g.get("x") is not None:
            verts.append((float(g.get("x")), float(g.get("y")),
                          float(g.get("width", 0)), float(g.get("height", 0)),
                          st, label_of(c)))

    W = max(x + w for x, y, w, h, s, l in verts) + 40
    H = max(y + h for x, y, w, h, s, l in verts) + 40
    fig, ax = plt.subplots(figsize=(W / 100, H / 100), dpi=100)
    ax.set_xlim(0, W)
    ax.set_ylim(H, 0)          # draw.io y grows downward
    ax.axis("off")
    fig.patch.set_facecolor("white")

    for x, y, w, h, st, lab in verts:
        fill = sval(st, "fillColor", "none")
        stroke = sval(st, "strokeColor", "none")
        op = float(sval(st, "fillOpacity", "100")) / 100.0
        fc = "none" if fill in ("none", None) else fill
        ec = "none" if stroke in ("none", None) else stroke
        lw = float(sval(st, "strokeWidth", "1"))
        common = dict(facecolor=fc, edgecolor=ec, linewidth=lw, alpha=op,
                      zorder=2)
        if st.startswith("text;") or "text;html" in st:
            pass
        elif "ellipse" in st:
            ax.add_patch(Ellipse((x + w / 2, y + h / 2), w, h, **common))
        elif "rhombus" in st:
            ax.add_patch(Polygon([(x + w / 2, y), (x + w, y + h / 2),
                                  (x + w / 2, y + h), (x, y + h / 2)],
                                 closed=True, **common))
        elif "rounded=1" in st:
            ax.add_patch(FancyBboxPatch((x + 4, y + 4), max(w - 8, 1),
                                        max(h - 8, 1),
                                        boxstyle="round,pad=4", **common))
        else:
            ax.add_patch(Rectangle((x, y), w, h, **common))

        if lab:
            fs = float(sval(st, "fontSize", "12")) * 0.78
            col = sval(st, "fontColor", "#000000")
            bold = sval(st, "fontStyle", "0") in ("1", "3")
            align = sval(st, "align", "center")
            ha = {"left": "left", "center": "center", "right": "right"}[align]
            tx = x + (6 if ha == "left" else (w / 2 if ha == "center" else w - 6))
            ax.text(tx, y + h / 2, lab, fontsize=fs, color=col, ha=ha,
                    va="center", zorder=5,
                    fontweight="bold" if bold else "normal",
                    linespacing=1.35)

    for (x1, y1), (x2, y2), st in edges:
        col = sval(st, "strokeColor", "#000000")
        lw = float(sval(st, "strokeWidth", "1"))
        ls = "--" if "dashed=1" in st else "-"
        arrow = "block" in (sval(st, "endArrow", "") or "")
        ax.annotate("", xy=(x2, y2), xytext=(x1, y1), zorder=4,
                    arrowprops=dict(arrowstyle="-|>" if arrow else "-",
                                    color=col, lw=lw, linestyle=ls,
                                    shrinkA=0, shrinkB=0))

    fig.savefig(DST, dpi=100, bbox_inches="tight", pad_inches=0.1)
    print(f"{DST}  ({len(verts)} vertices, {len(edges)} edges, canvas {W:.0f}x{H:.0f})")


if __name__ == "__main__":
    main()
