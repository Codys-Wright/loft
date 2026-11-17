"""Loft's shortcuts in a Plasma session (cli/loft/kwinkeys.py, docs/KWIN.md §5):
niri/shell-binds.kdl.in → a KWin script of kglobalaccel shortcuts, the user's
Settings → Keyboard Shortcuts on top, and the record + revert of keys other
shortcuts hold (against a fake kglobalaccel).

The key spellings are the ones KWin 6.8 was seen to match in a nested session
(real key presses through a virtual keyboard): letters keep Shift, a shifted
digit or symbol is its symbol without Shift.
"""

from __future__ import annotations

import contextlib
import io
import json
import re
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

    def test_spotlight_keys_skip_the_unit(self):
        # docs/KWIN.md §4.22: loft-kwin's dev.loft.Launcher, the unit as the fallback.
        js = kwinkeys.render_js(self.actions)
        self.assertIn('"Meta+Space", function () { loftLauncher("launcher-open", "open"); });', js)
        emoji = next(a for a in self.actions if a.command == ["loft-launcher", "emoji"])
        self.assertEqual(kwinkeys.launcher_mode(emoji), "emoji")
        self.assertIn(f'loftLauncher("{emoji.id}", "emoji");', js)
        self.assertIn('"NameHasOwner", "dev.loft.Launcher"', js)
        self.assertIn("if (!ok) loftRun(id);", js)
        # The action file stays, for the fallback.
        with tempfile.TemporaryDirectory() as d:
            kwinkeys.write(Path(d), self.actions)
            self.assertEqual((Path(d) / "actions" / "launcher-open").read_text(), "exec loft-launcher open\n")

    def test_launcher_mode(self):
        A = kwinkeys.Action
        self.assertEqual(kwinkeys.launcher_mode(A("x", "Meta+X", "t", "exec", ["/nix/bin/loft-launcher"])), "open")
        self.assertEqual(kwinkeys.launcher_mode(A("x", "Meta+X", "t", "exec", ["loft-launcher", "help"])), "help")
        self.assertIsNone(kwinkeys.launcher_mode(A("x", "Meta+X", "t", "exec", ["loft-launcher", "service"])))
        self.assertIsNone(kwinkeys.launcher_mode(A("x", "Meta+X", "t", "exec", ["loft-launcher", "open", "x"])))
        self.assertIsNone(kwinkeys.launcher_mode(A("x", "Meta+X", "t", "exec", ["walker"])))
        self.assertIsNone(kwinkeys.launcher_mode(A("x", "Meta+X", "t", "kwin", js="f();")))

    def test_launcher_modes_are_loft_launchers(self):
        sh = (REPO / "launcher" / "loft-launcher.sh").read_text()
        for mode in kwinkeys.LAUNCHER_MODES:
            self.assertIn(f"\n  {mode})\n", sh)

    def test_quit_guard_falls_back_to_kwin(self):
        q = self.by_id["quit"]
        self.assertEqual(q.keys, "Meta+Q")
        self.assertNotIn("niri msg", " ".join(q.command))
        self.assertIn("invokeShortcut 'Window Close'", q.command[2])
        self.assertEqual(self.by_id["quit-2"].keys, "Alt+F4")

    def test_held_keys_keep_niris_repeat_and_cooldown(self):
        # KWin repeats a held shortcut and runs the callback each time.
        self.assertEqual(self.by_id["quit"].cooldown_ms, 100)
        self.assertTrue(self.by_id["controlcenter-toggle"].repeat)
        self.assertEqual(self.by_id["controlcenter-toggle"].cooldown_ms, 0)
        js = kwinkeys.render_js(self.actions)
        self.assertIn('"Meta+Q", function () { if (loftCooldown("quit", 100)) { loftRun("quit"); } });', js)
        self.assertIn('"Meta+A", function () { loftRun("controlcenter-toggle"); });', js)

    def test_override_props_carry_repeat(self):
        ov = {"binds": {"Mod+Ctrl+R": {"action": "spawn", "args": ["x"], "props": {"repeat": False}},
                        "Mod+Ctrl+C": {"action": "spawn", "args": ["y"], "props": {"cooldown-ms": 300}}}}
        actions, _ = kwinkeys.build(shell_binds(), ov)
        by_keys = {a.keys: a for a in actions}
        self.assertFalse(by_keys["Meta+Ctrl+R"].repeat)
        rid = by_keys["Meta+Ctrl+R"].id
        self.assertIn(f'"Meta+Ctrl+R", function () {{ if (loftOnce("{rid}")) {{ loftRun("{rid}"); }} }});', kwinkeys.render_js(actions))
        self.assertEqual(by_keys["Meta+Ctrl+C"].cooldown_ms, 300)

    def test_niri_actions_become_kwin_calls(self):
        self.assertEqual(self.by_id["toggle-overview"].kind, "kwin")
        self.assertIn('loftKwin("Overview")', self.by_id["toggle-overview"].js)
        self.assertEqual(self.by_id["fullscreen-window"].js, "loftFullscreen();")
        self.assertIn("w.fullScreen = !w.fullScreen", kwinkeys.render_js(self.actions))

    def test_unique_ids_and_keys(self):
        self.assertEqual(len({a.id for a in self.actions}), len(self.actions))
        self.assertEqual(len({a.keys for a in self.actions}), len(self.actions))
        for a in self.actions:
            self.assertRegex(a.id, r"^[a-z0-9-]+$")  # a systemd instance name, a file name

    def test_space_binds(self):
        """Spaces under KWin are KDE's Activities: ⌘1…9 stay KDE's "Switch to
        activity" keys (Loft binds none), ⌘⇧1…9, 0 move the focused window
        through the shell's IPC. ⌘⇧3/4/5 stay Capture (Super = Mod here)."""
        self.assertFalse(any(a.id.startswith("spaces-focus-") for a in self.actions))
        self.assertFalse(any(a.keys in {f"Meta+{n}" for n in range(10)} for a in self.actions))
        mv = self.by_id["spaces-movewindow-1"]
        self.assertEqual(mv.keys, "Meta+!")
        self.assertEqual(mv.command[-3:], ["spaces", "moveWindow", "1"])
        self.assertEqual(mv.command[:9], ["timeout", "-k", "1", "5", "/qs", "ipc", "--path", "/src", "call"])
        self.assertEqual(self.by_id["spaces-movewindow-0"].keys, "Meta+)")
        self.assertNotIn("spaces-movewindow-5", self.by_id)
        self.assertEqual(self.by_id["capture-toggle"].keys, "Meta+%")
        self.assertTrue(any(s.startswith("Mod+Shift+5:") for s in self.skipped))
        # The user's changes still win: a disabled ⌘⇧2 is gone.
        actions, _ = kwinkeys.build(shell_binds(), {"binds": {"Mod+Shift+2": {"disabled": True}}})
        self.assertNotIn("spaces-movewindow-2", {a.id for a in actions})

    def test_ctrl_arrows_are_kdes_desktops(self):
        """⌃←/→ (Meta+Ctrl+←/→ through the keyboard layer) are KWin's own
        Switch One Desktop to the Left/Right here: Loft doesn't bind them."""
        self.assertNotIn("Meta+Ctrl+Left", {a.keys for a in self.actions})
        self.assertNotIn("Meta+Ctrl+Right", {a.keys for a in self.actions})
        self.assertFalse(any((a.command or [])[-2:] in (["spaces", "prev"], ["spaces", "next"]) for a in self.actions))
        # ⌃↑ (Mission Control) is still Loft's.
        self.assertIn("Meta+Ctrl+Up", {a.keys for a in self.actions})

    def test_window_focus_and_move_like_niri(self):
        """Caps (Meta here) + H/J/K/L and arrows focus, + Shift + H/J/K/L move,
        as niri/base.kdl binds them; each a KWin workspace slot."""
        by_keys = {a.keys: a for a in self.actions}
        want = {
            "Meta+H": "slotSwitchWindowLeft", "Meta+L": "slotSwitchWindowRight",
            "Meta+J": "slotSwitchWindowDown", "Meta+K": "slotSwitchWindowUp",
            "Meta+Left": "slotSwitchWindowLeft", "Meta+Right": "slotSwitchWindowRight",
            "Meta+Down": "slotSwitchWindowDown", "Meta+Up": "slotSwitchWindowUp",
            "Meta+Shift+H": "slotWindowQuickTileLeft", "Meta+Shift+L": "slotWindowQuickTileRight",
            "Meta+Shift+J": "slotWindowQuickTileBottom", "Meta+Shift+K": "slotWindowQuickTileTop",
        }
        for keys, slot in want.items():
            self.assertEqual(by_keys[keys].kind, "kwin", keys)
            self.assertEqual(by_keys[keys].js, f"workspace.{slot}();", keys)
        self.assertEqual(by_keys["Meta+H"].text, "Loft: Focus Window Left")
        # niri's own arrows-with-Shift aren't bound: KDE keeps Meta+Shift+←/→ (window to screen).
        self.assertNotIn("Meta+Shift+Left", by_keys)
        # A disabled Mod+L (Settings → Keyboard Shortcuts) leaves Meta+L to KDE.
        actions, _ = kwinkeys.build(shell_binds(), {"binds": {"Mod+L": {"disabled": True}}})
        self.assertNotIn("Meta+L", {a.keys for a in actions})

    def test_window_binds_are_base_kdls(self):
        """WINDOW_BINDS is niri/base.kdl's window binds, one for one, but for
        the ones that stay unbound under KWin (Mod+V: every window floats)."""
        base = kwinkeys.parse_binds((REPO / "niri" / "base.kdl").read_text())
        # (Mod+1…5 and Mod+Shift+1…5 are Spaces: KDE's Activities, space_binds.)
        niri = {(b.combo, b.action) for b in base
                if "workspace" not in b.action or b.action.startswith(("focus-window-or", "move-window-down-or", "move-window-up-or"))}
        niri -= {(c, a) for c, a in niri if a in ("spawn", "close-window", "quit", "show-hotkey-overlay", "toggle-overview")}
        self.assertEqual({(c, a) for c, a in niri if a not in kwinkeys.WINDOW_UNBOUND}, set(kwinkeys.WINDOW_BINDS))
        self.assertIn(("Mod+V", "toggle-window-floating"), niri)
        self.assertTrue(all(a in kwinkeys.WINDOW_ACTIONS for _, a in kwinkeys.WINDOW_BINDS))

    def test_window_size_keys_like_niri(self):
        """Mod+F maximize, Mod+Shift+F fullscreen, Mod+C center, Mod+W next
        preset width; Mod+V stays KDE's; shell-binds' Mod+Ctrl+F still
        fullscreen."""
        by_keys = {a.keys: a for a in self.actions}
        self.assertEqual(by_keys["Meta+F"].js, "workspace.slotWindowMaximize();")
        self.assertEqual(by_keys["Meta+Shift+F"].js, "loftFullscreen();")
        self.assertEqual(by_keys["Meta+Ctrl+F"].js, "loftFullscreen();")
        self.assertEqual(by_keys["Meta+Ctrl+F"].text, "Loft: Full Screen")
        self.assertEqual(by_keys["Meta+Shift+F"].text, "Loft: Full Screen")
        self.assertEqual(by_keys["Meta+C"].js, "loftCenter();")
        self.assertEqual(by_keys["Meta+W"].js, "loftPresetWidth();")
        self.assertNotIn("Meta+V", by_keys)
        # Mod+Shift+W is still the shell's Wallpapers.
        self.assertEqual(by_keys["Meta+Shift+W"].kind, "exec")
        js = kwinkeys.render_js(self.actions)
        for fn in ("loftFullscreen", "loftCenter", "loftPresetWidth"):
            self.assertIn(f"function {fn}(", js)
        self.assertIn("var LOFT_PRESETS = [0.33333, 0.5, 0.66667];", js)

    def test_presets_follow_niri(self):
        """Mod+W's widths are base.kdl's preset-column-widths, or the user's."""
        text = (REPO / "niri" / "base.kdl").read_text()
        block = text[text.index("preset-column-widths {"):]
        block = block[:block.index("}")]
        self.assertEqual([float(x) for x in re.findall(r"proportion ([0-9.]+)", block)], kwinkeys.DEFAULT_PRESETS)
        self.assertEqual(kwinkeys.presets_of(None), kwinkeys.DEFAULT_PRESETS)
        ov = {"layout": {"preset-column-widths": [0.25, 0.5, {"fixed": 1200}, "x", 2, True]}}
        self.assertEqual(kwinkeys.presets_of(ov), [0.25, 0.5, {"fixed": 1200}])
        self.assertIn('var LOFT_PRESETS = [0.25, 0.5, {"fixed": 1200}];',
                      kwinkeys.render_js(self.actions, kwinkeys.presets_of(ov)))

    def test_hide_moves_off_meta_h(self):
        """⌘H / ⌘M (niri's Super+H / Super+M) would be Meta+H / Meta+M here,
        and Meta+H is focus left: they take their parity.json `kdeKeys`."""
        self.assertEqual(self.by_id["appmenu-hide"].keys, "Meta+Ctrl+Alt+H")
        self.assertEqual(self.by_id["appmenu-minimize"].keys, "Meta+Ctrl+Alt+M")
        self.assertEqual(self.by_id["appmenu-hide"].command[-2:], ["appmenu", "hide"])

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
                "Mod+O": {"action": "toggle-window-floating"},
                "Mod+Ctrl+H": {"action": "focus-column-left"},
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
        self.assertTrue(any("toggle-window-floating" in s for s in skipped))
        # A niri window action KWin has works from a custom shortcut too.
        self.assertIn("slotSwitchWindowLeft", by_keys["Meta+Ctrl+H"].js)


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
META_1 = 0x10000031


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

    def test_never_takes_kdes_activity_keys(self):
        """Even if Loft binds a key "Switch to activity" has, KDE keeps it."""
        self.bus.add("ActivityManager", "switch-to-activity-abc", [[META_1]], friendly='Switch to activity "Default"')
        self.bus.add("kwin", "loft-custom", [[META_1]])
        kwinkeys.claim(self.bus, self.names | {"loft-custom"}, self.record)
        self.assertEqual(self.bus.seqs[("ActivityManager", "switch-to-activity-abc")], [[META_1]])
        rec = json.loads(self.record.read_text())
        self.assertFalse(any(t["id"][0] == "ActivityManager" for t in rec))

    def test_activity_keys_taken_before_are_given_back(self):
        """The user's record from an older Loft lists six ActivityManager
        entries: the next claim gives them back and doesn't take them again;
        the other entries stay recorded."""
        acts = [(f"switch-to-activity-{n}", 0x10000030 + n) for n in range(1, 7)]
        for action, _ in acts:
            self.bus.add("ActivityManager", action, [])  # taken: no key now
        old = [{"id": ["ActivityManager", a, "Activity Manager", f"Switch to activity {a}"], "keys": [[k]]} for a, k in acts]
        old.append({"id": ["kwin", "Walk Through Windows", "KWin", "Walk Through Windows"], "keys": [[ALT_TAB], [META_TAB]]})
        self.record.parent.mkdir(parents=True)
        self.record.write_text(json.dumps(old))
        self.bus.seqs[("kwin", "Walk Through Windows")] = [[ALT_TAB]]
        kwinkeys.claim(self.bus, self.names, self.record)
        for action, k in acts:
            self.assertEqual(self.bus.seqs[("ActivityManager", action)], [[k]])
        rec = json.loads(self.record.read_text())
        self.assertNotIn("ActivityManager", [t["id"][0] for t in rec])
        self.assertEqual([t for t in rec if t["id"][1] == "Walk Through Windows"][0]["keys"], [[ALT_TAB], [META_TAB]])
        # And a second claim (Loft restarted) leaves them alone.
        kwinkeys.claim(self.bus, self.names, self.record)
        self.assertEqual(self.bus.seqs[("ActivityManager", "switch-to-activity-1")], [[0x10000031]])

    def test_move_to_space_yields_to_a_kde_key(self):
        """⌘⇧N (move to Space N) gives its key up when KDE binds it to
        something else, instead of taking it."""
        meta_excl = 0x10000021  # Meta+!
        self.bus.add("kwin", "Window to Desktop 1", [[meta_excl]])
        self.bus.add("kwin", "loft-spaces-movewindow-1", [[meta_excl]])
        self.bus.add("kwin", "loft-spaces-movewindow-2", [[0x10000040]])  # Meta+@: free
        names = self.names | {"loft-spaces-movewindow-1", "loft-spaces-movewindow-2"}
        with contextlib.redirect_stdout(io.StringIO()):
            kwinkeys.claim(self.bus, names, self.record)
        self.assertEqual(self.bus.seqs[("kwin", "Window to Desktop 1")], [[meta_excl]])
        self.assertEqual(self.bus.seqs[("kwin", "loft-spaces-movewindow-1")], [])
        self.assertEqual(self.bus.seqs[("kwin", "loft-spaces-movewindow-2")], [[0x10000040]])


if __name__ == "__main__":
    unittest.main()


ALT_F3, META_F3 = 0x8000032, 0x10000032


class WindowMenu(unittest.TestCase):
    """KWin's Window Operations Menu (Alt+F3) opens Loft's window menu."""

    def setUp(self):
        self.bus = FakeBus()
        self.tmp = tempfile.TemporaryDirectory()
        self.record = Path(self.tmp.name) / "taken.json"
        self.names = {"loft-window-menu"}

    def tearDown(self):
        self.tmp.cleanup()

    def test_rendered_with_fallback(self):
        actions, _ = kwinkeys.build(shell_binds())
        wm = next(a for a in actions if a.id == "window-menu")
        self.assertEqual((wm.keys, wm.kind), ("Alt+F3", "kwin"))
        js = kwinkeys.render_js(actions)
        self.assertIn('registerShortcut("loft-window-menu", "Loft: Window Menu", "Alt+F3", function () { loftWindowMenu(); });', js)
        self.assertIn('JSON.stringify({ cmd: "windowMenu" })', js)
        self.assertIn("workspace.slotWindowOperations();", js)

    def test_a_user_bind_on_alt_f3_wins(self):
        ov = {"binds": {"Alt+F3": {"action": "spawn", "args": ["foot"]}}}
        actions, _ = kwinkeys.build(shell_binds(), ov)
        self.assertFalse(any(a.id == "window-menu" for a in actions))

    def test_claim_takes_alt_f3_and_release_gives_it_back(self):
        self.bus.add("kwin", "Window Operations Menu", [[ALT_F3]])
        self.bus.add("kwin", "loft-window-menu", [[ALT_F3]])
        kwinkeys.claim(self.bus, self.names, self.record)
        self.assertEqual(self.bus.seqs[("kwin", "Window Operations Menu")], [])
        kwinkeys.release(self.bus, self.record)
        self.assertEqual(self.bus.seqs[("kwin", "Window Operations Menu")], [[ALT_F3]])

    def test_follows_a_moved_window_operations_key(self):
        self.bus.add("kwin", "Window Operations Menu", [[META_F3]])
        self.bus.add("kwin", "loft-window-menu", [[ALT_F3]])
        kwinkeys.claim(self.bus, self.names, self.record)
        self.assertEqual(self.bus.seqs[("kwin", "loft-window-menu")], [[META_F3]])
        self.assertEqual(self.bus.seqs[("kwin", "Window Operations Menu")], [])
        # A second claim (restart without release) still knows the original key.
        self.bus.seqs[("kwin", "loft-window-menu")] = [[ALT_F3]]  # re-registered from the script
        kwinkeys.claim(self.bus, self.names, self.record)
        self.assertEqual(self.bus.seqs[("kwin", "loft-window-menu")], [[META_F3]])
        kwinkeys.release(self.bus, self.record)
        self.assertEqual(self.bus.seqs[("kwin", "Window Operations Menu")], [[META_F3]])
