"""studio — the studio-linux CLI (theme engine + manager).

Environment (all optional):
  STUDIO_STATE_DIR     `current` → active rendered theme, `rendered/` cache
                       (default: $XDG_STATE_HOME/studio-linux)
  STUDIO_THEME_PATH    colon-separated dirs of theme packs
                       (default: $XDG_DATA_HOME/studio-linux/themes, then built-ins);
                       the library's Packs/ always joins, before the built-ins
  STUDIO_LIBRARY       the theme + wallpaper library (default: ~/Documents/Themes;
                       `none` = off). When it exists, packs install into its Packs/
  STUDIO_SHELL_PATH    Quickshell config of the running shell, for IPC
  STUDIO_DATA_DIR      root holding themes/ and templates/render/ (default: this tree)
  STUDIO_TEMPLATE_DIR  override the render templates (dev)
  STUDIO_HOOKS         reload hooks after apply: all|none|comma list of
                       shell,niri,kitty,ghostty,gtk (default: all; --dev: shell,niri)
  STUDIO_THEME_INDEX   themes index (path, file:// or http(s) URL; `none` = off)
                       for curated vibe links (default: studio-linux-themes on GitHub)

`studio --dev …` targets the session started by `nix run .#dev` instead
($STUDIO_SESSION=NAME: the one started with `studio-dev --session NAME`).
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

from . import hooks, importers, index, library, render, vibes
from .pack import IGNORED, Pack, PackError, is_pack

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
        self.data_dir = Path(_env("STUDIO_DATA_DIR") or here)
        self.template_dir = Path(_env("STUDIO_TEMPLATE_DIR") or self.data_dir / "templates" / "render")
        self.schema = self.data_dir / "themes" / "schema.json"
        self.builtin_themes = self.data_dir / "themes"
        home = Path.home()
        data_home = Path(_env("XDG_DATA_HOME") or home / ".local" / "share")
        state_home = Path(_env("XDG_STATE_HOME") or home / ".local" / "state")
        self.legacy_themes = data_home / "studio-linux" / "themes"
        self.state_dir = Path(_env("STUDIO_STATE_DIR") or state_home / "studio-linux")
        tp = _env("STUDIO_THEME_PATH") or f"{self.legacy_themes}:{self.builtin_themes}"
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
        self.shell_path = Path(_env("STUDIO_SHELL_PATH") or self.data_dir / "src")
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


def _resolve(p: Path) -> Path:
    try:
        return p.resolve()
    except OSError:
        return p


def load_dev_env() -> None:
    # `studio-dev --session NAME` sessions live in studio-dev-NAME; the
    # default (`dev`) in studio-dev. Inside an isolated session
    # XDG_RUNTIME_DIR is the session's own, so prefer the host's.
    name = _env("STUDIO_SESSION") or "dev"
    runtime = _env("STUDIO_DEV_HOST_RUNTIME") or _env("XDG_RUNTIME_DIR") or "/tmp"
    sub = "studio-dev" if name == "dev" else f"studio-dev-{name}"
    env_file = Path(runtime) / sub / "session.env"
    if not env_file.is_file() and _env("XDG_RUNTIME_DIR"):
        env_file = Path(f"/run/user/{os.getuid()}") / sub / "session.env"
    if not env_file.is_file():
        raise Fail(f"no studio-dev session `{name}` running")
    for line in env_file.read_text().splitlines():
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            os.environ[k.strip()] = v.strip()


# ── commands ────────────────────────────────────────────────────────────────


def cmd_list(ctx: Ctx, args) -> None:
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
    f = ctx.current / "theme.json"
    if not f.is_file():
        print("(none — the shell uses its built-in default)")
        return
    print(json.loads(f.read_text()).get("name") or ctx.current.resolve().name)


def cmd_render(ctx: Ctx, args) -> None:
    pack = ctx.find(args.pack)
    ctx.validate(pack)
    render.render(pack, Path(args.outdir), ctx.template_dir, curated=ctx.curated(pack))


def cmd_validate(ctx: Ctx, args) -> None:
    import importlib.util

    if importlib.util.find_spec("jsonschema") is None:
        raise Fail("validate needs the jsonschema python module (use the Nix-packaged studio)")
    for ref in args.packs:
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
    pack = ctx.find(args.theme)
    ctx.validate(pack)
    # Cached by content: re-applying an unchanged pack is just a symlink swap,
    # and an edited pack lands in a new dir (a new path niri also notices).
    # Curated vibes point into other installed packs: what they resolve to
    # is part of the key, so installing a linked pack re-renders.
    curated = ctx.curated(pack)
    digest = pack.digest(render.renderer_salt(ctx.template_dir) + json.dumps(curated, sort_keys=True))
    base = ctx.state_dir / "rendered" / pack.name
    dest = base / digest
    if not (dest / "theme.json").is_file():
        base.mkdir(parents=True, exist_ok=True)
        tmp = Path(tempfile.mkdtemp(prefix=f".{digest}-", dir=base))
        tmp.chmod(0o755)  # mkdtemp is 0700; consumers may run as other users
        render.render(pack, tmp, ctx.template_dir, curated=curated)
        if dest.exists():
            shutil.rmtree(dest)
        tmp.rename(dest)
    _swap_symlink(ctx.current, dest)
    for old in base.iterdir():
        if old != dest:
            shutil.rmtree(old, ignore_errors=True)

    ctx.theme = json.loads((dest / "theme.json").read_text())
    try:
        names = hooks.selected(_env("STUDIO_HOOKS") if "STUDIO_HOOKS" in os.environ else None, ctx.dev)
    except ValueError as e:
        raise Fail(str(e)) from e
    hooks.run(names, ctx)
    print(f"studio: applied {pack.name}")


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


def _find_pack_root(root: Path, subdir: str | None) -> Path:
    if subdir:
        root = root / subdir
    if is_pack(root):
        return root
    # Tarballs usually wrap the pack in one top-level directory.
    subs = [d for d in root.iterdir() if d.is_dir() and is_pack(d)] if root.is_dir() else []
    if len(subs) == 1:
        return subs[0]
    if subs:
        raise Fail(f"several packs found ({', '.join(d.name for d in subs)}); pick one with --subdir")
    raise Fail(f"no theme pack (theme.json) found in {root}")


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
    def validate(path: Path) -> None:
        ctx.validate(Pack(path), require_manifest=True)

    try:
        if args.list:
            for theme, pack in importers.list_available(args.source):
                print(f"{pack:28} {args.source.split(':', 1)[0]}:{theme}")
            return
        importers.install(args.source, ctx.user_themes, force=args.force, validate=validate, index=ctx.index())
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
    with tempfile.TemporaryDirectory(prefix="studio-install-") as tmpd:
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

        pack = Pack(_find_pack_root(root, args.subdir))
        ctx.validate(pack, require_manifest=True)
        name = pack.name
        if not NAME.match(name) or name == "default":
            raise Fail(f"pack name '{name}' is not a valid theme name")
        dest = ctx.user_themes / name
        if dest.exists():
            if not args.force:
                raise Fail(f"{name} is already installed ({dest}); use --force to replace it")
            shutil.rmtree(dest)
        dest.parent.mkdir(parents=True, exist_ok=True)
        _copy_pack(pack.path, dest)
    print(f"studio: installed {name} → {dest}")


def cmd_remove(ctx: Ctx, args) -> None:
    dest = next((d / args.name for d in ctx.user_dirs if is_pack(d / args.name)), None)
    if dest is None:
        where = ":".join(map(str, ctx.user_dirs))
        raise Fail(f"'{args.name}' is not an installed theme ({where}); built-in themes can't be removed")
    shutil.rmtree(dest)
    # Drop its render cache unless it's what `current` shows right now.
    rendered = ctx.state_dir / "rendered" / args.name
    cur = ctx.current.resolve() if ctx.current.is_symlink() else None
    if rendered.is_dir() and not (cur and rendered.resolve() in cur.parents):
        shutil.rmtree(rendered)
    print(f"studio: removed {args.name}")


def cmd_export(ctx: Ctx, args) -> None:
    pack = ctx.find(args.name)
    out = Path(args.output or f"{pack.name}.tar.gz")
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
            tf.add(pack.path, arcname=pack.name, filter=clean)
    except tarfile.CompressionError as e:
        raise Fail(f"{out}: {e} (try .tar.gz)") from e
    print(out)


# ── library ─────────────────────────────────────────────────────────────────


def _library(ctx: Ctx) -> library.Library:
    if ctx.library is None:
        raise Fail("the library is turned off (STUDIO_LIBRARY=none)")
    return library.Library(ctx.library)


def cmd_library_sort(ctx: Ctx, args) -> None:
    lib = _library(ctx)
    if not lib.exists():
        if args.json:  # the shell asks on every machine; no library is not an error
            print(json.dumps({"root": str(lib.root), "exists": False}))
            return
        raise Fail(f"no library at {lib.root} (create it, `studio library add`, or set STUDIO_LIBRARY)")
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
        print(f"{lib.root}: " + ("not sorted yet (`studio library sort`)" if lib.exists() else "no library"))
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
    print(f"studio: {'moved' if args.move else 'copied'} {len(added)} into {lib.topics_dir / args.topic}")


# ── entry ───────────────────────────────────────────────────────────────────


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="studio", description="studio-linux CLI")
    p.add_argument("--dev", action="store_true", help="target the `nix run .#dev` session")
    top = p.add_subparsers(dest="group", required=True)
    theme = top.add_parser("theme", help="theme engine and manager")
    sub = theme.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("list", help="list available theme packs")
    s.add_argument("--json", action="store_true", help="names, paths and palettes as JSON")
    s.set_defaults(fn=cmd_list)
    sub.add_parser("current", help="print the active theme").set_defaults(fn=cmd_current)

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

    s = sub.add_parser("apply", help="render (cached), make current, reload consumers")
    s.add_argument("theme", help="theme name or pack path")
    s.set_defaults(fn=cmd_apply)

    s = sub.add_parser("render", help="render a pack's consumer files into a directory")
    s.add_argument("pack")
    s.add_argument("outdir")
    s.set_defaults(fn=cmd_render)

    s = sub.add_parser("validate", help="check packs against themes/schema.json")
    s.add_argument("packs", nargs="+")
    s.set_defaults(fn=cmd_validate)

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
    s.set_defaults(fn=cmd_install)

    s = sub.add_parser("remove", help="remove an installed pack")
    s.add_argument("name")
    s.set_defaults(fn=cmd_remove)

    s = sub.add_parser("export", help="archive a pack for sharing")
    s.add_argument("name")
    s.add_argument("-o", "--output", help="archive path (default: NAME.tar.gz)")
    s.set_defaults(fn=cmd_export)

    lib = top.add_parser(
        "library",
        help="the theme + wallpaper library ($STUDIO_LIBRARY, default ~/Documents/Themes)",
        description="Packs/ and Wallpapers/Topics/<Topic>/ hold the files; sort generates symlink views "
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
    return p


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.dev:
            load_dev_env()
        args.fn(Ctx(args.dev), args)
    except Fail as e:
        print(f"studio: {e}", file=sys.stderr)
        return 1
    except PackError as e:
        print(f"studio: {e}", file=sys.stderr)
        return 1
    return 0
