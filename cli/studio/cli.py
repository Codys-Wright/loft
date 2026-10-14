"""studio — the studio-linux CLI (theme engine + manager).

Environment (all optional):
  STUDIO_STATE_DIR     `current` → active rendered theme, `rendered/` cache
                       (default: $XDG_STATE_HOME/studio-linux)
  STUDIO_THEME_PATH    colon-separated dirs of theme packs
                       (default: $XDG_DATA_HOME/studio-linux/themes, then built-ins)
  STUDIO_SHELL_PATH    Quickshell config of the running shell, for IPC
  STUDIO_DATA_DIR      root holding themes/ and templates/render/ (default: this tree)
  STUDIO_TEMPLATE_DIR  override the render templates (dev)
  STUDIO_HOOKS         reload hooks after apply: all|none|comma list of
                       shell,niri,kitty,ghostty,gtk (default: all; --dev: shell,niri)

`studio --dev …` targets the session started by `nix run .#dev` instead.
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

from . import hooks, importers, render
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
        self.user_themes = data_home / "studio-linux" / "themes"
        self.state_dir = Path(_env("STUDIO_STATE_DIR") or state_home / "studio-linux")
        tp = _env("STUDIO_THEME_PATH") or f"{self.user_themes}:{self.builtin_themes}"
        self.theme_path = [Path(p) for p in tp.split(":") if p]
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

    def validate(self, pack: Pack, require_manifest: bool = False) -> None:
        try:
            pack.validate(self.schema, require_manifest)
        except PackError as e:
            raise Fail(str(e)) from e


def load_dev_env() -> None:
    env_file = Path(_env("XDG_RUNTIME_DIR") or "/tmp") / "studio-dev" / "session.env"
    if not env_file.is_file():
        raise Fail("no studio-dev session running")
    for line in env_file.read_text().splitlines():
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            os.environ[k.strip()] = v.strip()


# ── commands ────────────────────────────────────────────────────────────────


def cmd_list(ctx: Ctx, args) -> None:
    # First match on the theme path wins, as in `find` (user packs shadow built-ins).
    packs: dict[str, Path] = {}
    for d in ctx.theme_path:
        if not d.is_dir():
            continue
        for sub in sorted(d.iterdir()):
            # `default` is an alias (symlink) for one of the real themes.
            if is_pack(sub) and not sub.is_symlink():
                packs.setdefault(sub.name, sub)
    if not args.json:
        for n in sorted(packs):
            print(n)
        return
    # For pickers (the shell's theme selector): enough to draw a swatch.
    out = []
    for name in sorted(packs):
        path = packs[name]
        try:
            theme = json.loads((path / "theme.json").read_text())
        except (OSError, ValueError):
            continue
        out.append(
            {
                "name": name,
                "path": str(path),
                "polarity": theme.get("polarity", "dark"),
                "palette": theme.get("palette", {}),
                "glass": theme.get("glass", {}),
                "wallpaper": theme.get("wallpaper", {}),
            }
        )
    print(json.dumps(out))


def cmd_current(ctx: Ctx, args) -> None:
    f = ctx.current / "theme.json"
    if not f.is_file():
        print("(none — the shell uses its built-in default)")
        return
    print(json.loads(f.read_text()).get("name") or ctx.current.resolve().name)


def cmd_render(ctx: Ctx, args) -> None:
    pack = ctx.find(args.pack)
    ctx.validate(pack)
    render.render(pack, Path(args.outdir), ctx.template_dir)


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
    digest = pack.digest(render.renderer_salt(ctx.template_dir))
    base = ctx.state_dir / "rendered" / pack.name
    dest = base / digest
    if not (dest / "theme.json").is_file():
        base.mkdir(parents=True, exist_ok=True)
        tmp = Path(tempfile.mkdtemp(prefix=f".{digest}-", dir=base))
        tmp.chmod(0o755)  # mkdtemp is 0700; consumers may run as other users
        render.render(pack, tmp, ctx.template_dir)
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
        importers.install(args.source, ctx.user_themes, force=args.force, validate=validate)
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
    dest = ctx.user_themes / args.name
    if not is_pack(dest):
        raise Fail(f"'{args.name}' is not an installed theme ({ctx.user_themes}); built-in themes can't be removed")
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
