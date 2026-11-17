"""Loft's idle settings in KDE's kscreenlockerrc / powerdevilrc (cli/loft/kdeidle.py)."""

from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from loft import kdeidle


class Idle(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.cfg = self.tmp / "config"
        self.state = self.tmp / "state"
        self.cfg.mkdir()
        p = mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": str(self.cfg), "LOFT_IDLE_NO_NOTIFY": "1"})
        p.start()
        self.addCleanup(p.stop)

    def file(self, name: str) -> Path:
        return self.cfg / name

    def test_layers(self):
        self.assertEqual(kdeidle.settings(self.state), kdeidle.DEFAULTS)
        (self.cfg / "loft").mkdir()
        (self.cfg / "loft" / "idle.json").write_text(json.dumps({"lockAfter": 120, "screenOffAfter": None}))
        s = kdeidle.settings(self.state)
        self.assertEqual((s["lockAfter"], s["screenOffAfter"]), (120, 0))
        # Settings' -1 = not set here; the shell's own values win.
        (self.state / "overrides").mkdir(parents=True)
        (self.state / "overrides" / "shell.json").write_text(json.dumps({"idle": {"lockAfter": -1, "screenOffAfter": 900}}))
        s = kdeidle.settings(self.state)
        self.assertEqual((s["lockAfter"], s["screenOffAfter"]), (120, 900))
        s = kdeidle.settings(self.state, {"lockAfter": 30, "suspendAfter": 0, "lockOnResume": False, "lockGrace": -1})
        self.assertEqual((s["lockAfter"], s["suspendAfter"], s["lockOnResume"], s["lockGrace"]), (30, 0, False, 5))

    def test_wanted(self):
        w = kdeidle.wanted({"lockAfter": 30, "screenOffAfter": 0, "suspendAfter": 1800, "lockOnResume": True, "lockGrace": 0})
        lock = {(g, k): v for g, k, v in w["kscreenlockerrc"]}
        self.assertEqual(lock[("Daemon", "Timeout")], "0.5")
        self.assertEqual(lock[("Daemon", "Autolock")], "true")
        self.assertEqual(lock[("Daemon", "LockGrace")], "0")
        power = {(g, k): v for g, k, v in w["powerdevilrc"]}
        for p in kdeidle.PROFILES:
            self.assertEqual(power[(f"{p}][Display", "TurnOffDisplayWhenIdle")], "false")
            self.assertNotIn((f"{p}][Display", "TurnOffDisplayIdleTimeoutSec"), power)
            self.assertEqual(power[(f"{p}][SuspendAndShutdown", "AutoSuspendAction")], "1")
            self.assertEqual(power[(f"{p}][SuspendAndShutdown", "AutoSuspendIdleTimeoutSec")], "1800")
        never = kdeidle.wanted(dict(kdeidle.DEFAULTS, lockAfter=0))
        self.assertNotIn(("Daemon", "Timeout", "5"), never["kscreenlockerrc"])
        self.assertIn(("Daemon", "Autolock", "false"), never["kscreenlockerrc"])

    def test_apply_and_revert(self):
        lock_before = "[Daemon]\nTimeout=15\nLockGrace=30\n\n[Greeter]\nTheme=x\n"
        power_before = "[AC][Display]\nTurnOffDisplayIdleTimeoutSec=1200\n\n[General]\nkeep=1\n"
        self.file("kscreenlockerrc").write_text(lock_before)
        self.file("powerdevilrc").write_text(power_before)
        kdeidle.apply(self.state, {"lockAfter": 60, "screenOffAfter": 120, "suspendAfter": 0})
        st = kdeidle.status(self.state, {"lockAfter": 60, "screenOffAfter": 120, "suspendAfter": 0})
        self.assertTrue(st["matches"], st)
        self.assertTrue(st["applied"])
        self.assertEqual(st["kde"]["lockAfter"], 60)
        self.assertIn("[LowBattery][SuspendAndShutdown]\nAutoSuspendAction=0", self.file("powerdevilrc").read_text())
        # A second apply keeps the first record's originals.
        kdeidle.apply(self.state, {"lockAfter": 90})
        self.assertEqual(kdeidle.kde_values()["lockAfter"], 90)
        rec = kdeidle.read_record(self.state)
        self.assertEqual(rec["kscreenlockerrc"]["Daemon\x1fTimeout"], {"prev": "15", "ours": "1.5"})
        kdeidle.revert(self.state)
        self.assertEqual(self.file("kscreenlockerrc").read_text(), lock_before)
        self.assertEqual(self.file("powerdevilrc").read_text(), power_before)
        self.assertEqual(kdeidle.read_record(self.state), {})

    def test_revert_keeps_a_change_made_meanwhile(self):
        kdeidle.apply(self.state)
        text = self.file("kscreenlockerrc").read_text().replace("Timeout=5", "Timeout=20")
        self.file("kscreenlockerrc").write_text(text)
        kdeidle.revert(self.state)
        after = self.file("kscreenlockerrc").read_text()
        self.assertIn("Timeout=20", after)
        self.assertNotIn("LockGrace", after)
        self.assertFalse(self.file("powerdevilrc").read_text().strip())

    def test_revert_without_record(self):
        self.assertEqual(kdeidle.revert(self.state), [])
        self.assertFalse(self.file("kscreenlockerrc").exists())


if __name__ == "__main__":
    unittest.main()
