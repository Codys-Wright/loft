"""Reload hooks run by `loft theme apply` after `current` is re-pointed.

A hook is named after the render unit whose files it reloads (`spotify`
reloads unit `spotify`'s spicetify.ini); apply runs a hook only when that
unit's digest changed (render/compose.py), so a wallpaper-only change
doesn't signal terminals or reload niri.

Every hook is best effort: a consumer that isn't running (or isn't
installed) is skipped silently, since it reads `current` when it starts.
"""

from __future__ import annotations

import os
import shutil
import signal
import subprocess
from pathlib import Path

ALL = ("shell", "niri", "wallpapers", "kitty", "ghostty", "gtk", "qt", "spotify")
# Not a unit's reload hook: apply_resolved re-syncs the login screen when what
# it shows changed (greeter.follow), if the machine opted in. Selected like one.
EXTRA = ("greeter",)
# `--dev` targets the nested session (and a test session's own shell runs
# loft with LOFT_DEV=1): GTK settings belong to the host desktop, so leave
# them alone unless asked. Terminals are signalled only within the Wayland
# session loft runs in (_same_session), so the session's own are reloaded
# and the host's never are.
DEV = ("shell", "niri", "wallpapers", "kitty", "ghostty")


def _run(argv: list[str]) -> bool:
    if not shutil.which(argv[0]):
        return False
    try:
        return subprocess.run(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def _wayland_socket(env: dict) -> str:
    wd = env.get("WAYLAND_DISPLAY") or ""
    if not wd:
        return ""
    return wd if wd.startswith("/") else str(Path(env.get("XDG_RUNTIME_DIR") or "") / wd)


def _environ(pid_dir: Path) -> dict:
    try:
        raw = (pid_dir / "environ").read_bytes()
    except OSError:
        return {}
    out = {}
    for item in raw.split(b"\0"):
        k, sep, v = item.partition(b"=")
        if sep:
            out[k.decode(errors="replace")] = v.decode(errors="replace")
    return out


def _same_session(pid_dir: Path, mine: str) -> bool:
    """Whether the process talks to the Wayland compositor we do (`mine`, the
    socket path; "" = no session to scope to: any process, as before). A
    test session's terminals are not the desktop's, and the other way round."""
    return not mine or _wayland_socket(_environ(pid_dir)) == mine


def _signal_procs(names: tuple[str, ...], sig: int) -> int:
    """Signal this user's processes whose comm matches (nix wrappers rename
    the real binary to .<name>-wrapped), in this Wayland session only."""
    uid = os.getuid()
    mine = _wayland_socket(dict(os.environ))
    sent = 0
    for d in Path("/proc").iterdir():
        if not d.name.isdigit():
            continue
        try:
            if d.stat().st_uid != uid:
                continue
            comm = (d / "comm").read_text().strip()
        except OSError:
            continue
        if comm.lstrip(".").split("-wrap")[0] in names and _same_session(d, mine):
            try:
                os.kill(int(d.name), sig)
                sent += 1
            except OSError:
                pass
    return sent


def _ipc(ctx, *call: str) -> bool:
    return _run(["quickshell", "ipc", "--any-display", "--path", str(ctx.shell_path), "call", *call])


def shell(ctx) -> None:
    # Re-pointing `current` is invisible to Quickshell's FileView watcher
    # (it follows the old target), so ask the shell to re-resolve the path.
    _ipc(ctx, "theme", "reload")


def wallpapers(ctx) -> None:
    # The wallpaper layer and pickers re-read the theme's wallpapers.
    _ipc(ctx, "vibes", "refresh")


def preview(ctx, composition: Path | None) -> None:
    """Point the shell (only) at a composition, or back at `current` (§6.3)."""
    _ipc(ctx, "theme", "preview", str(composition) if composition is not None else "")


def niri(ctx) -> None:
    # The window rules (translucent windows) come from theme.json `windows`
    # through loft-niri: re-render them now so the windows change with the
    # rest (the shell would also do it on the theme change, a beat later;
    # unchanged rules are a no-op). It validates and reloads niri itself.
    if shutil.which("loft-niri") and (ctx.state_dir / "overrides").is_dir():
        _run(["loft-niri", "--state-dir", str(ctx.state_dir), "render"])
    # niri polls included files by canonical path, so the new symlink target
    # is picked up within ~500ms anyway; this just makes it immediate.
    if os.environ.get("NIRI_SOCKET"):
        _run(["niri", "msg", "action", "load-config-file"])


def kitty(ctx) -> None:
    _signal_procs(("kitty",), signal.SIGUSR1)


def ghostty(ctx) -> None:
    # Ghostty (GTK apprt) reloads its config on SIGUSR2.
    _signal_procs(("ghostty",), signal.SIGUSR2)


def gtk(ctx) -> None:
    light = ctx.theme.get("polarity") == "light"
    # gsettings is the host desktop's (dconf), never a test session's.
    if os.environ.get("LOFT_DEV") != "1":
        _run(["gsettings", "set", "org.gnome.desktop.interface", "color-scheme", "prefer-light" if light else "prefer-dark"])
    link_gtk_base(ctx.state_dir, "light" if light else "dark")


def qt(ctx) -> None:
    # Loft's Kvantum theme + KDE color scheme for the apps programs.loft.qt
    # lists (qtapps.py): links and targeted rc keys, a no-op without
    # ~/.config/loft/qt.json. Running Qt apps pick it up when restarted.
    from . import qtapps

    try:
        qtapps.sync(ctx.state_dir)
    except OSError:
        pass


def spotify(ctx) -> None:
    # Loft's Spicetify install (cli/loft/spotify.py): the theme's scheme into
    # colors.css, which loft-live.js swaps in live. No-op when not set up.
    from . import spotify as sp

    try:
        sp.sync(sp.root_dir(), ctx.state_dir, ctx.current)
    except (OSError, sp.SpotifyError):
        pass


def link_gtk_base(state_dir: Path, polarity: str) -> None:
    """Point <state>/gtk-base.css at the GTK 4 base stylesheet for this polarity
    (~/.config/loft/gtk-base-{dark,light}.css, written by `programs.loft.gtkBase`,
    e.g. MacTahoe's libadwaita CSS), or an empty file when there is none. The
    gtk.css home-manager writes imports it before the theme's own gtk.css."""
    config = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    base = config / "loft" / f"gtk-base-{polarity}.css"
    link = state_dir / "gtk-base.css"
    tmp = state_dir / ".gtk-base.css.tmp"
    try:
        tmp.unlink(missing_ok=True)
        if base.exists():
            tmp.symlink_to(base)
        else:
            tmp.write_text("/* no GTK base stylesheet (programs.loft.gtkBase) */\n")
        tmp.replace(link)
    except OSError:
        pass


def selected(spec: str | None, dev: bool) -> list[str]:
    if spec is None:
        return list(DEV if dev or os.environ.get("LOFT_DEV") == "1" else ALL + EXTRA)
    if spec in ("", "none"):
        return []
    if spec == "all":
        return list(ALL + EXTRA)
    names = [s.strip() for s in spec.split(",") if s.strip()]
    unknown = [n for n in names if n not in ALL + EXTRA]
    if unknown:
        raise ValueError(f"unknown hook(s) {', '.join(unknown)} (known: {', '.join(ALL + EXTRA)})")
    return names


def run(names: list[str], ctx) -> None:
    for n in names:
        if n not in EXTRA:  # run by apply_resolved, which has the resolved theme
            globals()[n](ctx)
