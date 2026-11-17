"""`loft spaces`: Spaces outside the shell (docs/SPACES.md, docs/KWIN.md §4.2).

Under KWin each Space is a KDE Activity, made by loft-kwin and kept in
<state>/kwin-activities.json (space id → activity id). Activities stay in Plasma
when you go back to plasmashell (harmless, docs/KWIN.md §5); `prune` removes the
ones Loft created and gives an adopted one (the Activity the first Space took
over) its old name and icon back:

  loft spaces activities            the map and kactivitymanagerd's activities (JSON)
  loft spaces prune [--dry-run]     remove Loft's activities (refused while Loft's
                                    shell runs, which would make them again; --force)

Both run `loft-kwin spaces …` ($LOFT_KWIN_BIN) on the session bus, with the
same state dir as the CLI (`loft --dev` targets the dev session's).
"""

from __future__ import annotations

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
    p = top.add_parser("spaces", help="Spaces as KDE Activities under KWin: list or prune the ones Loft made (docs/KWIN.md §4.2)")
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

    s = sub.add_parser("activities", help="the space ↔ activity map and the session's activities (JSON)")
    s.set_defaults(fn=_go("list"))
    s = sub.add_parser("prune", help="remove the Activities Loft created for Spaces (an adopted one gets its name back)")
    s.add_argument("-n", "--dry-run", action="store_true", help="say what would go, change nothing")
    s.add_argument("-f", "--force", action="store_true", help="even while Loft's shell runs (it makes them again)")
    s.set_defaults(fn=_go("prune", ("--dry-run", "dry_run"), ("--force", "force")))
