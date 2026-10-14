"""Workspace panorama: one image of a whole niri workspace strip — every
column side by side, as if the display were as wide as the strip.

niri lays a workspace out as columns on an endless horizontal strip, and the
display only ever shows a window onto it. This visits the columns through
niri's IPC (no synthetic input): for each column it runs `focus-column N` +
`center-column`, waits for the view to settle, grabs the output with grim,
and crops that column's tiles. The tiles are then composited at their strip
positions on a background — the wallpaper scaled to cover the whole
panorama (like the wallpaper layer covers a display; it doesn't scroll with
the windows, so the screen's own background can't be reused) or a plain
backdrop. Afterwards the original focus and, where it can be reproduced,
the view position come back.

What niri 26.04 tells a client (`niri msg -j windows`, `workspaces`,
`outputs`): per window `layout.pos_in_scrolling_layout` (column, tile; 1-based),
`tile_size`, `window_size`, `window_offset_in_tile`, and
`tile_pos_in_workspace_view` — but only for floating windows. Where a tiled
window is on screen isn't reported, nor is the view offset, the working area
(the output minus layer-shell exclusive zones minus `layout.struts`), the
gaps or a column's display mode (normal / tabbed). So positions come from
niri's own layout rules (niri src/layout/scrolling.rs):

  * a column is as wide as its widest tile; column x on the strip =
    Σ (width + gaps) of the columns left of it;
  * `center-column` puts the column at working.x + (working.w - width) / 2,
    a column at least as wide as the working area at working.x, a
    maximized one (maximize-window-to-edges) at the output minus exclusive
    zones, a fullscreen one at 0, 0;
  * tiles start at working.y + gaps and stack with gaps between them; in a
    tabbed column they all sit at the top and only the active one shows.

Gaps, struts and center-focused-column come from `loft-niri --json show`
(the effective niri config + Loft's overrides); the exclusive zones from
the caller (`--insets`: the shell knows its bar and dock). A tabbed column
is recognised by its tiles not fitting the working area's height stacked;
the active tab (the focused window once the column is focused) is captured
and the result notes it. Floating windows aren't part of the strip — they
float over the view — so they are left out (and a column they cover is
noted). An empty workspace is an error; a strip wider than MAX_WIDTH keeps
the columns that fit and notes the rest.
"""

from __future__ import annotations

import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

from . import stitch
from .stitch import Image

MAX_WIDTH = 40000  # px: the same cap as scrolling capture
SETTLE_FIRST = 0.15  # s after an action before the first look
SETTLE_STEP = 0.08  # s between looks while the view moves
SETTLE_MAX = 2.5  # s: give up waiting (an animated window never settles)
SAME_ROWS = 0.97  # sampled rows unchanged between two looks: settled


# ── Layout ──────────────────────────────────────────────────────────────


@dataclass
class Params:
    gaps: float = 16.0
    # niri `layout { struts { … } }`
    struts: tuple[float, float, float, float] = (0.0, 0.0, 0.0, 0.0)  # left, right, top, bottom
    # layer-shell exclusive zones on the output (the shell's bar / dock)
    insets: tuple[float, float, float, float] = (0.0, 0.0, 0.0, 0.0)  # left, right, top, bottom
    center: str = "never"  # center-focused-column
    radius: float = 0.0  # window corner radius (geometry-corner-radius)


@dataclass
class Rect:
    x: float
    y: float
    w: float
    h: float

    def contains(self, o: "Rect", slack: float = 0.5) -> bool:
        return self.x - slack <= o.x and self.y - slack <= o.y and o.x + o.w <= self.x + self.w + slack and o.y + o.h <= self.y + self.h + slack

    def overlaps(self, o: "Rect") -> bool:
        return self.x < o.x + o.w and o.x < self.x + self.w and self.y < o.y + o.h and o.y < self.y + self.h


@dataclass
class Tile:
    id: int
    col: int  # 0-based
    idx: int  # 0-based within the column
    w: float
    h: float
    title: str = ""
    app_id: str = ""


@dataclass
class Take:
    """One look at a column: center column `via` (None: the column itself)
    and focus this one, which puts it at `x` on the output; then crop
    `regions` (tile id → tile-local rects; None: the whole tile)."""

    via: int | None
    x: float
    regions: dict[int, list["Rect"] | None] = field(default_factory=dict)

    def actions(self, col: int) -> list[tuple[str, ...]]:
        if self.via is None:
            return [("focus-column", str(col + 1)), ("center-column",)]
        return [("focus-column", str(self.via + 1)), ("center-column",), ("focus-column", str(col + 1))]


@dataclass
class Column:
    index: int  # 0-based
    tiles: list[Tile]
    width: float
    mode: str = "normal"  # normal | tabbed | fullscreen | maximized
    strip_x: float = 0.0  # left edge on the strip (first column at 0)
    canvas_x: float = 0.0  # left edge in the panorama
    screen_x: float = 0.0  # left edge on the output once centered
    takes: list[Take] = field(default_factory=list)
    hidden: list[Rect] = field(default_factory=list)  # tile-local, never seen uncovered


@dataclass
class Layout:
    output: dict  # name, width, height, scale (logical)
    working: Rect  # output-local, logical
    parent: Rect  # the output minus exclusive zones
    columns: list[Column]
    floating: list[dict] = field(default_factory=list)  # {id, rect}
    left_out: list[int] = field(default_factory=list)  # column indices over MAX_WIDTH
    margin: float = 0.0
    width: float = 0.0  # panorama, logical
    height: float = 0.0
    notes: list[str] = field(default_factory=list)
    gaps: float = 0.0
    center: str = "never"
    radius: float = 0.0

    def tile_rect(self, col: Column, tile: Tile, screen_x: float | None = None) -> Rect:
        """Where `tile` is on the output while `col` is centered (or at
        `screen_x`)."""
        sx = col.screen_x if screen_x is None else screen_x
        if col.mode == "fullscreen":
            return Rect(0.0, 0.0, tile.w, tile.h)
        if col.mode == "maximized":
            return Rect(sx, self.parent.y, tile.w, tile.h)
        g = self.gaps
        x = sx + ((col.width - tile.w) / 2 if self.center == "always" else 0.0)
        y = self.working.y + g
        if col.mode != "tabbed":
            for t in col.tiles[: tile.idx]:
                y += t.h + g
        return Rect(x, y, tile.w, tile.h)

    def canvas_pos(self, col: Column, tile: Tile) -> tuple[float, float]:
        """Where `tile` goes in the panorama: same y as on the output, x
        moved from the centered column's place to the strip's."""
        r = self.tile_rect(col, tile)
        return col.canvas_x + (r.x - col.screen_x), r.y


def _ceil_px(v: float, scale: float) -> float:
    return math.ceil(v * scale - 1e-9) / scale


def working_area(out_w: float, out_h: float, p: Params, scale: float = 1.0) -> tuple[Rect, Rect]:
    """(parent, working): the output minus exclusive zones, then minus
    struts, starting at a physical pixel (niri compute_working_area)."""
    il, ir, it, ib = p.insets
    parent = Rect(il, it, max(0.0, out_w - il - ir), max(0.0, out_h - it - ib))
    sl, sr, st, sb = p.struts
    x, y = parent.x + sl, parent.y + st
    w, h = max(0.0, parent.w - sl - sr), max(0.0, parent.h - st - sb)
    cx, cy = _ceil_px(x, scale), _ceil_px(y, scale)
    w -= min(w, cx - x)
    h -= min(h, cy - y)
    return parent, Rect(cx, cy, w, h)


def _near(a: float, b: float, tol: float = 0.5) -> bool:
    return abs(a - b) <= tol


def plan(windows: list[dict], workspace_id: int, output: dict, p: Params, max_width: float = MAX_WIDTH) -> Layout:
    """The panorama of one workspace from `niri msg -j windows` (all of
    them; only `workspace_id`'s count) and the output's logical geometry
    ({name, width, height, scale})."""
    ow, oh, scale = float(output["width"]), float(output["height"]), float(output.get("scale") or 1.0)
    parent, wa = working_area(ow, oh, p, scale)
    g = float(p.gaps)
    cols: dict[int, list[Tile]] = {}
    floating = []
    for w in windows:
        if w.get("workspace_id") != workspace_id:
            continue
        lay = w.get("layout") or {}
        if w.get("is_floating"):
            pos = lay.get("tile_pos_in_workspace_view")
            if pos:
                floating.append({"id": w["id"], "rect": Rect(pos[0], pos[1], *lay["tile_size"])})
            continue
        at = lay.get("pos_in_scrolling_layout")
        if not at:
            continue
        tw, th = lay["tile_size"]
        cols.setdefault(at[0] - 1, []).append(Tile(w["id"], at[0] - 1, at[1] - 1, float(tw), float(th), w.get("title") or "", w.get("app_id") or ""))
    columns: list[Column] = []
    notes: list[str] = []
    for i in sorted(cols):
        tiles = sorted(cols[i], key=lambda t: t.idx)
        width = max(t.w for t in tiles)
        mode = "normal"
        if len(tiles) == 1 and _near(tiles[0].w, ow) and _near(tiles[0].h, oh):
            mode = "fullscreen"
        elif len(tiles) == 1 and _near(tiles[0].w, parent.w) and _near(tiles[0].h, parent.h):
            # maximize-window-to-edges: the output minus exclusive zones
            # (a normal tile is at least 2 gaps shorter).
            mode = "maximized"
        elif len(tiles) > 1 and sum(t.h for t in tiles) + (len(tiles) + 1) * g > wa.h + 1:
            # Stacked they wouldn't fit: they share the space as tabs.
            mode = "tabbed"
            notes.append(f"column {i + 1} is tabbed: only its active tab is captured")
        columns.append(Column(len(columns), tiles, width, mode))
    lay = Layout(
        output={"name": output.get("name", ""), "width": ow, "height": oh, "scale": scale},
        working=wa,
        parent=parent,
        columns=columns,
        floating=floating,
        notes=notes,
        gaps=g,
        center=p.center,
        radius=p.radius,
    )
    if floating:
        lay.notes.append(f"{len(floating)} floating window{'s' if len(floating) != 1 else ''} left out (they float over the view, not on the strip)")
    if not columns:
        return lay

    # Strip positions; the panorama keeps a gap's margin at both ends.
    margin = g
    x = 0.0
    kept: list[Column] = []
    for c in columns:
        right = margin + x + c.width + margin
        if kept and right * scale > max_width:
            lay.left_out.append(c.index)
            continue
        c.strip_x = x
        c.canvas_x = margin + x
        x += c.width + g
        kept.append(c)
    if lay.left_out:
        lay.notes.append(f"{len(lay.left_out)} column{'s' if len(lay.left_out) != 1 else ''} past the {MAX_WIDTH:,} px limit left out")
    lay.columns = kept
    lay.margin = margin
    lay.width = min(margin + x - g + margin, max_width / scale) if kept else 0.0
    lay.height = oh

    for c in kept:
        if c.mode == "fullscreen":
            c.screen_x = 0.0
        elif c.mode == "maximized":
            c.screen_x = parent.x
        elif c.width >= wa.w:
            c.screen_x = wa.x
        else:
            c.screen_x = wa.x + (wa.w - c.width) / 2
    plan_takes(lay)
    return lay


FLOAT_SHADOW = 24.0  # logical px around a floating window its shadow may darken


def fit_x(lay: Layout, view: float, col: Column) -> float:
    """Where `col` lands on the output when it gets focus while the view is
    at `view` (strip x of the output's left edge): niri's "fit" — no move
    if it is fully visible, else the nearer edge with a gap's padding
    (compute_new_view_offset in niri's scrolling.rs)."""
    if col.mode == "fullscreen":
        return 0.0
    area, pad = (lay.parent, 0.0) if col.mode == "maximized" else (lay.working, lay.gaps)
    cur = view + area.x
    w = col.width
    if area.w <= w:
        return area.x
    padding = min(max((area.w - w) / 2, 0.0), pad)
    left, right = col.strip_x - padding, col.strip_x + w + padding
    if cur <= left and right <= cur + area.w:
        return col.strip_x - view
    if abs(cur - left) <= abs(cur + area.w - right):
        return area.x + padding
    return area.x + area.w - padding - w


def _cut(r: Rect, holes: list[Rect]) -> list[Rect]:
    """`r` minus `holes`, as rects."""
    out = [r]
    for h in holes:
        nxt = []
        for a in out:
            if not a.overlaps(h):
                nxt.append(a)
                continue
            x0, x1 = max(a.x, h.x), min(a.x + a.w, h.x + h.w)
            y0, y1 = max(a.y, h.y), min(a.y + a.h, h.y + h.h)
            if a.y < y0:
                nxt.append(Rect(a.x, a.y, a.w, y0 - a.y))
            if y1 < a.y + a.h:
                nxt.append(Rect(a.x, y1, a.w, a.y + a.h - y1))
            if a.x < x0:
                nxt.append(Rect(a.x, y0, x0 - a.x, y1 - y0))
            if x1 < a.x + a.w:
                nxt.append(Rect(x1, y0, a.x + a.w - x1, y1 - y0))
        out = nxt
    return [a for a in out if a.w > 0.5 and a.h > 0.5]


def hidden_parts(lay: Layout, col: Column, tile: Tile, x: float) -> list[Rect]:
    """The parts of `tile` (tile-local) not seen with the column at `x`:
    off the output, or under a floating window (and its shadow)."""
    r = lay.tile_rect(col, tile, x)
    holes = [Rect(-100_000, -100_000, 100_000, 300_000), Rect(lay.output["width"], -100_000, 100_000, 300_000)]
    m = FLOAT_SHADOW
    holes += [Rect(f["rect"].x - m, f["rect"].y - m, f["rect"].w + 2 * m, f["rect"].h + 2 * m) for f in lay.floating]
    tile_area = Rect(r.x, r.y, r.w, r.h)
    seen = _cut(tile_area, holes)
    # hidden = tile minus seen
    hidden = _cut(tile_area, seen)
    return [Rect(h.x - r.x, h.y - r.y, h.w, h.h) for h in hidden]


def _inside(a: Rect, rects: list[Rect]) -> bool:
    """`a` is covered by `rects` (sampled: corners and middle)."""
    pts = [(a.x + 0.5, a.y + 0.5), (a.x + a.w - 0.5, a.y + 0.5), (a.x + 0.5, a.y + a.h - 0.5), (a.x + a.w - 0.5, a.y + a.h - 0.5), (a.x + a.w / 2, a.y + a.h / 2)]
    return all(any(r.x <= px <= r.x + r.w and r.y <= py <= r.y + r.h for r in rects) for px, py in pts)


def plan_takes(lay: Layout) -> None:
    """How to look at every column. Centered, unless a floating window is in
    the way: then another reachable place (center another column first,
    then focus this one, so niri's fit puts it at an edge), or the centered
    look patched in strips from other places. What no place shows
    uncovered stays as the centered look has it (Column.hidden)."""
    for c in lay.columns:
        places: list[tuple[int | None, float]] = [(None, c.screen_x)]
        if lay.floating and lay.center == "never" and c.mode in ("normal", "tabbed"):
            seen_x = {round(c.screen_x, 3)}
            for m in lay.columns:
                if m.index == c.index:
                    continue
                x = fit_x(lay, m.strip_x - m.screen_x, c)
                if round(x, 3) not in seen_x:
                    seen_x.add(round(x, 3))
                    places.append((m.index, x))
        tiles = c.tiles if c.mode != "tabbed" else c.tiles[:1]  # tabs share one place
        hidden = {(via, x): {t.id: hidden_parts(lay, c, t, x) for t in tiles} for via, x in places}
        clean = next(((via, x) for via, x in places if not any(hidden[(via, x)].values())), None)
        if clean is not None:
            c.takes = [Take(clean[0], clean[1], {t.id: None for t in c.tiles})]
            c.screen_x = clean[1]
            continue
        base = places[0]
        c.takes = [Take(base[0], base[1], {t.id: None for t in c.tiles})]
        patches: dict[tuple[int | None, float], dict[int, list[Rect]]] = {}
        for t in tiles:
            for h in hidden[base][t.id]:
                n = max(1, math.ceil(h.w / 32))
                for i in range(n):
                    strip_ = Rect(h.x + h.w * i / n, h.y, h.w / n, h.h)
                    got = None
                    for pl in places[1:]:
                        if not any(r.overlaps(strip_) for r in hidden[pl][t.id]):
                            got = pl
                            break
                    if got is None:
                        c.hidden.append(strip_)
                    else:
                        patches.setdefault(got, {}).setdefault(t.id, []).append(strip_)
        for (via, x), regions in patches.items():
            if c.mode == "tabbed":
                # Whichever tab is active: the same place for all of them.
                regions = {t.id: regions[tiles[0].id] for t in c.tiles}
            c.takes.append(Take(via, x, regions))


def _round(v: float) -> int:
    return int(math.floor(v + 0.5)) if v >= 0 else -int(math.floor(-v + 0.5))


def px_rect(r: Rect, scale: float) -> tuple[int, int, int, int]:
    """A logical rect in the output's pixels (x, y, w, h)."""
    # niri rounds to physical pixels half away from zero (f64::round), not
    # to even like Python's round().
    x0, y0 = _round(r.x * scale), _round(r.y * scale)
    x1, y1 = _round((r.x + r.w) * scale), _round((r.y + r.h) * scale)
    return x0, y0, max(1, x1 - x0), max(1, y1 - y0)


# ── Pixels ──────────────────────────────────────────────────────────────


def crop(img: Image, x: int, y: int, w: int, h: int) -> Image:
    """A crop, clamped to the image."""
    x0, y0 = max(0, x), max(0, y)
    x1, y1 = min(img.width, x + w), min(img.height, y + h)
    if x1 <= x0 or y1 <= y0:
        return Image(0, 0, b"")
    rows = [img.row(r)[x0 * 3 : x1 * 3] for r in range(y0, y1)]
    return Image(x1 - x0, y1 - y0, b"".join(rows))


def corner_alpha(radius: int) -> list[list[float]]:
    """Coverage of a quarter circle of `radius` px: [y][x] for the top-left
    corner square (1 inside the window, 0 outside)."""
    out = []
    for y in range(radius):
        row = []
        for x in range(radius):
            dx, dy = radius - (x + 0.5), radius - (y + 0.5)
            d = (dx * dx + dy * dy) ** 0.5
            row.append(min(1.0, max(0.0, radius - d + 0.5)))
        out.append(row)
    return out


def paste(canvas: bytearray, cw: int, ch: int, tile: Image, x: int, y: int) -> None:
    """Copy `tile` into the RGB canvas (cw × ch) at (x, y), clipped."""
    stride = cw * 3
    for r in range(tile.height):
        cy = y + r
        if not 0 <= cy < ch:
            continue
        sx0 = max(0, -x)
        sx1 = min(tile.width, cw - x)
        if sx1 <= sx0:
            return
        row = tile.row(r)
        canvas[cy * stride + (x + sx0) * 3 : cy * stride + (x + sx1) * 3] = row[sx0 * 3 : sx1 * 3]


def round_corners(canvas: bytearray, cw: int, ch: int, bg: bytes, x: int, y: int, w: int, h: int, radius: int) -> None:
    """Round the corners of the tile pasted at (x, y, w, h): outside the
    quarter circles the grab shows whatever was behind the window on screen,
    so the panorama's own background (`bg`, same size as the canvas) comes
    back there, blended along the edge."""
    if radius <= 0 or radius * 2 > min(w, h):
        return
    a = corner_alpha(radius)
    stride = cw * 3
    for cy_off in range(radius):
        for cx_off in range(radius):
            k = a[cy_off][cx_off]
            if k >= 1.0:
                continue
            for px, py in ((x + cx_off, y + cy_off), (x + w - 1 - cx_off, y + cy_off), (x + cx_off, y + h - 1 - cy_off), (x + w - 1 - cx_off, y + h - 1 - cy_off)):
                if 0 <= px < cw and 0 <= py < ch:
                    o = py * stride + px * 3
                    for c in range(3):
                        canvas[o + c] = round(canvas[o + c] * k + bg[o + c] * (1 - k))


def hex_color(s: str) -> tuple[int, int, int]:
    """#rrggbb, or Qt's #aarrggbb (the alpha is dropped)."""
    s = s.strip().lstrip("#")
    if len(s) == 8:
        s = s[2:]
    if len(s) != 6:
        raise ValueError(f"bad color {s!r}")
    return int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16)


def wallpaper_canvas(path: str, w: int, h: int, focus: tuple[float, float] = (0.5, 0.5)) -> bytes:
    """The wallpaper scaled to cover w×h (keeping its aspect), cropped around
    `focus` (0–1 of the image) like the wallpaper layer does. RGB bytes."""
    fx, fy = focus
    vf = (
        f"scale={w}:{h}:force_original_aspect_ratio=increase:flags=lanczos,"
        f"crop={w}:{h}:'min(max(iw*{fx:.4f}-ow/2,0),iw-ow)':'min(max(ih*{fy:.4f}-oh/2,0),ih-oh)'"
    )
    r = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", path, "-frames:v", "1", "-vf", vf, "-pix_fmt", "rgb24", "-f", "rawvideo", "-"],
        capture_output=True,
    )
    if r.returncode != 0 or len(r.stdout) != w * h * 3:
        raise RuntimeError(f"can't scale the wallpaper {path}: {r.stderr.decode(errors='replace').strip()[-300:]}")
    return r.stdout


# ── niri ────────────────────────────────────────────────────────────────


class NiriIpc:
    """`niri msg` on $NIRI_SOCKET (the session the shell runs in)."""

    def __init__(self, exe: str = "niri"):
        self.exe = exe

    def query(self, what: str):
        r = subprocess.run([self.exe, "msg", "--json", what], capture_output=True, text=True, timeout=10)
        if r.returncode != 0:
            raise RuntimeError(f"niri msg {what}: {r.stderr.strip()}")
        return json.loads(r.stdout or "null")

    def action(self, *args: str) -> None:
        r = subprocess.run([self.exe, "msg", "action", *args], capture_output=True, text=True, timeout=10)
        if r.returncode != 0:
            raise RuntimeError(f"niri msg action {' '.join(args)}: {r.stderr.strip()}")


def niri_layout_params() -> dict:
    """gaps / struts / center-focused-column from `loft-niri --json show`
    (the effective niri config with Loft's overrides); {} without it."""
    exe = shutil.which("loft-niri")
    if not exe:
        return {}
    try:
        r = subprocess.run([exe, "--json", "show"], capture_output=True, text=True, timeout=10)
        keys = json.loads(r.stdout).get("keys", {}) if r.returncode == 0 else {}
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return {}

    def val(k, d=None):
        v = keys.get(k, {}).get("value")
        return d if v is None else v

    return {
        "gaps": float(val("layout.gaps", 16)),
        "struts": tuple(float(val(f"layout.struts.{s}", 0)) for s in ("left", "right", "top", "bottom")),
        "center": str(val("layout.center-focused-column", "never")),
    }


def grim_output(name: str, path: Path) -> Image:
    r = subprocess.run(["grim", "-o", name, "-t", "ppm", str(path)], capture_output=True)
    if r.returncode != 0:
        raise RuntimeError(f"grim -o {name}: {r.stderr.decode(errors='replace').strip()}")
    return stitch.read_ppm(path)


def _rows_same(a: Image, b: Image, step: int = 7, band: tuple[int, int] | None = None) -> float:
    """The share of sampled rows (every `step`-th, within `band`) that two
    frames have in common."""
    if (a.width, a.height) != (b.width, b.height):
        return 0.0
    y0, y1 = band or (0, a.height)
    n = same = 0
    for y in range(max(0, y0), min(a.height, y1), step):
        n += 1
        same += a.row(y) == b.row(y)
    return same / n if n else 1.0


def view_match(a: Image, b: Image, band: tuple[int, int], reach: int = 24, chunk: int = 48) -> tuple[float, int]:
    """How well `b` shows the same view as `a`: the best horizontal shift
    (px, within ±reach) of `b`'s content against `a`'s, and the share of
    `chunk`-wide pieces of sampled rows that match at that shift. The
    wallpaper doesn't move with the windows, so whole rows rarely match
    when the view is a pixel off; pieces of them do."""
    if (a.width, a.height) != (b.width, b.height):
        return 0.0, 0
    y0, y1 = max(0, band[0]), min(a.height, band[1])
    rows = [(a.row(y), b.row(y)) for y in range(y0, y1, 9)]
    best = (0.0, 0)
    w = a.width
    for dx in sorted(range(-reach, reach + 1), key=abs):
        hit = n = 0
        for ra, rb in rows:
            for x in range(max(0, -dx), min(w, w - dx) - chunk + 1, chunk):
                n += 1
                hit += ra[x * 3 : (x + chunk) * 3] == rb[(x + dx) * 3 : (x + dx + chunk) * 3]
        frac = hit / n if n else 0.0
        if frac > best[0] + 1e-9:
            best = (frac, dx)
    return best


class Session:
    """One panorama run against niri (or fakes, in tests)."""

    def __init__(self, ipc, grab, sleep=time.sleep, clock=time.monotonic, log=None):
        self.ipc, self.grab, self.sleep, self.clock = ipc, grab, sleep, clock
        self.log = log or (lambda *_a: None)
        # Pixel rows of the working area: the view moves there (the bar
        # above it may animate on its own).
        self.band: tuple[int, int] | None = None

    def settled(self) -> Image:
        """The output once the view has stopped moving (or SETTLE_MAX)."""
        self.sleep(SETTLE_FIRST)
        start = self.clock()
        prev = self.grab()
        while True:
            self.sleep(SETTLE_STEP)
            cur = self.grab()
            if _rows_same(prev, cur, band=self.band) >= SAME_ROWS or self.clock() - start > SETTLE_MAX:
                return cur
            prev = cur

    def focused_id(self) -> int | None:
        w = self.ipc.query("focused-window")
        return w.get("id") if isinstance(w, dict) else None

    def run(self, output_name: str | None, p: Params) -> tuple[Layout, list[tuple[Column, Tile, Image]], dict]:
        outputs = self.ipc.query("outputs")
        focused_out = self.ipc.query("focused-output") or {}
        name = output_name or focused_out.get("name")
        o = outputs.get(name) if isinstance(outputs, dict) else next((x for x in outputs if x.get("name") == name), None)
        if not o or not o.get("logical"):
            raise RuntimeError(f"no output {name!r}")
        lg = o["logical"]
        output = {"name": name, "width": lg["width"], "height": lg["height"], "scale": lg.get("scale") or 1.0}
        workspaces = self.ipc.query("workspaces")
        ws = next((w for w in workspaces if w.get("output") == name and w.get("is_active")), None)
        if ws is None:
            raise RuntimeError(f"no workspace on {name}")
        windows = self.ipc.query("windows")
        lay = plan(windows, ws["id"], output, p)
        if not lay.columns:
            raise EmptyWorkspace(f"workspace {ws.get('name') or ws['idx']} on {name} has no tiled windows")

        s = lay.output["scale"]
        self.band = (_round(lay.working.y * s), _round((lay.working.y + lay.working.h) * s))
        orig_focus = self.focused_id()
        orig_active = ws.get("active_window_id")
        # The view follows the scrolling layout's active column; with a
        # floating window active, that's the tiled window focused last.
        tiled = {t.id for c in lay.columns for t in c.tiles}
        mine = [w for w in windows if w.get("workspace_id") == ws["id"]]
        anchor = orig_active if orig_active in tiled else None
        if anchor is None:
            stamped = [w for w in mine if w["id"] in tiled]
            stamped.sort(key=lambda w: ((w.get("focus_timestamp") or {}).get("secs", 0), (w.get("focus_timestamp") or {}).get("nanos", 0)))
            anchor = stamped[-1]["id"] if stamped else None
        floats = {w["id"]: tuple(w["layout"]["tile_pos_in_workspace_view"]) for w in mine if w.get("is_floating") and w["layout"].get("tile_pos_in_workspace_view")}
        state = {"workspace": ws["id"], "output": name, "stops": 0, "view": "", "covered": []}
        first = self.grab()  # the view as it was, to put it back
        if not ws.get("is_focused"):
            self.ipc.action("focus-monitor", name)

        shots: list[Shot] = []
        scale = lay.output["scale"]
        try:
            if any(c.hidden for c in lay.columns):
                lay = self.park_floating(lay, ws["id"], output, p, floats)
                state["parked"] = len(floats)
            for c in lay.columns:
                active = None
                for take in c.takes:
                    for a in take.actions(c.index):
                        self.ipc.action(*a)
                    frame = self.settled()
                    state["stops"] += 1
                    if active is None:
                        active = self.focused_id()
                    tiles = c.tiles
                    if c.mode == "tabbed":
                        tiles = [t for t in c.tiles if t.id == active] or c.tiles[:1]
                    for t in tiles:
                        r = lay.tile_rect(c, t, take.x)
                        for reg in take.regions.get(t.id) or [None]:
                            if reg is None:
                                shots.append(Shot(c, t, crop(frame, *px_rect(r, scale)), 0, 0))
                                continue
                            x, y, w, h = px_rect(Rect(r.x + reg.x, r.y + reg.y, reg.w, reg.h), scale)
                            ox, oy = x - px_rect(r, scale)[0], y - px_rect(r, scale)[1]
                            shots.append(Shot(c, t, crop(frame, x, y, w, h), ox, oy))
                if c.hidden:
                    state["covered"].append(c.index + 1)
        finally:
            state["view"] = self.restore(anchor, orig_active, orig_focus, first, focused_out.get("name", ""), name)
            self.put_back_floating(floats)
        if state["covered"]:
            lay.notes.append("partly covered by a floating window: column " + ", ".join(map(str, state["covered"])))
        return lay, shots, state

    def park_floating(self, lay: Layout, ws_id: int, output: dict, p: Params, floats: dict[int, tuple[float, float]]) -> Layout:
        """Floating windows hide parts of some column wherever it can be put:
        slide them to the right edge for the capture (niri keeps a sliver
        of a floating window on screen) and plan again; put_back_floating
        returns them afterwards, exactly."""
        for wid in floats:
            self.ipc.action("move-floating-window", "--id", str(wid), "-x", "+100000", "-y", "+0")
        self.settled()
        again = plan(self.ipc.query("windows"), ws_id, output, p)
        again.notes.append(f"{len(floats)} floating window{'s' if len(floats) != 1 else ''} moved aside during the capture, and back")
        return again if again.columns else lay

    def put_back_floating(self, floats: dict[int, tuple[float, float]]) -> None:
        """Nothing here should move a floating window; if one moved anyway,
        move it back (relative moves: niri's absolute ones are in working-
        area coordinates, the IPC reports output ones)."""
        if not floats:
            return
        try:
            now = {w["id"]: w["layout"].get("tile_pos_in_workspace_view") for w in self.ipc.query("windows")}
            for wid, (x, y) in floats.items():
                cur = now.get(wid)
                if cur and (abs(cur[0] - x) > 0.5 or abs(cur[1] - y) > 0.5):
                    self.ipc.action("move-floating-window", "--id", str(wid), "-x", f"{x - cur[0]:+g}", "-y", f"{y - cur[1]:+g}")
        except RuntimeError as e:
            self.log(f"floating: {e}")

    def restore(self, anchor: int | None, active: int | None, focus: int | None, first: Image, focus_output: str, name: str) -> str:
        """Bring the view back to where it was (compared with the first grab)
        with the tiled window `anchor` active, then focus goes back to the
        workspace's active window and the window that had focus. niri has
        no "set view offset", so a few deterministic moves are tried — fit
        from where the capture ended, centered, fit coming from the left,
        fit coming from the right, centered visible columns — and the
        closest is kept. "exact", "near" (a few px off: the view had been
        dragged or animated somewhere in between) or "moved"."""
        result = "moved"
        try:
            if anchor is not None:
                win = ("focus-window", "--id", str(anchor))
                tries = [
                    [win],
                    [win, ("center-column",)],
                    [("focus-column-first",), win],
                    [("focus-column-last",), win],
                    [win, ("center-visible-columns",)],
                ]
                scores = []
                for steps in tries:
                    for st in steps:
                        self.ipc.action(*st)
                    frac, dx = view_match(first, self.settled(), self.band or (0, first.height))
                    scores.append((frac, -abs(dx)))
                    if frac >= SAME_ROWS and dx == 0:
                        result = "exact"
                        break
                if result != "exact":
                    best = max(range(len(scores)), key=scores.__getitem__)
                    if scores[best][0] >= 0.5:
                        result = "near"
                    if best != len(scores) - 1:
                        for st in tries[best]:
                            self.ipc.action(*st)
            if active is not None and active != anchor:
                self.ipc.action("focus-window", "--id", str(active))
            if focus is not None and focus != active:
                self.ipc.action("focus-window", "--id", str(focus))
            elif focus is None and focus_output and focus_output != name:
                self.ipc.action("focus-monitor", focus_output)
        except RuntimeError as e:
            self.log(f"restore: {e}")
        return result


class EmptyWorkspace(RuntimeError):
    pass


@dataclass
class Shot:
    """Pixels of a tile from one look: `img` goes at (ox, oy) px within the
    tile (0, 0 for the whole tile)."""

    col: Column
    tile: Tile
    img: Image
    ox: int = 0
    oy: int = 0


def compose(lay: Layout, shots: list[Shot], out: Path, background: str = "", wallpaper: str = "", focus: tuple[float, float] = (0.5, 0.5)) -> tuple[int, int]:
    """Composite the tiles on the background and write the PNG."""
    s = lay.output["scale"]
    cw, ch = _round(lay.width * s), _round(lay.height * s)
    bg = b""
    if wallpaper:
        bg = wallpaper_canvas(wallpaper, cw, ch, focus)
    else:
        bg = bytes(hex_color(background or "#1e1e2e")) * (cw * ch)
    canvas = bytearray(bg)
    radius = _round(lay.radius * s)
    done: dict[int, tuple[Column, int, int, int, int]] = {}
    for sh in shots:
        x, y = lay.canvas_pos(sh.col, sh.tile)
        px, py = _round(x * s), _round(y * s)
        paste(canvas, cw, ch, sh.img, px + sh.ox, py + sh.oy)
        if sh.ox == 0 and sh.oy == 0:
            done[sh.tile.id] = (sh.col, px, py, sh.img.width, sh.img.height)
    for col, px, py, w, h in done.values():
        if col.mode != "fullscreen":
            round_corners(canvas, cw, ch, bg, px, py, w, h, radius)
    stride = cw * 3
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_name(out.name + ".part")
    tmp.write_bytes(stitch.png_bytes(cw, ch, (bytes(canvas[y * stride : (y + 1) * stride]) for y in range(ch))))
    tmp.replace(out)
    return cw, ch


# ── CLI ─────────────────────────────────────────────────────────────────


def _floats(s: str, n: int) -> tuple[float, ...]:
    v = tuple(float(x) for x in s.replace(" ", ",").split(",") if x != "")
    if len(v) != n:
        raise ValueError(f"want {n} numbers, got {s!r}")
    return v


def add_parser(sub) -> None:
    s = sub.add_parser("panorama", help="one image of a whole niri workspace strip (every column, wider than the display)")
    s.add_argument("output", nargs="?", help="the display (default: the focused one)")
    s.add_argument("--out", required=True, help="PNG to write")
    s.add_argument("--wallpaper", default="", help="background: this image, scaled to cover the panorama")
    s.add_argument("--focus", default="0.5,0.5", help="the wallpaper's point to keep central (0–1, like the wallpaper layer)")
    s.add_argument("--backdrop", default="#1e1e2e", help="plain background color (without --wallpaper)")
    s.add_argument("--insets", default="0,0,0,0", help="exclusive zones on the output: left,right,top,bottom (the bar, a dock)")
    s.add_argument("--gaps", type=float, help="niri layout gaps (default: loft-niri show, else 16)")
    s.add_argument("--struts", help="niri layout struts left,right,top,bottom (default: loft-niri show)")
    s.add_argument("--center", choices=("never", "always", "on-overflow"), help="center-focused-column (default: loft-niri show)")
    s.add_argument("--radius", type=float, default=0.0, help="window corner radius (rounded on the background)")
    s.add_argument("--plan", action="store_true", help="print the layout (columns, positions) without capturing")
    s.add_argument("--windows", help="plan from `niri msg -j windows` JSON in this file (with --plan)")
    s.add_argument("--output-json", help="… and this `outputs`-style {name, width, height, scale}")
    s.add_argument("--workspace", type=int, help="… and this workspace id")

    def _run(ctx, a):
        known = niri_layout_params()
        p = Params(
            gaps=a.gaps if a.gaps is not None else known.get("gaps", 16.0),
            struts=_floats(a.struts, 4) if a.struts else known.get("struts", (0.0, 0.0, 0.0, 0.0)),
            insets=_floats(a.insets, 4),
            center=a.center or known.get("center", "never"),
            radius=a.radius,
        )
        if a.plan and a.windows:
            out = json.loads(Path(a.output_json).read_text()) if a.output_json else {"name": a.output or "", "width": 1600, "height": 1000, "scale": 1}
            lay = plan(json.loads(Path(a.windows).read_text()), a.workspace, out, p)
            print(json.dumps(layout_json(lay)))
            return
        ipc = NiriIpc()
        work = Path(tempfile.mkdtemp(prefix="loft-panorama-", dir=os.environ.get("XDG_RUNTIME_DIR") or None))
        try:
            name = a.output or (ipc.query("focused-output") or {}).get("name")
            ses = Session(ipc, lambda: grim_output(name, work / "frame.ppm"), log=lambda m: print(m, file=sys.stderr))
            if a.plan:
                outputs = ipc.query("outputs")
                lg = outputs[name]["logical"]
                ws = next(w for w in ipc.query("workspaces") if w.get("output") == name and w.get("is_active"))
                lay = plan(ipc.query("windows"), ws["id"], {"name": name, **lg}, p)
                print(json.dumps(layout_json(lay)))
                return
            try:
                lay, shots, state = ses.run(name, p)
            except EmptyWorkspace as e:
                print(json.dumps({"event": "error", "reason": "empty", "message": str(e)}))
                sys.exit(1)
            t = time.monotonic()
            w, h = compose(lay, shots, Path(a.out), a.backdrop, a.wallpaper, _floats(a.focus, 2))
            print(
                json.dumps(
                    {
                        "event": "done",
                        "path": a.out,
                        "width": w,
                        "height": h,
                        "columns": len(lay.columns),
                        "tiles": len({sh.tile.id for sh in shots}),
                        "stops": state["stops"],
                        "view": state["view"],
                        "notes": lay.notes,
                        "seconds": round(time.monotonic() - t, 2),
                    }
                )
            )
        except RuntimeError as e:
            print(json.dumps({"event": "error", "reason": "failed", "message": str(e)}))
            sys.exit(1)
        finally:
            shutil.rmtree(work, ignore_errors=True)

    s.set_defaults(fn=_run)


def layout_json(lay: Layout) -> dict:
    def r(v: Rect) -> list[float]:
        return [v.x, v.y, v.w, v.h]

    return {
        "output": lay.output,
        "working": r(lay.working),
        "parent": r(lay.parent),
        "width": lay.width,
        "height": lay.height,
        "margin": lay.margin,
        "columns": [
            {
                "index": c.index + 1,
                "mode": c.mode,
                "width": c.width,
                "strip_x": c.strip_x,
                "canvas_x": c.canvas_x,
                "screen_x": c.screen_x,
                "tiles": [{"id": t.id, "rect": r(lay.tile_rect(c, t)), "canvas": list(lay.canvas_pos(c, t))} for t in c.tiles],
                "takes": [{"via": None if k.via is None else k.via + 1, "x": k.x, "regions": {str(i): None if v is None else [r(x) for x in v] for i, v in k.regions.items()}} for k in c.takes],
                "hidden": [r(h) for h in c.hidden],
            }
            for c in lay.columns
        ],
        "floating": [f["id"] for f in lay.floating],
        "left_out": [i + 1 for i in lay.left_out],
        "notes": lay.notes,
    }
