"""Unit `qt` (Kvantum theme + KDE color scheme) and the `qt` hook (qtapps.py)."""

from __future__ import annotations

import json
import os
import re
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
from unittest import mock

from loft import qtapps
from loft.render import qt

ROOT = Path(__file__).resolve().parents[1]
GOLDEN = ROOT / "tests" / "golden" / "tokyonight"


class Ini(unittest.TestCase):
    def test_set_keeps_everything_else(self):
        text = "# c\n[General]\nVersion=202\n\n[KFileDialog Settings]\nA=1\n"
        out = qtapps.ini_set(text, "General", "Version", "203")
        self.assertEqual(out, "# c\n[General]\nVersion=203\n\n[KFileDialog Settings]\nA=1\n")
        out = qtapps.ini_set(text, "General", "LockPanels", "true")
        self.assertEqual(out, "# c\n[General]\nVersion=202\nLockPanels=true\n\n[KFileDialog Settings]\nA=1\n")
        out = qtapps.ini_set(text, "MainWindow][Toolbar mainToolBar", "ToolButtonStyle", "IconOnly")
        self.assertTrue(out.endswith("A=1\n\n[MainWindow][Toolbar mainToolBar]\nToolButtonStyle=IconOnly\n"))
        self.assertEqual(qtapps.ini_get(out, "MainWindow][Toolbar mainToolBar", "ToolButtonStyle"), "IconOnly")
        self.assertEqual(qtapps.ini_set("", "KDE", "widgetStyle", "kvantum"), "[KDE]\nwidgetStyle=kvantum\n")


class Sync(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.cfg, self.data, self.state = self.tmp / "config", self.tmp / "data", self.tmp / "state"
        env = {"XDG_CONFIG_HOME": str(self.cfg), "XDG_DATA_HOME": str(self.data), "XDG_CONFIG_DIRS": str(self.tmp / "etc")}
        p = mock.patch.dict(os.environ, env)
        p.start()
        self.addCleanup(p.stop)

    def test_off_without_settings(self):
        self.assertEqual(qtapps.sync(self.state), [])
        self.assertFalse(self.cfg.exists())

    def test_links_and_targeted_keys(self):
        (self.cfg / "loft").mkdir(parents=True)
        (self.cfg / "loft" / "qt.json").write_text(json.dumps({"apps": ["dolphin"], "iconTheme": "MacTahoe-blue"}))
        (self.cfg / "dolphinrc").write_text("[General]\nVersion=202\n\n[PlacesPanel]\nIconSize=22\n")
        # A system-wide Kvantum theme choice is carried over into the new user file.
        (self.tmp / "etc" / "Kvantum").mkdir(parents=True)
        (self.tmp / "etc" / "Kvantum" / "kvantum.kvconfig").write_text("[General]\ntheme=KvArcDark\n")
        qtapps.sync(self.state)

        link = self.cfg / "Kvantum" / "Loft" / "Loft.kvconfig"
        self.assertEqual(os.readlink(link), str(self.state / "current" / "kvantum.kvconfig"))
        self.assertEqual(os.readlink(self.data / "color-schemes" / "Loft.colors"), str(self.state / "current" / "kde.colors"))
        chooser = (self.cfg / "Kvantum" / "kvantum.kvconfig").read_text()
        self.assertEqual(qtapps.ini_get(chooser, "General", "theme"), "KvArcDark")
        self.assertEqual(qtapps.ini_get(chooser, "Applications", "Loft"), "dolphin")

        rc = (self.cfg / "dolphinrc").read_text()
        self.assertEqual(qtapps.ini_get(rc, "KDE", "widgetStyle"), "kvantum")
        self.assertEqual(qtapps.ini_get(rc, "UiSettings", "ColorScheme"), "Loft")
        self.assertEqual(qtapps.ini_get(rc, "Icons", "Theme"), "MacTahoe-blue")
        self.assertEqual(qtapps.ini_get(rc, "PlacesPanel", "IconSize"), "22")  # the user's choice wins over the default
        self.assertEqual(qtapps.ini_get(rc, "General", "Version"), "202")

        # Idempotent; a real file where a link would go is left alone.
        self.assertEqual(qtapps.sync(self.state), [])
        (self.data / "color-schemes" / "Loft.colors").unlink()
        (self.data / "color-schemes" / "Loft.colors").write_text("mine")
        self.assertTrue(any("left" in n for n in qtapps.sync(self.state)))


class Render(unittest.TestCase):
    def test_golden_svg_has_every_referenced_element(self):
        root = ET.fromstring((GOLDEN / "kvantum.svg").read_text())
        ids = {e.get("id") for e in root.iter() if e.get("id")}
        conf = (GOLDEN / "kvantum.kvconfig").read_text()
        frames = set(re.findall(r"^(?:frame|interior)\.element=(\S+)", conf, re.M))
        for el in frames:  # nothing falls back to Kvantum's built-in default theme
            self.assertTrue(any(i.startswith(f"{el}-") for i in ids), el)
        for el in ("button", "lineedit", "itemview-toggled", "menu-normal", "scrollbarslider-normal"):
            for part in ("", "-topleft", "-top", "-right", "-bottomright"):
                if not el.endswith(("-normal", "-toggled")):
                    continue
                self.assertIn(el + part, ids)
        for el in ("window-normal", "itemview-toggled", "itemview-toggled-inactive", "menu-normal", "checkbox-checked-normal", "arrow-down-normal"):
            self.assertIn(el, ids)

    def test_glass_alpha(self):
        self.assertAlmostEqual(qt.glass_alpha(0.45, True), 0.63)
        self.assertEqual(qt.glass_alpha(0.1, False), 0.72)
        self.assertEqual(qt.glass_alpha(0.9, True), 0.88)
        self.assertEqual(qt._kde("#102030"), "16,32,48")
        self.assertEqual(qt._kde("#10203080"), "16,32,48,128")


if __name__ == "__main__":
    unittest.main()
