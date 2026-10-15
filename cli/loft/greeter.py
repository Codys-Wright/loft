"""`loft greeter …` and `loft theme apply --greeter`: the login screen follows
the lock screen (PLAN §4.5, THEME-ARCHITECTURE.md §2.8).

SDDM runs as its own user and can't read $HOME, so the greeter reads a
machine-wide copy: /var/lib/loft/greeter → /var/lib/loft/themes/<name>-<id>/

    theme.json      the active theme's rendered shell theme (palette, glass)
    greeter.json    {name, label, format, main, wallpaper, source, user, key}
    lock/           the lock design's directory (lock/theme.conf with the
                    facet's `config` merged in), absent for the built-in one
    wallpaper.<ext> the image behind the built-in design, when it uses one

This module stages that pack as a tar and streams it to the privileged
helper (greeter_helper.py, `loft-greeter-install`) through pkexec. The
NixOS module (`programs.loft.greeter.enable`) installs the helper, its
polkit rule and /etc/loft/greeter.json, which names the helper and whether
the greeter follows the lock by default; without that file nothing here
runs automatically.
"""

from __future__ import annotations

import copy
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path

GREETER = Path("/var/lib/loft/greeter")
WALLPAPER_EXT = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif"}
MAX_WALLPAPER = 64 * 1024 * 1024


class GreeterError(Exception):
    pass


def config_path() -> Path:
    return Path(os.environ.get("LOFT_GREETER_CONFIG") or "/etc/loft/greeter.json")


def installed_dir() -> Path:
    return Path(os.environ.get("LOFT_GREETER_DIR") or GREETER)


def config() -> dict | None:
    """/etc/loft/greeter.json (the NixOS module's marker), or None."""
    try:
        c = json.loads(config_path().read_text())
        return c if isinstance(c, dict) else None
    except (OSError, ValueError):
        return None


def _prefs_file(ctx) -> Path:
    return ctx.state_dir / "greeter.json"


def follows(ctx, cfg: dict | None) -> bool:
    """Whether a theme apply re-syncs the greeter: your `loft greeter follow`
    choice, else the machine's default (programs.loft.greeter.followLock)."""
    try:
        v = json.loads(_prefs_file(ctx).read_text()).get("follow")
        if isinstance(v, bool):
            return v
    except (OSError, ValueError, AttributeError):
        pass
    return bool((cfg or {}).get("followLock", True))


# ── what the greeter shows ────────────────────────────────────────────────


def _design(cat, res, ref: str | None) -> tuple[dict, str, str]:
    """The lock design for the login screen, where it came from and its label: REF
    (`same`, `builtin` or a lock: ref), else the lock facet's `greeter`."""
    from .facets.model import fill, defaults

    lock = res.facets.get("lock") or {}
    want = ref or lock.get("greeter") or "same"
    if want == "same":
        src = res.sources.get("lock") or {}
        return copy.deepcopy(lock), src.get("ref") or "lock:builtin", src.get("label") or "Lock screen"
    if want == "builtin":
        return {"format": "builtin", "wallpaper": lock.get("wallpaper", "desktop")}, "builtin", "Built-in"
    f = cat.facet(want, "lock")
    return fill(defaults("lock"), copy.deepcopy(f.data)), f.id, f.label


def _desktop_wallpaper(res) -> str | None:
    w = res.facets.get("wallpapers") or {}
    arr = w.get("arrangement") or {}
    cands = [arr.get("wallpaper"), *(arr.get("displays") or {}).values(), w.get("default")]
    cands += [c.get("path") for c in w.get("collection") or [] if isinstance(c, dict)]
    for c in cands:
        if isinstance(c, str) and c and Path(c).is_file():
            return c
    return None


def _wallpaper(design: dict, res) -> str | None:
    """The image behind the design, for the built-in design (pack designs
    draw their own background): `desktop` → what the desktop shows."""
    if design.get("format") not in (None, "builtin", "loft"):
        return None
    w = design.get("wallpaper")
    path = _desktop_wallpaper(res) if w in (None, "desktop") else (None if w == "design" else w)
    if not path or Path(path).suffix.lower() not in WALLPAPER_EXT:
        return None
    p = Path(path)
    if not p.is_file() or p.stat().st_size > MAX_WALLPAPER:
        return None
    return str(p.resolve())


def _slug(s: str) -> str:
    s = re.sub(r"[^A-Za-z0-9._-]+", "-", s).strip("-._") or "greeter"
    return s[:48]


class Plan:
    """The greeter pack to install, before it's packed."""

    def __init__(self, ctx, cat, res, ref: str | None = None):
        self.design, self.source, self.label = _design(cat, res, ref)
        fmt = self.design.get("format") or "builtin"
        self.format = fmt
        self.lock_dir: Path | None = None
        self.main = ""
        if fmt != "builtin" and self.design.get("path"):
            d = Path(self.design["path"])
            if not d.is_dir():
                raise GreeterError(f"lock design {d} is not a directory")
            self.lock_dir = d.resolve()
            main = Path(self.design.get("main") or d / "Main.qml")
            try:
                rel = main.resolve().relative_to(self.lock_dir)
            except ValueError as e:
                raise GreeterError(f"lock design entry {main} is outside {d}") from e
            self.main = f"lock/{rel.as_posix()}"
        self.theme_json = ctx.current / "theme.json"
        if not self.theme_json.is_file():
            raise GreeterError(f"no applied theme ({self.theme_json}); run `loft theme apply` first")
        self.wallpaper = _wallpaper(self.design, res)
        self.name = _slug(self.source.split(":")[-1].replace("/", "-"))

    def key(self) -> str:
        """Changes when anything the greeter shows changes (cheap: no file walk)."""
        h = hashlib.sha256()
        h.update(json.dumps([self.design, self.source, self.wallpaper], sort_keys=True, default=str).encode())
        h.update(self.theme_json.read_bytes())
        if self.lock_dir is not None:
            for f in sorted(self.lock_dir.rglob("*")):
                try:
                    st = f.stat()
                except OSError:
                    continue
                h.update(f"{f}:{st.st_size}:{st.st_mtime_ns}".encode())
        return h.hexdigest()[:16]

    def meta(self) -> dict:
        if getattr(self, "_meta", None) is None:
            self._meta = self._make_meta()
        return self._meta

    def _make_meta(self) -> dict:
        return {
            "name": self.name,
            "label": self.label,
            "format": self.format,
            "main": self.main,
            "wallpaper": f"wallpaper{Path(self.wallpaper).suffix.lower()}" if self.wallpaper else "",
            "source": self.source,
            "user": os.environ.get("USER") or str(os.getuid()),
            "synced": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "key": self.key(),
        }

    def _theme_conf(self) -> bytes | None:
        """lock/theme.conf with the facet's `config` overlay (the SDDM `config` map)."""
        assert self.lock_dir is not None
        over = {str(k): str(v) for k, v in (self.design.get("config") or {}).items()}
        conf = self.lock_dir / "theme.conf"
        if not over:
            return None
        lines = conf.read_text(errors="replace").splitlines() if conf.is_file() else ["[General]"]
        seen = set()
        out = []
        for line in lines:
            t = line.strip()
            eq = t.find("=")
            k = t[:eq].strip() if eq > 0 and not t.startswith(("#", "[")) else None
            if k in over:
                out.append(f"{k}={over[k]}")
                seen.add(k)
            else:
                out.append(line)
        out += [f"{k}={v}" for k, v in over.items() if k not in seen]
        return ("\n".join(out) + "\n").encode()

    def files(self) -> list[tuple[str, Path | bytes]]:
        """(archive name, source file or contents), lock/ entries regular files only."""
        out: list[tuple[str, Path | bytes]] = [
            ("greeter.json", json.dumps(self.meta(), indent=2).encode()),
            ("theme.json", self.theme_json.read_bytes()),
        ]
        if self.wallpaper:
            out.append((self.meta()["wallpaper"], Path(self.wallpaper)))
        if self.lock_dir is not None:
            conf = self._theme_conf()
            for f in sorted(self.lock_dir.rglob("*")):
                rel = f.relative_to(self.lock_dir).as_posix()
                if any(part.startswith(".") for part in rel.split("/")):
                    continue
                # A link is copied as what it points at, only when that stays
                # inside the design (the greeter can't follow it into $HOME).
                real = f.resolve()
                if f.is_symlink():
                    try:
                        real.relative_to(self.lock_dir)
                    except ValueError:
                        print(f"loft: greeter: skipping {f} (links outside the design)", file=sys.stderr)
                        continue
                if real.is_file():
                    out.append((f"lock/{rel}", conf if (rel == "theme.conf" and conf) else real))
            if conf and not (self.lock_dir / "theme.conf").exists():
                out.append(("lock/theme.conf", conf))
        return out

    def size(self) -> int:
        return sum(len(s) if isinstance(s, bytes) else s.stat().st_size for _, s in self.files())

    def write_tar(self, out) -> None:
        with tarfile.open(fileobj=out, mode="w|", format=tarfile.PAX_FORMAT) as tar:
            for name, src in self.files():
                data = src if isinstance(src, bytes) else src.read_bytes()
                ti = tarfile.TarInfo(name)
                ti.size = len(data)
                ti.mode = 0o644
                ti.mtime = int(time.time())
                tar.addfile(ti, io.BytesIO(data))


def plan(ctx, ref: str | None = None) -> Plan:
    from . import themecmds

    state = themecmds.state_of(ctx)
    cat, theme, variant = themecmds.active(ctx, state)
    res = themecmds.resolved(ctx, cat, theme, variant, state)
    return Plan(ctx, cat, res, ref)


# ── install through the helper ────────────────────────────────────────────


def _helper_argv(cfg: dict | None, interactive: bool) -> list[str]:
    if os.environ.get("LOFT_GREETER_HELPER"):  # tests: run the helper directly
        return os.environ["LOFT_GREETER_HELPER"].split()
    helper = (cfg or {}).get("helper")
    if not helper:
        raise GreeterError(
            f"the greeter isn't set up on this machine ({config_path()} missing); "
            "enable programs.loft.greeter in the NixOS config (nixosModules.default)"
        )
    pkexec = "/run/wrappers/bin/pkexec"
    if not Path(pkexec).exists():
        raise GreeterError(f"{pkexec} is missing (security.polkit.enablePkexecWrapper, set by programs.loft.greeter)")
    return [pkexec, *([] if interactive else ["--disable-internal-agent"]), helper]


def _helper_env() -> dict:
    # pkexec refuses to run when $SHELL isn't listed in /etc/shells (nushell,
    # a home-manager zsh, …): the helper never uses it, so hand it /bin/sh.
    return {**os.environ, "SHELL": "/bin/sh"}


def install(ctx, p: Plan, interactive: bool = True) -> str:
    cfg = config()
    argv = _helper_argv(cfg, interactive)
    limit = int((cfg or {}).get("maxBytes") or 512 * 1024 * 1024)
    if p.size() > limit:
        raise GreeterError(f"the greeter pack is {p.size() // (1024 * 1024)} MiB, over the {limit // (1024 * 1024)} MiB limit")
    with tempfile.TemporaryFile() as tmp:
        p.write_tar(tmp)
        tmp.seek(0)
        r = subprocess.run([*argv, "install", p.name], stdin=tmp, capture_output=True, text=True, env=_helper_env())
    if r.returncode != 0:
        msg = (r.stderr or r.stdout).strip() or f"exit {r.returncode}"
        raise GreeterError(f"installing the greeter pack failed: {msg}")
    return r.stdout.strip()


def reset(interactive: bool = True) -> str:
    r = subprocess.run([*_helper_argv(config(), interactive), "reset"], capture_output=True, text=True, env=_helper_env())
    if r.returncode != 0:
        raise GreeterError(f"resetting the greeter failed: {(r.stderr or r.stdout).strip()}")
    return r.stdout.strip()


def status() -> dict:
    d = installed_dir()
    cfg = config()
    out: dict = {"enabled": cfg is not None, "path": str(d), "installed": None}
    if d.is_dir():
        out["target"] = str(d.resolve())
        try:
            out["installed"] = json.loads((d / "greeter.json").read_text())
        except (OSError, ValueError):
            out["installed"] = {}
    return out


# ── following the lock on `loft theme apply` ──────────────────────────────


def follow(ctx, cat, res) -> None:
    """After an apply: re-sync the greeter in the background when what it
    would show changed. Never raises and never prompts; failures go to
    <state>/greeter-sync.log."""
    try:
        cfg = config()
        if cfg is None or not follows(ctx, cfg) or os.environ.get("LOFT_GREETER_FOLLOW") == "0":
            return
        p = Plan(ctx, cat, res)
        have = (status().get("installed") or {}).get("key")
        if have == p.key():
            return
        log = ctx.state_dir / "greeter-sync.log"
        pid = os.fork()
        if pid:
            return
        # Child: detach from the caller's pipes (the shell waits for EOF).
        try:
            os.setsid()
            fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
            nul = os.open(os.devnull, os.O_RDONLY)
            os.dup2(nul, 0)
            os.dup2(fd, 1)
            os.dup2(fd, 2)
            print(f"{time.strftime('%F %T')} sync {p.source}", flush=True)
            print(install(ctx, p, interactive=False), flush=True)
        except BaseException as e:  # noqa: BLE001 — the child must never return
            print(f"loft: greeter sync failed: {e}", file=sys.stderr, flush=True)
        finally:
            os._exit(0)
    except Exception as e:  # noqa: BLE001 — a theme apply never fails over the greeter
        print(f"loft: greeter not synced: {e}", file=sys.stderr)


# ── CLI ───────────────────────────────────────────────────────────────────


def cmd_sync(ctx, args) -> None:
    p = plan(ctx, getattr(args, "ref", None) or getattr(args, "greeter", None) or None)
    if getattr(args, "dry_run", False):
        print(json.dumps({**p.meta(), "files": [n for n, _ in p.files()], "bytes": p.size()}, indent=2))
        return
    out = install(ctx, p, interactive=not getattr(args, "auto", False))
    print(f"loft: login screen → {p.label} ({p.source})" + (f"\n{out}" if out and getattr(args, "verbose", False) else ""))


def cmd_status(ctx, args) -> None:
    s = status()
    s["follow"] = s["enabled"] and follows(ctx, config())
    if args.json:
        print(json.dumps(s, indent=2))
        return
    if not s["enabled"]:
        print(f"greeter: not set up on this machine ({config_path()} missing)")
    inst = s["installed"]
    if inst is None:
        print("login screen: built-in design")
    else:
        print(f"login screen: {inst.get('label', '?')} ({inst.get('source', '?')}, {inst.get('format', '?')})")
        print(f"  synced {inst.get('synced', '?')} by {inst.get('user', '?')} → {s.get('target')}")
    print(f"follows your lock screen: {'yes' if s['follow'] else 'no'}")


def cmd_reset(ctx, args) -> None:
    reset()
    print("loft: login screen → built-in design")


def cmd_follow(ctx, args) -> None:
    f = _prefs_file(ctx)
    try:
        prefs = json.loads(f.read_text())
    except (OSError, ValueError):
        prefs = {}
    if args.state == "default":
        prefs.pop("follow", None)
    else:
        prefs["follow"] = args.state == "on"
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(json.dumps(prefs, indent=2) + "\n")
    print(f"loft: login screen follows your lock screen: {'yes' if follows(ctx, config()) else 'no'}")


def add_parser(top) -> None:
    g = top.add_parser("greeter", help="the login screen (SDDM): show your lock design there too")
    sub = g.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("sync", help="copy your lock design + colors to the login screen (pkexec helper)")
    s.add_argument("ref", nargs="?", help="same (default: the lock facet's `greeter`), builtin, or a lock: ref")
    s.add_argument("--dry-run", action="store_true", help="print what would be installed")
    s.add_argument("--auto", action="store_true", help="never prompt for authentication")
    s.add_argument("-v", "--verbose", action="store_true")
    s.set_defaults(fn=cmd_sync)
    s = sub.add_parser("status", help="what the login screen shows")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_status)
    s = sub.add_parser("reset", help="back to the built-in login design")
    s.set_defaults(fn=cmd_reset)
    s = sub.add_parser("follow", help="re-sync on every `loft theme apply` (default: on when the machine enables it)")
    s.add_argument("state", choices=["on", "off", "default"])
    s.set_defaults(fn=cmd_follow)
