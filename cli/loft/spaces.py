"""`loft spaces`: Spaces outside the shell (docs/SPACES.md, docs/KWIN.md §4.2).

Under KWin the Spaces are the user's own KDE Activities, read from
kactivitymanagerd; Loft never creates, renames or removes one. Older Loft
builds did (one Activity per library Space, kept in
<state>/kwin-activities.json); `prune` undoes only what that file records —
removes the Activities those builds created and gives an adopted one its old
name and icon back — and touches no other Activity:

  loft spaces activities            the Activities in Loft's order (JSON)
  loft spaces prune [--dry-run]     undo what older Loft builds did to Activities

Both run `loft-kwin spaces …` ($LOFT_KWIN_BIN) on the session bus, with the
same state dir as the CLI (`loft --dev` targets the dev session's).
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess


class SpacesError(Exception):
    pass


def kwin_argv(sub: str, *rest: str) -> list[str]:
    exe = os.environ.get("LOFT_KWIN_BIN") or shutil.which("loft-kwin")
    if not exe:
        raise SpacesError("loft-kwin isn't installed (it comes with Loft's Plasma support)")
    return [exe, "spaces", sub, *rest]


def run(state_dir, sub: str, *rest: str) -> int:
    env = dict(os.environ, LOFT_STATE_DIR=str(state_dir))
    argv = kwin_argv(sub, *rest)
    try:
        return subprocess.run(argv, env=env).returncode
    except OSError as e:
        raise SpacesError(f"can't run {argv[0]}: {e}") from e


def add_parser(top, state_dir_of) -> None:
    p = top.add_parser("spaces", help="Spaces under KWin are your KDE Activities: list them, or undo what older Loft builds did to them (docs/KWIN.md §4.2)")
    sub = p.add_subparsers(dest="spaces_cmd", required=True)

    def _go(sub_name, *flags):
        def fn(ctx, a):
            extra = [f for f, on in flags if getattr(a, on, False)]
            try:
                code = run(state_dir_of(ctx), sub_name, *extra)
            except SpacesError as e:
                print(f"loft spaces: {e}")
                raise SystemExit(1) from e
            if code:
                raise SystemExit(code)

        return fn

    s = sub.add_parser("activities", help="the session's Activities in Loft's order, with their KDE keys (JSON)")
    s.set_defaults(fn=_go("list"))
    s = sub.add_parser("prune", help="remove the Activities older Loft builds created (an adopted one gets its name back); no other Activity is touched")
    s.add_argument("-n", "--dry-run", action="store_true", help="say what would change, change nothing")
    # Accepted for old scripts; nothing refuses any more.
    s.add_argument("-f", "--force", action="store_true", help=argparse.SUPPRESS)
    s.set_defaults(fn=_go("prune", ("--dry-run", "dry_run")))
