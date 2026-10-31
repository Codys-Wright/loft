"""macOS keyboard parity (docs/PLAN.md §5): one table, keymap/parity.json, for the
macOS system shortcuts Loft answers in niri. From it come

  - the niri binds between the parity markers in niri/shell-binds.kdl.in, and
  - the `mac-parity` xremap group in keymap/mac.json, which gets the physical
    keys to those binds without touching what xremap sends apps,

both committed (four places render shell-binds.kdl.in with sed, and mac.json
is what users read), and checked against the table by tests/test_parity.py.
The flake exposes the table as `lib.keyboardParity` for voyager's config.

  PYTHONPATH=cli python3 -m loft.parity            exit 1 if either is stale
  PYTHONPATH=cli python3 -m loft.parity --write    regenerate both
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

KEYMAP_DIR = Path(__file__).parent / "keymap"
DATA = KEYMAP_DIR / "parity.json"
MAC_JSON = KEYMAP_DIR / "mac.json"
REPO = Path(__file__).resolve().parents[2]
SHELL_BINDS = REPO / "niri" / "shell-binds.kdl.in"

BEGIN = "    // BEGIN parity — generated from cli/loft/keymap/parity.json (python3 -m loft.parity --write)"
END = "    // END parity"
GROUP_ID = "mac-parity"
IPC_TIMEOUT = '"timeout" "-k" "1" "5" @IPC@'

# Mac modifier → xremap modifier (physical keys: ⌘ is Left Super).
XREMAP_MOD = {"Ctrl": "Ctrl", "Shift": "Shift", "Opt": "Alt", "Alt": "Alt", "Cmd": "Super_L"}
# niri / mac key names that differ from xremap's evdev names.
XREMAP_KEY = {"Escape": "Esc"}


def load(path: Path = DATA) -> dict:
    return json.loads(path.read_text())


def _split(combo: str) -> tuple[list[str], str]:
    *mods, key = combo.split("+")
    return mods, key


def _xkey(key: str) -> str:
    key = XREMAP_KEY.get(key, key)
    return key.lower() if len(key) == 1 else key


def xremap_pair(b: dict) -> tuple[str, str]:
    """(physical keys, what xremap sends niri) for one bind."""
    mods, key = _split(b["mac"])
    k = _xkey(key)
    src = "-".join([XREMAP_MOD[m] for m in mods] + [k])
    via = b["via"]
    if via == "ctrl":
        # Right Alt is niri's Mod (lv3:ralt_switch): the plain Ctrl shortcut
        # becomes the WM key's Mod+Ctrl one, so niri never binds a plain Ctrl+key.
        if mods != ["Ctrl"]:
            raise ValueError(f"{b['id']}: via ctrl takes a plain Ctrl shortcut, not {b['mac']!r}")
        return src, f"Ctrl-Alt_R-{k}"
    if via == "cmd":
        if "Cmd" not in mods:
            raise ValueError(f"{b['id']}: via cmd needs Cmd in {b['mac']!r}")
        return src, src
    if via == "super":
        if mods != ["Cmd"]:
            raise ValueError(f"{b['id']}: via super takes Cmd+key, not {b['mac']!r}")
        return src, f"Super_R-{k}"
    raise ValueError(f"{b['id']}: via must be ctrl, cmd or super, not {via!r}")


def xremap_group(data: dict) -> dict:
    remap = dict(xremap_pair(b) for b in data["binds"])
    return {
        "id": GROUP_ID,
        "name": "macOS system shortcuts → Loft (⌃←/→/↑/↓, ⌃⌘…, ⌘H/M)",
        "section": "keymap",
        "description": (
            "⌃←/→ spaces, ⌃↑ Mission Control, ⌃↓ App Exposé "
            "reach niri as Mod+⌃+arrow (plain ⌃+arrows, which ⌥←/→ word navigation sends, stay "
            "the app's); ⌃⌘ shortcuts pass through to niri instead of becoming Ctrl+key; ⌘H / ⌘M "
            "hide on Right Super (generated from keymap/parity.json)"
        ),
        # Exact: ⌃⇧← (select by word on Linux) isn't ⌃←, and ⌃⌘← isn't ⌃←.
        "exact_match": True,
        "remap": dict(sorted(remap.items())),
    }


def _action(run: dict) -> str:
    if "ipc" in run:
        return "spawn " + IPC_TIMEOUT + " " + " ".join(json.dumps(a) for a in run["ipc"]) + ";"
    if "spawn" in run:
        return "spawn " + " ".join(json.dumps(a) for a in run["spawn"]) + ";"
    if "niri" in run:
        return run["niri"] + ";"
    raise ValueError(f"run: expected ipc, spawn or niri, got {run!r}")


def _line(key: str, b: dict, title: str | None) -> str:
    props = []
    if b.get("repeat") is False:
        props.append("repeat=false")
    props.append(f"hotkey-overlay-title={json.dumps(title, ensure_ascii=False)}" if title is not None else "hotkey-overlay-title=null")
    return f"    {key} {' '.join(props)} {{ {_action(b['run'])} }}"


def niri_binds(data: dict) -> list[str]:
    """The KDL lines for shell-binds' `binds {}` (one bind per line)."""
    out = []
    for b in data["binds"]:
        xremap_pair(b)  # validates mac / via
        out.append(f"    // {b['mac']}: {b['macName']}")
        out.append(_line(b["niri"], b, b["title"]))
        if b["via"] == "cmd":
            if not b["niri"].startswith("Mod+"):
                raise ValueError(f"{b['id']}: a via cmd bind is a Mod+ bind")
            # Physical ⌘ is Super where lv3:lwin_switch isn't set.
            out.append(_line("Super+" + b["niri"][len("Mod+"):], b, None))
    return out


def niri_block(data: dict) -> str:
    return "\n".join([BEGIN, *niri_binds(data), END])


def splice_binds(text: str, block: str) -> str:
    start, end = text.index(BEGIN), text.index(END) + len(END)
    return text[:start] + block + text[end:]


def splice_group(mac: dict, group: dict) -> dict:
    groups = [g for g in mac["groups"] if g["id"] != GROUP_ID]
    # Before the ⌘→Ctrl groups: xremap's exact pass takes the first entry
    # that matches, and `cmd` maps ⌘H too.
    at = next(i for i, g in enumerate(groups) if g["id"] == "app-switching") + 1
    groups.insert(at, group)
    return dict(mac, groups=groups)


def dump_mac(mac: dict) -> str:
    return json.dumps(mac, indent=2, ensure_ascii=False) + "\n"


def expected(data: dict | None = None) -> tuple[str, str]:
    """(shell-binds.kdl.in, mac.json) as they should be."""
    data = data or load()
    binds = splice_binds(SHELL_BINDS.read_text(), niri_block(data))
    mac = dump_mac(splice_group(json.loads(MAC_JSON.read_text()), xremap_group(data)))
    return binds, mac


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="python3 -m loft.parity", description=__doc__.split("\n\n")[0])
    ap.add_argument("--write", action="store_true", help="regenerate shell-binds.kdl.in and mac.json")
    a = ap.parse_args(argv)
    binds, mac = expected()
    stale = [p for p, want in ((SHELL_BINDS, binds), (MAC_JSON, mac)) if p.read_text() != want]
    if a.write:
        for p, want in ((SHELL_BINDS, binds), (MAC_JSON, mac)):
            if p in stale:
                p.write_text(want)
                print(f"wrote {p}")
        return 0
    for p in stale:
        print(f"stale: {p} (python3 -m loft.parity --write)", file=sys.stderr)
    return 1 if stale else 0


if __name__ == "__main__":
    sys.exit(main())
