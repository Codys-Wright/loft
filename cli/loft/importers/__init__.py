"""Importers: convert upstream theme collections into Loft packs at install time.

`loft theme install <importer>:<theme>[,<theme>…]|all[@<git ref>]`
`loft theme install --list <importer>:`

Packs are written in format 2 (docs/THEME-ARCHITECTURE.md §5.5): the
importer builds each upstream theme as a v1 pack in a staging dir, and
migrate.import_packs turns them into one v2 pack per theme — cozytile: one
`cozytile` pack whose theme has a variant per upstream theme; qylock: a
`qylock-<theme>` pack, the declared pairs (VARIANT_OF) as variants of one.
Installing a variant brings its theme's base; installing more variants
later adds them to the pack. `--v1` (LOFT_IMPORT_FORMAT=1) writes the old
one-pack-per-theme v1 packs, which the shell's theme picker lists until it
reads the facet model.

An importer is a module registered in REGISTRY with:

  NAME, URL, LICENSE, DESCRIPTION
  list_themes(up: Upstream) -> list[str]      upstream theme names
  pack_name(theme: str) -> str                its v1 pack name (e.g. cozytile-sakura; old names, aliases)
  v2_group(theme, available) -> (pack, base theme, variant id | None for the base)
  install(theme, dest, up=None) -> manifest   write a complete v1 pack into dest
  resolve(up, name) -> str                    case-insensitive theme lookup
  prefetch(up, themes) (optional)             batch the downloads for several themes
  RICE, TITLE (optional)                      every theme is a variant of one theme (cozytile)
  VARIANT_OF (optional)                       {theme: (base theme, variant id)} (qylock)

`up` is a shared, lazily fetched sparse checkout (upstream.Upstream), so
`<importer>:all` fetches the repo's trees once. The upstream URL can be
overridden with LOFT_<NAME>_URL (tests point it at a local repo). The
themes index (loft-themes/index.json, "importers") names these keys.
"""

from __future__ import annotations

import json
import os
import shutil
import tempfile
import time
from pathlib import Path
from types import ModuleType
from typing import Callable

from .. import index as theme_index
from . import cozytile, qylock
from .upstream import ImporterError, Upstream, human

REGISTRY: dict[str, ModuleType] = {m.NAME: m for m in (cozytile, qylock)}

__all__ = ["REGISTRY", "ImporterError", "Upstream", "is_importer_ref", "parse_ref", "list_available", "install"]


def is_importer_ref(ref: str) -> bool:
    return ref.split(":", 1)[0] in REGISTRY and ":" in ref


def parse_ref(ref: str) -> tuple[ModuleType, list[str], str | None]:
    """'qylock:pixel-sakura,forest@abc123' → (qylock, ['pixel-sakura', 'forest'], 'abc123')."""
    name, _, rest = ref.partition(":")
    if name not in REGISTRY:
        raise ImporterError(f"unknown importer '{name}' (have: {', '.join(sorted(REGISTRY))})")
    rest, _, gitref = rest.partition("@")
    themes = [t.strip() for t in rest.split(",") if t.strip()]
    return REGISTRY[name], themes, gitref or None


def upstream_for(mod: ModuleType, gitref: str | None = None, verbose: bool = True) -> Upstream:
    url = os.environ.get(f"LOFT_{mod.NAME.upper()}_URL") or mod.URL
    return Upstream(url, gitref, verbose=verbose)


def list_available(ref: str) -> list[tuple[str, str]]:
    """[(upstream theme, what it becomes)] an importer can install: the theme
    (or theme@variant) it becomes in format 2, else its v1 pack name."""
    mod, _, gitref = parse_ref(ref)
    with upstream_for(mod, gitref, verbose=False) as up:
        themes = mod.list_themes(up)
        if v1_format():
            return [(t, mod.pack_name(t)) for t in themes]
        out = []
        for t in themes:
            pid, _, vid = mod.v2_group(t, themes)
            out.append((t, pid + (f"@{vid}" if vid else "")))
        return out


def v1_format() -> bool:
    return os.environ.get("LOFT_IMPORT_FORMAT", "").strip() == "1"


def install(
    ref: str,
    user_themes: Path,
    *,
    force: bool = False,
    validate: Callable[[Path], None] | None = None,
    out: Callable[[str], None] = print,
    index: dict | None = None,
    v1: bool | None = None,
    builtin: Path | None = None,
) -> list[str]:
    """Install the packs `ref` names into user_themes (format 2, or v1 with
    v1=True); return the installed pack names."""
    if v1 if v1 is not None else v1_format():
        return install_v1(ref, user_themes, force=force, validate=validate, out=out, index=index)
    from .. import migrate

    mod, themes, gitref = parse_ref(ref)
    if not themes:
        raise ImporterError(f"name a theme: {mod.NAME}:<theme> or {mod.NAME}:all (list them with --list {mod.NAME}:)")
    installed: list[str] = []
    skipped: list[str] = []
    t0 = time.monotonic()
    with upstream_for(mod, gitref) as up:
        available = mod.list_themes(up)
        many = themes == ["all"] or len(themes) > 1
        targets = available if themes == ["all"] else [mod.resolve(up, t) for t in themes]
        groups: dict[str, dict] = {}
        for t in targets:
            pid, base, vid = mod.v2_group(t, available)
            g = groups.setdefault(pid, {"base": base, "want": []})
            if t not in g["want"]:
                g["want"].append(t)
        user_themes.mkdir(parents=True, exist_ok=True)
        plans = []
        for pid, g in groups.items():
            dest = user_themes / pid
            have = migrate.installed_members(dest) if dest.exists() else set()
            want = g["want"] if force or not dest.exists() else [t for t in g["want"] if t.lower() not in have]
            if not want:
                if not many:
                    raise ImporterError(f"{pid} already has {', '.join(g['want'])} ({dest}); use --force to replace it")
                skipped.append(pid)
                continue
            # The base always comes along (a variant is a delta on it).
            build = [g["base"]] + [t for t in want if t != g["base"]]
            plans.append((pid, dest, build, g["base"]))
        if plans and hasattr(mod, "prefetch"):
            mod.prefetch(up, [t for _, _, b, _ in plans for t in b])
        for pid, dest, build, base in plans:
            staging = Path(tempfile.mkdtemp(prefix=f".{pid}-", dir=user_themes))
            try:
                built = []
                for t in build:
                    d = staging / "v1" / mod.pack_name(t)
                    mod.install(t, d, up)
                    if index:
                        add_index_vibes(d, index)
                    _, _, vid = mod.v2_group(t, available)
                    built.append((d, None if t == base else vid))
                pack_dir = staging / pid
                if dest.exists() and not force:
                    # Hard links: import_packs never writes a file in place.
                    shutil.copytree(dest, pack_dir, symlinks=True, copy_function=os.link)
                migrate.import_packs(mod, pid, built, pack_dir, builtin)
                if validate is not None:
                    validate(pack_dir)
                if dest.exists():
                    shutil.rmtree(dest)
                pack_dir.rename(dest)
            finally:
                shutil.rmtree(staging, ignore_errors=True)
            installed.append(pid)
            out(f"loft: installed {pid} ({', '.join(build)}) → {dest}")
        if skipped:
            out(f"loft: skipped (already installed; --force replaces): {', '.join(skipped)}")
        out(
            f"loft: {mod.NAME} @ {up.commit[:12]}: downloaded {human(up.fetched_bytes)} "
            f"in {up.fetch_seconds:.1f}s (total {time.monotonic() - t0:.1f}s)"
        )
    return installed


def install_v1(
    ref: str,
    user_themes: Path,
    *,
    force: bool = False,
    validate: Callable[[Path], None] | None = None,
    out: Callable[[str], None] = print,
    index: dict | None = None,
) -> list[str]:
    """Install the packs `ref` names into user_themes as v1 packs; return the installed pack names.

    Each pack is built in a staging dir next to its destination, validated,
    then moved into place, so a failure never leaves a half-written pack.
    Already-installed packs are an error for a single theme and skipped for
    `all` / lists, unless force. Vibe links the themes `index` declares for a
    pack are written into its manifest (`vibes`), so they hold offline too.
    """
    mod, themes, gitref = parse_ref(ref)
    if not themes:
        raise ImporterError(f"name a theme: {mod.NAME}:<theme> or {mod.NAME}:all (list them with --list {mod.NAME}:)")
    installed: list[str] = []
    skipped: list[str] = []
    t0 = time.monotonic()
    with upstream_for(mod, gitref) as up:
        if themes == ["all"]:
            targets = mod.list_themes(up)
            many = True
        else:
            targets = [mod.resolve(up, t) for t in themes]
            many = len(targets) > 1
        user_themes.mkdir(parents=True, exist_ok=True)
        todo = [t for t in targets if force or not (user_themes / mod.pack_name(t)).exists()]
        if todo and hasattr(mod, "prefetch"):
            mod.prefetch(up, todo)
        for theme in targets:
            name = mod.pack_name(theme)
            dest = user_themes / name
            if dest.exists() and not force:
                if not many:
                    raise ImporterError(f"{name} is already installed ({dest}); use --force to replace it")
                skipped.append(name)
                continue
            staging = Path(tempfile.mkdtemp(prefix=f".{name}-", dir=user_themes))
            try:
                pack_dir = staging / name
                mod.install(theme, pack_dir, up)
                if index:
                    add_index_vibes(pack_dir, index)
                if validate is not None:
                    validate(pack_dir)
                if dest.exists():
                    shutil.rmtree(dest)
                pack_dir.rename(dest)
            finally:
                shutil.rmtree(staging, ignore_errors=True)
            installed.append(name)
            out(f"loft: installed {name} → {dest}")
        if skipped:
            out(f"loft: skipped (already installed; --force replaces): {', '.join(skipped)}")
        out(
            f"loft: {mod.NAME} @ {up.commit[:12]}: downloaded {human(up.fetched_bytes)} "
            f"in {up.fetch_seconds:.1f}s (total {time.monotonic() - t0:.1f}s)"
        )
    return installed


def add_index_vibes(pack_dir: Path, index: dict) -> None:
    """Merge the index's curated links for this pack into its manifest."""
    mf = pack_dir / "manifest.json"
    manifest = json.loads(mf.read_text())
    links = theme_index.merge_links(manifest.get("vibes"), theme_index.links_for(index, manifest["name"]))
    links = {k: v for k, v in links.items() if v}
    if links:
        manifest["vibes"] = links
        mf.write_text(json.dumps(manifest, indent=2) + "\n")
