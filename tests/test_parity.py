"""macOS keyboard parity (cli/loft/parity.py, docs/PLAN.md §5): the niri binds and
the xremap group generated from keymap/parity.json are committed and current, every
remap lands on a niri bind, and — the conflict Option A has to avoid — no key that
xremap sends *apps* (⌥←/→ → Ctrl+←/→ for word navigation, ⌘C → Ctrl+C, …) is a
niri bind, which would swallow it.
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

from loft import keys, parity

REPO = Path(__file__).resolve().parents[1]
NIRI_FILES = [REPO / "niri" / "base.kdl", REPO / "niri" / "shell-binds.kdl.in"]

# xremap outputs that are meant for niri, not the app: ⌘Q → Alt+F4 (the quit
# guard bind), ⌘` → Alt+grave (niri's recent-windows switcher).
FOR_NIRI = {"Alt-F4", "Alt-grave", "Alt-Shift-grave"}

KEY_ALIAS = {
    "esc": "escape",
    "enter": "return",
    "leftbrace": "bracketleft",
    "rightbrace": "bracketright",
    "dot": "period",
}
# xremap modifier → niri modifier. Right Alt is niri's Mod (lv3:ralt_switch);
# Left Super is Mod with lv3:lwin_switch and Super without, so it maps to both.
XMOD = {"shift": "Shift", "ctrl": "Ctrl", "control": "Ctrl", "c": "Ctrl", "alt": "Alt", "alt_l": "Alt",
        "m": "Alt", "alt_r": "Mod", "super_r": "Super", "super": "Super", "win": "Super"}


def norm_key(k: str) -> str:
    k = k.lower().replace("_", "")
    return KEY_ALIAS.get(k, k)


def niri_binds() -> dict[frozenset, str]:
    """Every bind in Loft's niri files, as {(modifiers…, key): source line}."""
    out: dict[frozenset, str] = {}
    for f in NIRI_FILES:
        for line in f.read_text().splitlines():
            m = re.match(r"^\s+([A-Za-z0-9_]+(?:\+[A-Za-z0-9_]+)*)\s.*\{", line) or re.match(r"^\s+([A-Za-z0-9_]+(?:\+[A-Za-z0-9_]+)*)\s+\{", line)
            if not m or m.group(1) in ("binds", "recent-windows"):
                continue
            *mods, key = m.group(1).split("+")
            out[frozenset(mods) | {norm_key(key)}] = f"{f.name}: {line.strip()}"
    return out


def as_niri(combo: str) -> list[frozenset]:
    """The niri binds an xremap output combo can hit (two for Left Super)."""
    *mods, key = combo.split("-")
    variants = [set()]
    for m in mods:
        if m.lower() == "super_l":
            variants = [v | {x} for v in variants for x in ("Mod", "Super")]
        else:
            variants = [v | {XMOD[m.lower()]} for v in variants]
    return [frozenset(v) | {norm_key(key)} for v in variants]


def outputs(action) -> list[str]:
    if isinstance(action, str):
        return [action]
    if isinstance(action, list):
        return [x for a in action for x in outputs(a)]
    return []


class Generated(unittest.TestCase):
    def test_committed_files_are_current(self):
        binds, mac = parity.expected()
        self.assertEqual(parity.SHELL_BINDS.read_text(), binds, "python3 -m loft.parity --write")
        self.assertEqual(parity.MAC_JSON.read_text(), mac, "python3 -m loft.parity --write")

    def test_group_renders_and_checks(self):
        model = {"virtual_modifiers": [], "classes": {}, "apps": {}, "remap": {},
                 "groups": [parity.xremap_group(parity.load())]}
        cfg = keys.render(model)
        keys.check(cfg)
        self.assertTrue(cfg["keymap"][0]["exact_match"], "⌃⇧← (select by word) must not count as ⌃←")

    def test_group_comes_before_the_cmd_groups(self):
        ids = [g["id"] for g in keys.defaults()["groups"]]
        self.assertLess(ids.index(parity.GROUP_ID), ids.index("cmd"))
        self.assertLess(ids.index(parity.GROUP_ID), ids.index("cmd-terminal"))

    def test_every_remap_lands_on_a_niri_bind(self):
        binds = niri_binds()
        for b in parity.load()["binds"]:
            _, to = parity.xremap_pair(b)
            for want in as_niri(to):
                self.assertIn(want, binds, f"{b['id']}: xremap sends {to}, niri has no {sorted(want)}")

    def test_the_mac_ctrl_arrows(self):
        pairs = dict(parity.xremap_pair(b) for b in parity.load()["binds"])
        self.assertEqual(pairs["Ctrl-Left"], "Ctrl-Alt_R-Left")
        self.assertEqual(pairs["Ctrl-Right"], "Ctrl-Alt_R-Right")
        self.assertEqual(pairs["Ctrl-Up"], "Ctrl-Alt_R-Up")
        self.assertEqual(pairs["Ctrl-Down"], "Ctrl-Alt_R-Down")
        binds = niri_binds()
        self.assertIn("toggle-overview", binds[frozenset({"Mod", "Ctrl", "up"})])
        self.assertIn('"spaces" "prev"', binds[frozenset({"Mod", "Ctrl", "left"})])


class WordNavigation(unittest.TestCase):
    """Option A's conflict: niri sees xremap's output as real keys, so a niri
    bind on a key xremap sends an app would eat it."""

    def test_niri_binds_no_plain_ctrl_arrow(self):
        binds = niri_binds()
        for key in ("left", "right", "up", "down", "home", "end", "backspace", "delete"):
            for mods in ({"Ctrl"}, {"Ctrl", "Shift"}):
                self.assertNotIn(frozenset(mods) | {key}, binds)

    def test_nothing_xremap_sends_apps_is_a_niri_bind(self):
        binds = niri_binds()
        groups = keys.defaults()["groups"]
        checked = 0
        for g in groups:
            if g.get("section", "keymap") != "keymap":
                continue
            for action in g["remap"].values():
                for out in outputs(action):
                    mods = [m.lower() for m in out.split("-")[:-1]]
                    # Sent to niri on purpose: the WM key, Right Super, ⌘ passed through.
                    if out in FOR_NIRI or {"alt_r", "super_r", "super_l"} & set(mods):
                        continue
                    for want in as_niri(out):
                        checked += 1
                        self.assertNotIn(want, binds, f"group {g['id']}: xremap sends apps {out}, but niri binds it ({binds.get(want)})")
        self.assertGreater(checked, 100)

    def test_option_arrows_still_reach_apps(self):
        groups = {g["id"]: g for g in keys.defaults()["groups"]}
        self.assertEqual(groups["text-editing"]["remap"]["Alt-Left"], "Ctrl-Left")
        self.assertEqual(groups["text-editing"]["remap"]["Alt-Right"], "Ctrl-Right")
        # …and physical ⌥← isn't a key the parity group takes.
        self.assertNotIn("Alt-Left", groups[parity.GROUP_ID]["remap"])


if __name__ == "__main__":
    unittest.main()
