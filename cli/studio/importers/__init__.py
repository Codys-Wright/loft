"""Importers: convert upstream theme collections into studio packs at install time.

`studio theme install <importer>:<theme>[,<theme>…]|all[@<git ref>]`
`studio theme install --list <importer>:`

An importer is a module registered in REGISTRY with:

  NAME, URL, LICENSE, DESCRIPTION
  list_themes(up: Upstream) -> list[str]      upstream theme names
  pack_name(theme: str) -> str                the pack it becomes (e.g. cozytile-sakura)
  install(theme, dest, up=None) -> manifest   write a complete pack into dest
  resolve(up, name) -> str                    case-insensitive theme lookup
  prefetch(up, themes) (optional)             batch the downloads for several themes

`up` is a shared, lazily fetched sparse checkout (upstream.Upstream), so
`<importer>:all` fetches the repo's trees once. The upstream URL can be
overridden with STUDIO_<NAME>_URL (tests point it at a local repo). The
themes index (studio-linux-themes/index.json, "importers") names these keys.
"""

from __future__ import annotations

import os
import shutil
import tempfile
import time
from pathlib import Path
from types import ModuleType
from typing import Callable

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
    url = os.environ.get(f"STUDIO_{mod.NAME.upper()}_URL") or mod.URL
    return Upstream(url, gitref, verbose=verbose)


def list_available(ref: str) -> list[tuple[str, str]]:
    """[(upstream theme, pack name)] an importer can install."""
    mod, _, gitref = parse_ref(ref)
    with upstream_for(mod, gitref, verbose=False) as up:
        return [(t, mod.pack_name(t)) for t in mod.list_themes(up)]


def install(
    ref: str,
    user_themes: Path,
    *,
    force: bool = False,
    validate: Callable[[Path], None] | None = None,
    out: Callable[[str], None] = print,
) -> list[str]:
    """Install the packs `ref` names into user_themes; return the installed pack names.

    Each pack is built in a staging dir next to its destination, validated,
    then moved into place, so a failure never leaves a half-written pack.
    Already-installed packs are an error for a single theme and skipped for
    `all` / lists, unless force.
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
                if validate is not None:
                    validate(pack_dir)
                if dest.exists():
                    shutil.rmtree(dest)
                pack_dir.rename(dest)
            finally:
                shutil.rmtree(staging, ignore_errors=True)
            installed.append(name)
            out(f"studio: installed {name} → {dest}")
        if skipped:
            out(f"studio: skipped (already installed; --force replaces): {', '.join(skipped)}")
        out(
            f"studio: {mod.NAME} @ {up.commit[:12]}: downloaded {human(up.fetched_bytes)} "
            f"in {up.fetch_seconds:.1f}s (total {time.monotonic() - t0:.1f}s)"
        )
    return installed
