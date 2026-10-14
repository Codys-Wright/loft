"""The facet model: ids, selections, merge rules and the catalog of facet
and theme documents (docs/THEME-ARCHITECTURE.md §2, §3, §5).

A *facet* is one aspect of the look (colors, material, motion, …) stored as
its own document; a *theme* is a named collection of facet selections with
variants. The catalog finds them in, by priority:

  user      the library root: loose facets in kind folders (Colors/, Materials/, …),
            Themes/<id>.json and Themes/<theme>.variants.json (writable)
  packs     directories of packs on the theme path: v2 packs (pack.json,
            themes/*.json, facets/<kind>/*.json) and v1 packs (theme.json),
            which load through the v1 adapter (pack.v1_documents)
  loft      the built-in pack (packs/loft in this tree)

Everything here is pure data handling; resolve.py applies it.
"""

from __future__ import annotations

import copy
import json
import re
from dataclasses import dataclass, field
from pathlib import Path

KINDS = ("colors", "wallpapers", "material", "motion", "shape", "typography", "icons", "lock", "launcher", "sounds")
NAME = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
REF = re.compile(r"^(?P<kind>[a-z]+):(?:(?P<pack>[a-z0-9][a-z0-9._-]*)/)?(?P<name>[a-z0-9][a-z0-9._-]*)$")
USER = "user"
BUILTIN = "loft"
MAX_EXTENDS = 4

# Library folders of the implicit `user` pack, per kind (§5.2).
LIBRARY_DIRS = {
    "colors": "Colors",
    "wallpapers": "Wallpapers/Sets",
    "material": "Materials",
    "motion": "Motion",
    "shape": "Shapes",
    "typography": "Typography",
    "icons": "Icons",
    "lock": "Locks",
    "launcher": "Launcher",
    "sounds": "Sounds",
}
THEMES_DIR = "Themes"
DEFAULTS_DIR = Path(__file__).resolve().parent / "defaults"


class FacetError(Exception):
    pass


# ── ids ─────────────────────────────────────────────────────────────────────


def parse_ref(ref: str, kind: str | None = None) -> tuple[str, str | None, str]:
    """`kind:name` or `kind:pack/name` → (kind, pack or None, name)."""
    m = REF.match(ref) if isinstance(ref, str) else None
    if not m or m["kind"] not in KINDS:
        raise FacetError(f"bad facet reference {ref!r} (kind:name or kind:pack/name)")
    if kind is not None and m["kind"] != kind:
        raise FacetError(f"{ref}: a {m['kind']} facet where {kind} is expected")
    return m["kind"], m["pack"], m["name"]


def qualify(kind: str, pack: str, name: str) -> str:
    return f"{kind}:{pack}/{name}"


def split_theme_ref(ref: str) -> tuple[str, str | None]:
    """`theme` or `theme@variant`."""
    name, _, variant = ref.partition("@")
    if not NAME.match(name) or (variant and not NAME.match(variant)) or (ref.endswith("@")):
        raise FacetError(f"bad theme name {ref!r} (theme or theme@variant)")
    return name, variant or None


# ── selections ──────────────────────────────────────────────────────────────


def selection(sel) -> dict:
    """Normalize a selection (§3.2) to a dict with any of ref / inline / patch."""
    if isinstance(sel, str):
        return {"ref": sel}
    if not isinstance(sel, dict) or not sel or set(sel) - {"ref", "inline", "patch"}:
        raise FacetError(f"bad selection {json.dumps(sel)} (a ref string, or {{ref?, inline?, patch?}})")
    if "ref" in sel and "inline" in sel:
        raise FacetError("a selection has a ref or an inline facet, not both")
    if "ref" in sel and not isinstance(sel["ref"], str):
        raise FacetError(f"bad ref {sel['ref']!r}")
    for k in ("inline", "patch"):
        if k in sel and not isinstance(sel[k], dict):
            raise FacetError(f"{k}: expected an object")
    return dict(sel)


def compact(sel: dict) -> str | dict:
    """The shortest spelling of a selection (a bare ref string when possible)."""
    return sel["ref"] if set(sel) == {"ref"} else sel


# ── merge rules ─────────────────────────────────────────────────────────────


def merge_patch(target, patch):
    """RFC 7386: objects recurse, arrays and scalars replace, null deletes."""
    if not isinstance(patch, dict):
        return copy.deepcopy(patch)
    out = dict(target) if isinstance(target, dict) else {}
    for k, v in patch.items():
        if v is None:
            out.pop(k, None)
        else:
            out[k] = merge_patch(out.get(k), v)
    return out


def compose_patches(first: dict, second: dict) -> dict:
    """One patch with the effect of `first` then `second`.

    Exact except when `second` patches inside a key `first` deletes or sets
    to a scalar: merge patch can't say "replace this object", so the result
    merges into what the base has there (a documented approximation)."""
    out = copy.deepcopy(first)
    for k, v in second.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = compose_patches(out[k], v)
        else:
            out[k] = copy.deepcopy(v)
    return out


def fill(default, value):
    """Deep fill: keys missing from value come from default; arrays never merge."""
    if isinstance(default, dict) and isinstance(value, dict):
        out = {k: fill(dv, value[k]) if k in value else copy.deepcopy(dv) for k, dv in default.items()}
        out.update({k: copy.deepcopy(v) for k, v in value.items() if k not in default})
        return out
    return copy.deepcopy(value)


def fold(layers: list[dict]) -> dict | None:
    """Fold selections into one: the last ref (or inline) wins, the patches
    after it are composed (§4.3). None when there is nothing."""
    out: dict = {}
    for sel in layers:
        if "ref" in sel or "inline" in sel:
            out = {k: copy.deepcopy(sel[k]) for k in ("ref", "inline") if k in sel}
        if "patch" in sel:
            out["patch"] = compose_patches(out.get("patch", {}), sel["patch"])
    return out or None


def get_path(data, path: list[str]):
    for p in path:
        if not isinstance(data, dict) or p not in data:
            return None
        data = data[p]
    return data


def path_patch(path: str, value) -> dict:
    """`glass.opacity` + 0.35 → {"glass": {"opacity": 0.35}}."""
    parts = [p for p in path.split(".") if p]
    if not parts:
        raise FacetError("empty path")
    out = value
    for p in reversed(parts):
        out = {p: out}
    return out


# ── paths inside facet data ─────────────────────────────────────────────────


def _abs(root: Path | None, p):
    if not isinstance(p, str) or not p or root is None:
        return p
    q = Path(p).expanduser()
    return str(q if q.is_absolute() else root / q)


def absolutize(kind: str, data: dict, root: Path | None) -> dict:
    """Make a facet's file references absolute (they are relative to the
    document's pack). Works on documents and on patches (missing keys stay missing)."""
    if root is None or not isinstance(data, dict):
        return data
    d = copy.deepcopy(data)
    if kind == "wallpapers":
        if isinstance(d.get("collection"), list):
            d["collection"] = [
                _abs(root, i) if isinstance(i, str) else {k: _abs(root, v) if k in ("path", "video", "preview") else v for k, v in i.items()} if isinstance(i, dict) else i
                for i in d["collection"]
            ]
        if isinstance(d.get("dirs"), list):
            d["dirs"] = [_abs(root, x) for x in d["dirs"]]
        if "default" in d:
            d["default"] = _abs(root, d["default"])
        if isinstance(d.get("sets"), list):
            for s in d["sets"]:
                for k in ("displays", "workspaces"):
                    if isinstance(s, dict) and isinstance(s.get(k), dict):
                        s[k] = {r: _abs(root, p) for r, p in s[k].items()}
    elif kind == "lock":
        for k in ("path", "main", "preview", "background"):
            if k in d:
                d[k] = _abs(root, d[k])
        if isinstance(d.get("wallpaper"), str) and d["wallpaper"] not in ("design", "desktop"):
            d["wallpaper"] = _abs(root, d["wallpaper"])
    elif kind == "typography" and isinstance(d.get("fonts"), list):
        d["fonts"] = [_abs(root, x) for x in d["fonts"]]
    elif kind == "launcher":
        for k in ("css", "layout"):
            if k in d:
                d[k] = _abs(root, d[k])
    elif kind == "sounds" and isinstance(d.get("events"), dict):
        d["events"] = {k: _abs(root, v) for k, v in d["events"].items()}
    return d


# ── documents ───────────────────────────────────────────────────────────────


@dataclass
class Facet:
    kind: str
    pack: str
    name: str  # the id within its pack
    doc: dict  # the envelope (data with absolute paths)
    root: Path | None  # pack root (relative paths, apps/)
    file: Path | None = None
    order: int = 0

    @property
    def id(self) -> str:
        return qualify(self.kind, self.pack, self.name)

    @property
    def data(self) -> dict:
        return self.doc.get("data", {})

    @property
    def label(self) -> str:
        return self.doc.get("name") or self.name


@dataclass
class Theme:
    id: str
    pack: str
    doc: dict
    root: Path | None
    file: Path | None = None
    readonly: bool = True
    user_variants: list[dict] = field(default_factory=list)
    extension_file: Path | None = None

    @property
    def name(self) -> str:
        return self.doc.get("name") or self.id

    @property
    def base_id(self) -> str | None:
        b = self.doc.get("base")
        return b.get("id") if isinstance(b, dict) else None

    def variants(self) -> list[dict]:
        own = [v for v in self.doc.get("variants") or [] if isinstance(v, dict)]
        return own + [dict(v, user=True) for v in self.user_variants]

    def variant(self, vid: str | None) -> dict | None:
        if vid is None or vid == self.base_id:
            return None
        for v in self.variants():
            if v.get("id") == vid:
                return v
        raise FacetError(f"theme {self.id} has no variant '{vid}' (variants: {', '.join(self.variant_ids()) or 'none'})")

    def variant_ids(self) -> list[str]:
        return [v["id"] for v in self.variants() if isinstance(v.get("id"), str)]

    def chain(self, vid: str | None) -> list[dict]:
        """The variant and its `extends` ancestors, root ancestor first."""
        out: list[dict] = []
        v = self.variant(vid)
        while v is not None:
            if any(x is v or x.get("id") == v.get("id") for x in out):
                raise FacetError(f"theme {self.id}: variant '{vid}' extends itself (cycle)")
            out.insert(0, v)
            if len(out) > MAX_EXTENDS + 1:
                raise FacetError(f"theme {self.id}: variant '{vid}' extends more than {MAX_EXTENDS} deep")
            v = self.variant(v["extends"]) if v.get("extends") else None
        return out

    def label_of(self, vid: str | None) -> str:
        v = self.variant(vid)
        if v is None:
            b = self.doc.get("base")
            return self.name if not isinstance(b, dict) else f"{self.name} {b.get('name') or b.get('id')}"
        return f"{self.name} {v.get('name') or v['id']}"

    def legacy_name(self, vid: str | None) -> str:
        """The name a v1 consumer knows this selection by (theme.json `name`,
        `perTheme` keys, rendered/<name>): an alias pointing at exactly it,
        else theme[@variant]."""
        want = None if vid == self.base_id else vid
        for a in self.doc.get("aliases") or []:
            if not isinstance(a, str):
                continue
            name, _, av = a.partition("@")
            if (av or None) == want and name != "default":
                return name
        return self.id if want is None else f"{self.id}@{want}"


def read_json(path: Path) -> dict:
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise FacetError(f"{path}: {e}") from e
    if not isinstance(data, dict):
        raise FacetError(f"{path}: expected a JSON object")
    return data


def write_json(path: Path, data) -> None:
    """Atomic replace (readers never see half a file)."""
    import os

    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}")
    tmp.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def defaults(kind: str) -> dict:
    """The product default data of a kind (what `fill` completes from)."""
    if kind not in _DEFAULTS:
        _DEFAULTS[kind] = read_json(DEFAULTS_DIR / f"{kind}.json")["data"]
    return copy.deepcopy(_DEFAULTS[kind])


_DEFAULTS: dict[str, dict] = {}


# ── catalog ─────────────────────────────────────────────────────────────────


class Catalog:
    """Facet and theme documents from the user library, pack dirs and built-ins.

    `pack_dirs`: directories holding packs, highest priority first (the
    theme path); `builtin`: the built-in packs dir (holding loft/); `user`:
    the library root (None: no user pack). v1 packs are adapted lazily."""

    def __init__(self, pack_dirs: list[Path], builtin: Path | None = None, user: Path | None = None, extra_packs: list[Path] = ()):
        self.user_root = user
        self.errors: list[str] = []
        self._facets: dict[tuple[str, str, str], Facet] = {}
        self._themes: dict[str, Theme] = {}
        self._packs: dict[str, dict] = {}  # id → {root, format, meta, priority}
        self._pending_v1: dict[str, Path] = {}  # pack id → path (adapted on demand)
        self._order = 0
        # Explicit packs (a path on the command line) come first.
        for p in extra_packs:
            self._add_pack(Path(p), front=True)
        if user is not None:
            self._load_user(user)
        for d in pack_dirs:
            if d is not None and Path(d).is_dir():
                for sub in sorted(Path(d).iterdir()):
                    if sub.is_dir() and not sub.is_symlink():
                        self._add_pack(sub)
        if builtin is not None and Path(builtin).is_dir():
            for sub in sorted(Path(builtin).iterdir()):
                if sub.is_dir() and not sub.is_symlink():
                    self._add_pack(sub)

    # loading ---------------------------------------------------------------

    def _add_pack(self, path: Path, front: bool = False) -> str | None:
        from ..pack import is_pack

        if (path / "pack.json").is_file():
            try:
                meta = read_json(path / "pack.json")
            except FacetError as e:
                self.errors.append(str(e))
                return None
            pid = meta.get("id") or path.name
            if pid in self._packs:
                return pid if front else None
            self._packs[pid] = {"root": path.resolve(), "format": 2, "meta": meta}
            self._load_v2(pid, path.resolve())
            return pid
        if is_pack(path):
            from ..pack import Pack, PackError

            try:
                pk = Pack(path)
            except PackError as e:
                self.errors.append(str(e))
                return None
            pid = pk.name
            if pid in self._packs:
                return pid if front else None
            self._packs[pid] = {"root": pk.path, "format": 1, "meta": pk.manifest or {}, "v1": pk}
            self._pending_v1[pid] = pk.path
            return pid
        return None

    def _put_facet(self, f: Facet) -> None:
        key = (f.kind, f.pack, f.name)
        if key in self._facets:
            return
        self._order += 1
        f.order = self._order
        self._facets[key] = f

    def _facet_doc(self, doc: dict, kind: str, pack: str, root: Path | None, file: Path | None, name: str | None = None) -> Facet | None:
        if doc.get("kind") != kind:
            self.errors.append(f"{file}: kind {doc.get('kind')!r} doesn't match its folder ({kind})")
            return None
        name = name or doc.get("id") or (file.stem if file else None)
        if not isinstance(name, str) or not NAME.match(name):
            self.errors.append(f"{file}: bad facet id {name!r}")
            return None
        if not isinstance(doc.get("data"), dict):
            self.errors.append(f"{file}: `data` must be an object")
            return None
        doc = dict(doc, data=absolutize(kind, doc["data"], root))
        f = Facet(kind, pack, name, doc, root, file)
        self._put_facet(f)
        return f

    def _load_v2(self, pid: str, root: Path) -> None:
        fdir = root / "facets"
        for kind in KINDS:
            d = fdir / kind
            if d.is_dir():
                for p in sorted(d.glob("*.json")):
                    try:
                        self._facet_doc(read_json(p), kind, pid, root, p, p.stem)
                    except FacetError as e:
                        self.errors.append(str(e))
        tdir = root / "themes"
        if tdir.is_dir():
            for p in sorted(tdir.glob("*.json")):
                if p.name.endswith(".variants.json"):
                    continue
                try:
                    self._put_theme(read_json(p), pid, root, p, readonly=True)
                except FacetError as e:
                    self.errors.append(str(e))

    def _put_theme(self, doc: dict, pid: str, root: Path | None, file: Path | None, readonly: bool) -> Theme | None:
        if doc.get("kind") != "theme":
            raise FacetError(f"{file}: not a theme document (kind {doc.get('kind')!r})")
        tid = doc.get("id") or (file.stem if file else None)
        if not isinstance(tid, str) or not NAME.match(tid):
            raise FacetError(f"{file}: bad theme id {tid!r}")
        if tid in self._themes:
            return None
        doc = _absolutize_theme(doc, root)
        t = Theme(tid, pid, doc, root, file, readonly)
        self._themes[tid] = t
        return t

    def _load_user(self, lib: Path) -> None:
        self._packs[USER] = {"root": lib, "format": 2, "meta": {"id": USER, "name": "Yours"}}
        for kind, sub in LIBRARY_DIRS.items():
            d = lib / sub
            if d.is_dir():
                for p in sorted(d.glob("*.json")):
                    try:
                        self._facet_doc(read_json(p), kind, USER, p.parent, p, p.stem)
                    except FacetError as e:
                        self.errors.append(str(e))
        tdir = lib / THEMES_DIR
        if tdir.is_dir():
            for p in sorted(tdir.glob("*.json")):
                if p.name.endswith(".variants.json"):
                    continue
                try:
                    self._put_theme(read_json(p), USER, lib, p, readonly=False)
                except FacetError as e:
                    self.errors.append(str(e))

    def _extensions(self) -> None:
        if getattr(self, "_ext_done", False) or self.user_root is None:
            return
        self._ext_done = True
        tdir = self.user_root / THEMES_DIR
        for p in sorted(tdir.glob("*.variants.json")) if tdir.is_dir() else []:
            try:
                doc = read_json(p)
                tid = str(doc.get("extends", "")).removeprefix("theme:")
                t = self._themes.get(tid) or self._adapt_named(tid)
                if t is None or doc.get("kind") != "theme-extension":
                    continue
                t.user_variants = [_absolutize_variant(v, self.user_root) for v in doc.get("variants") or [] if isinstance(v, dict)]
                t.extension_file = p
            except FacetError as e:
                self.errors.append(str(e))

    def _adapt(self, pid: str) -> None:
        path = self._pending_v1.pop(pid, None)
        if path is None:
            return
        from ..pack import PackError, v1_documents

        try:
            theme, facets = v1_documents(self._packs[pid]["v1"])
        except (PackError, ValueError, KeyError, TypeError) as e:
            self.errors.append(f"{path}: {e}")
            return
        for doc in facets:
            self._facet_doc(doc, doc["kind"], pid, path, None, doc["id"])
        try:
            self._put_theme(theme, pid, path, None, readonly=True)
        except FacetError as e:
            self.errors.append(str(e))

    def _adapt_named(self, tid: str) -> Theme | None:
        if tid in self._pending_v1:
            self._adapt(tid)
        return self._themes.get(tid)

    def _adapt_all(self) -> None:
        for pid in list(self._pending_v1):
            self._adapt(pid)

    # queries ---------------------------------------------------------------

    def pack_root(self, pid: str) -> Path | None:
        p = self._packs.get(pid)
        return p["root"] if p else None

    def pack_meta(self, pid: str) -> dict:
        p = self._packs.get(pid)
        return p["meta"] if p else {}

    def pack_ids(self) -> list[str]:
        return list(self._packs)

    def facet(self, ref: str, kind: str | None = None, from_pack: str | None = None) -> Facet:
        """Look a reference up (§5.3): the referring pack, user, built-ins, then
        every other pack (more than one match there is an error)."""
        k, pack, name = parse_ref(ref, kind)
        if pack is not None:
            self._adapt(pack)
            f = self._facets.get((k, pack, name))
            if f is None:
                raise FacetError(f"no facet {ref}")
            return f
        for p in (from_pack, USER, BUILTIN):
            if p is not None:
                self._adapt(p)
                f = self._facets.get((k, p, name))
                if f is not None:
                    return f
        self._adapt_all()
        hits = [f for (fk, fp, fn), f in self._facets.items() if fk == k and fn == name and fp not in (from_pack, USER, BUILTIN)]
        if not hits:
            raise FacetError(f"no facet {ref}")
        if len(hits) > 1:
            raise FacetError(f"{ref} is ambiguous: " + ", ".join(sorted(f.id for f in hits)))
        return hits[0]

    def facets(self, kind: str) -> list[Facet]:
        self._adapt_all()
        return sorted((f for f in self._facets.values() if f.kind == kind), key=lambda f: f.order)

    def facets_in(self, kind: str, pack: str) -> list[Facet]:
        """One pack's facets of a kind, in pack order (adapts only that pack)."""
        self._adapt(pack)
        return sorted((f for (k, p, _), f in self._facets.items() if k == kind and p == pack), key=lambda f: f.order)

    def themes(self) -> list[Theme]:
        self._adapt_all()
        self._extensions()
        return list(self._themes.values())

    def theme(self, ref: str) -> tuple[Theme, str | None]:
        """A theme by `id[@variant]`, else by alias (`latte` → loft@light)."""
        name, variant = split_theme_ref(ref)
        t = self._themes.get(name) or self._adapt_named(name)
        if t is None:
            # Only v2 documents carry aliases: no need to adapt every v1 pack.
            for cand in list(self._themes.values()):
                for a in cand.doc.get("aliases") or []:
                    if not isinstance(a, str):
                        continue
                    an, _, av = a.partition("@")
                    if an == name:
                        t, variant = cand, variant or av or None
                        break
                if t is not None:
                    break
        if t is None:
            raise FacetError(f"no theme '{name}'")
        self._extensions()
        if variant is not None:
            t.variant(variant)  # raises when unknown
        return t, (None if variant == t.base_id else variant)


def _absolutize_variant(v: dict, root: Path | None) -> dict:
    facets = v.get("facets")
    if not isinstance(facets, dict):
        return v
    return dict(v, facets={k: _absolutize_sel(k, s, root) for k, s in facets.items()})


def _absolutize_sel(kind: str, sel, root: Path | None):
    if not isinstance(sel, dict):
        return sel
    out = dict(sel)
    for key in ("inline", "patch"):
        if isinstance(out.get(key), dict):
            out[key] = absolutize(kind, out[key], root)
    return out


def _absolutize_theme(doc: dict, root: Path | None) -> dict:
    doc = dict(doc)
    if isinstance(doc.get("facets"), dict):
        doc["facets"] = {k: _absolutize_sel(k, s, root) for k, s in doc["facets"].items()}
    if isinstance(doc.get("variants"), list):
        doc["variants"] = [_absolutize_variant(v, root) if isinstance(v, dict) else v for v in doc["variants"]]
    return doc
