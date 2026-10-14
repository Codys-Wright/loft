"""Unit `wallpapers`: wallpapers.json, the resolved Wallpapers facet for the
shell's wallpaper layer and pickers (§2.2): the collection with absolute
paths, the default, the colors' gradient (the fallback when there is no
image), sets, behavior, related facets and the user's arrangement.

Also the collection helpers the `manifest` and `shell` units share.

An arrangement change (a wallpaper picked for one display) re-renders only
this unit: `shell` keys on the default wallpaper alone, `manifest` leaves the
arrangement out.
"""

from __future__ import annotations

import json
from pathlib import Path

from ..pack import media_kind, wallpaper_json
from . import look
from .unit import Source, Unit


def collection(data: dict) -> list[dict]:
    """The facet's collection as entries {path, kind, video?, preview?}
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


def default_entry(data: dict, entries: list[dict] | None = None) -> dict | None:
    """`default`, else the collection's first still."""
    entries = collection(data) if entries is None else entries
    if data.get("default"):
        p = Path(data["default"])
        return next((e for e in entries if e["path"] == p), {"path": p, "kind": media_kind(p) or "image"})
    return next((e for e in entries if e["kind"] == "image"), None)


def source_pack(src: Source) -> str:
    """The pack a wallpaper entry is credited to (manifest `source_pack`)."""
    origin = src.res.origins.get("wallpapers")
    return origin.pack if origin else src.res.theme.pack


def inputs(src: Source) -> dict:
    w = src.facet("wallpapers")
    entries = collection(w)
    d = default_entry(w, entries)
    return {
        "name": src.res.name,
        "collection": [wallpaper_json(e, source_pack(src)) for e in entries],
        "default": str(d["path"]) if d else "",
        "gradient": look.gradient(src.facet("colors")),
        "behavior": w.get("behavior") or {},
        "sets": w.get("sets") or [],
        "related": w.get("related") or [],
        "arrangement": w.get("arrangement") or {},
    }


def render(i: dict, template_dir: Path) -> dict:
    return {"wallpapers.json": json.dumps(i, indent=2) + "\n"}


UNIT = Unit(
    name="wallpapers",
    reads=("wallpapers", "colors"),
    files=("wallpapers.json",),
    inputs=inputs,
    render=render,
    hook="wallpapers",
    module=__file__,
)
