"""Reload hooks run by `studio theme apply` after `current` is re-pointed.

Every hook is best effort: a consumer that isn't running (or isn't
installed) is skipped silently, since it reads `current` when it starts.
"""

from __future__ import annotations

import os
import shutil
import signal
import subprocess
from pathlib import Path

ALL = ("shell", "niri", "kitty", "ghostty", "gtk")
# `--dev` targets the nested session; terminals and GTK settings belong to
# the host desktop, so leave them alone unless asked.
DEV = ("shell", "niri")


def _run(argv: list[str]) -> bool:
    if not shutil.which(argv[0]):
        return False
    try:
        return subprocess.run(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def _signal_procs(names: tuple[str, ...], sig: int) -> int:
    """Signal this user's processes whose comm matches (nix wrappers rename
    the real binary to .<name>-wrapped)."""
    uid = os.getuid()
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
        if comm.lstrip(".").split("-wrap")[0] in names:
            try:
                os.kill(int(d.name), sig)
                sent += 1
            except OSError:
                pass
    return sent


def shell(ctx) -> None:
    # Re-pointing `current` is invisible to Quickshell's FileView watcher
    # (it follows the old target), so ask the shell to re-resolve the path.
    _run(["quickshell", "ipc", "--any-display", "--path", str(ctx.shell_path), "call", "theme", "reload"])


def niri(ctx) -> None:
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
    scheme = "prefer-light" if ctx.theme.get("polarity") == "light" else "prefer-dark"
    _run(["gsettings", "set", "org.gnome.desktop.interface", "color-scheme", scheme])


def selected(spec: str | None, dev: bool) -> list[str]:
    if spec is None:
        return list(DEV if dev else ALL)
    if spec in ("", "none"):
        return []
    if spec == "all":
        return list(ALL)
    names = [s.strip() for s in spec.split(",") if s.strip()]
    unknown = [n for n in names if n not in ALL]
    if unknown:
        raise ValueError(f"unknown hook(s) {', '.join(unknown)} (known: {', '.join(ALL)})")
    return names


def run(names: list[str], ctx) -> None:
    for n in names:
        globals()[n](ctx)
