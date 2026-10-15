"""The Transparency / Blur dials (render/look.py, cli/loft/transparency.py)
and the session-scoped terminal reload hooks.

Run: PYTHONPATH=cli python3 -m unittest tests.test_transparency -v
Everything runs against scratch dirs; hooks are recorded, never run.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from loft import hooks
from loft.cli import main
from loft.facets import resolve as R
from loft.render import look

ROOT = Path(__file__).resolve().parent.parent


def loft(*argv: str) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = main(list(argv))
    return rc, out.getvalue(), err.getvalue()


MATERIAL = json.loads((ROOT / "cli" / "loft" / "facets" / "defaults" / "material.json").read_text())["data"]
MATERIAL["terminals"]["opacity"] = None
MATERIAL["glass"]["opacity"] = 0.45  # the dark side of the polar default


class Curves(unittest.TestCase):
    def test_dial_ends_and_middle(self):
        self.assertEqual(look.dial(0.9, None, 0.45), 0.9)
        self.assertEqual(look.dial(0.9, 0.5, 0.45), 0.9)
        self.assertEqual(look.dial(0.9, 0.0, 0.45), 1.0)
        self.assertEqual(look.dial(0.9, 1.0, 0.55, 1.6), 0.55)
        # The window curve eases in: halfway to Clear is still much nearer the theme.
        self.assertGreater(look.dial(0.9, 0.75, 0.55, 1.6), 0.9 - (0.9 - 0.55) / 2)
        # A theme already clearer than the floor keeps its value at Clear.
        self.assertEqual(look.dial(0.3, 1.0, 0.55), 0.3)

    def test_consumers(self):
        clear = {"level": 1.0}
        self.assertEqual(look.windows(MATERIAL, clear)["opacity"], {"focused": 0.55, "unfocused": 0.4})
        self.assertEqual(look.terminal_opacity(MATERIAL, clear), 0.3)
        self.assertEqual(look.terminal_opacity(MATERIAL, {"level": 1.0, "terminals": 0.6}), 0.6)
        self.assertEqual(look.gtk_glass_alpha(MATERIAL, True, clear), 0.3)
        self.assertEqual(look.gtk_glass_alpha(MATERIAL, True, {"level": 0.0}), 1.0)
        self.assertEqual(look.windows(MATERIAL)["opacity"], {"focused": 0.9, "unfocused": 0.8})

    def test_blur(self):
        b = look.blur(MATERIAL)
        self.assertEqual((b["on"], b["passes"], b["offset"], b["strength"]), (True, 3, 4.0, 0.5))
        self.assertEqual(look.blur(MATERIAL, {"blur": 0.5})["passes"], 3)
        self.assertEqual(look.blur(MATERIAL, {"blur": 0.5})["offset"], 4.0)
        frosted = look.blur(MATERIAL, {"blur": 1.0})
        self.assertEqual((frosted["passes"], frosted["offset"]), (4, 7.0))
        self.assertFalse(look.blur(MATERIAL, {"blur": 0.0})["on"])
        light = look.blur(MATERIAL, {"blur": 0.1})
        self.assertLess(light["noise"], MATERIAL["blur"]["noise"])
        self.assertLessEqual(light["passes"], 2)

    def test_dials_cleaned(self):
        self.assertEqual(R.dials({"level": 2, "blur": "x", "gtk": -1, "bogus": 0.3, "terminals": True}), {"level": 1.0, "gtk": 0.0})
        self.assertEqual(R.dials(None), {})


class Cli(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.saved = dict(os.environ)
        os.environ.update(
            {
                "HOME": str(self.tmp / "home"),
                "XDG_DATA_HOME": str(self.tmp / "data"),
                "XDG_STATE_HOME": str(self.tmp / "xstate"),
                "XDG_CONFIG_HOME": str(self.tmp / "config"),
                "LOFT_STATE_DIR": str(self.tmp / "state"),
                "LOFT_LIBRARY": "none",
                "LOFT_THEME_INDEX": "none",
                "LOFT_THEME_PATH": str(ROOT / "themes"),
                "LOFT_HOOKS": "all",
            }
        )
        for k in ("LOFT_DATA_DIR", "LOFT_THEME_ENGINE", "LOFT_DEV"):
            os.environ.pop(k, None)
        self.ran: list[list[str]] = []
        p = mock.patch.object(hooks, "run", lambda names, ctx: self.ran.append(list(names)))
        p.start()
        self.addCleanup(p.stop)
        rc, _, err = loft("theme", "apply", "tokyonight")
        self.assertEqual(rc, 0, err)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.saved)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def current(self, name: str) -> str:
        return (self.tmp / "state" / "current" / name).read_text()

    def test_set_reapplies_and_persists(self):
        self.ran.clear()
        rc, _, err = loft("appearance", "set", "transparency=1", "blur=0.2")
        self.assertEqual(rc, 0, err)
        st = json.loads((self.tmp / "state" / "appearance.json").read_text())
        self.assertEqual(st["transparency"], {"level": 1.0, "blur": 0.2})
        self.assertIn("background-opacity = 0.3", self.current("ghostty.conf"))
        self.assertIn("passes 2", self.current("niri.kdl"))
        t = json.loads(self.current("theme.json"))
        self.assertEqual(t["windows"]["opacity"], {"focused": 0.55, "unfocused": 0.4})
        self.assertEqual(t["transparency"]["level"], 1.0)
        self.assertEqual(t["glass"]["terminalOpacity"], 0.3)
        # Only the changed units' hooks ran (wallpapers didn't change).
        self.assertEqual(len(self.ran), 1)
        self.assertNotIn("wallpapers", self.ran[0])
        self.assertTrue({"shell", "niri", "ghostty", "kitty", "gtk"} <= set(self.ran[0]))

    def test_blur_clear_keeps_windows_translucent(self):
        rc, _, err = loft("appearance", "blur", "0")
        self.assertEqual(rc, 0, err)
        self.assertRegex(self.current("niri.kdl"), r"blur \{\n    off\n")
        t = json.loads(self.current("theme.json"))
        self.assertTrue(t["windows"]["translucent"])
        self.assertFalse(t["glass"]["blur"])
        self.assertIn("background-blur = false", self.current("ghostty.conf"))

    def test_reset_and_reduce_transparency_wins(self):
        loft("appearance", "transparency", "80%")
        rc, out, err = loft("appearance", "status", "--json")
        self.assertEqual(rc, 0, err)
        self.assertEqual(json.loads(out)["stored"], {"level": 0.8})
        loft("theme", "accessibility", "--reduce-transparency", "on")
        t = json.loads(self.current("theme.json"))
        self.assertEqual(t["glass"]["terminalOpacity"], 1.0)
        self.assertTrue(t["transparency"]["reduced"])
        loft("theme", "accessibility", "--reduce-transparency", "off")
        rc, _, err = loft("appearance", "reset")
        self.assertEqual(rc, 0, err)
        self.assertNotIn("transparency", json.loads((self.tmp / "state" / "appearance.json").read_text()))
        self.assertIn("background-opacity = 0.85", self.current("ghostty.conf"))

    def test_bad_values(self):
        self.assertEqual(loft("appearance", "transparency", "1.5")[0], 1)
        self.assertEqual(loft("appearance", "set", "bogus=1")[0], 1)


class SessionScopedSignals(unittest.TestCase):
    """Terminal reloads reach only processes on our Wayland socket."""

    def proc(self, root: Path, env: dict) -> Path:
        d = root / str(len(list(root.iterdir())) + 100)
        d.mkdir()
        (d / "environ").write_bytes(b"\0".join(f"{k}={v}".encode() for k, v in env.items()) + b"\0")
        return d

    def test_same_session(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            desktop = self.proc(root, {"WAYLAND_DISPLAY": "wayland-1", "XDG_RUNTIME_DIR": "/run/user/1000"})
            test = self.proc(root, {"WAYLAND_DISPLAY": "/run/user/1000/loft-dev-x/run/wayland-1"})
            nothing = self.proc(root, {})
            mine = hooks._wayland_socket({"WAYLAND_DISPLAY": "wayland-1", "XDG_RUNTIME_DIR": "/run/user/1000/loft-dev-x/run"})
            self.assertFalse(hooks._same_session(desktop, mine))
            self.assertTrue(hooks._same_session(test, mine))
            self.assertFalse(hooks._same_session(nothing, mine))
            self.assertTrue(hooks._same_session(desktop, hooks._wayland_socket({"WAYLAND_DISPLAY": "wayland-1", "XDG_RUNTIME_DIR": "/run/user/1000"})))
            # No session to scope to (a tty): as before, everything.
            self.assertTrue(hooks._same_session(desktop, ""))

    def test_test_session_defaults(self):
        with mock.patch.dict(os.environ, {"LOFT_DEV": "1"}):
            self.assertEqual(hooks.selected(None, dev=False), list(hooks.DEV))
            self.assertNotIn("gtk", hooks.selected(None, dev=False))


if __name__ == "__main__":
    unittest.main()
