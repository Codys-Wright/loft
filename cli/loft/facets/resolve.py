"""Resolution: theme + variant + user layer → one document per facet kind
(docs/THEME-ARCHITECTURE.md §3.4).

For each kind k:

    layers(k) = T.facets[k] ++ V₁…Vₙ.facets[k] ++ pins[k] ++ space[k]
                ++ customizations[T]["*"][k] ++ customizations[T][Vₙ][k]
    S := apply each layer: a ref (or inline) REPLACES, a patch merges (RFC 7386)
    R := fill(defaults[k], S) → polar → @color refs → accessibility → schema

Colors resolve first: the others need its polarity and palette. A layer that
breaks R (unknown ref, bad value, failing schema) is dropped and reported
with its source; resolution itself never fails.
"""

from __future__ import annotations

import copy
from dataclasses import dataclass, field

from .. import color, palette
from . import refs, schema
from .model import KINDS, Catalog, Facet, FacetError, Theme, defaults, fill, merge_patch, selection

ORDER = ("colors",) + tuple(k for k in KINDS if k != "colors")
A11Y = ("reduceMotion", "reduceTransparency", "increaseContrast")
CUSTOM = "custom"


@dataclass
class Layer:
    source: str  # "theme:loft", "variant:loft@light", "pins", "space:work", "customizations.loft.*"
    sel: dict
    pack: str | None  # where unqualified refs are looked up first
    slot: str  # theme | variant | pin | space | custom


@dataclass
class Resolved:
    theme: Theme
    variant: str | None
    facets: dict = field(default_factory=dict)  # kind → data
    origins: dict = field(default_factory=dict)  # kind → Facet | None (the doc the last ref picked)
    sources: dict = field(default_factory=dict)
    kept: dict = field(default_factory=dict)  # kind → [Layer] that survived
    errors: list = field(default_factory=list)
    accessibility: dict = field(default_factory=dict)

    @property
    def polarity(self) -> str:
        return self.facets["colors"]["polarity"]

    @property
    def name(self) -> str:
        return self.theme.legacy_name(self.variant)

    @property
    def ref(self) -> str:
        return self.theme.id + (f"@{self.variant}" if self.variant else "")

    @property
    def customized(self) -> list[str]:
        return [k for k in KINDS if self.sources.get(k, {}).get("customized")]

    @property
    def pinned(self) -> list[str]:
        return [k for k in KINDS if self.sources.get(k, {}).get("pinned")]

    def to_json(self) -> dict:
        return {
            "theme": self.theme.id,
            "variant": self.variant,
            "ref": self.ref,
            "name": self.name,
            "label": self.theme.label_of(self.variant),
            "polarity": self.polarity,
            "facets": self.facets,
            "sources": self.sources,
            "customized": self.customized,
            "pinned": self.pinned,
            "accessibility": self.accessibility,
            "errors": self.errors,
        }


def _replaces(v: dict, kind: str) -> bool:
    sel = (v.get("facets") or {}).get(kind)
    return isinstance(sel, str) or (isinstance(sel, dict) and ("ref" in sel or "inline" in sel))


def customization_slot(theme: Theme, variant: str | None, kind: str) -> str:
    """Where a change to `kind` on theme@variant is stored (§4.2).

    On a variant: under the variant when it (or an ancestor) *replaces* the
    kind (a ref or inline facet), else under "*" (a variant that only patches
    the kind composes with a "*" tweak, so the tweak can be shared). On the
    base: under the base id when some variant replaces the kind, so a Dark
    palette tweak doesn't leak into Light; else "*". The effect: on a
    Light/Dark theme whose variants only change colors, a material tweak
    applies to both polarities, while a palette tweak stays on its side."""
    if variant is None:
        b = theme.base_id
        return b if b and any(_replaces(v, kind) for v in theme.variants()) else "*"
    return variant if any(_replaces(v, kind) for v in theme.chain(variant)) else "*"


def layers(theme: Theme, variant: str | None, kind: str, state: dict | None = None, space: dict | None = None) -> list[tuple[str, object, str | None, str]]:
    """Raw (source, selection, pack, slot) layers of one kind, lowest first."""
    state = state or {}
    out: list = []
    if kind in (theme.doc.get("facets") or {}):
        out.append((f"theme:{theme.id}", theme.doc["facets"][kind], theme.pack, "theme"))
    for v in theme.chain(variant):
        if kind in (v.get("facets") or {}):
            out.append((f"variant:{theme.id}@{v['id']}", v["facets"][kind], theme.pack, "variant"))
    pins = state.get("pins") if isinstance(state.get("pins"), dict) else {}
    if kind in pins:
        out.append(("pins", pins[kind], None, "pin"))
    if space:
        name = space.get("name", "space")
        sf = space.get("facets") if isinstance(space.get("facets"), dict) else {}
        if kind in sf:
            out.append((f"space:{name}", sf[kind], None, "space"))
    cust = state.get("customizations") if isinstance(state.get("customizations"), dict) else {}
    mine = cust.get(theme.id) if isinstance(cust.get(theme.id), dict) else {}
    own = variant or theme.base_id
    for slot in ["*"] + ([own] if own else []):
        sel = (mine.get(slot) or {}).get(kind) if isinstance(mine.get(slot), dict) else None
        if sel is not None:
            out.append((f"customizations.{theme.id}.{slot}", sel, None, CUSTOM))
    return out


def accessibility(kind: str, data: dict, a11y: dict, pal: dict | None) -> dict:
    """System switches clamp the resolved look (§4.4); they are never theme data."""
    if kind == "colors" and a11y.get("increaseContrast"):
        p = data["palette"]
        for role in ("text", "subtext"):
            p[role] = palette.ensure_contrast(p[role], p["bg"], 7.0)
    elif kind == "material":
        if a11y.get("reduceTransparency"):
            data["blur"]["enabled"] = False
            data["glass"]["opacity"] = 1.0
            data["terminals"]["opacity"] = 1.0
            data["windows"]["translucent"] = False
            data["menuBar"]["background"] = True
        if a11y.get("increaseContrast") and pal:
            data["glass"]["border"] = color.hex6(pal["overlay"])
            data["glass"]["borderOpacity"] = 1.0
    elif kind == "motion" and a11y.get("reduceMotion"):
        data["minimal"] = True
    return data


def _compute(catalog: Catalog, kind: str, kept: list[Layer], polarity: str | None, pal: dict | None, a11y: dict):
    s = None
    origin: Facet | None = None
    for layer in kept:
        sel = layer.sel
        if "ref" in sel:
            origin = catalog.facet(sel["ref"], kind, layer.pack)
            s = copy.deepcopy(origin.data)
        if "inline" in sel:
            s, origin = copy.deepcopy(sel["inline"]), None
        if "patch" in sel:
            s = merge_patch(s if s is not None else {}, sel["patch"])
    r = fill(defaults(kind), s if s is not None else {})
    if kind != "colors":
        r = refs.resolve(refs.polar(r, polarity or "dark"), pal or {})
    r = accessibility(kind, r, a11y, pal)
    errs = schema.check_facet(kind, r)
    return r, origin, errs


def resolve_kind(catalog: Catalog, kind: str, raw: list, polarity=None, pal=None, a11y=None):
    """(data, origin, kept layers, errors) for one kind, dropping bad layers."""
    a11y = a11y or {}
    kept: list[Layer] = []
    errors: list[str] = []
    for source, sel, pack, slot in raw:
        try:
            layer = Layer(source, selection(sel), pack, slot)
            _, _, errs = _compute(catalog, kind, kept + [layer], polarity, pal, a11y)
        except (FacetError, refs.RefError, ValueError, TypeError, KeyError, AttributeError) as e:
            errs = [str(e)]
        if errs:
            errors.append(f"{source}.{kind}: " + "; ".join(errs[:3]))
            continue
        kept.append(layer)
    data, origin, errs = _compute(catalog, kind, kept, polarity, pal, a11y)
    if errs:  # the product defaults themselves don't validate: a Loft bug
        raise FacetError(f"defaults/{kind}.json: " + "; ".join(errs))
    return data, origin, kept, errors


def resolve(catalog: Catalog, theme: Theme, variant: str | None, state: dict | None = None, space: dict | None = None) -> Resolved:
    state = state or {}
    acc = state.get("accessibility") if isinstance(state.get("accessibility"), dict) else {}
    a11y = {k: bool(acc.get(k)) for k in A11Y}
    out = Resolved(theme, variant, accessibility=a11y)
    pins = state.get("pins") if isinstance(state.get("pins"), dict) else {}
    polarity = pal = None
    for kind in ORDER:
        try:
            raw = layers(theme, variant, kind, state, space)
        except FacetError as e:  # a broken variant chain: the theme alone
            out.errors.append(f"theme:{theme.id}: {e}")
            raw = layers(theme, None, kind, state, space)
        data, origin, kept, errs = resolve_kind(catalog, kind, raw, polarity, pal, a11y)
        if kind == "colors":
            polarity, pal = data["polarity"], data["palette"]
        out.facets[kind] = data
        out.origins[kind] = origin
        out.kept[kind] = kept
        out.errors += errs
        custom = any(slot == CUSTOM for _, _, _, slot in raw)
        out.sources[kind] = {
            "ref": origin.id if origin else None,
            "label": origin.label if origin else defaults_label(kind),
            "customized": custom,
            "pinned": kind in pins and not custom,
            "layers": [{"source": layer.source, "selection": layer.sel} for layer in kept],
        }
    return out


def defaults_label(kind: str) -> str:
    from .model import DEFAULTS_DIR, read_json

    try:
        return read_json(DEFAULTS_DIR / f"{kind}.json").get("name") or "Default"
    except FacetError:
        return "Default"


def changes(a, b, path: str = "") -> list[tuple[str, object, object]]:
    """Leaf differences between two resolved documents: (path, before, after)."""
    if isinstance(a, dict) and isinstance(b, dict):
        out = []
        for k in list(a) + [k for k in b if k not in a]:
            out += changes(a.get(k), b.get(k), f"{path}.{k}" if path else k)
        return out
    return [] if a == b else [(path or "(all)", a, b)]
