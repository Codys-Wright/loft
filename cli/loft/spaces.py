"""`loft spaces`: Spaces outside the shell (docs/SPACES.md, docs/KWIN.md §4.2).

Under KWin the Spaces are the user's own KDE Activities. These change them in
KDE itself (kactivitymanagerd, and the "Switch to activity" keys that are
their order), so Plasma and the ⌘N keys see the change:

  loft spaces activities                 the Activities in Loft's order (JSON)
  loft spaces new NAME [--icon ICON]     a new Activity, on the first free ⌘ number
  loft spaces rename ACTIVITY NAME       rename (Loft settings and window rules follow)
  loft spaces icon ACTIVITY ICON         its KDE icon (a freedesktop icon name)
  loft spaces move ACTIVITY N            to place N (its ⌘ key moves with it)
  loft spaces order ACTIVITY…            this order first (the ⌘ keys follow)
  loft spaces remove ACTIVITY [--yes]    remove it (its windows go to its neighbour)
  loft spaces prune [--dry-run]          undo what older Loft builds did to Activities

ACTIVITY is a name (any case), its ⌘ digit or its id. Older Loft builds made
one Activity per library Space (kept in <state>/kwin-activities.json);
`prune` undoes only what that file records and touches no other Activity.

All run `loft-kwin spaces …` ($LOFT_KWIN_BIN) on the session bus, with the
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


def edit_args(a) -> list[str]:
    """`loft spaces <edit> …` → `loft-kwin spaces <edit> …`'s arguments."""
    cmd = a.spaces_cmd
    if cmd == "new":
        return ["new", *a.name, *(["--icon", a.icon] if a.icon else [])]
    if cmd == "rename":
        return ["rename", a.activity, *a.name]
    if cmd == "icon":
        return ["icon", a.activity, a.icon]
    if cmd == "move":
        return ["move", a.activity, str(a.position)]
    if cmd == "order":
        return ["order", *a.activities]
    if cmd == "remove":
        return ["remove", a.activity]
    raise SpacesError(f"unknown command {cmd}")


def confirm_remove(a, ask=input, tty=None) -> bool:
    """`remove` without --yes asks on a terminal, and refuses elsewhere."""
    if a.yes:
        return True
    if not (tty if tty is not None else os.isatty(0)):
        raise SpacesError("removing an Activity needs --yes when nobody can be asked")
    answer = ask(f"Remove the KDE Activity “{a.activity}”? Its windows move to its neighbour. [y/N] ")
    return answer.strip().lower() in ("y", "yes")


def add_parser(top, state_dir_of) -> None:
    p = top.add_parser("spaces", help="Spaces under KWin are your KDE Activities: list, create, rename, re-icon, reorder or remove them (docs/KWIN.md §4.2)")
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

    def _edit(ctx, a):
        try:
            if a.spaces_cmd == "remove" and not confirm_remove(a):
                print("left as it was")
                return
            args = edit_args(a)
            code = run(state_dir_of(ctx), *args)
        except SpacesError as e:
            print(f"loft spaces: {e}")
            raise SystemExit(1) from e
        if code:
            raise SystemExit(code)

    which = "ACTIVITY: a name (any case), its ⌘ digit or its id"
    s = sub.add_parser("new", help="create a KDE Activity (it gets the first free ⌘ number)")
    s.add_argument("name", nargs="+")
    s.add_argument("--icon", default="", help="a freedesktop icon name, e.g. audio-x-generic")
    s.set_defaults(fn=_edit)
    s = sub.add_parser("rename", help="rename a KDE Activity (Loft settings and window rules naming it follow)")
    s.add_argument("activity", help=which)
    s.add_argument("name", nargs="+")
    s.set_defaults(fn=_edit)
    s = sub.add_parser("icon", help="set a KDE Activity's icon (a freedesktop icon name)")
    s.add_argument("activity", help=which)
    s.add_argument("icon")
    s.set_defaults(fn=_edit)
    s = sub.add_parser("move", help="move a KDE Activity to place N (1 = first); the ⌘ number keys follow the order")
    s.add_argument("activity", help=which)
    s.add_argument("position", type=int)
    s.set_defaults(fn=_edit)
    s = sub.add_parser("order", help="put these Activities first, in this order (the others follow); the ⌘ number keys follow")
    s.add_argument("activities", nargs="+")
    s.set_defaults(fn=_edit)
    s = sub.add_parser("remove", help="remove a KDE Activity: its windows move to its neighbour, Loft settings linked to it stay in the library")
    s.add_argument("activity", help=which)
    s.add_argument("-y", "--yes", action="store_true", help="don't ask")
    s.set_defaults(fn=_edit)
