"""Vibes: which wallpapers and lock designs go with a theme.

A theme's vibe set, in order:

  own      the pack's own wallpapers and lock designs (pack.py)
  curated  links the pack's manifest (`vibes`) or the themes index declares
           to other packs' assets; resolved only when those packs are installed
  match    every other installed pack's wallpapers and locks (plus loose images
           from extra directories), ranked by how close their colors are

Closeness is a palette distance in CIELAB: CIEDE2000 between the semantic
roles, weighted (bg 3, accent 2, surface/text/accent2 1; the two accents
are matched either way round, so a pink/blue theme is close to a blue/pink
one), averaged, plus a flat penalty when the polarities differ. Roughly: < 10
is the same vibe, 10-20 related, 30+ unrelated.

An asset's distance is the mean of two measures: its source pack's palette
vs the theme's (above), and its image vs the theme's default wallpaper (for
a lock: its background, else its pack's wallpaper). Images are compared by
their color distributions: median cut + k-means swatches (palette.py), each
swatch's CIEDE2000 to the nearest swatch of the other image, weighted by its
share, both ways. That also ranks loose images that belong to no pack.
Swatches (and a role-mapped palette for preview cards) are cached by content
hash in <state>/cache/palettes.json.
"""

from __future__ import annotations

import functools
import hashlib
import json
import math
import os
from pathlib import Path

from . import color, index, palette
from .pack import IMAGE_EXT, Pack, PackError, lock_json, media_kind, wallpaper_json

ROLE_WEIGHTS = {"bg": 3.0, "surface": 1.0, "text": 1.0}
ACCENT_WEIGHTS = (2.0, 1.0)  # accent, accent2
POLARITY_PENALTY = 20.0
SCORE_SCALE = 30.0
CARD_ROLES = ("bg", "surface", "text", "subtext", "accent", "accent2")


@functools.lru_cache(maxsize=4096)
def _lab(c: str) -> tuple[float, float, float]:
    return color.to_lab(color.hex6(c))


def _de(a: str, b: str) -> float:
    return color.delta_e(_lab(a), _lab(b))


def palette_distance(a: dict, b: dict, polarity_a: str = "dark", polarity_b: str = "dark") -> float:
    """Weighted mean CIEDE2000 between two palettes (+ polarity penalty)."""
    total = sum(w * _de(a[r], b[r]) for r, w in ROLE_WEIGHTS.items())
    wa, wb = ACCENT_WEIGHTS
    straight = wa * _de(a["accent"], b["accent"]) + wb * _de(a["accent2"], b["accent2"])
    crossed = wa * _de(a["accent"], b["accent2"]) + wb * _de(a["accent2"], b["accent"])
    d = (total + min(straight, crossed)) / (sum(ROLE_WEIGHTS.values()) + wa + wb)
    if (polarity_a == "light") != (polarity_b == "light"):
        d += POLARITY_PENALTY
    return d


# A theme palette as a pseudo image: how much of the screen each role covers.
PALETTE_COVERAGE = {"bg": 0.5, "surface": 0.2, "accent": 0.12, "accent2": 0.08, "text": 0.1}


def palette_swatches(pal: dict) -> list[tuple[str, float]]:
    return [(color.hex6(pal[r]), w) for r, w in PALETTE_COVERAGE.items() if isinstance(pal.get(r), str)]


def swatch_distance(a: list, b: list) -> float:
    """How far apart two color distributions are: every swatch's CIEDE2000 to
    the nearest swatch of the other set, weighted by its share, both ways."""
    if not a or not b:
        return float("inf")

    def one(x, y) -> float:
        total = sum(w for _, w in x) or 1.0
        return sum(w * min(_de(c, d) for d, _ in y) for c, w in x) / total

    return (one(a, b) + one(b, a)) / 2


def score(distance: float) -> float:
    """0..1 similarity for display (1 = identical)."""
    return math.exp(-distance / SCORE_SCALE)


# ── image palettes (cached) ─────────────────────────────────────────────────


class PaletteCache:
    """Image → {swatches, polarity, palette}, keyed by the file's SHA-1.

    `swatches` are the quantized colors with their shares (what images are
    compared by); polarity + palette are those swatches mapped to roles (for
    preview cards and comparing an image to a theme). A stat index (path,
    size, mtime) avoids rehashing unchanged files."""

    VERSION = 2

    def __init__(self, state_dir: Path | None):
        self.file = Path(state_dir) / "cache" / "palettes.json" if state_dir else None
        self.data: dict = {"version": self.VERSION, "stat": {}, "palettes": {}}
        self.dirty = False
        if self.file and self.file.is_file():
            try:
                d = json.loads(self.file.read_text())
                if d.get("version") == self.VERSION:
                    self.data = d
            except (OSError, ValueError):
                pass

    def _hash(self, path: Path) -> str | None:
        try:
            st = path.stat()
        except OSError:
            return None
        key = str(path)
        sig = [st.st_size, st.st_mtime_ns]
        hit = self.data["stat"].get(key)
        if hit and hit[:2] == sig:
            return hit[2]
        h = hashlib.sha1()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        digest = h.hexdigest()
        self.data["stat"][key] = sig + [digest]
        self.dirty = True
        return digest

    def get(self, path: Path) -> dict | None:
        """{"swatches", "polarity", "palette"} of an image (or a video's frame), None if unreadable."""
        digest = self._hash(Path(path))
        if digest is None:
            return None
        if digest in self.data["palettes"]:
            return self.data["palettes"][digest]
        swatches = palette.quantize(palette.sample(Path(path)))
        result = None
        if swatches:
            pol, pal = palette.scheme(swatches=swatches)
            result = {"swatches": [[c, round(w, 4)] for c, w in swatches], "polarity": pol, "palette": pal}
        self.data["palettes"][digest] = result
        self.dirty = True
        return result

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


# ── curated links ───────────────────────────────────────────────────────────


def links(pack: Pack, idx: dict) -> dict[str, list[str]]:
    """The pack's curated refs: its manifest `vibes` plus the index's."""
    return index.merge_links((pack.manifest or {}).get("vibes"), index.links_for(idx, pack.name))


def resolve(pack: Pack, packs: dict[str, Pack], idx: dict) -> dict[str, list[dict]]:
    """Curated refs → wallpaper / lock entries (JSON, absolute paths) of the
    installed packs they name; refs to missing packs or files are skipped."""
    refs = links(pack, idx)
    walls: list[dict] = []
    locks: list[dict] = []
    for ref in refs["wallpapers"]:
        name, _, item = ref.partition(":")
        other = packs.get(name)
        if other is None or other.name == pack.name:
            continue
        entries = other.wallpaper_entries()
        if item:
            target = other.abspath(item)
            hit = [e for e in entries if e["path"] == target or e.get("video") == target]
            if not hit and target.is_file() and other.path in target.parents and media_kind(target):
                hit = [{"path": target, "kind": media_kind(target)}]
            entries = hit
        walls += [wallpaper_json(e, other.name) for e in entries]
    for ref in refs["locks"]:
        name, _, item = ref.partition(":")
        other = packs.get(name)
        if other is None or other.name == pack.name:
            continue
        locks += [lock_json(e, other.name) for e in other.lock_entries() if not item or e["name"] == item]
    return {"wallpapers": _dedupe(walls), "locks": _dedupe(locks)}


def _dedupe(entries: list[dict]) -> list[dict]:
    seen: set[str] = set()
    out = []
    for e in entries:
        if e["path"] not in seen:
            seen.add(e["path"])
            out.append(e)
    return out


# ── ranking ─────────────────────────────────────────────────────────────────


def _pal(pack: Pack) -> tuple[str, dict] | None:
    pal = pack.theme.get("palette")
    if not isinstance(pal, dict) or not all(isinstance(pal.get(r), str) for r in ("bg", "surface", "text", "accent", "accent2")):
        return None
    return pack.theme.get("polarity", "dark"), pal


def _card(pol: str, pal: dict) -> dict:
    return {"polarity": pol, **{r: color.hex6(pal[r]) for r in CARD_ROLES if isinstance(pal.get(r), str)}}


def loose_images(directory: Path) -> list[Path]:
    try:
        return sorted(p for p in Path(directory).expanduser().iterdir() if p.is_file() and p.suffix.lower() in IMAGE_EXT)
    except OSError:
        return []


def rank(
    target: Pack,
    packs: dict[str, Pack],
    *,
    idx: dict | None = None,
    cache: PaletteCache | None = None,
    dirs: list[Path] | None = None,
    limit: int | None = None,
) -> dict:
    """The vibe set of `target`: own, curated, then ranked matches."""
    idx = idx or {}
    cache = cache or PaletteCache(None)
    tp = _pal(target)
    if tp is None:
        raise PackError(f"{target.path}: theme.json has no usable palette")
    tpol, tpal = tp
    other_pal: dict[str, tuple[str, dict]] = {}
    pack_d: dict[str, float] = {}
    for name, p in packs.items():
        pp = _pal(p)
        if pp is not None:
            other_pal[name] = pp
            pack_d[name] = palette_distance(tpal, pp[1], tpol, pp[0])

    # The theme's imagery: its default wallpaper's colors (else its palette
    # as a pseudo image). An asset is measured palette-to-palette (theme vs
    # its source pack) and image-to-image (swatches of the theme's wallpaper
    # vs the asset's image), so a dark UI with a light pink wallpaper still
    # finds other light pink wallpapers.
    tdef = target.default_wallpaper()
    timg = cache.get(tdef["path"]) if tdef else None
    tswatches = [tuple(x) for x in timg["swatches"]] if timg else palette_swatches(tpal)

    def distance(entry: dict, image: str | None) -> tuple[float | None, dict | None]:
        img = cache.get(Path(image)) if image else None
        ds = []
        if entry.get("source_pack") in pack_d and entry["source_pack"] != target.name:
            ds.append(pack_d[entry["source_pack"]])
        if img:
            ds.append(swatch_distance(tswatches, [tuple(x) for x in img["swatches"]]))
        return (sum(ds) / len(ds) if ds else None), img

    def decorate(entry: dict, origin: str, measure: bool) -> dict:
        e = dict(entry, origin=origin)
        e.pop("curated", None)
        is_lock = "kind" not in e
        if is_lock:  # colors + backdrop for a preview card
            src = other_pal.get(e["source_pack"], (tpol, tpal))
            e["palette"] = _card(*src)
            if "background" not in e and e["source_pack"] in packs:
                d = packs[e["source_pack"]].default_wallpaper()
                if d and d["kind"] == "image":
                    e["background"] = str(d["path"])
        if measure:
            d, img = distance(e, e.get("background") if is_lock else e["path"])
            if d is not None:
                e["distance"] = round(d, 2)
                e["score"] = round(score(d), 3)
            if img and not is_lock:
                e["palette"] = _card(img["polarity"], img["palette"])
        return e

    own_w = [decorate(wallpaper_json(e, target.name), "own", False) for e in target.wallpaper_entries()]
    own_l = [decorate(lock_json(e, target.name), "own", False) for e in target.lock_entries()]
    cur = resolve(target, packs, idx)
    cur_w = [decorate(e, "curated", True) for e in cur["wallpapers"]]
    cur_l = [decorate(e, "curated", True) for e in cur["locks"]]
    seen_w = {e["path"] for e in own_w + cur_w}
    seen_l = {e["path"] for e in own_l + cur_l}

    match_w: list[dict] = []
    match_l: list[dict] = []
    for name, p in packs.items():
        if name == target.name:
            continue
        for e in p.wallpaper_entries():
            j = wallpaper_json(e, name)
            if j["path"] not in seen_w:
                seen_w.add(j["path"])
                match_w.append(decorate(j, "match", True))
        for e in p.lock_entries():
            j = lock_json(e, name)
            if j["path"] not in seen_l:
                seen_l.add(j["path"])
                match_l.append(decorate(j, "match", True))
    for d in dirs or []:
        for img in loose_images(d):
            if str(img) not in seen_w:
                seen_w.add(str(img))
                match_w.append(decorate({"path": str(img), "source_pack": "", "kind": "image", "folder": str(d)}, "match", True))

    def key(e: dict):
        return (e.get("distance") is None, e.get("distance") or 0.0, e["source_pack"], e["path"])

    match_w.sort(key=key)
    match_l.sort(key=key)
    if limit is not None:
        match_w, match_l = match_w[:limit], match_l[:limit]
    default_wall = target.default_wallpaper()
    return {
        "theme": target.name,
        "polarity": tpol,
        "palette": _card(tpol, tpal),
        "defaults": {
            "wallpaper": str(default_wall["path"]) if default_wall else "",
            "lock": own_l[0]["path"] if own_l else "",
        },
        "wallpapers": own_w + cur_w + match_w,
        "locks": own_l + cur_l + match_l,
    }
