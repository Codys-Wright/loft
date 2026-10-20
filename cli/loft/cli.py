"""loft — the Loft CLI (theme engine + manager).

Environment (all optional):
  LOFT_STATE_DIR       `current` → the active composition, `rendered/` cache
                       (units/<unit>/<digest>, compositions/<hash>)
                       (default: $XDG_STATE_HOME/loft)
  LOFT_THEME_PATH      colon-separated dirs of theme packs
                       (default: $XDG_DATA_HOME/loft/themes, then built-ins);
                       the library's Packs/ always joins, before the built-ins
  LOFT_LIBRARY         the theme + wallpaper library (default: ~/Documents/Loft, or
                       ~/Documents/Themes until `loft library migrate` moves it;
                       `none` = off). When it exists, packs install into its Packs/
  LOFT_SHELL_PATH      Quickshell config of the running shell, for IPC
  LOFT_DATA_DIR        root holding themes/ and templates/render/ (default: this tree)
  LOFT_TEMPLATE_DIR    override the render templates (dev)
  LOFT_HOOKS           reload hooks after apply (each runs only when its unit's
                       output changed): all|none|comma list of shell,niri,
                       wallpapers,kitty,ghostty,gtk,spotify
                       (default: all; --dev: shell,niri,wallpapers)
  LOFT_THEME_INDEX     themes index (path, file:// or http(s) URL; `none` = off)
                       for curated vibe links (default: loft-themes on GitHub)
  LOFT_THEME_ENGINE    `v1`: apply/render a pack by name or path alone, bypassing
                       the catalog and appearance.json (themecmds.py);
                       default: resolve every theme name

The STUDIO_* names from before the rename (studio-linux) are read when the
LOFT_* one is unset.

`loft --dev …` targets the session started by `nix run .#dev` instead
($LOFT_SESSION=NAME: the one started with `loft-dev --session NAME`).
`loft dev …` starts sessions: it is `loft-dev …`.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

from . import capture, cleaner, dock, doctor, greeter, hooks, importers, index, island, keys, library, mcp, media, ports, render, spotify, themecmds, transparency, updates, utilities, vibes, wallsets, wallvideo
from .facets import FacetError
from .pack import IGNORED, Pack, PackError, is_any_pack, is_pack, is_pack_v2, pack_id, validate_v2

NAME = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
TAR_SUFFIXES = (".tar", ".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.bz2", ".tar.zst", ".tzst")


class Fail(Exception):
    pass


def _env(key: str) -> str | None:
    return os.environ.get(key) or None


class Ctx:
    def __init__(self, dev: bool):
        self.dev = dev
        here = Path(__file__).resolve().parents[2]
        self.data_dir = Path(_env("LOFT_DATA_DIR") or here)
        self.template_dir = Path(_env("LOFT_TEMPLATE_DIR") or self.data_dir / "templates" / "render")
        self.schema = self.data_dir / "themes" / "schema.json"
        self.builtin_themes = self.data_dir / "themes"
        home = Path.home()
        data_home = Path(_env("XDG_DATA_HOME") or home / ".local" / "share")
        state_home = Path(_env("XDG_STATE_HOME") or home / ".local" / "state")
        self.legacy_themes = data_home / "loft" / "themes"
        self.state_dir = Path(_env("LOFT_STATE_DIR") or state_home / "loft")
        tp = _env("LOFT_THEME_PATH") or f"{self.legacy_themes}:{self.builtin_themes}"
        self.theme_path = [Path(p) for p in tp.split(":") if p]
        # The library (library.py): its Packs/ is where packs install when it
        # exists, and it is always searched, first (so a freshly installed
        # pack wins). The old data dir stays searched (it may be a symlink
        # into the library).
        self.library = library.root()
        lib_packs = library.packs_dir(self.library)
        if lib_packs is not None and _resolve(lib_packs) not in [_resolve(p) for p in self.theme_path]:
            self.theme_path.insert(0, lib_packs)
        # Where `install` / `new` put packs; `remove` looks in both.
        self.user_themes = lib_packs if lib_packs is not None else self.legacy_themes
        self.user_dirs = [self.user_themes] + ([self.legacy_themes] if _resolve(self.legacy_themes) != _resolve(self.user_themes) else [])
        self.shell_path = Path(_env("LOFT_SHELL_PATH") or self.data_dir / "src")
        self.theme: dict = {}

    @property
    def current(self) -> Path:
        return self.state_dir / "current"

    def find(self, ref: str) -> Pack:
        """A pack by path, or by name along the theme path (first wins)."""
        p = Path(ref).expanduser()
        if ("/" in ref or ref.startswith(".")) and is_pack(p):
            return Pack(p)
        for d in self.theme_path:
            if is_pack(d / ref):
                return Pack(d / ref)
        if is_pack(p):
            return Pack(p)
        raise Fail(f"no theme '{ref}' in {':'.join(map(str, self.theme_path))}")

    def packs(self) -> dict[str, Pack]:
        """Every pack on the theme path by name (first wins; `default` alias skipped)."""
        out: dict[str, Pack] = {}
        for d in self.theme_path:
            if not d.is_dir():
                continue
            for sub in sorted(d.iterdir()):
                if sub.name not in out and is_pack(sub) and not sub.is_symlink():
                    try:
                        out[sub.name] = Pack(sub)
                    except PackError:
                        continue
        return out

    def index(self) -> dict:
        if not hasattr(self, "_index"):
            self._index = index.load(self.state_dir)
        return self._index

    def curated(self, pack: Pack) -> dict:
        """The pack's curated vibes (manifest + index), resolved against installed packs."""
        return vibes.resolve(pack, self.packs(), self.index())

    def current_name(self) -> str | None:
        for f in ("manifest.json", "theme.json"):
            try:
                name = json.loads((self.current / f).read_text()).get("name")
            except (OSError, ValueError):
                continue
            if name:
                return name
        return None

    def validate(self, pack: Pack, require_manifest: bool = False) -> None:
        try:
            pack.validate(self.schema, require_manifest)
        except PackError as e:
            raise Fail(str(e)) from e

    def validate_any(self, path: Path, others: list[Path] = ()) -> None:
        """A v2 pack (pack.json: documents, files, its themes resolving
        against `others`, the theme path and the built-ins), else a v1 pack."""
        if not is_pack_v2(path):
            self.validate(Pack(path), require_manifest=True)
            return
        errors = validate_v2(path, self.data_dir / "packs", [*others, *self.theme_path])
        if errors:
            raise Fail(f"{path}: invalid pack\n  " + "\n  ".join(errors))

    def pack_dir(self, ref: str, user_only: bool = False) -> Path:
        """An installed pack's directory: a path; a pack (dir) name or id on the
        theme path (the user dirs only with user_only); or a theme / old name,
        through the theme it names."""
        p = Path(ref).expanduser()
        if ("/" in ref or ref.startswith(".")) and is_any_pack(p):
            return p.resolve()
        dirs = self.user_dirs if user_only else self.theme_path
        for d in dirs:
            if is_any_pack(d / ref):
                return (d / ref).resolve()
        for d in dirs:
            for sub in sorted(d.iterdir()) if d.is_dir() else []:
                if sub.is_dir() and is_pack_v2(sub) and pack_id(sub) == ref:
                    return sub.resolve()
        try:
            cat = themecmds.catalog(self)
            theme, _ = cat.theme(ref)
        except FacetError:
            theme = None
        if theme is not None and theme.root is not None:
            root = Path(theme.root).resolve()
            if any(_resolve(d) in root.parents for d in dirs if d.is_dir()):
                return root
        where = ":".join(map(str, dirs))
        raise Fail(f"no installed pack or theme '{ref}' ({where})" + ("; built-in themes can't be removed" if user_only else ""))


def _resolve(p: Path) -> Path:
    try:
        return p.resolve()
    except OSError:
        return p


def load_dev_env() -> None:
    # `loft-dev --session NAME` sessions live in loft-dev-NAME; the
    # default (`dev`) in loft-dev. Inside an isolated session
    # XDG_RUNTIME_DIR is the session's own, so prefer the host's.
    name = _env("LOFT_SESSION") or "dev"
    runtime = _env("LOFT_DEV_HOST_RUNTIME") or _env("XDG_RUNTIME_DIR") or "/tmp"
    sub = "loft-dev" if name == "dev" else f"loft-dev-{name}"
    env_file = Path(runtime) / sub / "session.env"
    if not env_file.is_file() and _env("XDG_RUNTIME_DIR"):
        env_file = Path(f"/run/user/{os.getuid()}") / sub / "session.env"
    if not env_file.is_file():
        raise Fail(f"no loft-dev session `{name}` running")
    for line in env_file.read_text().splitlines():
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            os.environ[k.strip()] = v.strip()


# ── commands ────────────────────────────────────────────────────────────────


def cmd_list(ctx: Ctx, args) -> None:
    if args.themes or args.collection:
        themecmds.cmd_theme_list(ctx, args)
        return
    # First match on the theme path wins, as in `find` (user packs shadow built-ins).
    packs = ctx.packs()
    if not args.json:
        for n in sorted(packs):
            print(n)
        return
    # For pickers (the shell's theme selector): enough to draw a swatch, plus
    # the size of each vibe set and the installed packs it links to.
    idx = ctx.index()
    out = []
    for name in sorted(packs):
        pack = packs[name]
        theme = pack.theme
        refs = vibes.links(pack, idx)
        linked = sorted({r.partition(":")[0] for k in refs for r in refs[k]} & set(packs) - {name})
        default = pack.default_wallpaper()
        out.append(
            {
                "name": name,
                "path": str(pack.path),
                "polarity": theme.get("polarity", "dark"),
                "palette": theme.get("palette", {}),
                "glass": theme.get("glass", {}),
                "wallpaper": dict(theme.get("wallpaper", {}), default=str(default["path"]) if default else ""),
                "wallpapers": len(pack.wallpaper_entries()),
                "locks": [e["name"] for e in pack.lock_entries()],
                "vibes": linked,
            }
        )
    print(json.dumps(out))


def cmd_vibes(ctx: Ctx, args) -> None:
    name = args.theme or ctx.current_name()
    if not name:
        raise Fail("no theme given and none is current")
    pack = ctx.find(name)
    packs = ctx.packs()
    packs.setdefault(pack.name, pack)
    cache = vibes.PaletteCache(ctx.state_dir)
    lib = library.Library(ctx.library) if ctx.library is not None and not args.no_library else None
    topics = lib.topics() if lib is not None and lib.exists() else {}

    def thumb(path: str) -> str | None:
        return library.thumb(ctx.state_dir, cache, Path(path))

    try:
        result = vibes.rank(
            pack, packs, idx=ctx.index(), cache=cache, dirs=[Path(d) for d in args.dir], topics=topics, thumb=thumb, limit=args.limit
        )
    finally:
        cache.save()
    if args.json:
        print(json.dumps(result))
        return
    print(f"{result['theme']} ({result['polarity']})")
    for kind in ("wallpapers", "locks"):
        print(f"\n{kind}:")
        for e in result[kind]:
            d = f"{e['distance']:6.1f}" if "distance" in e else "      "
            what = e.get("name") or os.path.relpath(e["path"], packs[e["source_pack"]].path) if e["source_pack"] in packs else e["path"]
            flag = "  [video]" if e.get("kind") == "video" else ""
            src = e["source_pack"] or (f"[{e['topic']}]" if e.get("topic") else "(folder)")
            print(f"  {e['origin']:8} {d}  {src:22} {what}{flag}")


def cmd_current(ctx: Ctx, args) -> None:
    if args.json:
        themecmds.cmd_current(ctx, args)
        return
    f = ctx.current / "theme.json"
    if not f.is_file():
        print("(none — the shell uses its built-in default)")
        return
    print(json.loads(f.read_text()).get("name") or ctx.current.resolve().name)


def cmd_render(ctx: Ctx, args) -> None:
    if not themecmds.legacy_engine():
        themecmds.cmd_render(ctx, args)
        return
    pack = ctx.find(args.pack)
    ctx.validate(pack)
    cat, theme, variant = themecmds.legacy_select(ctx, pack)
    res = themecmds.resolved(ctx, cat, theme, variant, None)
    render.render_to(res, cat, Path(args.outdir), ctx.template_dir, ctx.curated(pack))


def cmd_validate(ctx: Ctx, args) -> None:
    import importlib.util

    for ref in args.packs:
        p = Path(ref).expanduser()
        if is_pack_v2(p) or (not is_pack(p) and "/" not in ref and any(is_pack_v2(d / ref) for d in ctx.theme_path)):
            root = p if is_pack_v2(p) else ctx.pack_dir(ref)
            ctx.validate_any(root)
            print(f"ok  {pack_id(root)}  ({root})")
            continue
        if importlib.util.find_spec("jsonschema") is None:
            raise Fail("validating a v1 pack needs the jsonschema python module (use the Nix-packaged loft)")
        pack = ctx.find(ref)
        ctx.validate(pack, require_manifest=True)
        print(f"ok  {pack.name}  ({pack.path})")


def _swap_symlink(link: Path, target: Path) -> None:
    tmp = link.with_name(f".{link.name}.tmp-{os.getpid()}")
    if tmp.is_symlink() or tmp.exists():
        tmp.unlink()
    tmp.symlink_to(target)
    os.replace(tmp, link)  # atomic: readers never see a missing `current`


def cmd_apply(ctx: Ctx, args) -> None:
    if not themecmds.legacy_engine():
        themecmds.cmd_apply(ctx, args)
        return
    if not args.theme:
        raise Fail("apply what? (LOFT_THEME_ENGINE=v1 needs a theme name)")
    # The pack alone (no catalog, no appearance.json), rendered by the same
    # units through the same composition cache.
    pack = ctx.find(args.theme)
    cat, theme, variant = themecmds.legacy_select(ctx, pack)
    res = themecmds.resolved(ctx, cat, theme, variant, None)
    themecmds.apply_resolved(ctx, cat, res, reload_all=args.reload, verbose=args.verbose)


def _copy_pack(src: Path, dest: Path) -> None:
    shutil.copytree(src, dest, ignore=shutil.ignore_patterns(*IGNORED), symlinks=False)
    # Store paths are read-only; an installed pack must stay editable.
    for p in [dest, *dest.rglob("*")]:
        p.chmod(p.stat().st_mode | 0o200)


def cmd_new(ctx: Ctx, args) -> None:
    if not NAME.match(args.name) or args.name == "default":
        raise Fail(f"invalid theme name '{args.name}' (lowercase letters, digits, . _ -)")
    src = ctx.find(args.from_)
    dest = ctx.user_themes / args.name
    if dest.exists():
        raise Fail(f"{dest} already exists")
    dest.parent.mkdir(parents=True, exist_ok=True)
    _copy_pack(src.path, dest)
    manifest = {
        "name": args.name,
        "author": os.environ.get("USER", ""),
        "version": "0.1.0",
        "license": "NOASSERTION",
        "source": "",
        "description": f"Based on {src.name}",
    }
    (dest / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    theme = json.loads((dest / "theme.json").read_text())
    if "name" in theme:
        theme["name"] = args.name
        (dest / "theme.json").write_text(json.dumps(theme, indent=2) + "\n")
    print(dest)


def _find_pack_roots(root: Path, subdir: str | None) -> list[Path]:
    """The pack(s) to install: root itself, or the one pack inside it (tarballs
    wrap it in a directory), or several v2 packs (a theme exported with the
    packs it refers to)."""
    if subdir:
        root = root / subdir
    if is_any_pack(root):
        return [root]
    subs = [d for d in sorted(root.iterdir()) if d.is_dir() and is_any_pack(d)] if root.is_dir() else []
    if len(subs) == 1 or (subs and all(is_pack_v2(d) for d in subs)):
        return subs
    if subs:
        raise Fail(f"several packs found ({', '.join(d.name for d in subs)}); pick one with --subdir")
    raise Fail(f"no theme pack (pack.json or theme.json) found in {root}")


def _is_git(ref: str) -> bool:
    return ref.startswith(("git@", "git://", "ssh://", "git+")) or ref.endswith(".git") or (
        ref.startswith(("https://", "http://", "file://")) and not ref.endswith(TAR_SUFFIXES)
    )


def _extract(archive: Path, into: Path) -> None:
    try:
        with tarfile.open(archive) as tf:
            tf.extractall(into, filter="data")  # refuses absolute paths / escapes
    except (tarfile.TarError, ValueError) as e:
        raise Fail(f"{archive}: cannot extract: {e}") from e


def _import(ctx: Ctx, args) -> None:
    v1 = True if getattr(args, "v1", False) else None
    if v1:
        os.environ["LOFT_IMPORT_FORMAT"] = "1"  # --list too

    def validate(path: Path) -> None:
        ctx.validate_any(path)

    try:
        if args.list:
            for theme, pack in importers.list_available(args.source):
                print(f"{pack:28} {args.source.split(':', 1)[0]}:{theme}")
            return
        importers.install(
            args.source, ctx.user_themes, force=args.force, validate=validate, index=ctx.index(), v1=v1, builtin=ctx.data_dir / "packs"
        )
    except importers.ImporterError as e:
        raise Fail(str(e)) from e


def cmd_install(ctx: Ctx, args) -> None:
    ref = args.source
    if importers.is_importer_ref(ref) or (args.list and ref.rstrip(":") in importers.REGISTRY):
        if args.list and ":" not in ref:
            args.source = ref + ":"
        _import(ctx, args)
        return
    if args.list:
        raise Fail(f"--list needs an importer: {', '.join(n + ':' for n in sorted(importers.REGISTRY))}")
    with tempfile.TemporaryDirectory(prefix="loft-install-") as tmpd:
        tmp = Path(tmpd)
        local = Path(ref).expanduser()
        if local.is_dir():
            root = local
        elif local.is_file() and ref.endswith(TAR_SUFFIXES):
            _extract(local, tmp / "x")
            root = tmp / "x"
        elif ref.startswith(("https://", "http://")) and ref.endswith(TAR_SUFFIXES):
            archive = tmp / ("pack" + "".join(Path(ref).suffixes[-2:]))
            urllib.request.urlretrieve(ref, archive)  # noqa: S310 — user-given URL
            _extract(archive, tmp / "x")
            root = tmp / "x"
        elif _is_git(ref):
            url = ref.removeprefix("git+")
            r = subprocess.run(["git", "clone", "--quiet", "--depth", "1", url, str(tmp / "x")])
            if r.returncode != 0:
                raise Fail(f"git clone {url} failed")
            root = tmp / "x"
        else:
            raise Fail(f"'{ref}' is not a pack directory, tarball or git URL")

        roots = _find_pack_roots(root, args.subdir)
        names = []
        for r in roots:
            ctx.validate_any(r, others=[r.parent] if len(roots) > 1 else [])
            name = pack_id(r)
            if not NAME.match(name) or name == "default":
                raise Fail(f"pack name '{name}' is not a valid theme name")
            if (ctx.user_themes / name).exists() and not args.force:
                raise Fail(f"{name} is already installed ({ctx.user_themes / name}); use --force to replace it")
            names.append(name)
        for r, name in zip(roots, names):
            dest = ctx.user_themes / name
            if dest.exists():
                shutil.rmtree(dest)
            dest.parent.mkdir(parents=True, exist_ok=True)
            _copy_pack(r, dest)
            print(f"loft: installed {name} → {dest}")


def _theme_names(ctx: Ctx, pack_root: Path) -> set[str]:
    """What a pack's themes are known by: theme ids and every alias name (rendered/<name>)."""
    if not is_pack_v2(pack_root):
        return {Pack(pack_root).name} if is_pack(pack_root) else set()
    out: set[str] = set()
    for f in sorted((pack_root / "themes").glob("*.json")) if (pack_root / "themes").is_dir() else []:
        try:
            doc = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        out.add(doc.get("id") or f.stem)
        out.update(str(a).partition("@")[0] for a in doc.get("aliases") or [])
    return out


def _deps(ctx: Ctx, pack_root: Path) -> list[Path]:
    """Other installed packs whose facets this pack's themes refer to
    (a migrated theme like cozytile uses the five cozytile-* packs)."""
    if not is_pack_v2(pack_root):
        return []
    cat = themecmds.catalog(ctx, [pack_root])
    pid = pack_id(pack_root)
    out: list[Path] = []
    for t in [t for t in cat.themes() if t.pack == pid]:
        for sels in [t.doc.get("facets") or {}, *[v.get("facets") or {} for v in t.variants()]]:
            for kind, sel in sels.items():
                ref = sel if isinstance(sel, str) else sel.get("ref") if isinstance(sel, dict) else None
                if not ref:
                    continue
                try:
                    f = cat.facet(ref, kind, pid)
                except FacetError:
                    continue
                root = cat.pack_root(f.pack)
                if f.pack not in (pid, "loft", "user") and root is not None and root not in out:
                    out.append(Path(root))
    return out


def cmd_update(ctx: Ctx, args) -> None:
    """Re-import packs that came from an importer (pack.json / manifest
    `upstream.importer`), at the upstream's HEAD or --ref."""
    roots = [ctx.pack_dir(n, user_only=True) for n in args.names] if args.names else [
        d for u in ctx.user_dirs if u.is_dir() for d in sorted(u.iterdir()) if d.is_dir() and is_any_pack(d)
    ]  # fmt: skip
    refs: dict[str, list[str]] = {}
    for r in roots:
        meta = json.loads((r / ("pack.json" if is_pack_v2(r) else "manifest.json")).read_text()) if (r / ("pack.json" if is_pack_v2(r) else "manifest.json")).is_file() else {}
        imp = (meta.get("upstream") or {}).get("importer")
        if imp not in importers.REGISTRY:
            if args.names:
                raise Fail(f"{r.name}: not from an importer (nothing to update from)")
            continue
        from . import migrate

        members = sorted(migrate.installed_members(r)) if is_pack_v2(r) else [Path((meta.get("upstream") or {}).get("path", r.name)).name]
        refs.setdefault(imp, []).extend(m for m in members if m not in refs.get(imp, []))
    if not refs:
        print("loft: nothing to update (no packs from an importer)")
        return
    for imp, themes in refs.items():
        args.source = f"{imp}:{','.join(themes)}" + (f"@{args.ref}" if args.ref else "")
        args.force, args.list = True, False
        _import(ctx, args)


def cmd_remove(ctx: Ctx, args) -> None:
    dest = ctx.pack_dir(args.name, user_only=True)
    # A pack another installed theme uses (a migrated cozytile-sakura holds
    # cozytile@sakura's facets) goes only with that theme.
    users = [
        d for u in ctx.user_dirs if u.is_dir() for d in sorted(u.iterdir())
        if d.is_dir() and _resolve(d) != dest and is_pack_v2(d) and dest in [_resolve(x) for x in _deps(ctx, d)]
    ]  # fmt: skip
    if users:
        what = ""
        try:
            t, v = themecmds.catalog(ctx).theme(args.name)
            what = f" ({args.name} is {t.id}{'@' + v if v else ''} now)"
        except FacetError:
            pass
        raise Fail(f"{dest.name} is used by {', '.join(d.name for d in users)}{what}: remove that with --with-deps")
    deps = [d for d in _deps(ctx, dest) if any(_resolve(u) in d.parents for u in ctx.user_dirs if u.is_dir())]
    targets = [dest] + (deps if args.with_deps else [])
    cur = ctx.current.resolve() if ctx.current.is_symlink() else None
    for t in targets:
        names = _theme_names(ctx, t) | {t.name}
        shutil.rmtree(t)
        # Drop its render caches unless one is what `current` shows right now.
        for n in sorted(names):
            rendered = ctx.state_dir / "rendered" / n
            if rendered.is_dir() and not (cur and rendered.resolve() in cur.parents):
                shutil.rmtree(rendered)
        print(f"loft: removed {t.name}")
    if deps and not args.with_deps:
        print("loft: its themes also used " + ", ".join(d.name for d in deps) + " (remove them too with --with-deps)")


def cmd_export(ctx: Ctx, args) -> None:
    root = ctx.pack_dir(args.name)
    name = pack_id(root)
    # A v2 pack goes with the packs its themes refer to (not the built-ins).
    extra = _deps(ctx, root)
    out = Path(args.output or f"{name}.tar.gz")
    mode = {
        ".gz": "w:gz",
        ".tgz": "w:gz",
        ".xz": "w:xz",
        ".txz": "w:xz",
        ".bz2": "w:bz2",
        ".zst": "w:zst",
        ".tzst": "w:zst",
        ".tar": "w",
    }.get(out.suffix)
    if mode is None:
        raise Fail(f"{out}: unknown archive type (use .tar, .tar.gz, .tar.xz, .tar.bz2 or .tar.zst)")

    def clean(ti: tarfile.TarInfo):
        if any(part in IGNORED for part in Path(ti.name).parts):
            return None
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = ""
        return ti

    try:
        with tarfile.open(out, mode) as tf:
            tf.add(root, arcname=name, filter=clean)
            for d in extra:
                tf.add(d, arcname=pack_id(d), filter=clean)
    except tarfile.CompressionError as e:
        raise Fail(f"{out}: {e} (try .tar.gz)") from e
    if extra:
        print(f"loft: with {', '.join(pack_id(d) for d in extra)} (its themes use them)", file=sys.stderr)
    print(out)


# ── library ─────────────────────────────────────────────────────────────────


def _library(ctx: Ctx) -> library.Library:
    if ctx.library is None:
        raise Fail("the library is turned off (LOFT_LIBRARY=none)")
    return library.Library(ctx.library)


def cmd_library_sort(ctx: Ctx, args) -> None:
    lib = _library(ctx)
    if not lib.exists():
        if args.json:  # the shell asks on every machine; no library is not an error
            print(json.dumps({"root": str(lib.root), "exists": False}))
            return
        raise Fail(f"no library at {lib.root} (create it, `loft library add`, or set LOFT_LIBRARY)")
    cache = vibes.PaletteCache(ctx.state_dir)
    try:
        idx = lib.sort(ctx.packs(), cache=cache, state_dir=ctx.state_dir, idx=ctx.index())
    except library.LibraryError as e:
        raise Fail(str(e)) from e
    finally:
        cache.save()
    if args.json:
        print(json.dumps(idx))
    elif not args.quiet:
        ch = idx["changes"]
        print(library.summary(idx))
        print(f"\nlinks: {ch['created']} created, {ch['removed']} removed")


def cmd_library_status(ctx: Ctx, args) -> None:
    lib = _library(ctx)
    idx = library.load_index(lib)
    if args.json:
        print(json.dumps(idx or {"root": str(lib.root), "exists": lib.exists()}))
        return
    if idx is None:
        print(f"{lib.root}: " + ("not sorted yet (`loft library sort`)" if lib.exists() else "no library"))
        return
    print(library.summary(idx))
    print(f"\nsorted {idx['generated']}")


def cmd_library_add(ctx: Ctx, args) -> None:
    lib = _library(ctx)
    try:
        added = lib.add([Path(f).expanduser() for f in args.files], args.topic, move=args.move)
    except library.LibraryError as e:
        raise Fail(str(e)) from e
    for p in added:
        print(p)
    if not args.no_sort:
        args.json = False
        args.quiet = True
        cmd_library_sort(ctx, args)
    print(f"loft: {'moved' if args.move else 'copied'} {len(added)} into {lib.topics_dir / args.topic}")


def cmd_library_migrate(ctx: Ctx, args) -> None:
    """docs/THEME-ARCHITECTURE.md §5.5 (cli/loft/migrate.py): a dry run unless --apply."""
    from . import migrate

    builtin = ctx.data_dir / "packs"
    if args.undo is not None:
        rep = Path(args.undo) if args.undo else migrate.latest_report(ctx.state_dir)
        if rep is None or not rep.is_file():
            raise Fail(f"no migration report to undo in {ctx.state_dir / migrate.REPORT_DIR}")
        for line in migrate.undo(rep):
            print(f"loft: {line}")
        print(f"loft: undid {rep}")
        return
    home = Path.home()
    data_home = Path(_env("XDG_DATA_HOME") or home / ".local" / "share")
    state_home = Path(_env("XDG_STATE_HOME") or home / ".local" / "state")
    p = migrate.plan(
        ctx.state_dir, builtin,
        Path(args.from_).expanduser() if args.from_ else None, Path(args.to).expanduser() if args.to else None,
        data_home=data_home, state_home=state_home,
    )  # fmt: skip
    summary = migrate.summary(p, builtin)
    undo: dict = {}
    if args.apply:
        undo = migrate.apply(p, builtin, hardlinks=not args.no_hardlinks)
    text = migrate.render_report(p, summary, args.apply)
    if args.apply:
        rep = migrate.save_report(p, summary, undo, text)
        text += f"\nreport: {rep}\nundo: loft library migrate --undo {rep}"
    if args.json:
        print(json.dumps({"applied": args.apply, "summary": summary, "plan": p.to_json(), "undo": undo}))
    else:
        print(text)


# ── wallpaper sets ──────────────────────────────────────────────────────────


def _json_arg(value: str | None, what: str):
    """A JSON argument: inline, `-` (stdin) or @file."""
    if value is None:
        return None
    try:
        if value == "-":
            return json.load(sys.stdin)
        if value.startswith("@"):
            return json.loads(Path(value[1:]).expanduser().read_text())
        return json.loads(value)
    except (OSError, ValueError) as e:
        raise Fail(f"--{what}: {e}") from e


def _layout(ctx: Ctx, args) -> dict:
    """--layout, else the live niri layout (main display from the shell's settings)."""
    lay = _json_arg(getattr(args, "layout", None), "layout")
    if lay is not None:
        if not isinstance(lay, dict) or not isinstance(lay.get("outputs"), list):
            raise Fail("--layout: expected {outputs: [{name, identity, x, y, width, height}], main?, workspaces?}")
        lay.setdefault("workspaces", [])
        return lay

    def niri(what: str):
        try:
            r = subprocess.run(["niri", "msg", "-j", what], capture_output=True, text=True, timeout=5)
        except (OSError, subprocess.TimeoutExpired) as e:
            raise Fail(f"niri msg {what}: {e} (pass --layout)") from e
        if r.returncode != 0:
            raise Fail(f"niri msg {what} failed (not in a niri session? pass --layout)")
        return json.loads(r.stdout)

    shell = wallsets.load_shell(ctx.state_dir)
    main = (shell.get("displays") or {}).get("main") or None
    return wallsets.layout_from_niri(niri("outputs"), niri("workspaces"), main)


def _wall_theme(ctx: Ctx, args) -> Pack:
    name = getattr(args, "theme", None) or ctx.current_name()
    if not name:
        raise Fail("no theme given and none is current")
    return ctx.find(name)


def wallpaper_plan(ctx: Ctx, pack: Pack, layout: dict, choices: dict) -> dict:
    """Everything the shell's wallpaper sets need for this theme and layout
    (wallsets.py): auto picks, the candidate pool, framing, roles and sets."""
    packs = ctx.packs()
    packs.setdefault(pack.name, pack)
    cache = vibes.PaletteCache(ctx.state_dir)
    frames = wallsets.FramingCache(ctx.state_dir, cache)
    lib = library.Library(ctx.library) if ctx.library is not None else None
    topics = lib.topics() if lib is not None and lib.exists() else {}
    dirs = [Path(d).expanduser() for d in [(wallsets.load_shell(ctx.state_dir).get("wallpaper") or {}).get("directory") or "~/Pictures/Wallpapers"]]
    try:
        ranked = vibes.rank(
            pack, packs, idx=ctx.index(), cache=cache, dirs=[d for d in dirs if d.is_dir()], topics=topics,
            thumb=lambda p: library.thumb(ctx.state_dir, cache, Path(p)),
        )  # fmt: skip
        pool = wallsets.candidates(ranked, cache, frames)
        # A screenshot with a finished (processed) version isn't picked itself.
        done = lib.superseded() if lib is not None and lib.exists() else set()
        if done:
            pool = [c for c in pool if str(Path(c["path"]).resolve()) not in done]
        tone = wallsets.target_tone(ranked, cache)
        pack_sets = [
            {"name": s["name"], "origin": "pack", "displays": {r: str(p) for r, p in s["displays"].items()}, "workspaces": {k: str(p) for k, p in s["workspaces"].items()}}
            for s in pack.wallpaper_sets()
        ]
        user_sets = [dict(s, origin="user") for s in choices.get("sets") or [] if wallsets.valid_set(s)]
        pset_def = wallsets.best_set(pack_sets, layout) if len(layout.get("outputs", [])) >= 2 else None
        pset = dict(wallsets.resolve_set(pset_def, layout), name=pset_def["name"]) if pset_def else None
        in_tone = sum(1 for c in pool if c["tone"] == tone)
        auto_default = in_tone >= wallsets.AUTO_MIN
        auto = choices["auto"] if isinstance(choices.get("auto"), bool) else auto_default
        picks = wallsets.plan(
            pack.name, layout, pool, choices, tone=tone, cache=cache, pack_set=None if wallsets.has_explicit(choices) else pset
        )
        # Where to center each image's crop: the pool, and whatever is chosen.
        paths = {c["path"] for c in pool}
        paths |= {p for p in (choices.get("displays") or {}).values() if isinstance(p, str)}
        paths |= {p for p in (choices.get("workspaces") or {}).values() if isinstance(p, str)}
        paths |= {p for s in pack_sets + user_sets for k in ("displays", "workspaces") for p in (s.get(k) or {}).values() if isinstance(p, str)}
        if isinstance(choices.get("wallpaper"), str):
            paths.add(choices["wallpaper"])
        if ranked["defaults"]["wallpaper"]:
            paths.add(ranked["defaults"]["wallpaper"])
        framing = {}
        for p in sorted(paths):
            if p and Path(p).is_file():
                fr = frames.get(Path(p))
                if fr:
                    framing[p] = {"focus": fr["focus"], "size": fr["size"]}
                    video = wallsets.paired_video(Path(p))
                    if video:
                        framing[p]["video"] = str(video)
    finally:
        cache.save()
        frames.save()
    outs = layout.get("outputs", [])
    return {
        "theme": pack.name,
        "polarity": ranked["polarity"],
        "tone": tone,
        "auto": auto,
        "autoDefault": auto_default,
        "seed": int(choices.get("autoSeed", 0) or 0),
        "roles": wallsets.roles(outs, layout.get("main")),
        "displays": picks["displays"],
        "workspaces": picks["workspaces"],
        "why": picks["why"],
        "packSet": pset,
        "sets": pack_sets + user_sets,
        "activeSet": choices.get("activeSet", ""),
        "framing": framing,
        "pool": [
            {
                "path": c["path"],
                "thumb": c["thumb"],
                "origin": c["origin"],
                "source": c["source_pack"] or c["topic"],
                "score": c["score"],
                "tone": c["tone"],
                "colors": c["colors"],
                "kept": {wallsets._ident(o): round(wallsets.interest_kept(c["framing"], o["width"] / max(o["height"], 1)), 2) for o in outs},
            }
            for c in pool
        ],
    }


def _choices(ctx: Ctx, args, theme: str) -> dict:
    c = _json_arg(getattr(args, "choices", None), "choices")
    if c is None:
        c = wallsets.theme_choices(wallsets.load_shell(ctx.state_dir), theme)
    if not isinstance(c, dict):
        raise Fail("--choices: expected an object (perTheme.<theme> of shell.json)")
    return c


def _short(path: str) -> str:
    """A caption: the file's stem, with its pack for pack images (bg.jpg is common)."""
    if not path:
        return "(theme default)"
    p = Path(path)
    stem = p.stem
    parts = p.parts
    if "Packs" in parts and parts.index("Packs") + 1 < len(parts):
        return f"{parts[parts.index('Packs') + 1]}/{stem}"
    return stem


def cmd_wall_plan(ctx: Ctx, args) -> None:
    pack = _wall_theme(ctx, args)
    layout = _layout(ctx, args)
    res = wallpaper_plan(ctx, pack, layout, _choices(ctx, args, pack.name))
    if args.json:
        print(json.dumps(res))
        return
    choices = _choices(ctx, args, pack.name)
    eff = wallsets.effective(layout, choices, res, res["packSet"] if not wallsets.has_explicit(choices) else None, res["auto"])
    print(f"{res['theme']} · tone {res['tone']} · {len(res['pool'])} candidates · auto {'on' if res['auto'] else 'off'} (seed {res['seed']})")
    for o in wallsets.ordered_outputs(layout):
        ident = wallsets._ident(o)
        base = eff["displays"].get(ident, "")
        src = "chosen" if ident in (choices.get("displays") or {}) else "auto" if ident in res["displays"] else "theme"
        print(f"\n{o['name']}  {ident}  [{', '.join(res['roles'][o['name']][:3])}]")
        print(f"  base      {_short(base):40} {src}  {res['why'].get('display:' + ident, '')}")
        for w in wallsets.workspaces_of(layout, o["name"]):
            key = wallsets.ws_key(w, ident)
            p = eff["workspaces"].get(key, "")
            src = "chosen" if key in (choices.get("workspaces") or {}) else "auto" if key in res["workspaces"] and p == res["workspaces"][key] else "base"
            print(f"  {w['idx']} {(w['name'] or '-')[:8]:8} {_short(p):40} {src}  {res['why'].get('workspace:' + key, '') if src == 'auto' else ''}")


def cmd_wall_sets(ctx: Ctx, args) -> None:
    pack = _wall_theme(ctx, args)
    choices = _choices(ctx, args, pack.name)
    sets = [dict(s, origin="pack") for s in (
        {"name": s["name"], "displays": {r: str(p) for r, p in s["displays"].items()}, "workspaces": {k: str(p) for k, p in s["workspaces"].items()}}
        for s in pack.wallpaper_sets()
    )] + [dict(s, origin="user") for s in choices.get("sets") or [] if wallsets.valid_set(s)]  # fmt: skip
    if args.json:
        print(json.dumps({"theme": pack.name, "activeSet": choices.get("activeSet", ""), "sets": sets}))
        return
    if not sets:
        print(f"{pack.name}: no wallpaper sets (loft wallpaper set save NAME)")
    for s in sets:
        mark = "*" if s["name"] == choices.get("activeSet") else " "
        roles = ", ".join(f"{r}={_short(p)}" for r, p in s["displays"].items())
        extra = f" + {len(s['workspaces'])} workspaces" if s["workspaces"] else ""
        print(f"{mark} {s['origin']:4}  {s['name']:20} {roles}{extra}")


def _find_set(pack: Pack, choices: dict, name: str) -> dict:
    for s in choices.get("sets") or []:
        if wallsets.valid_set(s) and s["name"] == name:
            return s
    for s in pack.wallpaper_sets():
        if s["name"] == name:
            return {"name": s["name"], "displays": {r: str(p) for r, p in s["displays"].items()}, "workspaces": {k: str(p) for k, p in s["workspaces"].items()}}
    raise Fail(f"{pack.name} has no wallpaper set '{name}' (loft wallpaper sets)")


def _update_choices(ctx: Ctx, theme: str, fn) -> dict:
    shell = wallsets.load_shell(ctx.state_dir)
    c = dict(wallsets.theme_choices(shell, theme))
    fn(c)
    wallsets.save_shell(ctx.state_dir, wallsets.set_theme_choices(shell, theme, c))
    return c


def cmd_wall_set(ctx: Ctx, args) -> None:
    pack = _wall_theme(ctx, args)
    choices = wallsets.theme_choices(wallsets.load_shell(ctx.state_dir), pack.name)
    if args.action == "show":
        print(json.dumps(_find_set(pack, choices, args.name), indent=2))
        return
    if args.action == "delete":
        if not any(wallsets.valid_set(s) and s["name"] == args.name for s in choices.get("sets") or []):
            raise Fail(f"no saved set '{args.name}' for {pack.name} (a pack's sets can't be deleted)")

        def drop(c: dict) -> None:
            c["sets"] = [s for s in c.get("sets") or [] if not (isinstance(s, dict) and s.get("name") == args.name)]
            if c.get("activeSet") == args.name:
                c.pop("activeSet")

        _update_choices(ctx, pack.name, drop)
        print(f"loft: deleted wallpaper set {args.name} ({pack.name})")
        return
    layout = _layout(ctx, args)
    if args.action == "apply":
        res = wallsets.resolve_set(_find_set(pack, choices, args.name), layout)

        def apply(c: dict) -> None:
            # A set replaces the display and workspace choices.
            c["displays"] = res["displays"]
            c["workspaces"] = res["workspaces"]
            c["activeSet"] = args.name

        _update_choices(ctx, pack.name, apply)
        n = len(res["displays"]) + len(res["workspaces"])
        print(f"loft: applied {args.name} to {pack.name} ({len(res['displays'])} displays, {len(res['workspaces'])} workspaces)" if n else f"loft: {args.name} names none of these displays")
        return
    # save
    res = wallpaper_plan(ctx, pack, layout, choices)
    dflt = pack.default_wallpaper()
    default = str(dflt["path"]) if dflt and dflt["kind"] == "image" else ""
    eff = wallsets.effective(layout, choices, res, res["packSet"] if not wallsets.has_explicit(choices) else None, res["auto"], default)
    s = wallsets.capture(args.name, layout, eff)
    if not s["displays"]:
        raise Fail("nothing to save: no display shows an image")
    if args.pack:
        _save_set_to_pack(Path(args.pack).expanduser(), s)
        print(f"loft: saved {args.name} into {args.pack}/theme.json")
        return

    def save(c: dict) -> None:
        c["sets"] = [x for x in c.get("sets") or [] if not (isinstance(x, dict) and x.get("name") == args.name)] + [s]
        c["activeSet"] = args.name

    _update_choices(ctx, pack.name, save)
    print(f"loft: saved wallpaper set {args.name} for {pack.name}: " + ", ".join(f"{r}={_short(p)}" for r, p in s["displays"].items()))


def _save_set_to_pack(dest: Path, s: dict) -> None:
    """Copy a set's images into the pack's wallpapers/ and add it to theme.json."""
    pack = Pack(dest)
    wdir = pack.path / "wallpapers"
    wdir.mkdir(exist_ok=True)

    def bring(p: str) -> str:
        src = Path(p)
        if pack.path in src.resolve().parents:
            return str(src.resolve().relative_to(pack.path))
        target = wdir / src.name
        n = 2
        while target.exists() and not _same_file(src, target):
            target = wdir / f"{src.stem}-{n}{src.suffix}"
            n += 1
        if not target.exists():
            shutil.copy2(src, target)
        return str(target.relative_to(pack.path))

    entry = {"name": s["name"], "displays": {r: bring(p) for r, p in s["displays"].items()}}
    if s.get("workspaces"):
        entry["workspaces"] = {k: bring(p) for k, p in s["workspaces"].items()}
    theme = json.loads((pack.path / "theme.json").read_text())
    theme["wallpaperSets"] = [x for x in theme.get("wallpaperSets", []) if x.get("name") != s["name"]] + [entry]
    (pack.path / "theme.json").write_text(json.dumps(theme, indent=2) + "\n")


def _same_file(a: Path, b: Path) -> bool:
    try:
        return a.stat().st_size == b.stat().st_size and a.read_bytes() == b.read_bytes()
    except OSError:
        return False


def cmd_wall_shuffle(ctx: Ctx, args) -> None:
    pack = _wall_theme(ctx, args)
    c = _update_choices(ctx, pack.name, lambda c: c.__setitem__("autoSeed", int(c.get("autoSeed", 0) or 0) + 1))
    print(f"loft: reshuffled {pack.name}'s auto wallpapers (seed {c['autoSeed']})")


def cmd_wall_focus(ctx: Ctx, args) -> None:
    img = Path(args.image).expanduser().resolve()
    if not img.is_file():
        raise Fail(f"no such image: {img}")
    path = str(img)
    shell = wallsets.load_shell(ctx.state_dir)
    if args.clear or args.x is not None:
        if args.x is not None and args.y is None:
            raise Fail("focus: give both X and Y (0..1 from the top left)")
        focus = None if args.clear else [args.x, args.y]
        shell = wallsets.set_focus_override(shell, path, args.role, focus)
        wallsets.save_shell(ctx.state_dir, shell)
    if args.fit:
        shell = wallsets.set_fit(shell, path, args.fit)
        wallsets.save_shell(ctx.state_dir, shell)
    over = wallsets.focus_overrides(shell, path)
    fr = wallsets.framing(img)
    auto = fr["focus"] if fr else [0.5, 0.5]
    video = wallsets.paired_video(img)
    if args.json:
        print(json.dumps({"path": path, "auto": auto, "overrides": over, "video": str(video) if video else None}))
        return
    print(f"{_short(path)}  auto focus {auto}" + (f"  [video: {video.name}]" if video else ""))
    for role, f in over.items():
        print(f"  {role:12} {f}")
    if not over:
        print("  (no overrides: every display crops around the auto focus)")


def cmd_wall_auto(ctx: Ctx, args) -> None:
    pack = _wall_theme(ctx, args)

    def set_auto(c: dict) -> None:
        if args.state == "default":
            c.pop("auto", None)
        else:
            c["auto"] = args.state == "on"

    _update_choices(ctx, pack.name, set_auto)
    print(f"loft: auto wallpapers for {pack.name}: {args.state}")


# ── entry ───────────────────────────────────────────────────────────────────


# loft-dev options that take a value (to tell them from the CHECKOUT argument).
DEV_VALUE_OPTS = {"--session", "--size", "--output", "--stop"}


def _fail(msg: str):
    raise Fail(msg)


def run_dev(args: list[str]) -> int:
    """`loft dev …` is `loft-dev …`: the dev / test sessions (nix/dev/loft-dev.sh).

    Run from a checkout (the dev session's own `loft`), that checkout is the
    session's default source."""
    here = Path(__file__).resolve().parents[2]
    checkout = here if (here / "src" / "shell.qml").is_file() and (here / "flake.nix").is_file() else None
    positional, i = [], 0
    while i < len(args):
        a = args[i]
        if a in DEV_VALUE_OPTS:
            i += 2
            continue
        if not a.startswith("-"):
            positional.append(a)
        i += 1
    if checkout and not positional and not {"--list", "--stop", "-h", "--help"} & set(args):
        args = [*args, str(checkout)]
    exe = shutil.which("loft-dev")
    if exe:
        os.execv(exe, [exe, *args])
    elif checkout and shutil.which("nix"):
        os.execvp("nix", ["nix", "run", f"{checkout}#dev", "--", *args])
    else:
        print("loft: loft-dev is not on PATH (try `nix run github:Codys-Wright/loft#dev`)", file=sys.stderr)
    return 1  # exec only returns by failing


def _exec_loft_niri(ctx: Ctx, args, prefix: list[str], default: list[str]) -> None:
    exe = shutil.which("loft-niri")
    if not exe:
        raise Fail("loft-niri is not on PATH")
    rest = list(args.rest or [])
    if rest[:1] == ["--"]:
        rest = rest[1:]
    os.execv(exe, [exe, "--state-dir", str(ctx.state_dir), *prefix, *(rest or default)])


def cmd_windows(ctx: Ctx, args) -> None:
    """`loft windows …` = `loft-niri windows …` (Settings → Window Rules):
    translucent windows and per-app window rules. With --dev, the session's
    state dir and niri config (load_dev_env set them)."""
    _exec_loft_niri(ctx, args, ["windows"], ["list"])


def cmd_niri(ctx: Ctx, args) -> None:
    """`loft niri …` = `loft-niri …`: the niri settings Loft manages
    (keys, show, set, unset, binds, outputs, render, reset, space …)."""
    _exec_loft_niri(ctx, args, [], ["--help"])


def cmd_qt_sync(ctx: Ctx, args) -> None:
    """`loft qt sync`: what the `qt` hook does (qtapps.py), on demand — the
    home-manager activation runs it so Dolphin is themed before the first apply."""
    from . import qtapps

    if qtapps.settings() is None:
        print(f"loft qt: off (no {qtapps.config_home() / 'loft' / 'qt.json'}; programs.loft.qt.enable)")
        return
    for note in qtapps.sync(ctx.state_dir):
        print(note)


def _migrate_args(s) -> None:
    s.add_argument("--apply", action="store_true", help="do it (default: a dry run that only reports)")
    s.add_argument("--json", action="store_true", help="the plan and summary as JSON")
    s.add_argument("--from", dest="from_", metavar="DIR", help="the old library root (default ~/Documents/Themes)")
    s.add_argument("--to", metavar="DIR", help="the new root (default $LOFT_LIBRARY, else ~/Documents/Loft)")
    s.add_argument("--no-hardlinks", action="store_true", help="leave duplicate media files as copies")
    s.add_argument("--undo", nargs="?", const="", metavar="REPORT", help="put back an applied migration (default: the latest report)")
    s.set_defaults(fn=cmd_library_migrate)


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="loft", description="Loft CLI")
    p.add_argument("--dev", action="store_true", help="target the `nix run .#dev` session")
    top = p.add_subparsers(dest="group", required=True)
    # Handled before parsing (main): everything after `dev` goes to loft-dev.
    top.add_parser("dev", help="run a dev / test session: `loft dev [--session NAME] …` = `loft-dev …`", add_help=False)
    theme = top.add_parser("theme", help="theme engine and manager")
    sub = theme.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("list", help="list available theme packs (--themes: themes with variants)")
    s.add_argument("--json", action="store_true", help="names, paths and palettes as JSON")
    s.add_argument("--themes", action="store_true", help="themes with their variants and collection (the facet model)")
    s.add_argument("--collection", help="only this collection (builtin, user, cozytile, qylock, …); implies --themes")
    s.set_defaults(fn=cmd_list)
    s = sub.add_parser("current", help="print the active theme")
    s.add_argument("--json", action="store_true", help="theme, variant, customized and pinned kinds")
    s.set_defaults(fn=cmd_current)

    s = sub.add_parser(
        "vibes",
        help="wallpapers and lock designs that go with a theme",
        description="The theme's own wallpapers and lock designs, curated links (manifest `vibes`, themes index), "
        "then every other installed pack's (and --dir images), ranked by palette distance (CIEDE2000).",
    )
    s.add_argument("theme", nargs="?", help="theme name or pack path (default: the current theme)")
    s.add_argument("--json", action="store_true", help="machine-readable (the shell's pickers)")
    s.add_argument("--dir", action="append", default=[], metavar="DIR", help="also rank the images in DIR (repeatable)")
    s.add_argument("--limit", type=int, help="at most N ranked matches of each kind")
    s.add_argument("--no-library", action="store_true", help="leave out the library's topic images")
    s.set_defaults(fn=cmd_vibes)

    s = sub.add_parser("apply", help="render (cached per unit), make current, reload the consumers whose files changed")
    s.add_argument("theme", nargs="?", help="theme[@variant], an old pack name (alias) or a pack path")
    s.add_argument("--mode", choices=["light", "dark", "auto"], help="pick the theme's variant for this appearance")
    s.add_argument("--reload", action="store_true", help="run every reload hook, changed or not")
    s.add_argument("-v", "--verbose", action="store_true", help="say what was rendered, what changed and which hooks ran")
    s.add_argument(
        "--greeter",
        nargs="?",
        const="",
        metavar="REF",
        help="also show the lock design on the login screen now (REF: same, builtin or a lock: ref; "
        "default: the lock facet's `greeter`); without a theme, only that",
    )
    s.set_defaults(fn=cmd_apply)

    s = sub.add_parser(
        "preview",
        help="render a theme and show it in the shell only (current, niri, terminals, GTK unchanged)",
        description="Renders THEME[@VARIANT] (with your customizations) into a cached composition, points "
        "<state>/preview at it and asks the shell to show it (`qs ipc call theme preview DIR`). "
        "`--stop` goes back to `current`. Prints the composition dir.",
    )
    s.add_argument("theme", nargs="?", help="theme[@variant], an old pack name or a pack path")
    s.add_argument("--mode", choices=["light", "dark", "auto"], help="the theme's variant for this appearance")
    s.add_argument("--stop", action="store_true", help="end the preview: the shell shows `current` again")
    s.add_argument("--no-user", action="store_true", help="without your pins and customizations")
    s.add_argument("--no-shell", action="store_true", help="render only; don't tell the shell")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=themecmds.cmd_preview)

    s = sub.add_parser("render", help="render a theme's consumer files into a directory (no apply)")
    s.add_argument("pack", metavar="theme", help="theme[@variant], an old pack name or a pack path")
    s.add_argument("outdir")
    s.add_argument("--no-user", action="store_true", help="without your pins, customizations and accessibility switches")
    s.set_defaults(fn=cmd_render)

    s = sub.add_parser("validate", help="check packs against themes/schema.json")
    s.add_argument("packs", nargs="+")
    s.set_defaults(fn=cmd_validate)

    themecmds.add_theme_parsers(sub)

    s = sub.add_parser("migrate", help="= `loft library migrate` (themes, variants, settings; dry run)")
    _migrate_args(s)

    s = sub.add_parser("new", help="scaffold a pack in the user theme dir")
    s.add_argument("name")
    s.add_argument("--from", dest="from_", default="default", metavar="THEME")
    s.set_defaults(fn=cmd_new)

    s = sub.add_parser(
        "install",
        help="install a pack from a directory, tarball, git URL or importer",
        description="Importers fetch and convert upstream themes: "
        + "; ".join(f"{n}: {m.DESCRIPTION}" for n, m in sorted(importers.REGISTRY.items())),
    )
    s.add_argument(
        "source",
        help="path | tarball | git URL | IMPORTER:THEME[,THEME…]|all[@REF] (importers: "
        + ", ".join(sorted(importers.REGISTRY))
        + ")",
    )
    s.add_argument("--list", action="store_true", help="list what IMPORTER: can install")
    s.add_argument("--subdir", help="pack directory inside the repo/tarball")
    s.add_argument("--force", action="store_true", help="replace an installed pack of the same name")
    s.add_argument("--v1", action="store_true", help="importers: one v1 pack per upstream theme (what the shell's picker lists until it reads themes)")
    s.set_defaults(fn=cmd_install)

    s = sub.add_parser("update", help="re-import packs that came from an importer (cozytile:, qylock:)")
    s.add_argument("names", nargs="*", metavar="PACK", help="packs or themes (default: every one from an importer)")
    s.add_argument("--ref", help="upstream git ref (default: HEAD)")
    s.add_argument("--v1", action="store_true", help=argparse.SUPPRESS)
    s.set_defaults(fn=cmd_update)

    s = sub.add_parser("remove", help="remove an installed pack (by pack, theme or old name)")
    s.add_argument("name")
    s.add_argument("--with-deps", action="store_true", help="also the installed packs its themes use (a migrated cozytile: cozytile-*)")
    s.set_defaults(fn=cmd_remove)

    s = sub.add_parser("export", help="archive a pack for sharing (v2: with the packs its themes use)")
    s.add_argument("name")
    s.add_argument("-o", "--output", help="archive path (default: NAME.tar.gz)")
    s.set_defaults(fn=cmd_export)

    lib = top.add_parser(
        "library",
        help="the theme + wallpaper library ($LOFT_LIBRARY, default ~/Documents/Loft)",
        description="Packs/, Wallpapers/Processed/<Topic>/ and Wallpapers/Unprocessed/<Topic>/ hold the files; sort generates symlink views "
        "in Wallpapers/Colors, Wallpapers/Tones and Wallpapers/Themes (and README.md).",
    )
    sub = lib.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("sort", help="(re)generate the Colors / Tones / Themes views and the index")
    s.add_argument("--json", action="store_true", help="print the index (what the shell reads)")
    s.add_argument("-q", "--quiet", action="store_true")
    s.set_defaults(fn=cmd_library_sort)
    s = sub.add_parser("status", help="counts per topic, color, tone and theme (from the last sort)")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_library_status)
    s = sub.add_parser("add", help="copy (or move) images into a topic, then sort")
    s.add_argument("files", nargs="+")
    s.add_argument("--topic", required=True, help="topic folder name (created when new)")
    s.add_argument("--move", action="store_true", help="move instead of copy")
    s.add_argument("--no-sort", action="store_true", help="don't re-sort afterwards")
    s.set_defaults(fn=cmd_library_add)
    s = sub.add_parser(
        "migrate",
        help="move the library to ~/Documents/Loft and convert packs + settings to themes and variants (dry run)",
        description="docs/THEME-ARCHITECTURE.md §5.5. Without --apply nothing changes: the report says what would. "
        "Every step is idempotent; --undo puts an applied migration back from its report.",
    )
    _migrate_args(s)

    wall = top.add_parser(
        "wallpaper",
        help="wallpapers per display and workspace: sets, auto matching",
        description="Wallpaper sets assign images by display role (main, left, right, portrait, display-N, …) and per "
        "workspace; auto mode fills the rest with images of the theme's vibe set in the same tone (wallsets.py). "
        "Choices live in <state>/overrides/shell.json perTheme.<theme>; the running shell picks changes up.",
    )
    sub = wall.add_subparsers(dest="cmd", required=True)

    def common(s, layout: bool = True) -> None:
        s.add_argument("--theme", help="theme name (default: the current theme)")
        if layout:
            s.add_argument("--layout", metavar="JSON", help="{outputs, main, workspaces} inline, - or @file (default: ask niri)")

    s = sub.add_parser("plan", help="what every display and workspace shows, with the auto picks")
    common(s)
    s.add_argument("--choices", metavar="JSON", help="the theme's choices (default: from shell.json)")
    s.add_argument("--json", action="store_true", help="machine-readable (what the shell reads)")
    s.set_defaults(fn=cmd_wall_plan)
    s = sub.add_parser("sets", help="list the theme's wallpaper sets (the pack's and saved ones)")
    common(s, layout=False)
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_wall_sets)
    s = sub.add_parser("set", help="apply, save, show or delete a wallpaper set")
    s.add_argument("action", choices=["apply", "save", "show", "delete"])
    s.add_argument("name")
    common(s)
    s.add_argument("--pack", metavar="DIR", help="save: into this pack's theme.json (images copied into its wallpapers/)")
    s.set_defaults(fn=cmd_wall_set)
    s = sub.add_parser("shuffle", help="reseed the auto picks")
    common(s, layout=False)
    s.set_defaults(fn=cmd_wall_shuffle)
    s = sub.add_parser("auto", help="auto-fill displays and workspaces with matching images")
    s.add_argument("state", choices=["on", "off", "default"])
    common(s, layout=False)
    s.set_defaults(fn=cmd_wall_auto)
    s = sub.add_parser(
        "focus",
        help="where an image is cropped on each kind of display",
        description="Show or set the point (0..1 from the top left) an image's crop is centered on, per display role "
        "(ultrawide, portrait, landscape, main, left, display-N, … or * for all). Without one a display crops around "
        "the image's auto focus. Stored globally in shell.json wallpaperFraming; the running shell picks it up.",
    )
    s.add_argument("image")
    s.add_argument("x", type=float, nargs="?")
    s.add_argument("y", type=float, nargs="?")
    s.add_argument("--role", default="*", help="display role (default: * = every display)")
    s.add_argument("--clear", action="store_true", help="drop the role's override")
    s.add_argument(
        "--fit", choices=wallsets.FITS, help="cover: scaled to cover each display (default); native: pixel for pixel, cropped, never shrunk"
    )
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_wall_focus)
    wallvideo.add_wallpaper_parser(sub)

    s = top.add_parser(
        "windows",
        help="translucent windows and per-app window rules (= loft-niri windows …)",
        description="glass [on|off|status|reset] [--focused F] [--unfocused F] [--blur on|off] · "
        "opaque [list|add|remove] [APP-ID] · rule APP-ID [FIELD=VALUE…] · reset [APP-ID] · list. "
        "Add --json before the subcommand for JSON (loft windows --json glass).",
    )
    s.add_argument("rest", nargs=argparse.REMAINDER, help="loft-niri windows arguments")
    s.set_defaults(fn=cmd_windows)

    s = top.add_parser(
        "niri",
        help="the niri settings Loft manages (= loft-niri …): keys, show, set, unset, binds, outputs",
        description="Everything after `niri` goes to loft-niri (`loft niri --help`).",
        add_help=False,
    )
    s.add_argument("rest", nargs=argparse.REMAINDER, help="loft-niri arguments")
    s.set_defaults(fn=cmd_niri)

    s = top.add_parser("qt", help="Qt / KDE apps (Dolphin) in the Loft look (programs.loft.qt)")
    qsub = s.add_subparsers(dest="cmd", required=True)
    q = qsub.add_parser("sync", help="link the Kvantum theme + color scheme and write the apps' rc keys (the `qt` hook)")
    q.set_defaults(fn=cmd_qt_sync)

    # The Transparency / Blur dials (Settings → Appearance).
    transparency.add_parser(top)
    dock.add_parser(top, lambda ctx: ctx.state_dir)
    island.add_parser(top, lambda ctx: str(ctx.shell_path))
    # Utilities window (src/utilities): ports, flake updates, cleaner, media tools.
    ports.add_parser(top)
    updates.add_parser(top, lambda ctx: ctx.state_dir)
    cleaner.add_parser(top, lambda ctx: ctx.state_dir)
    media.add_parser(top, lambda ctx: ctx.shell_path)
    capture.add_parser(top)
    utilities.add_parser(top, lambda ctx: ctx.shell_path)
    keys.add_parser(top, lambda ctx: ctx.state_dir)
    # Theme facets: loft colors|wallpapers|material|motion|… list/show/apply/set/reset/save-as.
    themecmds.add_kind_parsers(top)
    # The login screen (SDDM) following the lock screen (PLAN §4.5).
    greeter.add_parser(top)
    spotify.add_parser(top, _fail)
    doctor.add_parser(top)
    mcp.add_parser(top)
    return p


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["dev"]:
        return run_dev(argv[1:])
    # `loft [--dev] windows|niri …`: everything after it goes to loft-niri
    # (argparse would claim its options, e.g. --json).
    w = 1 if argv[:1] == ["--dev"] else 0
    forward = {"windows": cmd_windows, "niri": cmd_niri}.get(argv[w] if len(argv) > w else "")
    if forward and (forward is cmd_niri or not {"-h", "--help"} & set(argv[w + 1 : w + 2])):
        try:
            if w:
                load_dev_env()
            forward(Ctx(bool(w)), argparse.Namespace(rest=argv[w + 1 :]))
        except Fail as e:
            print(f"loft: {e}", file=sys.stderr)
            return 1
    args = parser().parse_args(argv)
    try:
        if args.dev:
            load_dev_env()
        args.fn(Ctx(args.dev), args)
    except Fail as e:
        print(f"loft: {e}", file=sys.stderr)
        return 1
    except (PackError, FacetError, greeter.GreeterError) as e:
        print(f"loft: {e}", file=sys.stderr)
        return 1
    return 0
