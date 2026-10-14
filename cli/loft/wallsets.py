"""Wallpaper sets: a wallpaper per display and per workspace, by role.

Every choice is per theme, in the shell's `overrides/shell.json`
(`perTheme.<theme>`, written by the shell's Settings → Wallpaper or by
`loft wallpaper …`):

  wallpaper   one image for the theme (every display)
  displays    {"<niri identity>": path}        a display's image
  workspaces  {"<name>" | "<identity>#<idx>": path}   a workspace's image
  sameAll     {"<identity>": true}             "Use for all workspaces": the
                                               display's image everywhere on it
  auto        bool                             fill the rest with matching images
  autoSeed    int                              Shuffle reseeds the auto picks
  sets        [set]                            saved sets (below)
  activeSet   name of the last applied set (shown by the pickers)

What a screen shows, for its active workspace W on display D:

  1. W's choice (unless D is "same on all workspaces")
  2. the pack's set for W (same condition; see "Pack sets")
  3. D's *base*: D's choice, else the theme's choice, else the pack's set
     for D, else (auto) an auto pick for D
  4. with auto on and D not "same on all": W's auto pick, related to D's
     base, for every workspace but D's first (which shows the base)
  5. the base; else rotation / per-workspace through the collection; else
     the theme's default (Vibes.qml)

Roles name displays by the live layout instead of connectors, so a set made
on one desk applies to another: `main` (the largest display, or the one
Settings → Displays names), `left` / `right` / `top` / `bottom` of it
(`left-2` … further out), the shape (`portrait`, `ultrawide` ≥ 2.2:1,
`landscape`), the ordinal `display-1..N` (by x, then y) and `*` (any).
A display takes the first of its roles a set has.

A set is {"name", "displays": {role: path}, "workspaces": {key: path}}:
workspace keys are a niri workspace name, or `<role>#<idx>`. Packs ship sets
in theme.json `wallpaperSets` (paths relative to the pack); the shell
applies the pack's best-covering set on a multi-display layout while the
theme has no explicit choices.

Auto picks (`plan`) come from the theme's vibe set (vibes.rank: own, curated,
then matches with a library score ≥ 0.6, the same floor as the library's
theme views): only stills in the target tone bucket (library.classify; the
theme's own default wallpaper's tone, else Dark / Light by polarity), costed
by color distance (to the theme, or to the display's base image for its
workspaces), tone, a shared color family, the same folder as the base image
(a series stays together), and how much of the image's interest survives
the display's crop (`framing`); a hash of
(seed, theme, slot, image) breaks near-ties so every slot gets its own
image deterministically. Distinct images while the pool lasts.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import struct
from pathlib import Path

from . import color, library, palette, vibes
from .pack import SET_ROLE

ULTRAWIDE = 2.2
DIRECTIONS = ("left", "right", "top", "bottom")
ROLE = SET_ROLE

AUTO_MIN = 6  # auto defaults on for themes with at least this many candidates in tone
FRAMING_BINS = 16

# Cost weights (CIEDE2000 units).
TONE_NEAR = 10.0  # Dark vs Medium, Medium vs Light
TONE_FAR = 30.0  # Dark vs Light: never picked
FAMILY_MISS = 6.0  # no color family in common with the slot's reference
FIT_WEIGHT = 22.0  # × the share of the image's interest the crop loses
JITTER = 8.0  # × hash(seed, theme, slot, image) in [0, 1)
SAME_FOLDER = 4.0  # bonus: from the same folder as the slot's reference (a series, a topic)


# ── layout and roles ────────────────────────────────────────────────────────


def _area(o: dict) -> float:
    return o["width"] * o["height"]


def main_output(outputs: list[dict], main: str | None = None) -> dict | None:
    """The display named by `main` (connector or identity), else the largest
    (ties: leftmost, then topmost)."""
    if not outputs:
        return None
    if main:
        hit = next((o for o in outputs if o["name"] == main or o.get("identity") == main), None)
        if hit:
            return hit
    return sorted(outputs, key=lambda o: (-_area(o), o["x"], o["y"]))[0]


def shape(o: dict) -> str:
    w, h = o["width"], o["height"]
    if h > w:
        return "portrait"
    return "ultrawide" if w / max(h, 1) >= ULTRAWIDE else "landscape"


def roles(outputs: list[dict], main: str | None = None) -> dict[str, list[str]]:
    """connector → its roles, most specific first (see the module docstring)."""
    m = main_output(outputs, main)
    if m is None:
        return {}
    out: dict[str, list[str]] = {}
    groups: dict[str, list[tuple[float, float, str]]] = {d: [] for d in DIRECTIONS}
    for o in outputs:
        if o is m:
            continue
        mx2, my2 = m["x"] + m["width"], m["y"] + m["height"]
        ox2, oy2 = o["x"] + o["width"], o["y"] + o["height"]
        cx, cy = o["x"] + o["width"] / 2, o["y"] + o["height"] / 2
        mcx, mcy = m["x"] + m["width"] / 2, m["y"] + m["height"] / 2
        if ox2 <= m["x"]:
            groups["left"].append((m["x"] - ox2, abs(cy - mcy), o["name"]))
        elif o["x"] >= mx2:
            groups["right"].append((o["x"] - mx2, abs(cy - mcy), o["name"]))
        elif oy2 <= m["y"]:
            groups["top"].append((m["y"] - oy2, abs(cx - mcx), o["name"]))
        elif o["y"] >= my2:
            groups["bottom"].append((o["y"] - my2, abs(cx - mcx), o["name"]))
    positional = {m["name"]: "main"}
    for d, items in groups.items():
        for i, (_, _, name) in enumerate(sorted(items)):
            positional[name] = d if i == 0 else f"{d}-{i + 1}"
    ordinal = {o["name"]: f"display-{i + 1}" for i, o in enumerate(sorted(outputs, key=lambda o: (o["x"], o["y"], o["name"])))}
    for o in outputs:
        rs = [positional[o["name"]]] if o["name"] in positional else []
        out[o["name"]] = rs + [shape(o), ordinal[o["name"]], "*"]
    return out


def ws_key(ws: dict, identity: str) -> str:
    """How a workspace's choice is stored: its name, else <identity>#<idx>."""
    return ws["name"] if ws.get("name") else f"{identity}#{ws['idx']}"


def ordered_outputs(layout: dict) -> list[dict]:
    """Main first, then by x / y (the order auto picks are made in)."""
    outs = layout.get("outputs", [])
    m = main_output(outs, layout.get("main"))
    rest = sorted((o for o in outs if o is not m), key=lambda o: (o["x"], o["y"], o["name"]))
    return ([m] if m else []) + rest


def _ident(o: dict) -> str:
    return o.get("identity") or o["name"]


def workspaces_of(layout: dict, output: str) -> list[dict]:
    return sorted((w for w in layout.get("workspaces", []) if w.get("output") == output), key=lambda w: w["idx"])


def layout_from_niri(niri_outputs: dict, niri_workspaces: list, main: str | None = None) -> dict:
    """`niri msg -j outputs` + `niri msg -j workspaces` → a layout."""
    outs = []
    for name, o in sorted(niri_outputs.items()):
        lg = o.get("logical")
        if not lg:
            continue  # disabled
        outs.append(
            {
                "name": name,
                "identity": f"{o.get('make')} {o.get('model')} {o.get('serial') or 'Unknown'}",
                "x": lg["x"],
                "y": lg["y"],
                "width": lg["width"],
                "height": lg["height"],
            }
        )
    wss = [{"output": w.get("output"), "idx": w["idx"], "name": w.get("name") or ""} for w in niri_workspaces]
    return {"outputs": outs, "main": main or "", "workspaces": wss}


# ── sets ────────────────────────────────────────────────────────────────────


def valid_set(s) -> bool:
    return (
        isinstance(s, dict)
        and isinstance(s.get("name"), str)
        and s["name"] != ""
        and isinstance(s.get("displays", {}), dict)
        and isinstance(s.get("workspaces", {}), dict)
    )


def resolve_set(s: dict, layout: dict) -> dict:
    """A set on a live layout → {"displays": {identity: path}, "workspaces": {ws key: path}}."""
    rs = roles(layout.get("outputs", []), layout.get("main"))
    disp = s.get("displays") or {}
    wsp = s.get("workspaces") or {}
    out: dict = {"displays": {}, "workspaces": {}}
    for o in layout.get("outputs", []):
        for r in rs.get(o["name"], []):
            if disp.get(r):
                out["displays"][_ident(o)] = disp[r]
                break
        for w in workspaces_of(layout, o["name"]):
            path = wsp.get(w["name"]) if w.get("name") else None
            if not path:
                path = next((wsp[k] for r in rs.get(o["name"], []) if wsp.get(k := f"{r}#{w['idx']}")), None)
            if path:
                out["workspaces"][ws_key(w, _ident(o))] = path
    return out


def coverage(s: dict, layout: dict) -> int:
    """How many displays a set names by a specific role (not `*`)."""
    rs = roles(layout.get("outputs", []), layout.get("main"))
    disp = s.get("displays") or {}
    return sum(1 for o in layout.get("outputs", []) if any(disp.get(r) for r in rs.get(o["name"], []) if r != "*"))


def best_set(sets: list[dict], layout: dict) -> dict | None:
    """The set that covers the most displays of this layout (first on ties)."""
    best, n = None, 0
    for s in sets:
        c = coverage(s, layout)
        if c > n:
            best, n = s, c
    return best


def capture(name: str, layout: dict, effective: dict) -> dict:
    """The arrangement on screen as a set: each display's base image under
    its primary role, and each workspace that shows something else under its
    name (or <primary role>#<idx>).

    effective = {"displays": {identity: base path}, "workspaces": {ws key: path}}."""
    rs = roles(layout.get("outputs", []), layout.get("main"))
    out: dict = {"name": name, "displays": {}, "workspaces": {}}
    for o in layout.get("outputs", []):
        primary = rs[o["name"]][0]
        base = effective["displays"].get(_ident(o))
        if base:
            out["displays"][primary] = base
        for w in workspaces_of(layout, o["name"]):
            p = effective["workspaces"].get(ws_key(w, _ident(o)))
            if p and p != base:
                out["workspaces"][w["name"] or f"{primary}#{w['idx']}"] = p
    return out


# ── framing: where an image's interest is ─────────────────────────────────


def image_size(path: Path) -> tuple[int, int] | None:
    """(width, height) from the file header: PNG, JPEG, GIF, WebP; else None."""
    try:
        with open(path, "rb") as f:
            head = f.read(64)
            if head.startswith(b"\x89PNG\r\n\x1a\n"):
                return struct.unpack(">II", head[16:24])
            if head[:6] in (b"GIF87a", b"GIF89a"):
                return struct.unpack("<HH", head[6:10])
            if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
                kind = head[12:16]
                if kind == b"VP8X":
                    w = int.from_bytes(head[24:27], "little") + 1
                    h = int.from_bytes(head[27:30], "little") + 1
                    return w, h
                if kind == b"VP8L":
                    b = head[21:25]
                    w = 1 + (((b[1] & 0x3F) << 8) | b[0])
                    h = 1 + (((b[3] & 0xF) << 10) | (b[2] << 2) | ((b[1] & 0xC0) >> 6))
                    return w, h
                if kind == b"VP8 ":
                    w, h = struct.unpack("<HH", head[26:30])
                    return w & 0x3FFF, h & 0x3FFF
                return None
            if head.startswith(b"\xff\xd8"):
                f.seek(2)
                while True:
                    m = f.read(2)
                    if len(m) < 2 or m[0] != 0xFF:
                        return None
                    while m[1] == 0xFF:
                        m = m[:1] + f.read(1)
                    marker = m[1]
                    if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
                        continue
                    seg = f.read(2)
                    if len(seg) < 2:
                        return None
                    length = struct.unpack(">H", seg)[0]
                    if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                        h, w = struct.unpack(">HH", f.read(5)[1:5])
                        return w, h
                    f.seek(length - 2, os.SEEK_CUR)
    except (OSError, struct.error, IndexError):
        return None
    return None


def _grid(path: Path) -> tuple[int, int, list] | None:
    """(columns, rows, pixels) of a small sample of the image."""
    if palette.have_ffmpeg():
        px = palette.ffmpeg_sample(path)
        if len(px) == palette.SAMPLE_SIZE * palette.SAMPLE_SIZE:
            return palette.SAMPLE_SIZE, palette.SAMPLE_SIZE, px
    if palette.sniff(path) == "png":
        size = image_size(path)
        try:
            px = palette.decode_png(path.read_bytes())
        except Exception:  # noqa: BLE001 — unreadable: no framing
            return None
        if size:
            step = max(1, max(size) // palette.SAMPLE_SIZE)
            cols, rows = -(-size[0] // step), -(-size[1] // step)
            if cols * rows == len(px):
                return cols, rows, px
    return None


def _profile(weights: list[float], n: int) -> list[float]:
    total = sum(weights) or 1.0
    bins = [0.0] * FRAMING_BINS
    for i, w in enumerate(weights):
        bins[min(FRAMING_BINS - 1, i * FRAMING_BINS // n)] += w / total
    return [round(b, 4) for b in bins]


def framing(path: Path) -> dict | None:
    """{size: [w, h], focus: [fx, fy], cols, rows} of an image, or None.

    Interest is a cheap saliency: luminance edges plus how far each sampled
    pixel's color is from the image's mean color (and how colorful it is),
    squared so the peaks dominate. focus is its centroid (0..1 from the top
    left); cols / rows are its share per 1/16 of the width / height, so a
    crop's loss can be measured for any display shape (`capture`)."""
    path = Path(path)
    size = image_size(path)
    g = _grid(path)
    if g is None:
        return {"size": list(size), "focus": [0.5, 0.5], "cols": None, "rows": None} if size else None
    cols, rows, px = g
    labs = [color.to_lab("#%02x%02x%02x" % p) for p in px]
    n = len(labs)
    mean = [sum(lab[i] for lab in labs) / n for i in range(3)]
    lum = [lab[0] for lab in labs]
    dev = [math.sqrt(0.5 * (lab[0] - mean[0]) ** 2 + (lab[1] - mean[1]) ** 2 + (lab[2] - mean[2]) ** 2) for lab in labs]
    chroma = [math.hypot(lab[1], lab[2]) for lab in labs]
    edge = [0.0] * n
    for y in range(rows):
        for x in range(cols):
            i = y * cols + x
            e = 0.0
            if x + 1 < cols:
                e += abs(lum[i + 1] - lum[i])
            if y + 1 < rows:
                e += abs(lum[i + cols] - lum[i])
            edge[i] = e

    def norm(v: list[float]) -> list[float]:
        m = sum(v) / len(v) or 1.0
        return [x / m for x in v]

    en, dn, cn = norm(edge), norm(dev), norm(chroma)
    w = [(en[i] + dn[i] + 0.5 * cn[i]) ** 2 for i in range(n)]
    total = sum(w) or 1.0
    fx = sum(w[i] * ((i % cols) + 0.5) / cols for i in range(n)) / total
    fy = sum(w[i] * ((i // cols) + 0.5) / rows for i in range(n)) / total
    colw = [sum(w[y * cols + x] for y in range(rows)) for x in range(cols)]
    roww = [sum(w[y * cols : (y + 1) * cols]) for y in range(rows)]
    return {
        "size": list(size) if size else [cols, rows],
        "focus": [round(fx, 3), round(fy, 3)],
        "cols": _profile(colw, cols),
        "rows": _profile(roww, rows),
    }


def crop_window(focus: float, frac: float) -> tuple[float, float]:
    """The visible [start, end) (0..1) of a crop keeping `frac` of the image, centered on focus."""
    start = min(max(focus - frac / 2, 0.0), 1.0 - frac)
    return start, start + frac


def interest_kept(fr: dict | None, aspect: float) -> float:
    """Share (0..1) of the image's interest a display of this aspect (w / h)
    shows with the crop centered on the image's focus. 1 for unknown images."""
    if not fr or not fr.get("size"):
        return 1.0
    w, h = fr["size"]
    ai = w / max(h, 1)
    if abs(ai - aspect) / aspect < 0.02:
        return 1.0
    if ai > aspect:
        frac, prof, focus = aspect / ai, fr.get("cols"), fr["focus"][0]
    else:
        frac, prof, focus = ai / aspect, fr.get("rows"), fr["focus"][1]
    if not prof:
        return frac  # no profile: interest assumed even
    a, b = crop_window(focus, frac)
    kept = 0.0
    for i, share in enumerate(prof):
        lo, hi = i / len(prof), (i + 1) / len(prof)
        overlap = max(0.0, min(b, hi) - max(a, lo))
        kept += share * overlap * len(prof)
    return max(0.0, min(1.0, kept))


class FramingCache:
    """Image framing by content hash, in <state>/cache/framing.json."""

    VERSION = 1

    def __init__(self, state_dir: Path | None, palettes: vibes.PaletteCache):
        self.file = Path(state_dir) / "cache" / "framing.json" if state_dir else None
        self.palettes = palettes
        self.data: dict = {"version": self.VERSION, "items": {}}
        self.dirty = False
        if self.file and self.file.is_file():
            try:
                d = json.loads(self.file.read_text())
                if d.get("version") == self.VERSION:
                    self.data = d
            except (OSError, ValueError):
                pass

    def get(self, path: Path) -> dict | None:
        digest = self.palettes.digest(Path(path))
        if digest is None:
            return None
        items = self.data["items"]
        if digest not in items:
            items[digest] = framing(Path(path))
            self.dirty = True
        return items[digest]

    def save(self) -> None:
        if not (self.dirty and self.file):
            return
        try:
            self.file.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.file.with_name(f".{self.file.name}.{os.getpid()}")
            tmp.write_text(json.dumps(self.data))
            os.replace(tmp, self.file)
            self.dirty = False
        except OSError:
            pass


# ── the auto pool and plan ──────────────────────────────────────────────────


def target_tone(rank_result: dict, cache: vibes.PaletteCache) -> str:
    """The theme's light/dark level: its default wallpaper's tone, else by polarity."""
    d = rank_result.get("defaults", {}).get("wallpaper")
    img = cache.get(Path(d)) if d else None
    if img and img.get("swatches"):
        return library.classify(img["swatches"])["tone"]
    return "Light" if rank_result.get("polarity") == "light" else "Dark"


def candidates(rank_result: dict, cache: vibes.PaletteCache, frames: FramingCache) -> list[dict]:
    """The theme's vibe stills that may be auto-picked: own and curated, plus
    matches scoring at least library.THEME_MIN_SCORE, with tone, color
    families, swatches and framing."""
    out = []
    for e in rank_result.get("wallpapers", []):
        if e.get("kind") != "image":
            continue
        if e.get("origin") == "match" and e.get("score", 0.0) < library.THEME_MIN_SCORE:
            continue
        img = cache.get(Path(e["path"]))
        if not img or not img.get("swatches"):
            continue
        cls = library.classify(img["swatches"])
        fr = frames.get(Path(e["path"]))
        out.append(
            {
                "path": e["path"],
                "thumb": e.get("thumb", ""),
                "origin": e.get("origin", "match"),
                "source_pack": e.get("source_pack", ""),
                "topic": e.get("topic", ""),
                "distance": e.get("distance", 0.0),
                "score": e.get("score", 1.0),
                "tone": cls["tone"],
                "colors": cls["colors"],
                "lightness": cls["lightness"],
                "swatches": [tuple(s) for s in img["swatches"]],
                "framing": fr,
            }
        )
    return out


def _tone_cost(a: str, b: str) -> float:
    if a == b:
        return 0.0
    return TONE_NEAR if "Medium" in (a, b) else TONE_FAR


def _jitter(seed: int, theme: str, slot: str, path: str) -> float:
    h = hashlib.sha1(f"{seed}\0{theme}\0{slot}\0{path}".encode()).digest()
    return int.from_bytes(h[:8], "big") / 2**64


def _ref(path: str | None, pool_by_path: dict, cache: vibes.PaletteCache) -> dict | None:
    """Tone / families / swatches of a base image (in the pool or not)."""
    if not path:
        return None
    if path in pool_by_path:
        c = pool_by_path[path]
        return {"tone": c["tone"], "colors": c["colors"], "swatches": c["swatches"]}
    img = cache.get(Path(path))
    if not img or not img.get("swatches"):
        return None
    cls = library.classify(img["swatches"])
    return {"tone": cls["tone"], "colors": cls["colors"], "swatches": [tuple(s) for s in img["swatches"]]}


def plan(
    theme: str,
    layout: dict,
    pool: list[dict],
    choices: dict,
    *,
    tone: str,
    cache: vibes.PaletteCache,
    pack_set: dict | None = None,
) -> dict:
    """Auto picks for every display without a base image and every workspace
    without a choice: {"displays": {identity: path}, "workspaces": {ws key: path},
    "why": {slot: reason}}. See the module docstring for the costs."""
    seed = int(choices.get("autoSeed", 0) or 0)
    disp_choice = choices.get("displays") or {}
    ws_choice = choices.get("workspaces") or {}
    same_all = choices.get("sameAll") or {}
    theme_choice = choices.get("wallpaper") or ""
    pset = pack_set or {"displays": {}, "workspaces": {}}
    by_path = {c["path"]: c for c in pool}

    # Images are told apart by content (a choice may name a library view's
    # symlink, the pool the real file).
    digests: dict[str, str] = {}

    def same(p: str) -> str:
        if p not in digests:
            digests[p] = cache.digest(Path(p)) or p
        return digests[p]

    used: dict[str, int] = {}
    for p in list(disp_choice.values()) + list(ws_choice.values()) + [theme_choice] + list(pset["displays"].values()) + list(pset["workspaces"].values()):
        if p:
            used[same(p)] = used.get(same(p), 0) + 1

    out: dict = {"displays": {}, "workspaces": {}, "why": {}}
    # The family the whole arrangement leans to: the main display's base.
    lean: list[str] = []

    def pick(slot: str, out_aspect: float, ref: dict | None, slot_tone: str) -> str | None:
        families = set(ref["colors"]) if ref else set(lean)
        best, best_cost, best_why = None, math.inf, ""
        avoid = same(ref["path"]) if ref else None
        for c in pool:
            if same(c["path"]) == avoid:
                continue
            color_d = vibes.swatch_distance(ref["swatches"], c["swatches"]) if ref else c["distance"]
            tc = _tone_cost(c["tone"], slot_tone)
            if tc >= TONE_FAR:
                continue  # never the opposite light/dark level
            fc = FAMILY_MISS if families and not families & set(c["colors"]) else 0.0
            kept = interest_kept(c["framing"], out_aspect)
            cost = color_d + tc + fc + (1.0 - kept) * FIT_WEIGHT + _jitter(seed, theme, slot, c["path"]) * JITTER
            if ref and Path(c["path"]).parent == Path(ref["path"]).parent:
                cost -= SAME_FOLDER
            cost += used.get(same(c["path"]), 0) * 1000.0  # distinct while the pool lasts
            if cost < best_cost:
                best, best_cost = c["path"], cost
                best_why = f"color {color_d:.1f} · {c['tone']} · {'+'.join(c['colors'])} · keeps {kept:.0%}"
        if best:
            used[same(best)] = used.get(same(best), 0) + 1
            out["why"][slot] = best_why
        return best

    for o in ordered_outputs(layout):
        ident = _ident(o)
        aspect = o["width"] / max(o["height"], 1)
        base = disp_choice.get(ident) or disp_choice.get(o["name"]) or theme_choice or pset["displays"].get(ident)
        if not base:
            base = pick(f"display:{ident}", aspect, None, tone)
            if base:
                out["displays"][ident] = base
        ref = _ref(base, by_path, cache)
        if ref is not None:
            ref["path"] = base
            if not lean:
                lean = list(ref["colors"])
        if same_all.get(ident):
            continue
        for w in workspaces_of(layout, o["name"]):
            if w["idx"] <= 1:
                continue  # the display's first workspace shows its base
            key = ws_key(w, ident)
            if ws_choice.get(key) or pset["workspaces"].get(key):
                continue
            p = pick(f"workspace:{key}", aspect, ref, ref["tone"] if ref else tone)
            if p:
                out["workspaces"][key] = p
    return out


def effective(layout: dict, choices: dict, auto_plan: dict | None, pack_set: dict | None, auto_on: bool, default: str = "") -> dict:
    """What every display (its base) and workspace shows, by the shell's rules
    (module docstring; rotation aside: `default` stands in) — for `capture`."""
    disp_choice = choices.get("displays") or {}
    ws_choice = choices.get("workspaces") or {}
    same_all = choices.get("sameAll") or {}
    theme_choice = choices.get("wallpaper") or ""
    pset = pack_set or {"displays": {}, "workspaces": {}}
    ap = auto_plan if auto_on and auto_plan else {"displays": {}, "workspaces": {}}
    out: dict = {"displays": {}, "workspaces": {}}
    for o in layout.get("outputs", []):
        ident = _ident(o)
        base = disp_choice.get(ident) or disp_choice.get(o["name"]) or theme_choice or pset["displays"].get(ident) or ap["displays"].get(ident) or default
        out["displays"][ident] = base
        for w in workspaces_of(layout, o["name"]):
            key = ws_key(w, ident)
            p = ""
            if not same_all.get(ident):
                p = ws_choice.get(key) or pset["workspaces"].get(key) or ""
                if not p and w["idx"] > 1:
                    p = ap["workspaces"].get(key) or ""
            out["workspaces"][key] = p or base
    return out


def has_explicit(choices: dict) -> bool:
    """The user picked something for this theme (a pack's set then stays out)."""
    return bool(choices.get("wallpaper") or choices.get("displays") or choices.get("workspaces"))


# ── shell.json (the shell's overrides) ──────────────────────────────────────


def shell_file(state_dir: Path) -> Path:
    return Path(state_dir) / "overrides" / "shell.json"


def load_shell(state_dir: Path) -> dict:
    try:
        d = json.loads(shell_file(state_dir).read_text())
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def save_shell(state_dir: Path, data: dict) -> None:
    """Atomic replace; the running shell watches the file and reloads it."""
    f = shell_file(state_dir)
    f.parent.mkdir(parents=True, exist_ok=True)
    tmp = f.with_name(f".{f.name}.{os.getpid()}")
    tmp.write_text(json.dumps(data, indent=4) + "\n")
    os.replace(tmp, f)


def theme_choices(shell: dict, theme: str) -> dict:
    pt = shell.get("perTheme") if isinstance(shell.get("perTheme"), dict) else {}
    c = pt.get(theme)
    return c if isinstance(c, dict) else {}


def set_theme_choices(shell: dict, theme: str, choices: dict) -> dict:
    pt = dict(shell.get("perTheme") or {})
    pt[theme] = choices
    return dict(shell, perTheme=pt)
