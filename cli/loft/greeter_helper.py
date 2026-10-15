"""loft-greeter-install: the privileged half of `loft greeter sync` (PLAN §4.5).

Runs as root through pkexec (the NixOS module's polkit rule lets local
active users of one group run it without a password). It never reads the
caller's files: the unprivileged CLI (cli/loft/greeter.py) stages the
greeter pack and streams it as an uncompressed tar on stdin, so a caller
can't make root copy something only root may read.

    loft-greeter-install install NAME < greeter.tar
    loft-greeter-install reset

`install` checks the archive (regular files and directories only, relative
names, only the entries the greeter reads, a size cap), unpacks it into a
fresh root-owned, world-readable directory under <root>/themes/, then
atomically re-points <root>/greeter at it and removes the previous copies.
`reset` removes the link (and the copies): the login screen goes back to
the built-in design.

<root> is /var/lib/loft. Tests pass --root, which is refused when running
as root. Stdlib only, so the Nix package needs nothing but python3.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import shutil
import sys
import tarfile
import tempfile
from pathlib import Path, PurePosixPath

ROOT = Path("/var/lib/loft")
CONFIG = Path("/etc/loft/greeter.json")
DEFAULT_MAX_BYTES = 512 * 1024 * 1024
MAX_FILES = 20000
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
WALLPAPER_EXT = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif"}


class Refused(Exception):
    pass


def max_bytes() -> int:
    try:
        v = json.loads(CONFIG.read_text()).get("maxBytes")
        if isinstance(v, int) and v > 0:
            return v
    except (OSError, ValueError, AttributeError):
        pass
    return DEFAULT_MAX_BYTES


def allowed(name: str) -> PurePosixPath:
    """A member name the greeter reads, normalized; else Refused."""
    if name.startswith("/") or "\\" in name or "\0" in name:
        raise Refused(f"bad path {name!r}")
    parts = [p for p in name.split("/") if p not in ("", ".")]
    if not parts or any(p == ".." for p in parts):
        raise Refused(f"bad path {name!r}")
    p = PurePosixPath(*parts)
    top = parts[0]
    if top == "lock":
        return p
    if len(parts) == 1 and top in ("theme.json", "greeter.json"):
        return p
    if len(parts) == 1 and top.startswith("wallpaper.") and PurePosixPath(top).suffix.lower() in WALLPAPER_EXT:
        return p
    raise Refused(f"unexpected entry {name!r} (the greeter reads theme.json, greeter.json, wallpaper.*, lock/)")


def spool(stream, limit: int, into: Path) -> Path:
    """stdin → a root-owned temp file, refusing more than the cap (+ tar overhead)."""
    budget = limit + 64 * 1024 * 1024
    fd, name = tempfile.mkstemp(prefix=".incoming-", suffix=".tar", dir=into)
    total = 0
    with os.fdopen(fd, "wb") as out:
        while chunk := stream.read(1 << 20):
            total += len(chunk)
            if total > budget:
                raise Refused(f"archive larger than {limit // (1024 * 1024)} MiB")
            out.write(chunk)
    return Path(name)


def unpack(archive: Path, dest: Path, limit: int) -> dict:
    """Check every member, then write them under dest (0755 dirs, 0644 files)."""
    with tarfile.open(archive, "r:") as tar:
        members = tar.getmembers()
        if len(members) > MAX_FILES:
            raise Refused(f"more than {MAX_FILES} entries")
        size = 0
        plan: list[tuple[PurePosixPath, tarfile.TarInfo]] = []
        for m in members:
            p = allowed(m.name)
            if not (m.isreg() or m.isdir()):
                raise Refused(f"{m.name}: only regular files and directories (no links or devices)")
            size += m.size if m.isreg() else 0
            if size > limit:
                raise Refused(f"pack larger than {limit // (1024 * 1024)} MiB")
            plan.append((p, m))
        names = {str(p) for p, m in plan if m.isreg()}
        if "theme.json" not in names or "greeter.json" not in names:
            raise Refused("theme.json and greeter.json are required")
        dest.mkdir(mode=0o755)
        for p, m in plan:
            target = dest.joinpath(*p.parts)
            if m.isdir():
                target.mkdir(mode=0o755, parents=True, exist_ok=True)
                continue
            target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
            src = tar.extractfile(m)
            # dest is a fresh root-owned directory: nothing in it can be a
            # planted link, O_EXCL|O_NOFOLLOW just make that explicit.
            fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
            with os.fdopen(fd, "wb") as out:
                shutil.copyfileobj(src, out)
    meta = json.loads((dest / "greeter.json").read_text())
    json.loads((dest / "theme.json").read_text())
    if not isinstance(meta, dict):
        raise Refused("greeter.json is not an object")
    main = meta.get("main") or ""
    if main:
        mp = allowed(main)
        if mp.parts[0] != "lock" or mp.suffix != ".qml" or not dest.joinpath(*mp.parts).is_file():
            raise Refused(f"greeter.json main {main!r} is not a .qml file under lock/")
    wp = meta.get("wallpaper") or ""
    if wp and (wp not in names or not wp.startswith("wallpaper.")):
        raise Refused(f"greeter.json wallpaper {wp!r} is not in the archive")
    return meta


def swap_link(link: Path, target: str) -> None:
    if link.exists() and not link.is_symlink():
        raise Refused(f"{link} is not a symlink; move it away first")
    tmp = link.with_name(f".{link.name}.tmp-{os.getpid()}")
    if tmp.is_symlink() or tmp.exists():
        tmp.unlink()
    tmp.symlink_to(target)
    os.replace(tmp, link)


def prune(themes: Path, keep: str | None) -> None:
    for d in themes.iterdir():
        if d.name != keep and not d.name.startswith(".incoming-"):
            if d.is_dir() and not d.is_symlink():
                shutil.rmtree(d)
            else:
                d.unlink()


def install(root: Path, name: str, stream) -> Path:
    if not NAME.match(name):
        raise Refused(f"bad name {name!r} (letters, digits, . _ -)")
    limit = max_bytes()
    themes = root / "themes"
    themes.mkdir(mode=0o755, parents=True, exist_ok=True)
    archive = spool(stream, limit, themes)
    dest = themes / f"{name}-{secrets.token_hex(4)}"
    try:
        unpack(archive, dest, limit)
    except (Refused, tarfile.TarError, ValueError, OSError) as e:
        shutil.rmtree(dest, ignore_errors=True)
        raise Refused(str(e)) from e
    finally:
        archive.unlink(missing_ok=True)
    swap_link(root / "greeter", f"themes/{dest.name}")
    prune(themes, dest.name)
    return dest


def reset(root: Path) -> None:
    link = root / "greeter"
    if link.is_symlink():
        link.unlink()
    elif link.exists():
        raise Refused(f"{link} is not a symlink; leaving it alone")
    if (root / "themes").is_dir():
        prune(root / "themes", None)


def main(argv: list[str] | None = None, stdin=None) -> int:
    p = argparse.ArgumentParser(prog="loft-greeter-install", description="install a greeter pack for the Loft login screen")
    p.add_argument("--root", help=argparse.SUPPRESS)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("install", help="install the tar on stdin as the greeter pack")
    s.add_argument("name")
    sub.add_parser("reset", help="back to the built-in login design")
    args = p.parse_args(argv)
    if args.root and os.geteuid() == 0:
        print("loft-greeter-install: --root is for tests only", file=sys.stderr)
        return 2
    root = Path(args.root) if args.root else ROOT
    os.umask(0o022)
    try:
        if args.cmd == "install":
            dest = install(root, args.name, stdin if stdin is not None else sys.stdin.buffer)
            print(f"loft-greeter-install: {root / 'greeter'} → {dest}")
        else:
            reset(root)
            print("loft-greeter-install: greeter reset to the built-in design")
    except Refused as e:
        print(f"loft-greeter-install: refused: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
