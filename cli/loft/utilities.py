"""`loft utilities open [SECTION]` and `loft media open FILES…`: open the
shell's Utilities window (src/utilities/) over Quickshell IPC — what the
desktop entries (applications/loft-utilities.desktop, loft-media-tools.desktop)
run, so Spotlight and any file manager's "Open With" reach them.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

SECTIONS = ("ports", "updates", "cleaner", "media")


def ipc(shell_path: Path, target: str, fn: str, *args: str) -> int:
    argv = ["quickshell", "ipc", "--any-display", "--path", str(shell_path), "call", target, fn, *args]
    try:
        return subprocess.run(argv).returncode
    except OSError as e:
        print(f"loft: {e}", file=sys.stderr)
        return 1


def add_parser(top, shell_path_of) -> None:
    ut = top.add_parser("utilities", help="open the Utilities window (ports, updates, cleaner, media tools)")
    sub = ut.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("open")
    s.add_argument("section", nargs="?", choices=SECTIONS)

    def _open(ctx, a):
        code = ipc(shell_path_of(ctx), "utilities", a.section or "open")
        if code:
            raise SystemExit(code)

    s.set_defaults(fn=_open)


def media_open(shell_path: Path, files: list[str], op: str | None) -> int:
    paths = [str(Path(f).expanduser().absolute()) if not f.startswith("file://") else f for f in files]
    return ipc(shell_path, "media", "open", op or "", "\n".join(paths))


def register_media_open(media_sub, shell_path_of) -> None:
    s = media_sub.add_parser("open", help="open files in the Utilities window's Media Tools")
    s.add_argument("files", nargs="*")
    s.add_argument("--op", choices=["compress", "convert", "gif", "watermark", "audio"])

    def _open(ctx, a):
        code = media_open(shell_path_of(ctx), a.files, a.op)
        if code:
            raise SystemExit(code)

    s.set_defaults(fn=_open)

