"""The user layer: <state>/appearance.json (docs/THEME-ARCHITECTURE.md §4).

    {"version": 1, "theme": "cozytile", "variant": "sakura", "mode": "dark",
     "pins": {kind: selection},
     "customizations": {theme: {"*" | variant: {kind: selection}}},
     "accessibility": {"reduceMotion", "reduceTransparency", "increaseContrast"},
     "transparency": {"level", "blur", "terminals", "gtk"}}

`transparency` holds the Transparency / Blur dials (render/look.py: how
they scale the theme's material; cli/loft/transparency.py: the commands):
numbers 0..1, a missing key follows the theme.

`loft` is its only writer. Customizations are stored per the storage rule
(resolve.customization_slot). Saving turns them into a variant (only the
diff) or a new theme of references plus small patches — never copied data.
"""

from __future__ import annotations

import copy
import datetime
import os
from pathlib import Path

from . import resolve as R
from .model import KINDS, LIBRARY_DIRS, NAME, THEMES_DIR, USER, Catalog, FacetError, Theme, compact, fold, read_json, selection, write_json

FILE = "appearance.json"
VERSION = 1
MODES = ("dark", "light", "auto")


def path(state_dir: Path) -> Path:
    return Path(state_dir) / FILE


def empty() -> dict:
    return {
        "version": VERSION,
        "theme": None,
        "variant": None,
        "mode": None,
        "pins": {},
        "customizations": {},
        "accessibility": {k: False for k in R.A11Y},
        "transparency": {},
    }


def load(state_dir: Path) -> dict:
    """The user layer (missing or unreadable file: empty). Unknown shapes are
    dropped key by key, never the whole file."""
    out = empty()
    try:
        data = read_json(path(state_dir))
    except FacetError:
        return out
    if data.get("version", VERSION) > VERSION:
        raise FacetError(f"{path(state_dir)}: version {data['version']} is newer than this loft understands ({VERSION})")
    for k in ("theme", "variant"):
        if isinstance(data.get(k), str):
            out[k] = data[k]
    if data.get("mode") in MODES:
        out["mode"] = data["mode"]
    if isinstance(data.get("pins"), dict):
        out["pins"] = {k: v for k, v in data["pins"].items() if k in KINDS}
    if isinstance(data.get("customizations"), dict):
        out["customizations"] = {
            t: {s: dict(c) for s, c in slots.items() if isinstance(c, dict)}
            for t, slots in data["customizations"].items()
            if isinstance(slots, dict)
        }
    if isinstance(data.get("accessibility"), dict):
        out["accessibility"].update({k: bool(data["accessibility"].get(k)) for k in R.A11Y if k in data["accessibility"]})
    out["transparency"] = R.dials(data.get("transparency"))
    return out


def save(state_dir: Path, state: dict) -> None:
    state = dict(state, version=VERSION)
    # Empty slots and themes are noise.
    cust = {}
    for t, slots in (state.get("customizations") or {}).items():
        slots = {s: c for s, c in slots.items() if c}
        if slots:
            cust[t] = slots
    state["customizations"] = cust
    dials = R.dials(state.get("transparency"))
    if dials:
        state["transparency"] = dials
    else:
        state.pop("transparency", None)
    write_json(path(state_dir), state)


# ── mode ────────────────────────────────────────────────────────────────────


def auto_polarity(now: datetime.datetime | None = None) -> str:
    """Auto appearance: light by day. Decision 5 wants the Night Light
    schedule, which Loft doesn't have yet (07:00–19:00 until it does);
    $LOFT_AUTO_POLARITY forces a side (tests, the shell)."""
    forced = os.environ.get("LOFT_AUTO_POLARITY")
    if forced in ("dark", "light"):
        return forced
    h = (now or datetime.datetime.now()).hour
    return "light" if 7 <= h < 19 else "dark"


def variant_for_mode(theme: Theme, mode: str) -> str | None:
    """The variant theme.appearance maps a mode to (None: the base)."""
    side = auto_polarity() if mode == "auto" else mode
    app = theme.doc.get("appearance") if isinstance(theme.doc.get("appearance"), dict) else {}
    if side not in app:
        raise FacetError(f"theme {theme.id} has no {side} appearance (it maps: {', '.join(app) or 'none'})")
    vid = app[side]
    theme.variant(vid)  # raises when unknown
    return None if vid == theme.base_id else vid


# ── customizations and pins ─────────────────────────────────────────────────


def _combine(existing, new: dict) -> dict:
    """A new selection in a slot: a ref replaces it, a patch composes onto it."""
    if existing is None or "ref" in new or "inline" in new:
        return new
    return fold([selection(existing), new]) or new


def set_selection(state: dict, theme: Theme, variant: str | None, kind: str, sel, pin: bool = False) -> str:
    """Write a customization (or pin) for kind; returns where it went."""
    sel = selection(sel)
    if pin:
        state["pins"][kind] = compact(_combine(state["pins"].get(kind), sel))
        return "pins"
    slot = R.customization_slot(theme, variant, kind)
    slots = state["customizations"].setdefault(theme.id, {})
    cur = slots.setdefault(slot, {})
    cur[kind] = compact(_combine(cur.get(kind), sel))
    return f"customizations.{theme.id}.{slot}"


def reset(state: dict, theme: Theme, kinds: list[str] | None, pin: bool = False, variant: str | None = None) -> list[str]:
    """Drop customizations — of each kind, both slots that apply to
    theme@variant ("*" and the variant's); with kinds None, all of the
    theme's — or pins. Returns what was dropped."""
    dropped = []
    if pin:
        for k in kinds or list(state["pins"]):
            if state["pins"].pop(k, None) is not None:
                dropped.append(f"pins.{k}")
        return dropped
    slots = state["customizations"].get(theme.id, {})
    if kinds is None:
        dropped = [f"customizations.{theme.id}.{s}.{k}" for s, c in slots.items() for k in c]
        state["customizations"].pop(theme.id, None)
        return dropped
    for s, c in slots.items():
        if s not in ("*", variant or theme.base_id):
            continue
        for k in kinds:
            if c.pop(k, None) is not None:
                dropped.append(f"customizations.{theme.id}.{s}.{k}")
    return dropped


# ── saving ──────────────────────────────────────────────────────────────────


def slug(name: str) -> str:
    import re

    s = re.sub(r"[^a-z0-9._-]+", "-", name.lower()).strip("-._")
    if not s or not NAME.match(s):
        raise FacetError(f"can't make an id from {name!r}")
    return s


def _qualified(catalog: Catalog, kind: str, layer: R.Layer) -> dict:
    """The layer's selection with its ref written as kind:pack/name, so it
    means the same thing wherever the folded selection is stored."""
    sel = copy.deepcopy(layer.sel)
    if "ref" in sel:
        sel["ref"] = catalog.facet(sel["ref"], kind, layer.pack).id
    return sel


def _fold_layers(catalog: Catalog, res: R.Resolved, kind: str, slots: set[str]) -> dict | None:
    return fold([_qualified(catalog, kind, ly) for ly in res.kept[kind] if ly.slot in slots])


def _variant_ids(theme: Theme) -> set[str]:
    return set(theme.variant_ids()) | ({theme.base_id} if theme.base_id else set())


def save_variant(catalog: Catalog, state: dict, theme: Theme, variant: str | None, name: str, library: Path | None) -> dict:
    """Customizations of theme@variant → a new variant (the diff only),
    written into the theme (yours) or its extension (read-only themes).
    The two customization slots it used are cleared and the variant selected."""
    res = R.resolve(catalog, theme, variant, state)
    facets = {}
    for k in KINDS:
        f = _fold_layers(catalog, res, k, {R.CUSTOM})
        if f:
            facets[k] = compact(f)
    if not facets:
        raise FacetError(f"nothing to save: {theme.id} has no customizations")
    vid, n = slug(name), 2
    taken = _variant_ids(theme)
    base_id = vid
    while vid in taken:
        vid, n = f"{base_id}-{n}", n + 1
    v = {"id": vid, "name": name}
    if variant:
        v["extends"] = variant
    v["facets"] = facets
    if not theme.readonly and theme.file is not None:
        doc = read_json(theme.file)
        doc["variants"] = [*(doc.get("variants") or []), v]
        write_json(theme.file, doc)
        where = theme.file
    else:
        if library is None:
            raise FacetError("the library is turned off (LOFT_LIBRARY=none): nowhere to save the variant")
        where = Path(library) / THEMES_DIR / f"{theme.id}.variants.json"
        doc = read_json(where) if where.is_file() else {"kind": "theme-extension", "extends": f"theme:{theme.id}", "variants": []}
        doc["variants"] = [*(doc.get("variants") or []), v]
        write_json(where, doc)
    slots = state["customizations"].get(theme.id, {})
    for s in ["*", variant or theme.base_id]:
        slots.pop(s, None)
    state["theme"], state["variant"] = theme.id, vid
    return {"variant": v, "file": str(where), "before": res}


def save_as(
    catalog: Catalog, state: dict, theme: Theme, variant: str | None, tid: str, name: str | None, library: Path,
    with_pins: bool = False, with_variants: bool = False,
) -> dict:  # fmt: skip
    """theme@variant with its customizations (and pins) → Themes/<tid>.json:
    every layer of each kind folded to {ref, patch}. The new theme is selected."""
    if not NAME.match(tid):
        raise FacetError(f"invalid theme id {tid!r} (lowercase letters, digits, . _ -)")
    if tid in {t.id for t in catalog.themes()}:
        raise FacetError(f"a theme '{tid}' exists already")
    res = R.resolve(catalog, theme, variant, state)
    slots = {"theme", "variant", R.CUSTOM} | ({"pin"} if with_pins else set())
    facets = {}
    for k in KINDS:
        f = _fold_layers(catalog, res, k, slots)
        if f:
            facets[k] = compact(f)
    doc = {
        "$schema": "https://loft.dev/schema/theme-2.json",
        "kind": "theme",
        "id": tid,
        "name": name or tid,
        "author": os.environ.get("USER", ""),
        "collection": "user",
        "basedOn": res.ref,
        "facets": facets,
    }
    if with_variants:
        vs = []
        for v in theme.variants():
            v = {k: x for k, x in v.items() if k != "user"}
            if v.get("facets"):
                v["facets"] = {
                    k: compact(_qualified(catalog, k, R.Layer("", selection(s), theme.pack, "variant"))) for k, s in v["facets"].items()
                }
            vs.append(v)
        doc["variants"] = vs
        if isinstance(theme.doc.get("appearance"), dict):
            doc["appearance"] = theme.doc["appearance"]
        if isinstance(theme.doc.get("base"), dict):
            doc["base"] = theme.doc["base"]
    where = Path(library) / THEMES_DIR / f"{tid}.json"
    write_json(where, doc)
    state["theme"], state["variant"] = tid, None
    return {"theme": doc, "file": str(where), "before": res}


def save_facet(catalog: Catalog, state: dict, theme: Theme, variant: str | None, kind: str, fid: str, name: str | None, library: Path, pin: bool = False) -> dict:
    """The resolved facet → Library/<Kind>/<fid>.json, and the customization
    (or pin) of that kind becomes a ref to it."""
    if not NAME.match(fid):
        raise FacetError(f"invalid facet id {fid!r} (lowercase letters, digits, . _ -)")
    res = R.resolve(catalog, theme, variant, state)
    where = Path(library) / LIBRARY_DIRS[kind] / f"{fid}.json"
    doc = {"$schema": "https://loft.dev/schema/facet-1.json", "kind": kind, "id": fid, "name": name or fid, "data": res.facets[kind]}
    write_json(where, doc)
    ref = f"{kind}:{USER}/{fid}"
    if pin:
        state["pins"][kind] = ref
    else:
        reset(state, theme, [kind], variant=variant)
        set_selection(state, theme, variant, kind, ref)
    return {"ref": ref, "file": str(where)}
