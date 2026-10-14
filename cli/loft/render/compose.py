"""The composition cache (docs/THEME-ARCHITECTURE.md §6.2).

    digest(unit) = sha256(salt(unit) + canonical(inputs(unit)) + assets + apps override)
    rendered/units/<unit>/<digest>/<files>          written once, reused
    rendered/compositions/<hash>/                   symlinks to the units' files
        theme.json -> ../../units/shell/<d>/theme.json
        …
        resolved.json   theme, variant, sources, customized, pinned, units
    current -> rendered/compositions/<hash>          (atomic swap)

`hash` covers the unit digests and resolved.json (two selections that render
the same files but differ in identity, e.g. a customization that equals the
default, get their own resolved.json). A unit is rendered only when its
digest is new; switching back to a theme you used is resolve + symlinks.

GC keeps the 8 newest digests per unit and the 16 newest compositions, plus
whatever `current` and `preview` point at and the units those use, and drops
the v1-era rendered/<name>/<hash>/ dirs once `current` has left them.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

from .unit import Source, Unit, canonical

KEEP_UNITS = 8
KEEP_COMPOSITIONS = 16
RESOLVED = "resolved.json"
# Always generated: a pack's apps/ can't replace the shell's or the lock's contract.
NOT_OVERRIDABLE = ("theme.json", "manifest.json", RESOLVED)


def _sha_file(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def apps_files(apps: Path | None) -> dict[str, Path]:
    """A pack's hand-written consumer files: {relative path: file}."""
    if apps is None or not apps.is_dir():
        return {}
    out = {}
    for p in sorted(apps.rglob("*")):
        rel = str(p.relative_to(apps))
        if p.is_file() and rel not in NOT_OVERRIDABLE:
            out[rel] = p
    return out


def _apps_inputs(src: Source, claimed: set[str]) -> dict:
    return {"files": {rel: [str(p), _sha_file(p)] for rel, p in apps_files(src.apps).items() if rel not in claimed}}


def _apps_render(i: dict, template_dir: Path) -> dict:
    return {rel: Path(path) for rel, (path, _) in i["files"].items()}


# apps/ files no unit writes (extra configs a pack ships): a unit of their own.
APPS = Unit(name="apps", reads=(), files=(), inputs=lambda src: {}, render=_apps_render, hook=None, module=__file__)


@dataclass
class Planned:
    unit: Unit
    inputs: dict
    digest: str
    overrides: dict  # file name → apps/ file that replaces it


def plan(src: Source, units: list[Unit]) -> list[Planned]:
    """Every unit's inputs and digest (nothing is rendered)."""
    apps = apps_files(src.apps)
    claimed: set[str] = set()
    out = []
    for u in units:
        inputs = u.inputs(src)
        overrides = {f: apps[f] for f in u.files if f in apps}
        claimed.update(overrides)
        out.append(Planned(u, inputs, _digest(u, inputs, overrides, src.template_dir), overrides))
    extra = _apps_inputs(src, claimed)
    if extra["files"]:
        out.append(Planned(APPS, extra, _digest(APPS, extra, {}, src.template_dir), {}))
    return out


def _digest(u: Unit, inputs: dict, overrides: dict, template_dir: Path) -> str:
    h = hashlib.sha256(u.salt(template_dir).encode())
    h.update(canonical(inputs))
    for src, dest in u.assets(inputs):
        try:
            st = Path(src).stat()
            h.update(f"\0{dest}\0{src}\0{st.st_size}\0{st.st_mtime_ns}".encode())
        except OSError:
            h.update(f"\0{dest}\0{src}\0missing".encode())
    for name, p in sorted(overrides.items()):
        h.update(f"\0apps/{name}\0".encode() + p.read_bytes())
    return h.hexdigest()[:16]


def write_unit(pl: Planned, outdir: Path, template_dir: Path) -> list[str]:
    """Render one unit's files into outdir (which may hold other units' files)."""
    written = []
    files = {} if set(pl.unit.files) and set(pl.unit.files) <= set(pl.overrides) else pl.unit.render(pl.inputs, template_dir)
    files.update(pl.overrides)
    for src, dest in pl.unit.assets(pl.inputs):
        files.setdefault(dest, Path(src))
    for name, content in files.items():
        dest = outdir / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, Path):
            shutil.copyfile(content, dest)
        else:
            dest.write_text(content, encoding="utf-8")
        written.append(name)
    return written


def render_dir(src: Source, units: list[Unit], outdir: Path) -> list[str]:
    """`loft theme render`: every unit's files, flat, into outdir (no cache)."""
    outdir = Path(outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    written: list[str] = []
    for pl in plan(src, units):
        written += [n for n in write_unit(pl, outdir, src.template_dir) if n not in written]
    return written


# ── the cache ───────────────────────────────────────────────────────────────


@dataclass
class Composition:
    path: Path
    units: dict  # unit → digest
    rendered: list = field(default_factory=list)  # units rendered now (cache misses)


def units_root(state_dir: Path) -> Path:
    return state_dir / "rendered" / "units"


def compositions_root(state_dir: Path) -> Path:
    return state_dir / "rendered" / "compositions"


def _mkdtemp(parent: Path, prefix: str) -> Path:
    parent.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(prefix=f".{prefix}-", dir=parent))
    tmp.chmod(0o755)  # mkdtemp is 0700; consumers may run as other users
    return tmp


def _publish(tmp: Path, dest: Path) -> None:
    """Move a finished tmp dir into place (another apply may have won the race)."""
    try:
        tmp.rename(dest)
    except OSError:
        if dest.is_dir():
            shutil.rmtree(tmp, ignore_errors=True)
        else:
            raise


def _touch(p: Path) -> None:
    try:
        os.utime(p)
    except OSError:
        pass


def _files(d: Path) -> list[str]:
    return sorted(str(p.relative_to(d)) for p in d.rglob("*") if p.is_file() or p.is_symlink())


def compose(src: Source, units: list[Unit], state_dir: Path, meta: dict) -> Composition:
    """Render what isn't cached, then the composition dir (not yet current)."""
    rendered = []
    digests = {}
    for pl in plan(src, units):
        d = units_root(state_dir) / pl.unit.name / pl.digest
        digests[pl.unit.name] = pl.digest
        if d.is_dir():
            _touch(d)
            continue
        tmp = _mkdtemp(d.parent, pl.digest)
        try:
            write_unit(pl, tmp, src.template_dir)
        except BaseException:
            shutil.rmtree(tmp, ignore_errors=True)
            raise
        _publish(tmp, d)
        rendered.append(pl.unit.name)
    resolved = dict(meta, units=digests)
    key = hashlib.sha256(canonical({"units": digests, "resolved": resolved})).hexdigest()[:16]
    comp = compositions_root(state_dir) / key
    if comp.is_dir():
        _touch(comp)
        return Composition(comp, digests, rendered)
    tmp = _mkdtemp(comp.parent, key)
    try:
        for name, digest in digests.items():
            udir = units_root(state_dir) / name / digest
            for rel in _files(udir):
                link = tmp / rel
                link.parent.mkdir(parents=True, exist_ok=True)
                if link.is_symlink() or link.exists():
                    link.unlink()
                # Relative, so the state dir can move (and paths stay short).
                link.symlink_to(os.path.relpath(udir / rel, comp / Path(rel).parent))
        (tmp / RESOLVED).write_text(json.dumps(resolved, indent=2) + "\n", encoding="utf-8")
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    _publish(tmp, comp)
    return Composition(comp, digests, rendered)


def units_of(composition: Path) -> dict | None:
    """The unit digests a composition was made of; None for a v1 render dir
    (or nothing), which means: everything changed."""
    try:
        doc = json.loads((composition / RESOLVED).read_text())
    except (OSError, ValueError):
        return None
    u = doc.get("units")
    return u if isinstance(u, dict) else None


def changed(old: dict | None, new: dict) -> list[str]:
    if old is None:
        return list(new)
    return [u for u in new if old.get(u) != new[u]] + [u for u in old if u not in new]


def _target(link: Path) -> Path | None:
    try:
        return link.resolve() if link.is_symlink() else None
    except OSError:
        return None


def gc(state_dir: Path, pinned: list[Path] = (), keep_units: int = KEEP_UNITS, keep_compositions: int = KEEP_COMPOSITIONS) -> dict:
    """Drop old compositions and unit digests. `pinned` (current, preview)
    and the units they use always stay. Returns what was removed."""
    removed = {"compositions": 0, "units": 0}
    croot, uroot = compositions_root(state_dir), units_root(state_dir)
    pinned = [p.resolve() for p in pinned if p is not None]
    comps = sorted((d for d in croot.iterdir() if d.is_dir() and not d.name.startswith(".")), key=lambda d: d.stat().st_mtime, reverse=True) if croot.is_dir() else []
    kept = []
    for i, d in enumerate(comps):
        if i < keep_compositions or d.resolve() in pinned:
            kept.append(d)
        else:
            shutil.rmtree(d, ignore_errors=True)
            removed["compositions"] += 1
    needed: set[tuple[str, str]] = set()
    for d in kept:
        for u, dg in (units_of(d) or {}).items():
            needed.add((u, dg))
    if uroot.is_dir():
        for udir in uroot.iterdir():
            if not udir.is_dir():
                continue
            digs = sorted((d for d in udir.iterdir() if d.is_dir() and not d.name.startswith(".")), key=lambda d: d.stat().st_mtime, reverse=True)
            for i, d in enumerate(digs):
                if i >= keep_units and (udir.name, d.name) not in needed:
                    shutil.rmtree(d, ignore_errors=True)
                    removed["units"] += 1
    # v1-era render dirs (rendered/<name>/<hash>/), once nothing points into them.
    rendered = state_dir / "rendered"
    if rendered.is_dir():
        for d in rendered.iterdir():
            if d.name in ("units", "compositions") or d.name.startswith(".") or not d.is_dir():
                continue
            if not any(d.resolve() in p.parents for p in pinned):
                shutil.rmtree(d, ignore_errors=True)
                removed["legacy"] = removed.get("legacy", 0) + 1
    # Compositions whose units are gone (a unit dir deleted by hand) are broken.
    for d in kept:
        if d.resolve() in pinned:
            continue
        if any(not (uroot / u / dg).is_dir() for u, dg in (units_of(d) or {}).items()):
            shutil.rmtree(d, ignore_errors=True)
            removed["compositions"] += 1
    return removed


def pinned_targets(state_dir: Path) -> list[Path]:
    return [t for t in (_target(state_dir / "current"), _target(state_dir / "preview")) if t is not None]
