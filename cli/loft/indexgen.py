"""Build the themes index (loft-themes `index.json`, format 2; index.py).

`loft theme index build [REPO] [-o FILE]` — run in (or on) a checkout of
Codys-Wright/loft-themes; its tools/gen-index script calls this. Inputs:

  REPO/catalog.json   hand-maintained: the repo URL and branch, the importers
                      to list, per-entry overrides and the vibe groups:

      {"repo": "https://github.com/Codys-Wright/loft-themes", "rev": "main",
       "importers": {"qylock": {"source": URL, "license": "GPL-3.0"}, …},
       "entries": {"cozytile-sakura": {"title"?, "description"?, "tags"?: […],
                   "preview"?: {"image": URL}, "curated"?: {"polarity"?, "palette": {…}},
                   "hidden"?: true}, …},
       "vibes": [{"name", "description"?, "packs": […], "wallpapers"?, "locks"?}, …]}

  REPO/packs/<dir>/   the repo's own packs (v1 manifest.json + theme.json, or
                      v2 pack.json): one entry each, installed from git
                      (repo URL, rev, path packs/<dir>), preview palette from
                      the pack, preview image preview.{png,jpg,webp} (else a v1
                      pack's default wallpaper) as a raw URL.

  the importers       each importer's upstream catalog (a tree-only fetch):
                      one entry per upstream theme, named by its v1 pack name
                      (what vibe groups use), `theme` = what it becomes in
                      format 2. `--extract[=IMPORTER,…]` also runs every import
                      (downloads every theme) to record its derived palette; without it,
                      palettes from the previous index.json are kept. An
                      importer that can't be reached keeps its previous entries.

The output is deterministic (sorted, no timestamps), so a regenerated index
only differs when its inputs do.
"""

from __future__ import annotations

import json
import shutil
import tempfile
from pathlib import Path
from typing import Callable

from . import index as I
from .pack import Pack, PackError, is_any_pack, is_pack_v2, pack_id

DEFAULT_REPO = "https://github.com/Codys-Wright/loft-themes"
PREVIEW_NAMES = ("preview.png", "preview.jpg", "preview.webp")


class BuildError(Exception):
    pass


def raw_url(repo: str, rev: str, path: str) -> str:
    """A file's raw URL for a GitHub repo URL (else REPO/raw/REV/PATH)."""
    repo = repo.removesuffix(".git").rstrip("/")
    if repo.startswith("https://github.com/"):
        return f"https://raw.githubusercontent.com/{repo[len('https://github.com/'):]}/{rev}/{path}"
    return f"{repo}/raw/{rev}/{path}"


def _read_json(path: Path) -> dict:
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError) as e:
        raise BuildError(f"{path}: {e}") from e
    if not isinstance(data, dict):
        raise BuildError(f"{path}: not a JSON object")
    return data


def _palette(polarity, pal) -> dict:
    pal = {k: v.lower() for k, v in (pal or {}).items() if k in I.PALETTE_KEYS and isinstance(v, str) and I.HEX.match(v)}
    return {"polarity": polarity if polarity in ("dark", "light") else "dark", "palette": pal}


# ── the repo's own packs ────────────────────────────────────────────────────


def pack_entry(d: Path, rel: str, repo: str, rev: str, builtin: Path | None) -> dict:
    """The entry for one of the repo's packs (d = REPO/<rel>)."""
    pid = pack_id(d)
    preview: dict = {}
    if is_pack_v2(d):
        meta = _read_json(d / "pack.json")
        title = meta.get("name") or pid
        desc = meta.get("description") or ""
        lic = meta.get("license")
        from .facets import resolve as R
        from .facets.model import Catalog, FacetError

        cat = Catalog([], builtin=builtin, extra_packs=[d.resolve()])
        themes = sorted((t for t in cat.themes() if t.pack == pid), key=lambda t: (t.id != pid, t.id))
        if not themes:
            raise BuildError(f"{rel}: the pack has no themes")
        theme = themes[0].id
        try:
            colors = R.resolve(cat, themes[0], None).facets["colors"]
            preview = _palette(colors.get("polarity"), colors.get("palette"))
        except FacetError:
            pass
        extra = {"themes": [t.id for t in themes]} if len(themes) > 1 else {}
    else:
        try:
            p = Pack(d)
        except PackError as e:
            raise BuildError(f"{rel}: {e}") from e
        m = p.manifest or {}
        title = m.get("name") or pid
        desc = m.get("description") or ""
        lic = m.get("license")
        theme = pid
        preview = _palette(p.theme.get("polarity"), p.theme.get("palette"))
        extra = {}
        wp = p.default_wallpaper()
        if wp and wp.get("kind") == "image" and isinstance(wp.get("path"), (str, Path)):
            try:
                preview["image"] = raw_url(repo, rev, f"{rel}/{Path(wp['path']).resolve().relative_to(d.resolve())}")
            except ValueError:
                pass
    for name in PREVIEW_NAMES:
        if (d / name).is_file():
            preview["image"] = raw_url(repo, rev, f"{rel}/{name}")
            break
    if preview.get("palette"):
        preview["paletteFrom"] = "pack"
    e = {
        "name": pid,
        "title": title,
        "description": desc,
        "collection": I.OWN,
        "theme": theme,
        **extra,
        "source": {"git": repo, "rev": rev, "path": rel},
    }
    if lic:
        e["license"] = lic
    if preview:
        e["preview"] = preview
    return e


# ── importer catalogs ───────────────────────────────────────────────────────


def _palette_from(mod_name: str, desc: str) -> str:
    if mod_name == "cozytile":
        return "upstream"
    if "theme.conf colors" in desc:
        return "upstream"
    if "palette from" in desc:
        return "extracted"
    return "default"


def importer_entries(name: str, *, rev: str | None, extract: bool, log: Callable[[str], None]) -> tuple[dict, list[dict]]:
    """({source, license, description, commit}, entries) for one importer."""
    from . import importers

    mod = importers.REGISTRY.get(name)
    if mod is None:
        raise BuildError(f"unknown importer '{name}' (have: {', '.join(sorted(importers.REGISTRY))})")
    out: list[dict] = []
    with importers.upstream_for(mod, rev, verbose=False) as up:
        themes = mod.list_themes(up)
        derived: dict[str, dict] = {}
        if extract and themes:
            if hasattr(mod, "prefetch"):
                mod.prefetch(up, themes)
            tmp = Path(tempfile.mkdtemp(prefix="loft-indexgen-"))
            try:
                for t in themes:
                    d = tmp / mod.pack_name(t)
                    try:
                        manifest = mod.install(t, d, up)
                        theme = json.loads((d / "theme.json").read_text())
                    except (importers.ImporterError, OSError, ValueError) as e:
                        log(f"warning: {name}:{t}: not extracted: {e}")
                        continue
                    pv = _palette(theme.get("polarity"), theme.get("palette"))
                    pv["paletteFrom"] = _palette_from(name, manifest.get("description") or "")
                    derived[t] = pv
            finally:
                shutil.rmtree(tmp, ignore_errors=True)
        for t in themes:
            pid, _, vid = mod.v2_group(t, themes)
            e = {
                "name": mod.pack_name(t),
                "title": f"{getattr(mod, 'TITLE', name)} {t}" if getattr(mod, "TITLE", None) else t,
                "description": "",
                "collection": name,
                "theme": pid + (f"@{vid}" if vid else ""),
                "license": mod.LICENSE,
                "source": {"importer": name, "id": t},
            }
            if t in derived:
                e["preview"] = derived[t]
            out.append(e)
        info = {"source": mod.URL, "license": mod.LICENSE, "description": mod.DESCRIPTION, "commit": up.commit}
    return info, out


# ── build ───────────────────────────────────────────────────────────────────


def build(
    repo: Path,
    *,
    builtin: Path | None = None,
    rev: str | None = None,
    importers: bool = True,
    extract: bool | set[str] = False,
    log: Callable[[str], None] = print,
) -> dict:
    repo = Path(repo)
    catalog = _read_json(repo / "catalog.json") if (repo / "catalog.json").is_file() else {}
    previous = I._read(repo / "index.json")
    prev_entries = {e["name"]: e for e in I.entries(previous)} if previous else {}
    url = catalog.get("repo") or previous.get("repo") or DEFAULT_REPO
    branch = rev or catalog.get("rev") or "main"

    entries: dict[str, dict] = {}
    packs = repo / "packs"
    for d in sorted(packs.iterdir()) if packs.is_dir() else []:
        if d.is_dir() and is_any_pack(d):
            e = pack_entry(d, f"packs/{d.name}", url, branch, builtin)
            if e["name"] in entries:
                raise BuildError(f"packs/{d.name}: '{e['name']}' is already the name of another pack")
            entries[e["name"]] = e

    imp_cfg = catalog.get("importers") if isinstance(catalog.get("importers"), dict) else previous.get("importers") or {}
    imp_info: dict[str, dict] = {}
    for name in sorted(imp_cfg):
        cfg = imp_cfg[name] if isinstance(imp_cfg[name], dict) else {}
        if not importers:
            info, got = {**(previous.get("importers") or {}).get(name, {}), **cfg}, [e for e in prev_entries.values() if (e.get("source") or {}).get("importer") == name]
        else:
            from .importers import ImporterError

            try:
                info, got = importer_entries(name, rev=cfg.get("rev"), extract=extract is True or name in (extract or ()), log=log)
            except ImporterError as e:
                log(f"warning: {name}: {e}; keeping its previous entries")
                info, got = {**(previous.get("importers") or {}).get(name, {}), **cfg}, [e for e in prev_entries.values() if (e.get("source") or {}).get("importer") == name]
            info = {**info, **{k: v for k, v in cfg.items() if k in ("source", "license", "description", "rev")}}
        imp_info[name] = info
        for e in got:
            if e["name"] in entries:
                log(f"warning: {name}: '{e['name']}' is also a pack of the repo; the repo's pack wins")
                continue
            old = prev_entries.get(e["name"]) or {}
            if "preview" not in e and isinstance(old.get("preview"), dict) and old["preview"].get("palette"):
                e["preview"] = {k: v for k, v in old["preview"].items() if k in ("polarity", "palette", "paletteFrom")}
            entries[e["name"]] = e

    overrides = catalog.get("entries") if isinstance(catalog.get("entries"), dict) else {}
    for name, o in sorted(overrides.items()):
        e = entries.get(name)
        if e is None or not isinstance(o, dict):
            log(f"warning: catalog.json: entries.{name}: no such pack or importer theme")
            continue
        if o.get("hidden"):
            del entries[name]
            continue
        for k in ("title", "description", "license"):
            if isinstance(o.get(k), str):
                e[k] = o[k]
        e["tags"] = sorted({*e.get("tags", []), *[t for t in o.get("tags") or [] if isinstance(t, str)]})
        if isinstance(o.get("preview"), dict):
            e["preview"] = {**e.get("preview", {}), **{k: v for k, v in o["preview"].items() if k == "image" and isinstance(v, str)}}
        if "curated" in o:
            c = I.clean_curated(o["curated"])
            if c is None:
                raise BuildError(f"catalog.json: entries.{name}.curated: no valid palette keys ({', '.join(I.PALETTE_KEYS)}) or polarity")
            e["curated"] = c  # laid over preview.palette (the derived one) by readers and at install

    for e in entries.values():
        if not e.get("tags"):
            e.pop("tags", None)
        if not e.get("description"):
            e.pop("description", None)
    vibes = catalog.get("vibes") if isinstance(catalog.get("vibes"), list) else previous.get("vibes") or []
    known = set(entries)
    for g in vibes:
        for p in g.get("packs", []) if isinstance(g, dict) else []:
            if p not in known:
                log(f"warning: vibes {g.get('name')}: '{p}' is not in the index")
    return {
        "version": I.VERSION,
        "repo": url,
        "importers": imp_info,
        "entries": sorted(entries.values(), key=lambda e: (e["collection"] != I.OWN, e["collection"], e["name"])),
        "vibes": vibes,
    }


def dumps(index: dict) -> str:
    return json.dumps(index, indent=2, ensure_ascii=False) + "\n"
