"""The Harvest Rush entity glyphs, in one place.

These were defined inside make_fig_game.py, which draws the game map. The
results figures want the same shapes so a reader who has seen the map
recognises them without a key, and two copies of a drawing routine drift.
So they live here and both scripts import them.

Two ways to use a glyph:

    quadruped(ax, x, y, s=1.0, c="#b3324b", d=-1)
        draw straight onto an axes, in DATA coordinates. Only sensible
        where the axes has equal aspect, i.e. the game map.

    glyph_image("animal", colour)
        render to a transparent RGBA array for use as a marker via
        OffsetImage/AnnotationBbox. Use this on the results figures, where
        x is a percentage and y is a row index: drawing in data coordinates
        there would stretch the animal across a quarter of the chart.

`d` is the vertical direction. The map axes runs y downward, so it passes
d=1; anywhere y grows upward (legends, the results figures) pass d=-1 or
the animal comes out on its back.
"""

import numpy as np
from matplotlib.figure import Figure
from matplotlib.backends.backend_agg import FigureCanvasAgg
from matplotlib.patches import Arc, Circle, Ellipse, Polygon

C_ANIMAL = "#b3324b"
C_HAY = "#d5ad33"
C_HAY_EDGE = "#a8821f"
C_ROCK = "#8f8f8f"


def quadruped(ax, cx, cy, s=1.0, c=C_ANIMAL, z=6, d=1):
    """Fleecy livestock silhouette, legible at one tile."""
    for dx in (-0.17, -0.06, 0.06, 0.16):          # legs behind the body
        ax.plot([cx + dx * s, cx + dx * s],
                [cy + d * 0.04 * s, cy + d * 0.26 * s],
                color=c, lw=1.0, solid_capstyle="butt", zorder=z)
    ax.add_patch(Ellipse((cx, cy + d * 0.01 * s), 0.50 * s, 0.30 * s, fc=c,
                         ec="none", zorder=z + 1))
    for dx, dy, r in ((-0.20, -0.06, 0.11), (-0.08, -0.12, 0.12),
                      (0.05, -0.12, 0.12), (0.18, -0.05, 0.10)):
        ax.add_patch(Circle((cx + dx * s, cy + d * dy * s), r * s, fc=c,
                            ec="none", zorder=z + 1))
    ax.add_patch(Ellipse((cx + 0.30 * s, cy + d * (-0.11 * s)), 0.20 * s,
                         0.15 * s, fc=c, ec="none", zorder=z + 2,
                         angle=-20 * d))
    ax.add_patch(Ellipse((cx + 0.24 * s, cy + d * (-0.19 * s)), 0.10 * s,
                         0.06 * s, fc=c, ec="none", zorder=z + 2, angle=25 * d))
    ax.plot([cx - 0.25 * s, cx - 0.33 * s],
            [cy + d * (-0.02 * s), cy + d * (-0.10 * s)],
            color=c, lw=0.8, solid_capstyle="round", zorder=z + 1)


def bird(ax, cx, cy, s=1.0, c=C_ANIMAL, z=6, d=1):
    ax.add_patch(Ellipse((cx, cy + d * 0.02 * s), 0.34 * s, 0.25 * s, fc=c,
                         ec="none", zorder=z))
    ax.add_patch(Circle((cx + 0.16 * s, cy + d * (-0.14 * s)), 0.09 * s, fc=c,
                        ec="none", zorder=z))
    ax.add_patch(Polygon([[cx + 0.24 * s, cy + d * (-0.16 * s)],
                          [cx + 0.34 * s, cy + d * (-0.12 * s)],
                          [cx + 0.24 * s, cy + d * (-0.09 * s)]], closed=True,
                         fc=c, ec="none", zorder=z))
    ax.add_patch(Polygon([[cx - 0.16 * s, cy + d * (-0.02 * s)],
                          [cx - 0.30 * s, cy + d * (-0.14 * s)],
                          [cx - 0.14 * s, cy + d * 0.06 * s]], closed=True,
                         fc=c, ec="none", zorder=z))
    for dx in (-0.04, 0.06):
        ax.plot([cx + dx * s, cx + dx * s],
                [cy + d * 0.12 * s, cy + d * 0.22 * s],
                color=c, lw=0.6, solid_capstyle="round", zorder=z)


def hay(ax, cx, cy, s=1.0, z=6, d=1, c=C_HAY, ec=C_HAY_EDGE):
    ax.add_patch(Circle((cx, cy), 0.28 * s, fc=c, ec=ec, lw=0.5, zorder=z))
    for r in (0.18, 0.09):
        ax.add_patch(Arc((cx, cy), 2 * r * s, 2 * r * s, angle=0, theta1=200,
                         theta2=70, color=ec, lw=0.45, zorder=z + 1))


def rock(ax, cx, cy, s=1.0, z=6, d=1):
    pts = np.array([[-0.30, 0.10], [-0.20, -0.18], [0.04, -0.28],
                    [0.26, -0.12], [0.30, 0.12], [0.10, 0.26], [-0.16, 0.24]])
    pts = pts * [1, d]
    ax.add_patch(Polygon(pts * s + [cx, cy], closed=True, fc=C_ROCK,
                         ec="#6b6b6b", lw=0.5, zorder=z))
    ax.add_patch(Polygon((pts[:4] * 0.5) * s + [cx - 0.05 * s, cy + d * (-0.02 * s)],
                         closed=True, fc="#a5a5a5", ec="none", zorder=z + 1))


def glyph_image(kind, colour=None, px=220):
    """A glyph as a transparent RGBA array, for OffsetImage.

    Built on its own Figure/canvas rather than pyplot so that importing
    this module cannot disturb the caller's rcParams or figure manager.
    """
    fig = Figure(figsize=(1, 1), dpi=px)
    FigureCanvasAgg(fig)
    fig.patch.set_alpha(0)
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_axis_off()
    ax.patch.set_alpha(0)
    ax.set_xlim(-0.5, 0.5)
    ax.set_ylim(-0.5, 0.5)          # y upward, so the glyphs take d=-1
    ax.set_aspect("equal")
    if kind == "animal":
        quadruped(ax, 0.0, 0.02, s=1.0, c=colour or C_ANIMAL, d=-1)
    elif kind == "hay":
        hay(ax, 0.0, 0.0, s=1.28, d=-1,
            c=colour or C_HAY, ec=colour or C_HAY_EDGE)
    elif kind == "rock":
        rock(ax, 0.0, 0.0, s=1.2, d=-1)
    else:
        raise ValueError(f"unknown glyph {kind!r}")
    fig.canvas.draw()
    return np.asarray(fig.canvas.buffer_rgba()).copy()
