"""Unit `manifest`: manifest.json, what the lock screen loader and the
shell's pickers read: identity, the wallpaper collection (the theme's own,
then curated links), the lock designs (the selected one, then the rest of
its pack, then curated), the defaults and the pack's wallpaper sets.

Keys and order are v1's `normalized_manifest`, so v1 consumers see no change.
The lock reads it at every lock, so it has no reload hook.
"""

from __future__ import annotations

import json
from pathlib import Path

from ..pack import lock_json, read_kv, wallpaper_json
from . import wallpapers as W
from .identity import identity, v1_info
from .unit import Source, Unit


def _lock_entry(name: str, data: dict) -> dict | None:
    if data.get("format") in (None, "builtin") or not data.get("path"):
        return None
    path = Path(data["path"])
    main = data.get("main")
    if not main:
        meta = read_kv(path / "metadata.desktop")
        main = str(path / (meta.get("MainScript") or "Main.qml")) if data["format"] == "qylock" else str(path / "Main.qml")
    e = {"name": name, "format": data["format"], "path": path, "main": Path(main)}
    e.update({k: Path(data[k]) for k in ("preview", "background") if data.get(k)})
    return e


def document(src: Source) -> dict:
    res, catalog = src.res, src.catalog
    t = res.theme
    doc = t.doc
    ident = identity(res)
    pack_meta = catalog.pack_meta(t.pack)
    colors_doc = res.origins["colors"].doc if res.origins.get("colors") else {}
    v = t.variant(res.variant)
    base = doc.get("base") if isinstance(doc.get("base"), dict) else {}
    out = {
        "name": res.name,
        "author": ident.get("author", pack_meta.get("author", "")),
        "version": ident.get("version") or pack_meta.get("version") or "0.0.0",
        "license": ident.get("license") or colors_doc.get("license") or pack_meta.get("license") or "NOASSERTION",
        "source": ident.get("source") or colors_doc.get("source") or pack_meta.get("source") or "",
        "description": (v or {}).get("description") or base.get("description") or doc.get("description", ""),
    }
    if isinstance(ident.get("upstream"), dict):
        out["upstream"] = ident["upstream"]
    curated = src.curated or {}
    wdata = src.facet("wallpapers")
    entries = W.collection(wdata)
    walls = [wallpaper_json(e, W.source_pack(src)) for e in entries]
    seen = {w["path"] for w in walls}
    for w in curated.get("wallpapers", []):
        if w["path"] not in seen:
            seen.add(w["path"])
            walls.append(dict(w, curated=True))
    locks = []
    lorigin = res.origins.get("lock")
    if lorigin is not None:
        sel = _lock_entry(lorigin.name, src.facet("lock"))
        if sel:
            locks.append(lock_json(sel, lorigin.pack))
        for f in catalog.facets_in("lock", lorigin.pack):
            e = _lock_entry(f.name, f.data) if f is not lorigin else None
            if e:
                locks.append(lock_json(e, f.pack))
    seen = {lk["path"] for lk in locks}
    for lk in curated.get("locks", []):
        if lk["path"] not in seen:
            seen.add(lk["path"])
            locks.append(dict(lk, curated=True))
    dw = W.default_entry(wdata, entries)
    out["wallpapers"] = walls
    out["locks"] = locks
    out["defaults"] = {
        "wallpaper": str(dw["path"]) if dw else "",
        "lock": locks[0]["path"] if locks and not locks[0].get("curated") else "",
    }
    if out["defaults"]["lock"]:
        d = locks[0]
        out["lock"] = {"name": d["name"], "format": d["format"], "path": d["path"], "main": d["main"]}
    sets = wdata.get("sets") or []
    if sets:
        out["wallpaperSets"] = [{"name": s["name"], "displays": dict(s.get("displays") or {}), "workspaces": dict(s.get("workspaces") or {})} for s in sets]
    v1 = v1_info(res)
    if isinstance(v1.get("vibes"), dict):
        out["vibes"] = v1["vibes"]
    if v1.get("greeter"):
        out["greeter"] = {"path": v1["greeter"]}
    return out


def inputs(src: Source) -> dict:
    # The manifest itself: it is built from the catalog (the lock pack's other
    # designs) and curated links, not only from resolved data.
    return {"manifest": document(src)}


def render(i: dict, template_dir: Path) -> dict:
    return {"manifest.json": json.dumps(i["manifest"], indent=2) + "\n"}


UNIT = Unit(
    name="manifest",
    reads=("lock", "wallpapers", "colors"),
    files=("manifest.json",),
    inputs=inputs,
    render=render,
    hook=None,
    module=__file__,
)
