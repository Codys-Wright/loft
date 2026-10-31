"""The themes index (loft-themes `index.json`): read it, look entries up,
and the curated vibe links and palettes it declares.

The index lives in the separate Codys-Wright/loft-themes repo (PLAN §8.3),
generated there by `loft theme index build` (indexgen.py) from its packs/,
catalog.json and the importers' upstream catalogs.

Where it comes from: $LOFT_THEME_INDEX, a local path, a file:// URL or an
http(s) URL; `none` turns it off. Default: the GitHub raw URL of
Codys-Wright/loft-themes. A remote index is cached in
<state>/cache/index.json and refetched at most once a day (short timeout);
when it can't be reached, the stale copy is used, else nothing. Nothing that
reads the index for vibes ever fails because of it; `loft theme browse` and
`install NAME` say when there is none.

Format (version 2; docs/THEME-FORMAT.md, "Themes index"):

  {"version": 2, "repo": URL,
   "importers": {"qylock": {"source": URL, "license", "description", "commit"}, …},
   "entries": [{"name": "qylock-pixel-sakura", "title", "description",
                "collection": "qylock", "theme": "qylock-pixel-sakura",
                "tags": […], "license",
                "source": {"importer": "qylock", "id": "pixel-sakura", "rev"?}
                        | {"git": URL, "rev": "main", "path": "packs/NAME"},
                "preview": {"image"?, "polarity", "palette": {…}, "paletteFrom"}?,
                "curated": {"polarity"?, "palette": {…}}?}, …],
   "vibes": [groups, below]}

`curated` is a hand-checked palette mapping for an imported theme: the
importers derive a palette (upstream config colors, else extracted from the
background), and a curated mapping, when the index has one, is laid over it
at install time (PLAN §8.2). A version-1 index (no "entries") still reads:
its importers' `themes` lists and its `packs` map become entries.

Vibe links (`"vibes"` in the index):

  {"name": "sakura", "packs": ["cozytile-sakura", "qylock-pixel-sakura"],
   "wallpapers": ["<pack>:<file>"…], "locks": ["<pack>:<lock>"…]}

Every pack of a group gets the other members' wallpapers and lock designs
(plus the group's own refs) as curated vibes, resolved only for packs that
are installed.
"""

from __future__ import annotations

import difflib
import json
import os
import re
import time
import urllib.request
from pathlib import Path

DEFAULT_URL = "https://raw.githubusercontent.com/Codys-Wright/loft-themes/main/index.json"
MAX_AGE = 24 * 3600
TIMEOUT = 3.0
VERSION = 2
PALETTE_KEYS = ("bg", "surface", "overlay", "text", "subtext", "accent", "accent2", "urgent", "ok", "warn")
OWN = "loft-themes"  # the collection of the index repo's own packs
HEX = re.compile(r"^#[0-9a-fA-F]{6}$")


class IndexLookupError(LookupError):
    """No index, or no (single) entry by that name."""


def source() -> str:
    return os.environ.get("LOFT_THEME_INDEX", DEFAULT_URL).strip()


def disabled() -> bool:
    return source() in ("", "none", "off")


def cache_path(state_dir: Path | None) -> Path | None:
    return Path(state_dir) / "cache" / "index.json" if state_dir else None


def load(state_dir: Path | None = None, *, refresh: bool = False) -> dict:
    """The index as a dict ({} when disabled or unreachable)."""
    src = source()
    if disabled():
        return {}
    if src.startswith("file://"):
        src = src[len("file://") :]
    if not src.startswith(("http://", "https://")):
        return _read(Path(src).expanduser())
    cache = cache_path(state_dir)
    if cache and cache.is_file() and not refresh and time.time() - cache.stat().st_mtime < MAX_AGE:
        data = _read(cache)
        if data.get("_source") == src:
            return data
    try:
        with urllib.request.urlopen(src, timeout=TIMEOUT) as r:  # noqa: S310 — configured index URL
            data = json.loads(r.read().decode())
        if not isinstance(data, dict):
            raise ValueError("not an object")
    except (OSError, ValueError):
        stale = _read(cache) if cache else {}
        return stale if stale.get("_source") == src else {}
    if cache:
        try:
            cache.parent.mkdir(parents=True, exist_ok=True)
            tmp = cache.with_suffix(".tmp")
            tmp.write_text(json.dumps(dict(data, _source=src)))
            os.replace(tmp, cache)
        except OSError:
            pass
    return data


def _read(path: Path) -> dict:
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def groups(index: dict) -> list[dict]:
    v = index.get("vibes")
    return [g for g in v if isinstance(g, dict)] if isinstance(v, list) else []


def links_for(index: dict, pack: str) -> dict[str, list[str]]:
    """{"wallpapers": [refs], "locks": [refs]} the index curates for `pack`."""
    out: dict[str, list[str]] = {"wallpapers": [], "locks": []}
    for g in groups(index):
        members = [m for m in g.get("packs", []) if isinstance(m, str)]
        if pack not in members:
            continue
        for kind in out:
            for other in members:
                if other != pack and other not in out[kind]:
                    out[kind].append(other)
            for ref in g.get(kind, []):
                if isinstance(ref, str) and not ref.startswith(pack + ":") and ref != pack and ref not in out[kind]:
                    out[kind].append(ref)
    return out


def merge_links(*parts: dict) -> dict[str, list[str]]:
    out: dict[str, list[str]] = {"wallpapers": [], "locks": []}
    for p in parts:
        for kind in out:
            for ref in (p or {}).get(kind, []) if isinstance(p, dict) else []:
                if isinstance(ref, str) and ref not in out[kind]:
                    out[kind].append(ref)
    return out


# ── entries ─────────────────────────────────────────────────────────────────


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9._-]+", "-", text.lower()).strip("-")


def entries(index: dict) -> list[dict]:
    """The index's entries, normalized (name, title, collection, source and
    tags always present). A version-1 index's `packs` map and importer
    `themes` lists are turned into entries."""
    raw = index.get("entries")
    out: list[dict] = []
    if isinstance(raw, list):
        out = [e for e in raw if isinstance(e, dict) and isinstance(e.get("name"), str) and isinstance(e.get("source"), dict)]
    else:
        packs = index.get("packs")
        for name, e in packs.items() if isinstance(packs, dict) else []:
            if isinstance(e, dict) and isinstance(e.get("source"), (str, dict)):
                src = e["source"] if isinstance(e["source"], dict) else {"git": e["source"]}
                out.append(dict(e, name=name, source=src))
        imps = index.get("importers")
        for imp, info in imps.items() if isinstance(imps, dict) else []:
            for t in (info.get("themes") or []) if isinstance(info, dict) else []:
                if isinstance(t, str):
                    out.append({"name": f"{imp}-{slug(t)}", "title": t, "collection": imp, "source": {"importer": imp, "id": t}})
    norm = []
    for e in out:
        e = dict(e)
        e.setdefault("title", e["name"])
        e.setdefault("collection", e["source"].get("importer") or OWN)
        e["tags"] = [t for t in e.get("tags") or [] if isinstance(t, str)]
        norm.append(e)
    return norm


def install_ref(entry: dict) -> tuple[str, str, str | None, str | None]:
    """How to install an entry: ("importer", "qylock:pixel-sakura[@rev]", None, None),
    ("git", url, rev, path) or ("url", tarball url, None, path)."""
    src = entry.get("source") or {}
    if src.get("importer"):
        ref = f"{src['importer']}:{src.get('id') or entry['name']}"
        return "importer", ref + (f"@{src['rev']}" if src.get("rev") else ""), None, None
    if src.get("git"):
        return "git", src["git"], src.get("rev") or None, src.get("path") or None
    if src.get("url"):
        return "url", src["url"], None, src.get("path") or None
    raise IndexLookupError(f"{entry['name']}: the index entry has no usable source")


def _aliases(e: dict) -> list[str]:
    theme = e.get("theme") or ""
    out = [theme]
    src = e.get("source") or {}
    if src.get("importer") and src.get("id"):
        out.append(f"{src['importer']}:{src['id']}")
    return [n.lower() for n in out if n]


def find(index: dict, name: str) -> dict:
    """The entry `name` names: its name, else the theme it becomes
    (`cozytile@sakura`) or `importer:id`, else an upstream id or title only
    one entry has."""
    want = name.strip().lower()
    es = entries(index)
    for e in es:
        if want == e["name"].lower():
            return e
    for test in (
        lambda e: want in _aliases(e),
        lambda e: want in (str((e.get("source") or {}).get("id", "")).lower(), e["title"].lower()),
    ):
        hits = [e for e in es if test(e)]
        if len(hits) == 1:
            return hits[0]
        if len(hits) > 1:
            raise IndexLookupError(f"'{name}' is ambiguous in the themes index: {', '.join(e['name'] for e in hits)}")
    close = difflib.get_close_matches(want, [e["name"] for e in es], n=3, cutoff=0.6)
    raise IndexLookupError(f"no '{name}' in the themes index" + (f" (did you mean {', '.join(close)}?)" if close else ""))


def vibe_names(index: dict) -> dict[str, list[str]]:
    """{pack name: [vibe group names]}."""
    out: dict[str, list[str]] = {}
    for g in groups(index):
        for p in g.get("packs", []):
            if isinstance(p, str) and isinstance(g.get("name"), str):
                out.setdefault(p, []).append(g["name"])
    return out


def search(index: dict, query: str = "", collection: str | None = None) -> list[dict]:
    """Entries whose name, title, theme, description, collection, tags or
    vibe groups contain every word of `query` (case-insensitive); the index
    repo's own packs first, then by collection and name."""
    words = query.lower().split()
    vibes = vibe_names(index)
    out = []
    for e in entries(index):
        if collection and e["collection"] != collection:
            continue
        hay = " ".join(
            [e["name"], e["title"], e.get("theme") or "", e.get("description") or "", e["collection"], *e["tags"], *vibes.get(e["name"], [])]
        ).lower()
        if all(w in hay for w in words):
            out.append(e)
    return sorted(out, key=lambda e: (e["collection"] != OWN, e["collection"], e["name"]))


# ── curated palettes (PLAN §8.2) ────────────────────────────────────────────


def clean_curated(c) -> dict | None:
    """A curated mapping with only valid keys ({"polarity"?, "palette"}), or None."""
    if not isinstance(c, dict):
        return None
    pal = c.get("palette") if isinstance(c.get("palette"), dict) else {}
    pal = {k: v.lower() for k, v in pal.items() if k in PALETTE_KEYS and isinstance(v, str) and HEX.match(v)}
    pol = c.get("polarity") if c.get("polarity") in ("dark", "light") else None
    if not pal and not pol:
        return None
    return {**({"polarity": pol} if pol else {}), "palette": pal}


def curated_for(index: dict, pack: str) -> dict | None:
    """The curated palette mapping the index has for a (v1) pack name."""
    for e in entries(index) if index else []:
        if e["name"] == pack:
            return clean_curated(e.get("curated"))
    return None


def preview(entry: dict) -> dict:
    """An entry's preview with its curated mapping laid over the derived
    palette (paletteFrom "curated" when it has one)."""
    pv = dict(entry["preview"]) if isinstance(entry.get("preview"), dict) else {}
    c = clean_curated(entry.get("curated"))
    if c:
        pv["palette"] = {**(pv.get("palette") or {}), **c["palette"]}
        pv["polarity"] = c.get("polarity") or pv.get("polarity") or "dark"
        pv["paletteFrom"] = "curated"
    return pv


def apply_curated(theme: dict, curated: dict) -> dict:
    """A v1 theme.json with the curated mapping laid over its palette."""
    out = dict(theme)
    out["palette"] = {**(theme.get("palette") or {}), **curated.get("palette", {})}
    if curated.get("polarity"):
        out["polarity"] = curated["polarity"]
    return out
