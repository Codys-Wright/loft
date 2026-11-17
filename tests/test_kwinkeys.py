"""Loft's shortcuts in a Plasma session (cli/loft/kwinkeys.py, docs/KWIN.md §5):
niri/shell-binds.kdl.in → a KWin script of kglobalaccel shortcuts, the user's
Settings → Keyboard Shortcuts on top, and the record + revert of keys other
shortcuts hold (against a fake kglobalaccel).

The key spellings are the ones KWin 6.8 was seen to match in a nested session
(real key presses through a virtual keyboard): letters keep Shift, a shifted
digit or symbol is its symbol without Shift.
"""

from __future__ import annotations

import json
import shlex
import tempfile
import unittest
from pathlib import Path

from loft import kwinkeys

REPO = Path(__file__).resolve().parents[1]
IPC = '"/qs" "ipc" "--path" "/src" "call"'


def shell_binds() -> str:
    return (REPO / "niri" / "shell-binds.kdl.in").read_text().replace("@IPC@", IPC)


class QtKeys(unittest.TestCase):
    def test_names(self):
        cases = {
            "Mod+Shift+R": "Meta+Shift+R",
            "Super+H": "Meta+H",
            "Mod+Period": "Meta+.",
            "Mod+Comma": "Meta+,",
            "Ctrl+Shift+Escape": "Ctrl+Shift+Esc",
            "Mod+F10": "Meta+F10",
            "Mod+Ctrl+Left": "Meta+Ctrl+Left",
            "Mod+Shift+Alt+V": "Meta+Alt+Shift+V",
            "Mod+Shift+Tab": "Meta+Shift+Tab",
            "XF86MonBrightnessUp": "Monitor Brightness Up",
            "XF86LaunchA": "Launch (A)",
            "Mod+grave": "Meta+`",
            "ISO_Level3_Shift+o": "Meta+O",
        }
        for niri, qt in cases.items():
            self.assertEqual(kwinkeys.qt_keys(niri), qt, niri)

    def test_shifted_symbols_drop_shift(self):
        self.assertEqual(kwinkeys.qt_keys("Super+Shift+5"), "Meta+%")
        self.assertEqual(kwinkeys.qt_keys("Super+Shift+3"), "Meta+#")
        self.assertEqual(kwinkeys.qt_keys("Mod+Shift+Period"), "Meta+>")
        self.assertEqual(kwinkeys.qt_keys("Mod+Shift+grave"), "Meta+~")

    def test_untranslatable(self):
        self.assertIsNone(kwinkeys.qt_keys("Mod+WheelScrollDown"))
        self.assertIsNone(kwinkeys.qt_keys("Hyper+A"))


class FromShellBinds(unittest.TestCase):
    def setUp(self):
        self.actions, self.skipped = kwinkeys.build(shell_binds())
        self.by_id = {a.id: a for a in self.actions}

    def test_every_shell_bind_is_covered(self):
        """Each bind is an action, the same key as an earlier one (Super+X and
        Mod+X are both Meta+X here), or reported as skipped."""
        binds = kwinkeys.parse_binds(shell_binds())
        self.assertGreater(len(binds), 40)
        covered = {a.combo for a in self.actions}
        for b in binds:
            if b.combo in covered:
                continue
            self.assertTrue(any(s.startswith(b.combo + ":") for s in self.skipped), b.combo)
        # The recent-windows section is niri's switcher, not Loft's.
        self.assertFalse(any(b.combo == "Alt+Tab" for b in binds))

    def test_ipc_actions_run_the_command(self):
        cc = self.by_id["controlcenter-toggle"]
        self.assertEqual(cc.keys, "Meta+A")
        self.assertEqual(cc.kind, "exec")
        self.assertEqual(cc.text, "Loft: Control Center")
        self.assertEqual(cc.command, ["timeout", "-k", "1", "5", "/qs", "ipc", "--path", "/src", "call", "controlcenter", "toggle"])
        self.assertEqual(self.by_id["launcher-open"].command, ["loft-launcher", "open"])
        self.assertEqual(self.by_id["capture-toggle"].keys, "Meta+%")

    def test_quit_guard_falls_back_to_kwin(self):
        q = self.by_id["quit"]
        self.assertEqual(q.keys, "Meta+Q")
        self.assertNotIn("niri msg", " ".join(q.command))
        self.assertIn("invokeShortcut 'Window Close'", q.command[2])
        self.assertEqual(self.by_id["quit-2"].keys, "Alt+F4")

    def test_niri_actions_become_kwin_calls(self):
        self.assertEqual(self.by_id["toggle-overview"].kind, "kwin")
        self.assertIn('loftKwin("Overview")', self.by_id["toggle-overview"].js)
        self.assertIn("fullScreen", self.by_id["fullscreen-window"].js)

    def test_unique_ids_and_keys(self):
        self.assertEqual(len({a.id for a in self.actions}), len(self.actions))
        self.assertEqual(len({a.keys for a in self.actions}), len(self.actions))
        for a in self.actions:
            self.assertRegex(a.id, r"^[a-z0-9-]+$")  # a systemd instance name, a file name

    def test_space_binds(self):
        """Spaces under KWin: ⌘1…9 focus, ⌘⇧1…9 move the focused window, through
        the shell's IPC (no spaces.kdl). ⌘⇧3/4/5 stay Capture (Super = Mod here)."""
        go = self.by_id["spaces-focus-3"]
        self.assertEqual(go.keys, "Meta+3")
        self.assertEqual(go.text, "Loft: Go to Space 3")
        self.assertEqual(go.command[-3:], ["spaces", "focus", "3"])
        self.assertEqual(go.command[:9], ["timeout", "-k", "1", "5", "/qs", "ipc", "--path", "/src", "call"])
        mv = self.by_id["spaces-movewindow-1"]
        self.assertEqual(mv.keys, "Meta+!")
        self.assertEqual(mv.command[-3:], ["spaces", "moveWindow", "1"])
        self.assertNotIn("spaces-movewindow-5", self.by_id)
        self.assertEqual(self.by_id["capture-toggle"].keys, "Meta+%")
        self.assertTrue(any(s.startswith("Mod+Shift+5:") for s in self.skipped))
        # The user's changes still win: a disabled ⌘2 is gone.
        actions, _ = kwinkeys.build(shell_binds(), {"binds": {"Mod+2": {"disabled": True}}})
        self.assertNotIn("spaces-focus-2", {a.id for a in actions})

    def test_twin_without_title_is_named(self):
        """XF86LaunchA has hotkey-overlay-title=null: it takes Mod+Shift+A's."""
        self.assertEqual(self.by_id["launchpad-toggle-2"].text, "Loft: Launchpad")

    def test_written_files(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            kwinkeys.write(out, self.actions)
            js = (out / "loft-keys.js").read_text()
            self.assertEqual(js.count("registerShortcut("), len(self.actions))
            self.assertIn('registerShortcut("loft-controlcenter-toggle", "Loft: Control Center", "Meta+A"', js)
            self.assertIn('"loft-plasma-key@" + id', js)
            names = (out / "names").read_text().split()
            self.assertEqual(names, [kwinkeys.name_of(a) for a in self.actions])
            script = (out / "actions" / "controlcenter-toggle").read_text()
            self.assertEqual(shlex.split(script), ["exec", *self.by_id["controlcenter-toggle"].command])
            self.assertFalse((out / "actions" / "toggle-overview").exists())
            # A render replaces the old actions.
            kwinkeys.write(out, self.actions[:1])
            self.assertEqual(len(list((out / "actions").iterdir())), 1)


class Overrides(unittest.TestCase):
    def test_disabled_moved_custom_and_off(self):
        ov = {
            "binds": {
                "Mod+Shift+T": {"disabled": True, "moved_to": "Mod+Alt+T"},
                "Mod+Alt+T": {"action": "spawn", "args": ["timeout", "-k", "1", "5", "/qs", "ipc", "--path", "/src", "call", "themes", "open"],
                              "title": "Themes", "moved_from": "Mod+Shift+T"},
                "Mod+Ctrl+X": {"action": "spawn", "args": ["kitty"], "title": "Kitty"},
                "Mod+Ctrl+Y": {"action": "spawn", "args": ["foot"], "off": True},
                "shift+mod+m": {"disabled": True},
                "Mod+O": {"action": "focus-column-left"},
            }
        }
        actions, skipped = kwinkeys.build(shell_binds(), ov)
        by_keys = {a.keys: a for a in actions}
        self.assertNotIn("Meta+Shift+T", by_keys)
        self.assertEqual(by_keys["Meta+Alt+T"].id, "themes-open")
        self.assertEqual(by_keys["Meta+Ctrl+X"].command, ["kitty"])
        self.assertEqual(by_keys["Meta+Ctrl+X"].text, "Loft: Kitty")
        self.assertNotIn("Meta+Ctrl+Y", by_keys)
        self.assertNotIn("Meta+Shift+M", by_keys)  # mute mics: disabled (any modifier order)
        self.assertTrue(any("focus-column-left" in s for s in skipped))


class FakeBus:
    """kglobalaccel: components → rows (action, friendly, component,
    componentFriendly, context, contextFriendly, keys, defaultKeys); keys per
    action as sequences."""

    def __init__(self):
        self.seqs: dict[tuple[str, str], list[list[int]]] = {}
        self.rows: dict[str, list[list]] = {}
        self.calls: list = []

    def add(self, comp, action, keys, friendly=None, context="default"):
        self.seqs[(comp, action)] = [list(k) for k in keys]
        path = "/component/" + comp.replace(".", "_")
        self.rows.setdefault(path, []).append([action, friendly or action, comp, comp.title(), context, "Default", [], []])

    def components(self):
        return list(self.rows)

    def infos(self, path):
        out = []
        for r in self.rows[path]:
            r = list(r)
            r[6] = [k[0] for k in self.seqs[(r[2], r[0])]]
            out.append(r)
        return out

    def keys(self, aid):
        return [list(k) for k in self.seqs[(aid[0], aid[1])]]

    def set_foreign(self, aid, keys):
        self.calls.append((aid[0], aid[1], keys))
        self.seqs[(aid[0], aid[1])] = [list(k) for k in keys]


META_TAB, ALT_TAB, META_I, ALT_F4, META_A = 0x11000001, 0x8000001, 0x10000049, 0x9000033, 0x10000041


class ClaimRelease(unittest.TestCase):
    def setUp(self):
        self.bus = FakeBus()
        self.bus.add("kwin", "Walk Through Windows", [[ALT_TAB], [META_TAB]])
        self.bus.add("kwin", "Window Close", [[ALT_F4]])
        self.bus.add("systemsettings.desktop", "_launch", [[META_I], [0x10000F1]])
        self.bus.add("kwin", "Something Else", [[0x10000042]])
        self.bus.add("kwin", "loft-switcher-next", [[META_TAB]])
        self.bus.add("kwin", "loft-island-toggle", [[META_I]])
        self.bus.add("kwin", "loft-controlcenter-toggle", [[META_A]])
        self.names = {"loft-switcher-next", "loft-island-toggle", "loft-controlcenter-toggle"}
        self.tmp = tempfile.TemporaryDirectory()
        self.record = Path(self.tmp.name) / "state" / "taken.json"

    def tearDown(self):
        self.tmp.cleanup()

    def test_claim_takes_only_loft_keys_and_release_restores(self):
        before = {k: [list(s) for s in v] for k, v in self.bus.seqs.items()}
        new = kwinkeys.claim(self.bus, self.names, self.record)
        self.assertEqual({tuple(t["id"][:2]) for t in new}, {("kwin", "Walk Through Windows"), ("systemsettings.desktop", "_launch")})
        self.assertEqual(self.bus.seqs[("kwin", "Walk Through Windows")], [[ALT_TAB]])
        self.assertEqual(self.bus.seqs[("systemsettings.desktop", "_launch")], [[0x10000F1]])
        self.assertEqual(self.bus.seqs[("kwin", "Window Close")], [[ALT_F4]])  # not Loft's key here
        self.assertEqual(self.bus.seqs[("kwin", "loft-island-toggle")], [[META_I]])
        self.assertTrue(self.record.exists())
        kwinkeys.release(self.bus, self.record)
        self.assertEqual(self.bus.seqs, before)
        self.assertFalse(self.record.exists())

    def test_second_claim_keeps_the_original_keys(self):
        """A restart without a release (crash) claims again: the record keeps
        what the owner had before Loft, not the already-trimmed keys."""
        kwinkeys.claim(self.bus, self.names, self.record)
        kwinkeys.claim(self.bus, self.names, self.record)
        rec = json.loads(self.record.read_text())
        wtw = [t for t in rec if t["id"][1] == "Walk Through Windows"]
        self.assertEqual(len(wtw), 1)
        self.assertEqual(wtw[0]["keys"], [[ALT_TAB], [META_TAB]])
        kwinkeys.release(self.bus, self.record)
        self.assertEqual(self.bus.seqs[("kwin", "Walk Through Windows")], [[ALT_TAB], [META_TAB]])

    def test_release_without_record_is_a_noop(self):
        self.assertEqual(kwinkeys.release(self.bus, self.record), [])
        self.assertEqual(self.bus.calls, [])

    def test_nothing_to_take_writes_no_record(self):
        kwinkeys.claim(self.bus, {"loft-controlcenter-toggle"}, self.record)
        self.assertFalse(self.record.exists())


if __name__ == "__main__":
    unittest.main()
