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
from loft.render import look, qt

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
        # gtk.css's sidebar rule (render/look.py), shared with Nautilus, and
        # the Transparency dial with it.
        def a(opacity, dark, tr=None):
            return look.gtk_glass_alpha({"glass": {"opacity": opacity}}, dark, tr)

        self.assertAlmostEqual(a(0.45, True), 0.63)
        self.assertEqual(a(0.1, False), 0.72)
        self.assertEqual(a(0.9, True), 0.88)
        self.assertEqual(a(0.45, True, {"level": 1.0}), 0.3)
        self.assertEqual(a(0.45, True, {"level": 1.0, "gtk": 0.5}), 0.5)
        self.assertEqual(qt._kde("#102030"), "16,32,48")
        self.assertEqual(qt._kde("#10203080"), "16,32,48,128")


if __name__ == "__main__":
    unittest.main()


class Global(unittest.TestCase):
    """Global mode (qtglobal.py): kdeglobals + Kvantum's theme, recorded and reverted."""

    SCHEME = (
        "[General]\nColorScheme=Loft\nName=Loft\n\n[KDE]\ncontrast=4\n\n"
        "[Colors:Window]\nBackgroundNormal=30,30,46\nForegroundNormal=205,214,244\n\n"
        "[Colors:Header][Inactive]\nBackgroundNormal=24,24,37\n\n"
        "[ColorEffects:Disabled]\nColor=30,30,46\n\n[WM]\nactiveBackground=30,30,46\n"
    )
    USER = (
        "[General]\nColorScheme=MacTahoeDark\nfixed=Inter,10\n\n"
        "[KDE]\nwidgetStyle=kvantum-dark\nSingleClick=false\n\n"
        "[Colors:Window]\nBackgroundNormal=1,2,3\nDecorationFocus=9,9,9\n"
    )

    def setUp(self):
        from loft import qtglobal

        self.g = qtglobal
        self.tmp = Path(tempfile.mkdtemp())
        self.cfg, self.data, self.state = self.tmp / "config", self.tmp / "data", self.tmp / "state"
        env = {"XDG_CONFIG_HOME": str(self.cfg), "XDG_DATA_HOME": str(self.data), "XDG_RUNTIME_DIR": str(self.tmp / "run"),
               "LOFT_QT_GLOBAL_NO_NOTIFY": "1"}
        p = mock.patch.dict(os.environ, env)
        p.start()
        self.addCleanup(p.stop)
        (self.state / "current").mkdir(parents=True)
        (self.state / "current" / "kde.colors").write_text(self.SCHEME)
        self.cfg.mkdir()
        (self.cfg / "kdeglobals").write_text(self.USER)
        (self.cfg / "Kvantum").mkdir()
        (self.cfg / "Kvantum" / "kvantum.kvconfig").write_text("[General]\ntheme=MacTahoeDark\n\n[Applications]\nLoft=dolphin\n")

    def kg(self, group, key):
        return qtapps.ini_get((self.cfg / "kdeglobals").read_text(), group, key)

    def test_apply_then_revert_restores_the_files(self):
        before_kg = (self.cfg / "kdeglobals").read_text()
        before_kv = (self.cfg / "Kvantum" / "kvantum.kvconfig").read_text()
        self.g.apply(self.state)
        self.assertEqual(self.kg("KDE", "widgetStyle"), "kvantum-dark")  # a dark scheme
        self.assertEqual(self.kg("General", "ColorScheme"), "Loft")
        self.assertEqual(self.kg("Colors:Window", "BackgroundNormal"), "30,30,46")
        self.assertEqual(self.kg("Colors:Window", "DecorationFocus"), "9,9,9")  # not in the scheme: kept
        self.assertEqual(self.kg("Colors:Header][Inactive", "BackgroundNormal"), "24,24,37")
        self.assertEqual(self.kg("WM", "activeBackground"), "30,30,46")
        self.assertIsNone(self.kg("KDE", "contrast"))  # only colour groups are copied
        self.assertEqual(self.kg("General", "fixed"), "Inter,10")
        kv = (self.cfg / "Kvantum" / "kvantum.kvconfig").read_text()
        self.assertEqual(qtapps.ini_get(kv, "General", "theme"), "Loft")
        self.assertEqual(os.readlink(self.data / "color-schemes" / "Loft.colors"), str(self.state / "current" / "kde.colors"))
        self.g.revert(self.state)
        self.assertEqual((self.cfg / "kdeglobals").read_text(), before_kg)
        self.assertEqual((self.cfg / "Kvantum" / "kvantum.kvconfig").read_text(), before_kv)
        self.assertFalse((self.state / "qt-global.prev").exists())

    def test_reapply_keeps_originals_and_a_choice_made_meanwhile_wins(self):
        self.g.apply(self.state)
        light = self.SCHEME.replace("30,30,46", "250,250,250")
        (self.state / "current" / "kde.colors").write_text(light)
        self.g.apply(self.state)  # a theme change
        self.assertEqual(self.kg("KDE", "widgetStyle"), "kvantum")
        self.assertEqual(self.kg("Colors:Window", "BackgroundNormal"), "250,250,250")
        # System Settings picks another style while Loft runs: revert keeps it.
        p = self.cfg / "kdeglobals"
        p.write_text(qtapps.ini_set(p.read_text(), "KDE", "widgetStyle", "Breeze"))
        self.g.revert(self.state)
        self.assertEqual(self.kg("KDE", "widgetStyle"), "Breeze")
        self.assertEqual(self.kg("Colors:Window", "BackgroundNormal"), "1,2,3")
        self.assertEqual(self.kg("General", "ColorScheme"), "MacTahoeDark")
        self.assertIsNone(self.kg("Colors:Header][Inactive", "BackgroundNormal"))
        self.assertNotIn("[WM]", p.read_text())

    def test_no_user_files(self):
        (self.cfg / "kdeglobals").unlink()
        (self.cfg / "Kvantum" / "kvantum.kvconfig").unlink()
        self.g.apply(self.state)
        self.g.revert(self.state)
        self.assertEqual((self.cfg / "kdeglobals").read_text(), "")
        self.assertEqual((self.cfg / "Kvantum" / "kvantum.kvconfig").read_text(), "")

    def test_switch_and_session(self):
        self.assertFalse(self.g.enabled(self.state))
        self.assertEqual(self.g.start(self.state), [])  # off: nothing applied
        self.g.set_choice(self.state, True)  # the shell runs: applies now
        self.assertEqual(self.kg("General", "ColorScheme"), "Loft")
        (self.state / "current" / "kde.colors").write_text(self.SCHEME.replace("30,30,46", "250,250,250"))
        self.g.follow_theme(self.state)
        self.assertEqual(self.kg("KDE", "widgetStyle"), "kvantum")
        self.g.stop(self.state)
        self.assertEqual(self.kg("General", "ColorScheme"), "MacTahoeDark")
        self.assertEqual(self.g.follow_theme(self.state), [])  # shell down: the hook leaves it alone
        self.assertTrue(self.g.enabled(self.state))
        self.g.start(self.state)
        self.assertEqual(self.kg("General", "ColorScheme"), "Loft")
        self.g.set_choice(self.state, False)
        self.assertEqual(self.kg("General", "ColorScheme"), "MacTahoeDark")

    def test_ini_delete(self):
        t = "[A]\na=1\n\n[B]\nx=1\n\n[C]\nc=1\n"
        self.assertEqual(self.g.ini_delete(t, "B", "x"), "[A]\na=1\n\n[C]\nc=1\n")
        self.assertEqual(self.g.ini_delete(t, "C", "c"), "[A]\na=1\n\n[B]\nx=1\n")
        self.assertEqual(self.g.ini_delete("[A]\na=1\nb=2\n", "A", "a"), "[A]\nb=2\n")
        self.assertEqual(self.g.ini_delete(t, "B", "nope"), t)
