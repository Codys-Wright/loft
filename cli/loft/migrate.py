"""`loft library migrate`: the v1 library → facets, themes and variants
(docs/THEME-ARCHITECTURE.md §5.5). A dry run unless --apply; every step is
idempotent, so a second run finds nothing left to do.

  1. Move the library root (~/Documents/Themes → ~/Documents/Loft, a symlink
     left at the old path; .studio-library.json → .loft-library.json; the
     state dir studio-linux → loft when only the old one exists) and repoint
     links into the old root (~/.local/share/loft/themes).
  2. Convert every v1 pack in Packs/ through the v1 adapter, in place: each
     gets pack.json and facets/<kind>/<id>.json (paths relative to the pack).
     Facets equal to a built-in (after resolution against the pack's colors)
     become references to it (material:imported, material:imported-dense,
     the product shape / typography); equal colors and wallpapers (images
     compared by content) merge into one. Its theme.json and manifest.json
     stay for the v1 readers (the shell's theme list, library sort, vibes,
     wallpaper sets) until they read the facet model, and only JSON is
     written: the images and lock designs stay where they are. Identical
     media files in different packs become hard links.
  3. Group packs into themes with variants by explicit rules (GROUP_RULES):
     an importer's rice (cozytile: all five, one theme in a JSON-only
     `cozytile` pack), an importer's declared pairs (qylock.VARIANT_OF),
     packs with the same colors and wallpapers, and `x` / `x-dark` / `x-light`
     siblings. Everything else is a theme of its own (qylock: collection
     `qylock`).
  4. Aliases: every old pack name still resolves (cozytile-sakura →
     cozytile@sakura; a theme whose id is the old name needs none).
  5. User state: shell.json `appearance` (global) → pins (material patch) and
     accessibility; `perTheme.<name>` → customizations of the theme the name
     resolves to, under the variant it names (sets → Wallpapers/Sets/*.json,
     lockDesign → a lock ref); global wallpaper rotate / per-workspace and
     lock.design → pins; niri.json animations → a motion pin. Merged into
     appearance.json without overwriting what is there; the originals are
     copied to *.pre-loft.json and left in place (the shell still reads
     them until phase E).
  6. A report: printed, and with --apply saved as <state>/migration/<time>.json,
     which `--undo` reads to put everything back.

The render of every old name through its alias is the same as before the
migration (tests/test_migrate.py; the M1 check renders all of them).
"""

from __future__ import annotations

import copy
import hashlib
import json
import os
import re
import shutil
import time
from dataclasses import dataclass, field
from pathlib import Path

from . import color
from .facets import resolve as R
from .facets.model import KINDS, NAME, Catalog, FacetError, relativize
from .pack import FACET_SCHEMA, PACK_JSON, PACK_SCHEMA, THEME_SCHEMA, Pack, PackError, is_pack, is_pack_v2, read_kv, v1_documents, write_doc

LEGACY_ROOT = Path("Documents") / "Themes"  # under $HOME
NEW_ROOT = Path("Documents") / "Loft"
LEGACY_STATE = "studio-linux"
REPORT_DIR = "migration"
BACKUP_SUFFIX = ".pre-loft.json"
HARDLINK_MIN = 64 * 1024  # smaller files aren't worth a link

# Kinds a v1 pack's facets may share with the built-in pack, in the order
# candidates are tried (None: leave the kind out, the product default).
SHARED = {
    "material": ["material:imported", "material:imported-dense", "material:liquid-glass", None],
    "shape": [None, "shape:loft"],
    "typography": [None, "typography:loft"],
}

GROUP_RULES = {
    "rice": "an importer's rice (all its packs are one theme)",
    "declared": "a pair the importer declares (VARIANT_OF)",
    "same-look": "same colors and wallpapers (only the rest differs)",
    "polarity": "x + x-dark / x-light siblings",
    "single": "a theme of its own",
}


def home() -> Path:
    return Path(os.environ.get("HOME") or Path.home())


def default_roots() -> tuple[Path, Path]:
    """(old root, new root): ~/Documents/Themes → $LOFT_LIBRARY when it names
    somewhere else, else ~/Documents/Loft."""
    old = home() / LEGACY_ROOT
    v = os.environ.get("LOFT_LIBRARY", "").strip()
    new = Path(v).expanduser() if v and v.lower() not in ("none", "off") else home() / NEW_ROOT
    if _same(new, old):
        new = home() / NEW_ROOT
    return old, new


def _same(a: Path, b: Path) -> bool:
    return os.path.abspath(a) == os.path.abspath(b)


def humanize(slug: str) -> str:
    words = re.split(r"[-_ ]+", slug)
    return " ".join(w[:1].upper() + w[1:] for w in words if w)


def canonical(obj) -> str:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"))


class Hasher:
    """Content hashes of files, cached by (path, size, mtime)."""

    def __init__(self):
        self._cache: dict[tuple, str] = {}

    def __call__(self, path) -> str:
        p = Path(path)
        try:
            st = p.stat()
        except OSError:
            return f"missing:{p}"
        if p.is_dir():
            return "dir:" + hashlib.sha1(
                "\0".join(f"{q.relative_to(p)}:{self(q)}" for q in sorted(p.rglob("*")) if q.is_file()).encode()
            ).hexdigest()
        key = (str(p), st.st_size, st.st_mtime_ns)
        if key not in self._cache:
            h = hashlib.sha1()
            with open(p, "rb") as f:
                for chunk in iter(lambda: f.read(1 << 20), b""):
                    h.update(chunk)
            self._cache[key] = h.hexdigest()
        return self._cache[key]


# ── the built-in facets a v1 pack's facets may equal ────────────────────────


class Shared:
    """Finds a built-in facet (or the product default) that resolves to the
    same data as a v1 pack's own facet, for that pack's colors."""

    def __init__(self, builtin: Path | None):
        self.cat = Catalog([], builtin=builtin)

    def colors(self, data: dict) -> tuple[str, dict]:
        r, _, _, errs = R.resolve_kind(self.cat, "colors", [("v1", {"inline": data}, None, "theme")])
        if errs:
            raise FacetError("; ".join(errs))
        return r["polarity"], r["palette"]

    def resolved(self, kind: str, sel, polarity: str, pal: dict) -> dict | None:
        raw = [] if sel is None else [("x", sel, None, "theme")]
        r, _, kept, errs = R.resolve_kind(self.cat, kind, raw, polarity, pal)
        return None if errs or len(kept) != len(raw) else r

    def match(self, kind: str, data: dict, polarity: str, pal: dict):
        """The first candidate of SHARED[kind] resolving like data: a ref,
        None (leave it out), or False (no match: the pack keeps its own)."""
        want = self.resolved(kind, {"inline": data}, polarity, pal)
        for cand in SHARED.get(kind, []):
            if self.resolved(kind, cand, polarity, pal) == want:
                return cand
        return False

    def generalize(self, kind: str, data: dict, polarity: str, pal: dict) -> dict:
        """§5.5 dedup rewrites: a glass tint equal to bg → "@bg", the light
        tint → "@mix(bg,#ffffff,0.5)" (kept only when it resolves the same)."""
        if kind != "material" or not isinstance((data.get("glass") or {}).get("tint"), str):
            return data
        tint = color.hex6(data["glass"]["tint"])
        for ref, val in (("@bg", pal["bg"]), ("@mix(bg,#ffffff,0.5)", color.mix(pal["bg"], "#ffffff", 0.5))):
            if tint == color.hex6(val):
                out = copy.deepcopy(data)
                out["glass"]["tint"] = ref
                if self.resolved(kind, {"inline": out}, polarity, pal) == self.resolved(kind, {"inline": data}, polarity, pal):
                    return out
        return data


# ── one v1 pack ─────────────────────────────────────────────────────────────


@dataclass
class Member:
    """A v1 pack being converted."""

    pack: Pack
    theme: dict  # the adapter's theme document (absolute paths)
    docs: dict  # kind → [facet docs] (absolute paths)
    polarity: str
    pal: dict
    sel: dict = field(default_factory=dict)  # kind → the selection its theme / variant uses

    @property
    def name(self) -> str:
        return self.pack.name

    @property
    def path(self) -> Path:
        return self.pack.path

    @property
    def upstream(self) -> dict:
        m = self.pack.manifest or {}
        return m.get("upstream") if isinstance(m.get("upstream"), dict) else {}

    @property
    def importer(self) -> str | None:
        return self.upstream.get("importer")

    def short(self, prefix: str | None = None) -> str:
        """The pack's name without its importer prefix (qylock-osu → osu)."""
        n = self.name
        for p in [prefix] if prefix else [self.importer]:
            if p and n.startswith(p + "-"):
                return n[len(p) + 1 :]
        return n


def load_member(pack: Pack, shared: Shared) -> Member:
    theme, docs = v1_documents(pack)
    by_kind: dict[str, list[dict]] = {}
    for d in docs:
        by_kind.setdefault(d["kind"], []).append(d)
    polarity, pal = shared.colors(by_kind["colors"][0]["data"])
    return Member(pack, theme, by_kind, polarity, pal)


# ── the plan ────────────────────────────────────────────────────────────────


@dataclass
class Group:
    theme: str  # theme id
    home: str  # the pack dir (under Packs/) that holds the theme document
    rule: str
    members: list  # [(Member, variant id or None for the base, variant name)]
    collection: str
    name: str
    base: dict | None = None  # {"id", "name"} when the theme has variants
    new_home: bool = False  # home is a new, JSON-only pack


@dataclass
class Plan:
    old_root: Path
    new_root: Path
    state_dir: Path
    moves: list = field(default_factory=list)  # [(kind, src, dst)]
    links: list = field(default_factory=list)  # [(link, old target, new target)]
    writes: dict = field(default_factory=dict)  # path (under the root it will be at) → doc
    groups: list = field(default_factory=list)
    aliases: dict = field(default_factory=dict)  # old name → theme[@variant]
    facets: dict = field(default_factory=dict)  # kind → {qualified ref}
    shared_refs: dict = field(default_factory=dict)  # ref → [pack names]
    hardlinks: list = field(default_factory=list)  # [(keep, dup, size)]
    skipped: list = field(default_factory=list)
    warnings: list = field(default_factory=list)
    state: dict = field(default_factory=dict)  # {"appearance": doc|None, "changes": [...], "backups": [...], "sets": {path: doc}}
    already: list = field(default_factory=list)  # packs already in v2

    def to_json(self) -> dict:
        return {
            "version": 1,
            "oldRoot": str(self.old_root),
            "newRoot": str(self.new_root),
            "stateDir": str(self.state_dir),
            "moves": [list(map(str, m)) for m in self.moves],
            "links": [list(map(str, x)) for x in self.links],
            "writes": sorted(str(p) for p in self.writes),
            "themes": [
                {
                    "id": g.theme,
                    "pack": g.home,
                    "rule": g.rule,
                    "collection": g.collection,
                    "base": g.base,
                    "variants": [v for _, v, _ in g.members if v is not None and (not g.base or v != g.base["id"])],
                    "members": [m.name for m, _, _ in g.members],
                }
                for g in self.groups
            ],
            "aliases": self.aliases,
            "facets": {k: sorted(v) for k, v in self.facets.items()},
            "hardlinks": [[str(a), str(b), n] for a, b, n in self.hardlinks],
            "skipped": self.skipped,
            "already": self.already,
            "warnings": self.warnings,
            "state": {k: v for k, v in self.state.items() if k != "sets"} | {"sets": sorted(self.state.get("sets", {}))},
        }


def _importer(name: str | None):
    if not name:
        return None
    from . import importers

    return importers.REGISTRY.get(name)


def group_members(members: list[Member], hasher: Hasher) -> list[Group]:
    """Members → themes, by the explicit rules (GROUP_RULES), in a stable order."""
    left = {m.name: m for m in members}
    groups: list[Group] = []

    # 1. An importer's rice: every pack of the importer and upstream URL is one theme.
    rices: dict[tuple, list[Member]] = {}
    for m in members:
        mod = _importer(m.importer)
        if mod is not None and getattr(mod, "RICE", None):
            rices.setdefault((m.importer, m.upstream.get("url")), []).append(m)
    for (imp, _), ms in sorted(rices.items(), key=lambda kv: kv[0][0]):
        mod = _importer(imp)
        order = [t.lower() for t in mod.RICE]
        ms.sort(key=lambda m: (order.index(m.short()) if m.short() in order else len(order), m.name))
        base = ms[0]
        g = Group(theme=imp, home=imp, rule="rice", members=[], collection=imp, name=getattr(mod, "TITLE", humanize(imp)), new_home=True)
        g.base = {"id": base.short(), "name": humanize(base.short())}
        for m in ms:
            g.members.append((m, m.short(), humanize(m.short())))
            left.pop(m.name, None)
        groups.append(g)

    def pair(base: Member, var: Member, vid: str, rule: str) -> None:
        bid = _base_id(base, [vid])
        g = Group(
            theme=base.name, home=base.path.name, rule=rule, members=[], collection=base.importer or "installed",
            name=humanize(base.short()),
        )  # fmt: skip
        g.base = {"id": bid, "name": humanize(bid)}
        g.members = [(base, bid, humanize(bid)), (var, vid, humanize(vid))]
        groups.append(g)
        left.pop(base.name, None)
        left.pop(var.name, None)

    # 2. Pairs an importer declares (qylock.VARIANT_OF: osumania → osu@mania).
    for m in sorted(members, key=lambda m: m.name):
        mod = _importer(m.importer)
        decl = getattr(mod, "VARIANT_OF", {}) if mod else {}
        short = m.short()
        if m.name in left and short in decl:
            bname, vid = decl[short]
            base = left.get(mod.pack_name(bname))
            if base is not None and base is not m:
                pair(base, m, vid, "declared")

    # 3. Same colors and wallpapers (and importer): variants differing in the rest.
    def look(m: Member):
        c = canonical(m.docs["colors"][0]["data"])
        w = m.docs.get("wallpapers")
        return (m.importer, c, wallpapers_key(w[0]["data"], hasher) if w else None)

    by_look: dict = {}
    for m in sorted(left.values(), key=lambda m: m.name):
        if m.docs.get("wallpapers"):
            by_look.setdefault(look(m), []).append(m)
    for ms in by_look.values():
        if len(ms) == 2:
            a, b = sorted(ms, key=lambda m: (len(m.name), m.name))
            vid = b.name[len(a.name) :].strip("-_") if b.name.startswith(a.name) else b.short()
            if vid and NAME.match(vid):
                pair(a, b, vid, "same-look")

    # 4. x + x-dark / x-light siblings.
    for m in sorted(list(left.values()), key=lambda m: m.name):
        for side in ("dark", "light"):
            if m.name in left and m.name.endswith("-" + side):
                base = left.get(m.name[: -len(side) - 1])
                if base is not None and base.importer == m.importer:
                    pair(base, m, side, "polarity")

    for m in sorted(left.values(), key=lambda m: m.name):
        groups.append(Group(theme=m.name, home=m.path.name, rule="single", members=[(m, None, "")], collection=m.importer or "installed", name=humanize(m.short())))
    groups.sort(key=lambda g: (g.collection, g.theme))
    return groups


def wallpapers_key(data: dict, hasher: Hasher) -> str:
    """Wallpapers facets are the same when their images are (by content)."""

    def h(p):
        return hasher(p) if isinstance(p, str) and Path(p).is_absolute() else p

    items = []
    for i in data.get("collection") or []:
        i = {"path": i} if isinstance(i, str) else i
        items.append({k: h(v) if k in ("path", "video", "preview") else v for k, v in sorted(i.items())})
    coll = [i.get("path") if isinstance(i, dict) else i for i in data.get("collection") or []]
    default = coll.index(data["default"]) if data.get("default") in coll else data.get("default")
    sets = [{k: ({r: h(p) for r, p in v.items()} if isinstance(v, dict) else v) for k, v in s.items()} for s in data.get("sets") or []]
    return canonical({"items": items, "default": default, "sets": sets})


def _rel(path: Path, start: Path) -> str:
    return os.path.relpath(path, start)


def assign_facets(
    members: list[Member], shared: Shared, hasher: Hasher, *, pack_of=None, fid_of=None, root_of=None, shared_refs: dict | None = None,
) -> list[tuple[str, str, str, dict, Member]]:  # fmt: skip
    """Each member's facets: a built-in it equals (SHARED), the same facet as
    an earlier member (equal colors; wallpapers with the same images), or its
    own. Sets member.sel; returns the own ones as (pack, kind, id, document,
    member), the document's paths relative to root_of(member).

    pack_of(m): the pack the member's facets go into (default: its own, in
    place); fid_of(m, kind, adapter id): their ids (default: the adapter's,
    which keeps lock names and so the rendered manifest the same);
    root_of(m): that pack's directory (default: the member's)."""
    pack_of = pack_of or (lambda m: m.name)
    fid_of = fid_of or (lambda m, kind, fid: fid)
    root_of = root_of or (lambda m: m.path)
    owned: dict[tuple[str, str], tuple[Member, dict]] = {}  # (kind, dedup key) → owner, adapter doc
    for m in members:
        for kind, docs in m.docs.items():
            if kind == "lock":
                for d in docs:
                    owned[("lock", f"{m.name}/{d['id']}")] = (m, d)
                m.sel["lock"] = f"lock:{pack_of(m)}/{fid_of(m, 'lock', docs[0]['id'])}"
                continue
            d = docs[0]
            if kind in SHARED:
                hit = shared.match(kind, d["data"], m.polarity, m.pal)
                if hit is not False:
                    if hit is not None:
                        m.sel[kind] = hit
                        if shared_refs is not None:
                            shared_refs.setdefault(hit, []).append(m.name)
                    continue
                d = dict(d, data=shared.generalize(kind, d["data"], m.polarity, m.pal))
            key = wallpapers_key(d["data"], hasher) if kind == "wallpapers" else canonical(d["data"])
            if (kind, key) not in owned:
                owned[(kind, key)] = (m, d)
            owner, od = owned[(kind, key)]
            m.sel[kind] = f"{kind}:{pack_of(owner)}/{fid_of(owner, kind, od['id'])}"
    out = []
    for (kind, _), (m, d) in owned.items():
        root = root_of(m)
        fid = fid_of(m, kind, d["id"])
        doc = {"$schema": FACET_SCHEMA, "kind": kind, "id": fid, "name": _facet_label(m, kind, d)}
        for k in ("description", "source", "license"):
            if d.get(k):
                doc[k] = d[k]
        if kind == "colors" and (m.path / "apps").is_dir():
            doc["apps"] = _rel(m.path / "apps", root)
        doc["data"] = relativize(kind, d["data"], root)
        out.append((pack_of(m), kind, fid, doc, m))
    return out


def build(packs_dir: Path, builtin: Path | None, plan: Plan, hasher: Hasher, root_for_writes: Path) -> None:
    """Steps 2-4 for the v1 packs in packs_dir (written under root_for_writes/Packs)."""
    shared = Shared(builtin)
    members: list[Member] = []
    if packs_dir.is_dir():
        for d in sorted(packs_dir.iterdir()):
            if not d.is_dir() or d.is_symlink() or d.name.startswith("."):
                continue
            if is_pack_v2(d):
                plan.already.append(d.name)
                continue
            if not is_pack(d):
                continue
            try:
                members.append(load_member(Pack(d), shared))
            except (PackError, FacetError, KeyError, ValueError, TypeError) as e:
                plan.skipped.append(f"{d.name}: {e}")
    out_packs = root_for_writes / "Packs"

    for pack, kind, fid, doc, m in assign_facets(members, shared, hasher, shared_refs=plan.shared_refs):
        plan.writes[out_packs / m.path.name / "facets" / kind / f"{fid}.json"] = doc
        plan.facets.setdefault(kind, set()).add(f"{kind}:{pack}/{fid}")
    for ref in plan.shared_refs:
        plan.facets.setdefault(ref.split(":")[0], set()).add(ref)

    # pack.json for every converted pack.
    for m in members:
        mf = m.pack.manifest or {}
        meta = {"$schema": PACK_SCHEMA, "format": 2, "id": m.name, "name": humanize(m.short())}
        for k in ("author", "version", "license", "source", "description"):
            if isinstance(mf.get(k), str):
                meta[k] = mf[k]
        if m.upstream:
            meta["upstream"] = m.upstream
        plan.writes[out_packs / m.path.name / PACK_JSON] = meta

    # Themes.
    groups = group_members(members, hasher)
    taken = {d.name for d in packs_dir.iterdir()} if packs_dir.is_dir() else set()
    for g in groups:
        if g.new_home and g.home in taken:
            plan.warnings.append(f"Packs/{g.home} exists already: theme {g.theme} goes into {g.members[0][0].path.name} instead")
            g.home, g.new_home = g.members[0][0].path.name, False
        home_dir = out_packs / g.home
        doc = theme_document(g, packs_dir / g.home)
        plan.writes[home_dir / "themes" / f"{g.theme}.json"] = doc
        if g.new_home:
            first = g.members[0][0]
            up = {k: v for k, v in first.upstream.items() if k != "path"}
            meta = {"$schema": PACK_SCHEMA, "format": 2, "id": g.home, "name": g.name}
            mf = first.pack.manifest or {}
            for k in ("author", "version", "license"):
                if isinstance(mf.get(k), str):
                    meta[k] = mf[k]
            meta["source"] = up.get("url") or mf.get("source", "")
            meta["description"] = f"{g.name}: {len(g.members)} variants (migrated from {', '.join(m.name for m, _, _ in g.members)})"
            if up:
                meta["upstream"] = up
            plan.writes[home_dir / PACK_JSON] = meta
        for m, vid, _ in g.members:
            if m.name != g.theme:
                plan.aliases[m.name] = g.theme + (f"@{vid}" if vid and g.base and vid != g.base["id"] else "")
            else:
                plan.aliases[m.name] = g.theme
    plan.groups += groups
    plan.hardlinks += hardlink_plan([m.path for m in members], hasher)


def _facet_label(m: Member, kind: str, d: dict) -> str:
    if kind == "lock":
        return humanize(d["id"])
    return humanize(m.short())


def theme_document(g: Group, home: Path, v1: bool = True) -> dict:
    """The theme document of a group: the base's selections, each variant's
    differences, identity per member (variants carry what differs), the v1
    link per member (relative to the home pack) and the aliases."""
    base_m = g.members[0][0]

    def ident(m: Member) -> dict:
        mf = m.pack.manifest or {}
        out = {k: mf[k] for k in ("author", "version", "license", "source") if isinstance(mf.get(k), str)}
        if m.upstream:
            out["upstream"] = m.upstream
        link: dict = {"path": _rel(m.path, home)} if v1 else {}
        if v1 and (m.path / "greeter").is_dir():
            link["greeter"] = _rel(m.path / "greeter", home)
        if isinstance(mf.get("vibes"), dict):
            link["vibes"] = mf["vibes"]
        if link:
            out["v1"] = link
        return out

    def facets(m: Member) -> dict:
        return {k: m.sel[k] for k in KINDS if k in m.sel}

    bmf = base_m.pack.manifest or {}
    doc: dict = {"$schema": THEME_SCHEMA, "kind": "theme", "id": g.theme, "name": g.name}
    bid = ident(base_m)
    for k in ("author", "version", "license", "source"):
        if k in bid:
            doc[k] = bid[k]
    doc["description"] = bmf.get("description", "") if not g.new_home else f"{g.name}: " + ", ".join(n for _, _, n in g.members)
    doc["collection"] = g.collection
    doc["facets"] = facets(base_m)
    if g.base:
        doc["base"] = dict(g.base, **({"description": bmf["description"]} if bmf.get("description") else {}))
        variants = []
        for m, vid, vname in g.members[1:]:
            mine = facets(m)
            sel = {k: s for k, s in mine.items() if doc["facets"].get(k) != s}
            sel.update({k: {"inline": {}} for k in doc["facets"] if k not in mine})
            v: dict = {"id": vid, "name": vname}
            mf = m.pack.manifest or {}
            if mf.get("description"):
                v["description"] = mf["description"]
            mi = ident(m)
            for k, val in mi.items():
                if (k == "v1" and v1) or bid.get(k) != val:
                    v[k] = val
            v["facets"] = sel
            variants.append(v)
        doc["variants"] = variants
        app: dict = {}
        for side in ("dark", "light"):
            hit = next((vid for m, vid, _ in g.members if m.polarity == side), None)
            if hit:
                app[side] = hit
        doc["appearance"] = app
    aliases = []
    for m, vid, _ in g.members:
        if m.name == g.theme:
            continue
        aliases.append(m.name if (g.base is None or vid == g.base["id"]) else f"{m.name}@{vid}")
    if aliases:
        doc["aliases"] = aliases
    if "upstream" in bid:
        doc["upstream"] = bid["upstream"]
    if "v1" in bid:
        doc["v1"] = bid["v1"]
    return doc


def hardlink_plan(dirs: list[Path], hasher: Hasher) -> list[tuple[Path, Path, int]]:
    """Identical media files in different packs: (keep, duplicate, size)."""
    by_size: dict[int, list[Path]] = {}
    for d in dirs:
        for p in sorted(d.rglob("*")):
            if p.is_file() and not p.is_symlink() and p.suffix != ".json":
                n = p.stat().st_size
                if n >= HARDLINK_MIN:
                    by_size.setdefault(n, []).append(p)
    out = []
    for n, ps in sorted(by_size.items()):
        if len({p.parent.parts[: len(dirs[0].parent.parts) + 1] for p in ps}) < 2:
            continue  # all in one pack
        by_hash: dict[str, list[Path]] = {}
        for p in ps:
            by_hash.setdefault(hasher(p), []).append(p)
        for same in by_hash.values():
            keep = same[0]
            for dup in same[1:]:
                if os.stat(dup).st_ino != os.stat(keep).st_ino:
                    out.append((keep, dup, n))
    return out


# ── user state (step 5) ─────────────────────────────────────────────────────

ARRANGEMENT = ("wallpaper", "displays", "workspaces", "sameAll", "auto", "autoSeed", "activeSet")


class Names:
    """Old names → (theme, variant) through the plan's aliases and the catalog."""

    def __init__(self, plan: Plan, catalog: Catalog):
        self.plan, self.cat = plan, catalog
        self.docs = {g.theme: g for g in plan.groups}

    def lookup(self, name: str) -> tuple[str, str | None, str | None] | None:
        """(theme id, variant or None for the base, base id or None)."""
        target = self.plan.aliases.get(name)
        if target:
            tid, _, vid = target.partition("@")
            g = self.docs[tid]
            bid = g.base["id"] if g.base else None
            return tid, vid or None, bid
        try:
            t, v = self.cat.theme(name)
        except FacetError:
            return None
        return t.id, v, t.base_id

    def slot(self, name: str) -> tuple[str, str] | None:
        """(theme id, customization slot): the variant (or base) the old name
        meant, or "*" for a theme without variants."""
        hit = self.lookup(name)
        if hit is None:
            return None
        tid, vid, bid = hit
        return tid, (vid or bid or "*")


def _round(x):
    return round(float(x), 4)


def _move_path(p: str, plan: Plan) -> str:
    """A path in the old library → the same file under the new root."""
    if not isinstance(p, str) or not p:
        return p
    old = str(plan.old_root)
    if p == old or p.startswith(old + "/"):
        return str(plan.new_root) + p[len(old) :]
    return p


def convert_state(plan: Plan, catalog: Catalog, locks: dict[str, str]) -> None:
    """Step 5: shell.json / niri.json → appearance.json (merged, nothing
    overwritten). `locks`: real path of a lock design dir → its lock ref."""
    from .facets import appearance as A

    sd = plan.state_dir
    shell_f = sd / "overrides" / "shell.json"
    niri_f = sd / "overrides" / "niri.json"
    changes: list[str] = []
    notes: list[str] = []
    try:
        shell = json.loads(shell_f.read_text()) if shell_f.is_file() else {}
    except (OSError, ValueError) as e:
        shell = {}
        notes.append(f"{shell_f}: unreadable ({e}); nothing converted from it")
    try:
        niri = json.loads(niri_f.read_text()) if niri_f.is_file() else {}
    except (OSError, ValueError):
        niri = {}
    had = A.path(sd).is_file()
    state = A.load(sd)
    before = canonical(state)
    names = Names(plan, catalog)

    def pin(kind: str, sel, why: str) -> None:
        if state["pins"].get(kind) == sel:
            return  # an earlier run
        if kind in state["pins"]:
            notes.append(f"pins.{kind} exists already; kept (not {json.dumps(sel)} from {why})")
            return
        state["pins"][kind] = sel
        changes.append(f"pins.{kind} = {json.dumps(sel)}  ← {why}")

    def custom(tid: str, slot: str, kind: str, sel, why: str) -> None:
        cur = state["customizations"].setdefault(tid, {}).setdefault(slot, {})
        if cur.get(kind) == sel:
            return  # an earlier run
        if kind in cur:
            notes.append(f"customizations.{tid}.{slot}.{kind} exists already; kept")
            return
        cur[kind] = sel
        changes.append(f"customizations.{tid}.{slot}.{kind} = {json.dumps(sel)}  ← {why}")

    def lock_ref(design: str) -> str | None:
        if design == "builtin":
            return "lock:loft"
        real = os.path.realpath(_move_path(design, plan)) if plan.new_root.exists() else os.path.realpath(design)
        return locks.get(real) or locks.get(os.path.realpath(design))

    # Global appearance → a material pin + accessibility.
    ap = shell.get("appearance") if isinstance(shell.get("appearance"), dict) else {}
    patch: dict = {}
    g = ap.get("glass", -1)
    if isinstance(g, (int, float)) and g >= 0:
        patch.setdefault("glass", {})["opacity"] = _round(g)
    elif isinstance(ap.get("glassOpacity"), (int, float)) and ap["glassOpacity"] >= 0:
        patch.setdefault("glass", {})["opacity"] = _round(ap["glassOpacity"])
    for key, path in (("blur", ("blur", "enabled")), ("barBackground", ("menuBar", "background")), ("barAdaptiveText", ("menuBar", "adaptiveText"))):
        v = ap.get(key, -1)
        if isinstance(v, (int, float)) and not isinstance(v, bool) and v in (0, 1):
            patch.setdefault(path[0], {})[path[1]] = bool(v)
    if patch:
        pin("material", {"patch": patch}, "shell.json appearance (global)")
    if ap.get("reduceTransparency") is True and not state["accessibility"].get("reduceTransparency"):
        state["accessibility"]["reduceTransparency"] = True
        changes.append("accessibility.reduceTransparency = true  ← shell.json appearance.reduceTransparency")

    # Global wallpaper behavior and lock design → pins.
    wp = shell.get("wallpaper") if isinstance(shell.get("wallpaper"), dict) else {}
    beh = {}
    if isinstance(wp.get("rotate"), (int, float)) and wp["rotate"] > 0:
        beh["rotate"] = wp["rotate"]
    if wp.get("perWorkspace") is True:
        beh["perWorkspace"] = True
    if beh:
        pin("wallpapers", {"patch": {"behavior": beh}}, "shell.json wallpaper (global)")
    design = (shell.get("lock") or {}).get("design") if isinstance(shell.get("lock"), dict) else None
    if design:
        ref = lock_ref(design)
        if ref:
            pin("lock", ref, "shell.json lock.design")
        else:
            notes.append(f"lock.design {design}: no lock facet has that design; not converted")

    # niri animations → a motion pin.
    anim = niri.get("animations") if isinstance(niri.get("animations"), dict) else {}
    if anim.get("off") is True:
        pin("motion", "motion:minimal", "niri.json animations.off")
    elif isinstance(anim.get("slowdown"), (int, float)) and anim["slowdown"] > 0 and anim["slowdown"] != 1:
        pin("motion", {"patch": {"speed": _round(1 / anim["slowdown"])}}, "niri.json animations.slowdown")

    # perTheme → customizations of the theme each name resolves to.
    sets_out: dict = {}
    per = shell.get("perTheme") if isinstance(shell.get("perTheme"), dict) else {}
    for name, c in sorted(per.items()):
        if not isinstance(c, dict):
            continue
        where = names.slot(name)
        if where is None:
            tid, slot = name, "*"
            notes.append(f"perTheme.{name}: no such theme now; kept as customizations.{name} (shown under removed themes)")
        else:
            tid, slot = where
        arr = {}
        for k in ARRANGEMENT:
            if k not in c:
                continue
            v = c[k]
            if k == "wallpaper":
                v = _move_path(v, plan)
            elif k in ("displays", "workspaces") and isinstance(v, dict):
                v = {kk: _move_path(p, plan) for kk, p in v.items()}
            arr[k] = v
        beh = {k: c[k] for k in ("rotate", "perWorkspace") if k in c}
        wpatch = {}
        if arr:
            wpatch["arrangement"] = arr
        if beh:
            wpatch["behavior"] = beh
        if wpatch:
            custom(tid, slot, "wallpapers", {"patch": wpatch}, f"perTheme.{name}")
        if c.get("lockDesign"):
            ref = lock_ref(c["lockDesign"])
            if ref:
                custom(tid, slot, "lock", ref, f"perTheme.{name}.lockDesign")
            else:
                notes.append(f"perTheme.{name}.lockDesign {c['lockDesign']}: no lock facet has that design; not converted")
        for s in c.get("sets") or []:
            if not isinstance(s, dict) or not s.get("name"):
                continue
            sid = _slug(f"{tid}-{s['name']}")
            disp = {r: _move_path(p, plan) for r, p in (s.get("displays") or {}).items()}
            work = {r: _move_path(p, plan) for r, p in (s.get("workspaces") or {}).items()}
            images = sorted(set(disp.values()) | set(work.values()))
            doc = {
                "$schema": FACET_SCHEMA, "kind": "wallpapers", "id": sid, "name": s["name"],
                "description": f"Saved set of {name} (migrated from shell.json perTheme)",
                "data": {"collection": images, "sets": [{"name": s["name"], "displays": disp, "workspaces": work}]},
            }  # fmt: skip
            dest = plan.new_root / "Wallpapers" / "Sets" / f"{sid}.json"
            if (dest.exists() or (plan.old_root / "Wallpapers" / "Sets" / f"{sid}.json").exists()):
                continue  # an earlier run
            sets_out[str(dest)] = doc
            changes.append(f"Wallpapers/Sets/{sid}.json  ← perTheme.{name}.sets[{s['name']}]")

    # The active selection, when appearance.json doesn't have one yet.
    if not state.get("theme"):
        cur = _current_name(sd)
        hit = names.lookup(cur) if cur else None
        if hit:
            state["theme"], state["variant"] = hit[0], hit[1]
            changes.append(f"theme = {hit[0]}{'@' + hit[1] if hit[1] else ''}  ← current ({cur})")

    plan.state = {
        "appearance": state if canonical(state) != before or not had else None,
        "existed": had,
        "changes": changes,
        "notes": notes,
        "backups": [str(f) for f in (shell_f, niri_f, A.path(sd)) if f.is_file()],
        "sets": sets_out,
    }


def _slug(text: str) -> str:
    return re.sub(r"[^a-z0-9._-]+", "-", text.lower()).strip("-._") or "set"


def _current_name(state_dir: Path) -> str | None:
    for f in ("manifest.json", "theme.json"):
        try:
            n = json.loads((state_dir / "current" / f).read_text()).get("name")
        except (OSError, ValueError):
            continue
        if n:
            return n
    return None


# ── plan / apply / undo ─────────────────────────────────────────────────────


def plan(state_dir: Path, builtin: Path | None, old_root: Path | None = None, new_root: Path | None = None, data_home: Path | None = None, state_home: Path | None = None) -> Plan:
    o, n = default_roots()
    old_root, new_root = Path(old_root or o), Path(new_root or n)
    p = Plan(old_root=old_root, new_root=new_root, state_dir=Path(state_dir))
    hasher = Hasher()

    # Step 1: where the library is now, and what moves.
    if old_root.is_symlink():
        src = new_root  # moved already
    elif old_root.is_dir():
        src = old_root
        if new_root.exists():
            clash = sorted(c.name for c in old_root.iterdir() if (new_root / c.name).exists())
            if clash:
                p.warnings.append(f"{new_root} exists and has {', '.join(clash)} too: those are left in {old_root}, the rest moves")
            p.moves.append(("merge", old_root, new_root))
        else:
            p.moves.append(("move", old_root, new_root))
        p.moves.append(("symlink", old_root, new_root))
    else:
        src = new_root
    legacy_manifest = src / ".studio-library.json"
    if legacy_manifest.is_file() and not (src / ".loft-library.json").exists():
        p.moves.append(("rename", new_root / ".studio-library.json", new_root / ".loft-library.json"))
    if not (src / "Themes").is_dir():
        p.moves.append(("mkdir", new_root / "Themes", new_root / "Themes"))
    if state_home is not None and not os.environ.get("LOFT_STATE_DIR"):
        legacy_state = state_home / LEGACY_STATE
        if legacy_state.is_dir() and not legacy_state.is_symlink() and not p.state_dir.exists():
            p.moves.append(("move", legacy_state, p.state_dir))
    if data_home is not None:
        for link in (data_home / "loft" / "themes",):
            if link.is_symlink():
                t = os.readlink(link)
                nt = _move_path(t, p)
                if nt != t:
                    p.links.append((link, t, nt))

    # Steps 2-4.
    if src.is_dir():
        build(src / "Packs", builtin, p, hasher, new_root)
    # Facets the catalog has already (an earlier run, other packs) count too.
    for g in p.groups:
        for m, _, _ in g.members:
            for k, s in m.sel.items():
                if isinstance(s, str):
                    p.facets.setdefault(k, set()).add(s)

    # Step 5. Lock designs by real path → ref, from the plan and the catalog.
    cat = Catalog([src / "Packs"], builtin=builtin, user=src if src.is_dir() else None)
    locks: dict[str, str] = {}
    for f in cat.facets("lock"):
        if isinstance(f.data.get("path"), str):
            locks.setdefault(os.path.realpath(f.data["path"]), f.id)
    for g in p.groups:
        for m, _, _ in g.members:
            for d in m.docs.get("lock", []):
                ref = f"lock:{m.name}/{d['id']}"
                locks[os.path.realpath(d["data"]["path"])] = ref
                locks[os.path.realpath(_move_path(d["data"]["path"], p))] = ref
    convert_state(p, cat, locks)
    return p


def summary(p: Plan, builtin: Path | None) -> dict:
    """Counts for the report: themes, variants, collections, facets, aliases, pins."""
    cat = Catalog([], builtin=builtin)
    builtin_themes = cat.themes()
    themes = len(p.groups) + len(builtin_themes)
    variants = sum(len(g.members) - 1 for g in p.groups if g.base) + sum(len(t.variant_ids()) for t in builtin_themes)
    chips = sum(len(g.members) for g in p.groups if g.base) + sum(len(t.variant_ids()) + 1 for t in builtin_themes if t.base_id)
    colls: dict[str, int] = {}
    for g in p.groups:
        colls[g.collection] = colls.get(g.collection, 0) + 1
    for t in builtin_themes:
        c = t.doc.get("collection") or "builtin"
        colls[c] = colls.get(c, 0) + 1
    facets = {k: set(v) for k, v in p.facets.items()}
    for t in builtin_themes:
        for sel in [t.doc.get("facets") or {}, *[v.get("facets") or {} for v in t.variants()]]:
            for k, s in sel.items():
                ref = s if isinstance(s, str) else s.get("ref") if isinstance(s, dict) else None
                if ref:
                    facets.setdefault(k, set()).add(cat.facet(ref, k, t.pack).id)
    builtin_aliases = sum(1 for t in builtin_themes for a in t.doc.get("aliases") or [] if a.partition("@")[0] != "default")
    return {
        "themes": themes,
        "variants": variants,
        "chips": chips,
        "collections": dict(sorted(colls.items())),
        "facets": {k: len(v) for k, v in sorted(facets.items())},
        "aliases": sum(1 for a, t in p.aliases.items() if a != t) + builtin_aliases,
        "oldNames": len(p.aliases) + builtin_aliases,
        "pins": sorted((p.state.get("appearance") or {}).get("pins", {})),
        "hardlinks": {"files": len(p.hardlinks), "bytes": sum(n for _, _, n in p.hardlinks)},
    }


def nothing_to_do(p: Plan) -> bool:
    return not (p.moves or p.links or p.writes or p.hardlinks or p.state.get("appearance") is not None or p.state.get("sets"))


def render_report(p: Plan, s: dict, applied: bool) -> str:
    L: list[str] = []
    if nothing_to_do(p):
        L.append(f"loft library migrate — nothing left to do: the library is at {p.new_root}"
                 + (f", {len(p.already)} packs are v2" if p.already else "") + ", and the settings are converted.")
        L += [f"  note: {n}" for n in p.state.get("notes", [])]
        L += [f"warning: {w}" for w in p.warnings] + [f"skipped: {sk}" for sk in p.skipped]
        return "\n".join(L)
    verb = "Done" if applied else "Would do (dry run; --apply acts)"
    L.append(f"loft library migrate — {verb}")
    L.append(f"  library: {p.old_root} → {p.new_root}")
    for kind, a, b in p.moves:
        L.append(f"  {kind:8} {a}" + (f" → {b}" if kind not in ("mkdir",) else ""))
    for link, a, b in p.links:
        L.append(f"  relink   {link}: {a} → {b}")
    L.append("")
    L.append(
        f"Themes: {s['themes']} ({', '.join(f'{c} {n}' for c, n in s['collections'].items())}); "
        f"{s['variants']} variants ({s['chips']} chips counting bases)"
    )
    L.append("Facets: " + ", ".join(f"{n} {k}" for k, n in s["facets"].items()))
    L.append(f"Old names: {s['oldNames']} resolve ({s['aliases']} through aliases, the rest are theme ids; built-ins included)")
    for g in p.groups:
        if g.base:
            vs = " · ".join(v for _, v, _ in g.members)
            L.append(f"  {g.theme:28} {g.rule:9} {vs}   (from {', '.join(m.name for m, _, _ in g.members)})")
    singles = [g.theme for g in p.groups if not g.base]
    if singles:
        L.append(f"  + {len(singles)} single themes: {', '.join(singles)}")
    aliased = {a: t for a, t in p.aliases.items() if a != t}
    if aliased:
        L.append("Aliases: " + ", ".join(f"{a} → {t}" for a, t in sorted(aliased.items())))
    if p.shared_refs:
        L.append("Shared facets: " + ", ".join(f"{r} ×{len(u)}" for r, u in sorted(p.shared_refs.items())))
    hl = s["hardlinks"]
    if hl["files"]:
        L.append(f"Hard links: {hl['files']} duplicate files, {hl['bytes'] / 1e6:.1f} MB")
    L.append(f"Files written: {len(p.writes) + len(p.state.get('sets', {}))} JSON documents")
    st = p.state
    L.append("")
    L.append(f"User state ({p.state_dir}):")
    for c in st.get("changes", []):
        L.append(f"  {c}")
    if not st.get("changes"):
        L.append("  nothing to convert")
    for n in st.get("notes", []):
        L.append(f"  note: {n}")
    if st.get("backups") and st.get("appearance") is not None:
        L.append("  originals kept as *" + BACKUP_SUFFIX + ": " + ", ".join(Path(b).name for b in st["backups"]))
    for w in p.warnings:
        L.append(f"warning: {w}")
    for sk in p.skipped:
        L.append(f"skipped: {sk}")
    if p.already:
        L.append(f"already v2: {len(p.already)} packs")
    return "\n".join(L)


def apply(p: Plan, builtin: Path | None, hardlinks: bool = True) -> dict:
    """Carry out a plan; returns the undo record (also saved in the report)."""
    from .facets import appearance as A

    undo: dict = {"moves": [], "links": [], "created": [], "dirs": [], "backups": [], "appearance": None, "hardlinks": 0}

    def mkdirs(d: Path) -> None:
        missing = []
        while not d.exists():
            missing.append(d)
            d = d.parent
        for m in reversed(missing):
            m.mkdir()
            undo["dirs"].append(str(m))

    for kind, a, b in p.moves:
        a, b = Path(a), Path(b)
        if kind == "move" and a.exists() and not b.exists():
            mkdirs(b.parent)
            os.rename(a, b)
            undo["moves"].append(["move", str(a), str(b)])
        elif kind == "merge" and a.is_dir() and not a.is_symlink():
            for c in sorted(a.iterdir()):
                if not (b / c.name).exists():
                    os.rename(c, b / c.name)
                    undo["moves"].append(["move", str(c), str(b / c.name)])
            try:
                a.rmdir()
            except OSError:
                pass
        elif kind == "symlink" and not a.exists() and not a.is_symlink():
            a.symlink_to(b)
            undo["moves"].append(["symlink", str(a), str(b)])
        elif kind == "rename" and a.is_file() and not b.exists():
            os.rename(a, b)
            undo["moves"].append(["move", str(a), str(b)])
        elif kind == "mkdir" and not a.exists():
            mkdirs(a)
    for link, old, new in p.links:
        if Path(link).is_symlink() and os.readlink(link) == old:
            tmp = Path(link).with_name(f".{Path(link).name}.{os.getpid()}")
            tmp.symlink_to(new)
            os.replace(tmp, link)
            undo["links"].append([str(link), old, new])

    # Documents: never over something that is there already (idempotence).
    for path, doc in sorted({**{Path(k): v for k, v in p.state.get("sets", {}).items()}, **p.writes}.items()):
        path = Path(path)
        if path.exists():
            continue
        mkdirs(path.parent)
        write_doc(path, doc)
        undo["created"].append(str(path))

    if hardlinks:
        for keep, dup, _ in p.hardlinks:
            keep, dup = Path(_move_path(str(keep), p)), Path(_move_path(str(dup), p))
            try:
                if os.stat(keep).st_ino == os.stat(dup).st_ino or Hasher()(keep) != Hasher()(dup):
                    continue
                tmp = dup.with_name(f".{dup.name}.loft-link")
                os.link(keep, tmp)
                os.replace(tmp, dup)
                undo["hardlinks"] += 1
            except OSError as e:
                p.warnings.append(f"hard link {dup}: {e}")

    st = p.state
    if st.get("appearance") is not None:
        for b in st.get("backups", []):
            b = Path(b)
            bk = b.with_name(b.name.removesuffix(".json") + BACKUP_SUFFIX)
            if b.is_file() and not bk.exists():
                shutil.copy2(b, bk)
                undo["backups"].append([str(b), str(bk)])
        f = A.path(p.state_dir)
        undo["appearance"] = {"file": str(f), "existed": f.is_file(), "before": json.loads(f.read_text()) if f.is_file() else None}
        mkdirs(f.parent)
        A.save(p.state_dir, st["appearance"])
    return undo


def save_report(p: Plan, s: dict, undo: dict, text: str) -> Path:
    d = p.state_dir / REPORT_DIR
    d.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    f = d / f"{stamp}.json"
    n = 2
    while f.exists():
        f, n = d / f"{stamp}-{n}.json", n + 1
    f.write_text(json.dumps({"summary": s, "plan": p.to_json(), "undo": undo, "text": text}, indent=1) + "\n")
    f.with_suffix(".txt").write_text(text + "\n")
    return f


def latest_report(state_dir: Path) -> Path | None:
    d = Path(state_dir) / REPORT_DIR
    reps = sorted(d.glob("*.json")) if d.is_dir() else []
    return reps[-1] if reps else None


def undo(report: Path) -> list[str]:
    """Put back what an applied migration did (its report's undo record).
    Hard links stay (same content); the original JSON files were never changed."""
    rec = json.loads(Path(report).read_text())["undo"]
    done: list[str] = []
    ap = rec.get("appearance")
    if ap:
        f = Path(ap["file"])
        if ap["existed"]:
            write_doc(f, ap["before"])
            done.append(f"restored {f}")
        elif f.exists():
            f.unlink()
            done.append(f"removed {f}")
    for _, bk in rec.get("backups", []):
        if Path(bk).exists():
            Path(bk).unlink()
            done.append(f"removed {bk}")
    for f in reversed(rec.get("created", [])):
        if Path(f).is_file():
            Path(f).unlink()
    if rec.get("created"):
        done.append(f"removed {len(rec['created'])} written documents")
    for d in sorted(rec.get("dirs", []), key=lambda d: -len(d)):
        try:
            Path(d).rmdir()
        except OSError:
            pass
    for link, old, _new in reversed(rec.get("links", [])):
        if Path(link).is_symlink():
            tmp = Path(link).with_name(f".{Path(link).name}.{os.getpid()}")
            tmp.symlink_to(old)
            os.replace(tmp, link)
            done.append(f"relinked {link} → {old}")
    for kind, a, b in reversed(rec.get("moves", [])):
        a, b = Path(a), Path(b)
        if kind == "symlink" and a.is_symlink():
            a.unlink()
            done.append(f"removed symlink {a}")
        elif kind == "move" and b.exists() and not a.exists():
            os.rename(b, a)
            done.append(f"moved {b} → {a}")
    return done


# ── importers: fresh v1 builds → one v2 pack (§5.5 "Importers write v2") ────


def _base_id(base: Member, vids: list[str]) -> str:
    """The base's chip id: its polarity when the variants are the other one
    (material-you + dark → light), else its own short name."""
    if vids and all(v in ("dark", "light") for v in vids) and base.polarity not in vids:
        return base.polarity
    return base.short()


def import_packs(mod, pid: str, built: list[tuple[Path, str | None]], out: Path, builtin: Path | None) -> dict:
    """Turn freshly built v1 packs (an importer's `install`) into the v2
    pack `out` (which may hold an earlier install, copied with hard links:
    nothing in it is written in place). built: [(v1 dir, variant id or None
    for the theme's base)], the base first. Assets move into the pack (a
    rice: every member under <variant>/; otherwise the base at the root and
    each variant under <variant>/), the facets go into facets/, the theme
    into themes/<pid>.json (variants of an earlier install kept), and the v1
    files are dropped. Returns the theme document."""
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    out = out.resolve()
    shared, hasher = Shared(builtin), Hasher()
    rice = bool(getattr(mod, "RICE", None))
    tfile = out / "themes" / f"{pid}.json"
    try:
        old = json.loads(tfile.read_text()) if tfile.is_file() else None
    except ValueError:
        old = None
    old_vids = [v.get("id") for v in (old or {}).get("variants") or [] if isinstance(v, dict)]
    members: list[Member] = []
    vids: list[str | None] = []
    for v1dir, vid in built:
        short = Pack(v1dir).name
        short = short[len(mod.NAME) + 1 :] if short.startswith(mod.NAME + "-") else short
        sub = (vid or short) if rice else (vid or "")
        target = out / sub if sub else out
        if sub:
            shutil.rmtree(target, ignore_errors=True)
        else:  # the base at the root: drop its previous assets, keep variants' dirs
            keep = {PACK_JSON, "themes", "facets", *(v for v in old_vids if v), *(v for _, v in built if v)}
            for c in list(out.iterdir()):
                if c.name not in keep:
                    shutil.rmtree(c) if c.is_dir() and not c.is_symlink() else c.unlink()
        target.mkdir(parents=True, exist_ok=True)
        for c in sorted(Path(v1dir).iterdir()):
            os.rename(c, target / c.name)
        members.append(load_member(Pack(target), shared))
        vids.append(vid)

    def fid(m: Member, kind: str, f: str) -> str:
        return f if kind == "lock" else _slug(m.short())

    for _pack, kind, f, doc, _m in assign_facets(members, shared, hasher, pack_of=lambda m: pid, fid_of=fid, root_of=lambda m: out):
        write_doc(out / "facets" / kind / f"{f}.json", doc)

    base = members[0]
    var_ids = [v for v in vids[1:] if v] + [v for v in old_vids if v and v not in vids]
    has_variants = bool(var_ids) or rice
    g = Group(
        theme=pid, home=pid, rule="rice" if rice else "declared" if has_variants else "single", members=[],
        collection=mod.NAME, name=getattr(mod, "TITLE", None) if rice else humanize(base.short()),
    )  # fmt: skip
    g.name = g.name or humanize(pid)
    bid = _base_id(base, [v for v in var_ids if v])
    if has_variants:
        g.base = {"id": bid, "name": humanize(bid)}
    g.members = [(base, bid if has_variants else None, humanize(bid))] + [(m, v, humanize(v)) for m, v in zip(members[1:], vids[1:])]
    doc = theme_document(g, out, v1=False)
    if rice:
        doc["description"] = f"{g.name}: " + ", ".join([humanize(bid)] + [humanize(v) for v in var_ids])
    # Variants of an earlier install that weren't rebuilt now stay.
    if old:
        rebuilt = {v.get("id") for v in doc.get("variants") or []}
        kept = [v for v in old.get("variants") or [] if isinstance(v, dict) and v.get("id") not in rebuilt and v.get("id") != bid]
        if kept:
            doc.setdefault("variants", []).extend(kept)
            doc["aliases"] = list(dict.fromkeys([*(doc.get("aliases") or []), *(old.get("aliases") or [])]))
            app = dict(old.get("appearance") or {})
            app.update(doc.get("appearance") or {})
            doc["appearance"] = app
    if rice and doc.get("variants"):
        order = [t.lower() for t in mod.RICE]
        doc["variants"].sort(key=lambda v: order.index(v["id"]) if v["id"] in order else len(order))
    write_doc(tfile, doc)
    for m in members:
        for f in ("theme.json", "manifest.json"):
            (m.path / f).unlink(missing_ok=True)
    mf = base.pack.manifest or {}
    meta = {"$schema": PACK_SCHEMA, "format": 2, "id": pid, "name": g.name}
    for k in ("author", "version", "license"):
        if isinstance(mf.get(k), str):
            meta[k] = mf[k]
    up = {k: v for k, v in base.upstream.items() if k != "path"}
    meta["source"] = up.get("url") or mf.get("source", "")
    meta["description"] = doc["description"] if rice else mf.get("description", "")
    if up:
        meta["upstream"] = up
    write_doc(out / PACK_JSON, meta)
    return doc


def installed_members(dest: Path) -> set[str]:
    """Upstream themes a v2 pack holds (lower case), from its themes' upstream paths."""
    out: set[str] = set()
    tdir = Path(dest) / "themes"
    for f in sorted(tdir.glob("*.json")) if tdir.is_dir() else []:
        try:
            doc = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        for d in [doc, *[v for v in doc.get("variants") or [] if isinstance(v, dict)]]:
            up = d.get("upstream") if isinstance(d.get("upstream"), dict) else {}
            if up.get("path"):
                out.add(Path(up["path"]).name.lower())
    return out
