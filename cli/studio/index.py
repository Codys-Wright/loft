"""The themes index (studio-linux-themes `index.json`): read it, and the
curated vibe links it declares between packs.

Where it comes from: $STUDIO_THEME_INDEX, a local path, a file:// URL or an
http(s) URL; `none` turns it off. Default: the GitHub raw URL of
Codys-Wright/studio-linux-themes. A remote index is cached in
<state>/cache/index.json and refetched at most once a day (short timeout);
when it can't be reached, the stale copy is used, else nothing. Nothing that
reads the index ever fails because of it.

Vibe links (`"vibes"` in the index):

  {"name": "sakura", "packs": ["cozytile-sakura", "qylock-pixel-sakura"],
   "wallpapers": ["<pack>:<file>"…], "locks": ["<pack>:<lock>"…]}

Every pack of a group gets the other members' wallpapers and lock designs
(plus the group's own refs) as curated vibes, resolved only for packs that
are installed.
"""

from __future__ import annotations

import json
import os
import time
import urllib.request
from pathlib import Path

DEFAULT_URL = "https://raw.githubusercontent.com/Codys-Wright/studio-linux-themes/main/index.json"
MAX_AGE = 24 * 3600
TIMEOUT = 3.0


def source() -> str:
    return os.environ.get("STUDIO_THEME_INDEX", DEFAULT_URL).strip()


def load(state_dir: Path | None = None, *, refresh: bool = False) -> dict:
    """The index as a dict ({} when disabled or unreachable)."""
    src = source()
    if src in ("", "none", "off"):
        return {}
    if src.startswith("file://"):
        src = src[len("file://") :]
    if not src.startswith(("http://", "https://")):
        return _read(Path(src).expanduser())
    cache = Path(state_dir) / "cache" / "index.json" if state_dir else None
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
        return _read(cache) if cache else {}
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
