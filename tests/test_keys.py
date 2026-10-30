"""Unit tests for Loft's keyboard layer (cli/loft/keys.py): the keymap layers
(Loft's defaults → Nix seed → runtime), per-app rules, Apps to leave alone,
checking and xremap's config — all in a scratch state dir.
"""

from __future__ import annotations

import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

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


class Scratch(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="loft-keys-"))
        self.addCleanup(shutil.rmtree, self.tmp)
        self.state = self.tmp / "state"
        self.seed = self.tmp / "seed.json"
        env = mock.patch.dict(os.environ, {"LOFT_KEYMAP_SEED": str(self.seed)})
        env.start()
        self.addCleanup(env.stop)

    def write_list(self, apps):
        f = keys.config_file(self.state)
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(json.dumps({"leaveAlone": apps, "pauseShellShortcuts": True}))

    def config(self) -> dict:
        return json.loads(keys.output_file(self.state).read_text())

    def entry(self, name: str) -> dict:
        return next(e for s in keys.SECTIONS for e in self.config().get(s, []) if e["name"] == name)


class LeaveAlone(Scratch):
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

    def test_set_keeps_the_shells_keys(self):
        f = keys.config_file(self.state)
        f.parent.mkdir(parents=True)
        f.write_text(json.dumps({"leaveAlone": ["foot"], "pauseShellShortcuts": False}))
        keys.set_leave_alone(self.state, "steam", True)
        keys.set_leave_alone(self.state, "foot", False)
        self.assertEqual(json.loads(f.read_text()), {"leaveAlone": ["steam"], "pauseShellShortcuts": False})


class Defaults(Scratch):
    def test_defaults_render_and_check(self):
        cfg = keys.render(keys.resolve(self.state))
        keys.check(cfg)
        names = [e["name"] for e in cfg["keymap"]]
        self.assertEqual(names[0], "App and tab switching")
        self.assertNotIn("Symbols layer (Right Super held)", names, "off by default")
        # Class references are expanded.
        term = next(e for e in cfg["keymap"] if e["name"] == "Cmd shortcuts (terminal)")
        self.assertIn("kitty", term["application"]["only"])
        self.assertFalse(any(a.startswith("@") for e in cfg["keymap"] for v in (e.get("application") or {}).values() for a in v))
        # Loft's fields stay out of xremap's config.
        self.assertFalse(any(k in e for e in cfg["keymap"] + cfg["modmap"] for k in keys.META))

    def test_write_skips_unchanged_and_drops_the_old_base(self):
        old = keys.xremap_dir(self.state) / "base"
        old.parent.mkdir(parents=True)
        old.write_text("/nix/store/x-xremap-base.json\n")
        r = keys.write_xremap(self.state)
        self.assertTrue(r["changed"])
        self.assertFalse(old.exists())
        before = keys.output_file(self.state).stat().st_mtime_ns
        self.assertFalse(keys.write_xremap(self.state)["changed"])
        self.assertEqual(keys.output_file(self.state).stat().st_mtime_ns, before)


class Layers(Scratch):
    def test_seed_then_runtime(self):
        self.seed.write_text(json.dumps({
            "groups": {"symbols": True, "browser": False},
            "classes": {"daws": {"name": "DAWs", "apps": ["REAPER"]}},
            "apps": {"REAPER": {"off": ["cmd"], "remap": {"Super_L-s": "Ctrl-s", "Super_L-z": "Ctrl-z"}}},
            "extraGroups": [{"id": "daw", "name": "DAW keys", "application": {"only": ["@daws"]}, "remap": {"Super_L-r": "r"}}],
        }))
        keys.edit(self.state, lambda l: l.update({"groups": {"symbols": False}, "apps": {"REAPER": {"remap": {"Super_L-z": None}}}}))
        m = keys.resolve(self.state)
        on = {g["id"]: g.get("on", True) for g in m["groups"]}
        self.assertFalse(on["symbols"], "runtime wins over the seed")
        self.assertFalse(on["browser"])
        self.assertEqual(m["apps"]["REAPER"]["remap"], {"Super_L-s": "Ctrl-s"}, "null drops a seeded remap")
        self.assertEqual(m["apps"]["REAPER"]["off"], ["cmd"], "fields the runtime doesn't set stay")
        self.assertEqual(self.entry("DAW keys")["application"], {"only": ["REAPER"]})
        self.assertIn("REAPER", self.entry("Cmd shortcuts (non-terminal)")["application"]["not"])

    def test_app_like_off_and_own_remaps(self):
        def mutate(l):
            l["apps"] = {"dev.cody.term": {"like": ["terminals"]}, "com.foo.Bar": {"off": ["text-editing"], "remap": {"Super_L-k": "Ctrl-k"}}}
            l["remap"] = {"Super_L-F1": "F1"}

        keys.edit(self.state, mutate)
        km = self.config()["keymap"]
        # Per-app remaps first (xremap takes the first match), then every-app ones.
        self.assertEqual(km[0], {"name": "com.foo.Bar (loft keys app)", "application": {"only": ["com.foo.Bar"]}, "remap": {"Super_L-k": "Ctrl-k"}})
        self.assertEqual(km[1]["remap"], {"Super_L-F1": "F1"})
        self.assertIn("dev.cody.term", self.entry("Cmd shortcuts (terminal)")["application"]["only"])
        self.assertIn("dev.cody.term", self.entry("Cmd shortcuts (non-terminal)")["application"]["not"])
        self.assertIn("com.foo.Bar", self.entry("Text navigation and editing")["application"]["not"])
        v = keys.app_view(self.state, "com.foo.Bar")
        why = {g["id"]: g["why"] for g in v["groups"]}
        self.assertEqual(why["text-editing"], "off for this app")
        self.assertIsNone(why["cmd"])
        self.assertEqual(keys.app_view(self.state, "dev.cody.term")["classes"], ["terminals"])

    def test_leave_alone_beats_everything(self):
        keys.edit(self.state, lambda l: l.update({"apps": {"steam": {"remap": {"F1": "F2"}}}}))
        self.write_list(["steam"])
        keys.write_xremap(self.state)
        self.assertEqual(self.config()["keymap"][0]["application"], {"only": []})
        self.assertIn("steam", self.entry("App and tab switching")["application"]["not"])
        self.assertTrue(all(not g["applies"] for g in keys.app_view(self.state, "steam")["groups"]))

    def test_bad_edits_are_not_saved(self):
        for bad in (
            {"apps": {"x": {"remap": {"Super_L-k": "Ctrl-Bogus"}}}},
            {"apps": {"x": {"remap": {"Hyper-k": "k"}}}},
            {"apps": {"x": {"like": ["nope"]}}},
            {"apps": {"x": {"off": ["nope"]}}},
        ):
            with self.assertRaises(SystemExit):
                keys.edit(self.state, lambda l, bad=bad: l.update(bad))
            self.assertFalse(keys.runtime_file(self.state).exists())
        keys.edit(self.state, lambda l: l.update({"apps": {"x": {"remap": {"Super_L-k": ["Ctrl-k", "Esc"], "Alt_R-BTN_LEFT": "BTN_RIGHT"}}}}))

    def test_only_groups(self):
        cfg = keys.render(keys.resolve(self.state), only_groups=["dual-role"])
        self.assertEqual([e["name"] for e in cfg["modmap"]], ["Esc / Caps Lock: tap = Escape, hold = window-manager key"])
        self.assertEqual(cfg["keymap"], [])


if __name__ == "__main__":
    unittest.main()
