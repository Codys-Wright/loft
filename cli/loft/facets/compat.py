"""Render resolved facets through today's (v1) renderer.

Until the per-unit renderer lands (phase B, `cli/loft/render/`), a resolved
theme is turned back into the v1 shapes — a theme.json dict for
`pack.normalize_theme` and the normalized manifest — and written by
`render.write_bundle`. With no user layer this is byte-identical to the v1
render of the same pack (tests/test_resolve.py, the golden gate), so
`loft theme apply` can go through the facet model for every theme.

What v1 consumers know a theme by (theme.json `name`, rendered/<name>,
`perTheme` keys) is `Resolved.name`: an alias pointing at the selection
(loft@dark → tokyonight), else theme[@variant].
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

from .. import color, render
from ..pack import Pack, lock_json, media_kind, normalize_theme, read_kv, wallpaper_json
from .model import Catalog
from .resolve import Resolved


def v1_theme(res: Resolved) -> tuple[dict, bool]:
    """(v1 theme.json dict, fonts_set) from the resolved facets."""
    c, m, sh, ty = (res.facets[k] for k in ("colors", "material", "shape", "typography"))
    t: dict = {"polarity": c["polarity"], "palette": c["palette"]}
    if c.get("ansi") is not None:
        t["ansi"] = c["ansi"]
    shadow = sh["shadow"]
    glass = {
        "blur": m["blur"]["enabled"],
        "xray": m["blur"]["xray"],
        "tint": m["glass"]["tint"],
        "opacity": m["glass"]["opacity"],
        "border": m["glass"]["border"],
        "borderOpacity": m["glass"]["borderOpacity"],
        "radius": sh["radius"]["surface"],
        "noise": m["blur"]["noise"],
        "saturation": m["blur"]["saturation"],
        "shadow": shadow["color"] if shadow.get("color") else color.with_alpha("#000000", shadow["opacity"]),
        "edgeDarken": m["glass"]["edgeDarken"],
        "specular": m["glass"]["specular"],
    }
    if m["terminals"].get("opacity") is not None:
        glass["terminalOpacity"] = m["terminals"]["opacity"]
    t["glass"] = glass
    t["wallpaper"] = {"gradient": c["gradient"]} if c.get("gradient") else {}
    t["fonts"] = {"ui": ty["ui"]["family"] or "sans-serif", "mono": ty["mono"]["family"] or "monospace", "size": ty["mono"]["size"]}
    t["shape"] = {"windowRadius": sh["radius"]["window"], "panelRadius": sh["radius"]["panel"], "controlRadius": sh["radius"]["control"]}
    t["bar"] = {"adaptiveText": m["menuBar"]["adaptiveText"], "background": m["menuBar"]["background"]}
    return t, bool(ty["applyTo"]["terminals"])


def collection(data: dict) -> list[dict]:
    """The wallpapers facet's collection as entries {path, kind, video?, preview?}
    (Paths): listed items, then the files of `dirs` (a still next to a video
    of the same stem stands for it, as in v1 packs)."""
    out: list[dict] = []
    seen: set[str] = set()
    for item in data.get("collection") or []:
        item = {"path": item} if isinstance(item, str) else item
        p = Path(item["path"])
        if str(p) in seen:
            continue
        seen.add(str(p))
        e: dict = {"path": p, "kind": item.get("kind") or media_kind(p) or "image"}
        e.update({k: Path(item[k]) for k in ("video", "preview") if item.get(k)})
        if e["kind"] == "video" and "video" not in e:
            e["video"] = p
        out.append(e)
    for d in data.get("dirs") or []:
        d = Path(d)
        if not d.is_dir():
            continue
        files = [(p, media_kind(p)) for p in sorted(d.iterdir()) if p.is_file() and not p.name.startswith(".")]
        files = [(p, k) for p, k in files if k]
        stills = {p.stem for p, k in files if k == "image"}
        videos = {p.stem: p for p, k in files if k == "video"}
        for p, k in files:
            if (k == "video" and p.stem in stills) or str(p) in seen:
                continue
            seen.add(str(p))
            e = {"path": p, "kind": k}
            if k == "video":
                e["video"] = p
            elif p.stem in videos:
                e["video"] = videos[p.stem]
            out.append(e)
    return out


def default_wallpaper(res: Resolved) -> dict | None:
    w = res.facets["wallpapers"]
    entries = collection(w)
    if w.get("default"):
        p = Path(w["default"])
        return next((e for e in entries if e["path"] == p), {"path": p, "kind": media_kind(p) or "image"})
    return next((e for e in entries if e["kind"] == "image"), None)


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


def manifest(res: Resolved, catalog: Catalog, curated: dict | None = None) -> dict:
    """normalized_manifest() for a resolved theme (same keys, same order)."""
    t = res.theme
    doc = t.doc
    pack_meta = catalog.pack_meta(t.pack)
    colors_doc = res.origins["colors"].doc if res.origins.get("colors") else {}
    v = t.variant(res.variant)
    base = doc.get("base") if isinstance(doc.get("base"), dict) else {}
    out = {
        "name": res.name,
        "author": doc.get("author", pack_meta.get("author", "")),
        "version": doc.get("version") or pack_meta.get("version") or "0.0.0",
        "license": doc.get("license") or colors_doc.get("license") or pack_meta.get("license") or "NOASSERTION",
        "source": doc.get("source") or colors_doc.get("source") or pack_meta.get("source") or "",
        "description": (v or {}).get("description") or base.get("description") or doc.get("description", ""),
    }
    if isinstance(doc.get("upstream"), dict):
        out["upstream"] = doc["upstream"]
    curated = curated or {}
    worigin = res.origins.get("wallpapers")
    wsource = worigin.pack if worigin else t.pack
    walls = [wallpaper_json(e, wsource) for e in collection(res.facets["wallpapers"])]
    seen = {w["path"] for w in walls}
    for w in curated.get("wallpapers", []):
        if w["path"] not in seen:
            seen.add(w["path"])
            walls.append(dict(w, curated=True))
    locks = []
    lorigin = res.origins.get("lock")
    if lorigin is not None:
        sel = _lock_entry(lorigin.name, res.facets["lock"])
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
    dw = default_wallpaper(res)
    out["wallpapers"] = walls
    out["locks"] = locks
    out["defaults"] = {
        "wallpaper": str(dw["path"]) if dw else "",
        "lock": locks[0]["path"] if locks and not locks[0].get("curated") else "",
    }
    if out["defaults"]["lock"]:
        d = locks[0]
        out["lock"] = {"name": d["name"], "format": d["format"], "path": d["path"], "main": d["main"]}
    sets = res.facets["wallpapers"].get("sets") or []
    if sets:
        out["wallpaperSets"] = [{"name": s["name"], "displays": dict(s.get("displays") or {}), "workspaces": dict(s.get("workspaces") or {})} for s in sets]
    v1 = doc.get("v1") if isinstance(doc.get("v1"), dict) else {}
    if isinstance(v1.get("vibes"), dict):
        out["vibes"] = v1["vibes"]
    if v1.get("greeter"):
        out["greeter"] = {"path": v1["greeter"]}
    return out


def v1_pack(res: Resolved) -> Pack | None:
    """The v1 pack a theme was adapted from (for curated vibes), if any."""
    v1 = res.theme.doc.get("v1")
    return Pack(Path(v1["path"])) if isinstance(v1, dict) and v1.get("path") else None


def bundle(res: Resolved, catalog: Catalog, curated: dict | None = None):
    """Everything write_bundle needs: (norm, assets, manifest, fonts_set, apps dir)."""
    t, fonts_set = v1_theme(res)
    worigin = res.origins.get("wallpapers")
    root = worigin.root.resolve() if worigin is not None and worigin.root is not None else None
    norm, assets = normalize_theme(t, res.name, root, default_wallpaper(res))
    apps = res.theme.root / "apps" if res.theme.root is not None else None
    return norm, assets, manifest(res, catalog, curated), fonts_set, apps


def digest(res: Resolved, catalog: Catalog, curated: dict | None, salt: str) -> str:
    """Render-cache key: renderer salt + what the bundle is made of (files
    copied into it by size and mtime, apps/ overrides by content)."""
    norm, assets, mf, fonts_set, apps = bundle(res, catalog, curated)
    h = hashlib.sha256(salt.encode())
    for p in sorted(Path(__file__).resolve().parent.glob("*.py")):
        h.update(p.read_bytes())
    h.update(json.dumps([norm, mf, fonts_set], sort_keys=True).encode())
    for src, dest in assets:
        st = src.stat()
        h.update(f"{src}\0{dest}\0{st.st_size}\0{st.st_mtime_ns}\0".encode())
    if apps is not None and apps.is_dir():
        for p in sorted(apps.rglob("*")):
            if p.is_file():
                h.update(str(p.relative_to(apps)).encode() + b"\0" + p.read_bytes())
    return h.hexdigest()[:16]


def write(res: Resolved, catalog: Catalog, outdir: Path, template_dir: Path, curated: dict | None = None) -> list[str]:
    norm, assets, mf, fonts_set, apps = bundle(res, catalog, curated)
    return render.write_bundle(Path(outdir), norm, assets, mf, fonts_set, template_dir, apps)
