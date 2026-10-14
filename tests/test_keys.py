"""Unit tests for Apps to leave alone (cli/loft/keys.py): reading the list and
turning an xremap config into one whose remaps are off in those apps — all in
a scratch state dir.
"""

from __future__ import annotations

import json
import shutil
import tempfile
import unittest
from pathlib import Path

from loft import keys

BASE = {
    "modmap": [
        {"name": "Esc hold → Mod", "remap": {"Esc": {"tap": "Esc", "hold": "Alt_R"}}},
    ],
    "keymap": [
        {"name": "Cmd shortcuts", "remap": {"Super-c": "C-c"}},
        {"name": "Terminals", "application": {"only": ["kitty", "org.gnome.Ptyxis", "foot"]}, "remap": {"Super-c": "C-Shift-c"}},
        {"name": "Not in Firefox", "application": {"not": "firefox"}, "remap": {"Super-l": "C-l"}},
        {"name": "Only regex", "application": {"only": "/^steam_app_/"}, "remap": {"F1": "F2"}},
    ],
    "virtual_modifiers": ["F20"],
}


class LeaveAlone(unittest.TestCase):
    def setUp(self):
        self.state = Path(tempfile.mkdtemp(prefix="loft-keys-"))
        self.addCleanup(shutil.rmtree, self.state)

    def write_list(self, apps):
        f = keys.config_file(self.state)
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(json.dumps({"leaveAlone": apps, "pauseShellShortcuts": True}))

    def test_list_is_cleaned(self):
        self.assertEqual(keys.leave_alone(self.state), [])
        self.write_list(["steam_app_1", " ", "foot", "foot", 3])
        self.assertEqual(keys.leave_alone(self.state), ["steam_app_1", "foot"])
        keys.config_file(self.state).write_text("not json")
        self.assertEqual(keys.leave_alone(self.state), [])

    def test_exclude(self):
        out = keys.exclude(BASE, ["foot", "virt-manager", "/regex/"])
        self.assertEqual(out["modmap"][0]["application"], {"not": ["foot", "virt-manager"]})
        km = out["keymap"]
        self.assertEqual(km[0]["application"], {"not": ["foot", "virt-manager"]})
        self.assertEqual(km[1]["application"], {"only": ["kitty", "org.gnome.Ptyxis"]})
        self.assertEqual(km[2]["application"], {"not": ["firefox", "foot", "virt-manager"]})
        self.assertEqual(km[3]["application"], {"only": ["/^steam_app_/"]})
        self.assertEqual(out["virtual_modifiers"], ["F20"])
        # The input is untouched; no apps = the same config.
        self.assertNotIn("application", BASE["keymap"][0])
        self.assertEqual(keys.exclude(BASE, []), BASE)

    def test_write_xremap_records_the_base(self):
        r = keys.write_xremap(self.state)
        self.assertIsNone(r["written"], "nothing to do before a base is recorded")
        base = self.state / "base.json"
        base.write_text(json.dumps(BASE))
        self.write_list(["foot"])
        r = keys.write_xremap(self.state, base)
        out = Path(r["written"])
        self.assertEqual(json.loads(out.read_text())["keymap"][1]["application"]["only"], ["kitty", "org.gnome.Ptyxis"])
        # Later runs (the shell, after the list changed) use the recorded base.
        self.write_list(["foot", "kitty"])
        r = keys.write_xremap(self.state)
        self.assertEqual(r["base"], str(base.resolve()))
        self.assertEqual(json.loads(out.read_text())["keymap"][1]["application"]["only"], ["org.gnome.Ptyxis"])
        # Unchanged output is not rewritten (xremap --watch=config reloads on writes).
        before = out.stat().st_mtime_ns
        keys.write_xremap(self.state)
        self.assertEqual(out.stat().st_mtime_ns, before)


if __name__ == "__main__":
    unittest.main()
