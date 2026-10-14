"""Unit tests for the Loft CLI / theme engine.

Run: PYTHONPATH=cli python3 -m unittest discover -s tests -v
(the Nix check `theme-unit` does this with jsonschema available).
Everything runs against scratch dirs with reload hooks disabled.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from loft import color, hooks
from loft.cli import main
from loft.pack import Pack, PackError, derive_ansi

ROOT = Path(__file__).resolve().parent.parent
THEMES = ROOT / "themes"
FIXTURE = ROOT / "tests" / "fixtures" / "glassless"

try:
    import jsonschema  # noqa: F401

    HAVE_JSONSCHEMA = True
except ImportError:
    HAVE_JSONSCHEMA = False


def copy_pack(src: Path, dest: Path) -> None:
    """copytree + u+w: in the Nix check the sources are read-only store paths."""
    shutil.copytree(src, dest)
    for q in [dest, *dest.rglob("*")]:
        q.chmod(q.stat().st_mode | 0o200)


def loft(*argv: str) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = main(list(argv))
    return rc, out.getvalue(), err.getvalue()


class Color(unittest.TestCase):
    def test_hex(self):
        self.assertEqual(color.hex6("#FFAA00"), "#ffaa00")
        self.assertEqual(color.with_alpha("#7aa2f7", 0.8), "#7aa2f7cc")
        self.assertEqual(color.rgba("#ffffff", 0.14), "rgba(255, 255, 255, 0.14)")
        with self.assertRaises(ValueError):
            color.parse("#fff")

    def test_mix_and_contrast(self):
        self.assertEqual(color.mix("#000000", "#ffffff", 0.5), "#808080")
        self.assertEqual(color.readable_on("#ffffff", "#111111", "#eeeeee"), "#111111")
        self.assertEqual(color.num(0.45), "0.45")
        self.assertEqual(color.num(14), "14")

    def test_ansi(self):
        pal = json.loads((THEMES / "tokyonight" / "theme.json").read_text())["palette"]
        ansi = derive_ansi(pal, dark=True)
        self.assertEqual(len(ansi), 16)
        self.assertEqual(ansi[1], pal["urgent"])
        self.assertEqual(ansi[4], pal["accent"])
        self.assertEqual(ansi[15], pal["text"])


class Render(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def test_glassless_fixture(self):
        rc, _, err = loft("theme", "render", str(FIXTURE), str(self.tmp))
        self.assertEqual(rc, 0, err)
        theme = json.loads((self.tmp / "theme.json").read_text())
        self.assertEqual(theme["name"], "glassless")
        self.assertEqual(theme["palette"]["bg"], "#ffffff")  # normalized case
        self.assertEqual(theme["glass"]["terminalOpacity"], 1.0)  # no blur → opaque
        self.assertEqual(theme["wallpaper"]["image"], "wallpaper.png")
        self.assertTrue((self.tmp / "wallpaper.png").is_file())
        niri = (self.tmp / "niri.kdl").read_text()
        self.assertIn("\n    off\n", niri)
        self.assertIn("xray false", niri)
        self.assertIn("geometry-corner-radius 0", niri)
        kitty = (self.tmp / "kitty.conf").read_text()
        self.assertIn("font_family JetBrains Mono", kitty)
        self.assertIn("background_blur 0", kitty)
        # apps/ overrides replace the generated file.
        self.assertEqual((self.tmp / "ghostty.conf").read_text(), (FIXTURE / "apps" / "ghostty.conf").read_text())

    def test_default_theme_keeps_terminal_fonts(self):
        rc, _, err = loft("theme", "render", str(THEMES / "tokyonight"), str(self.tmp))
        self.assertEqual(rc, 0, err)
        self.assertNotIn("font_family", (self.tmp / "kitty.conf").read_text())
        self.assertIn("\n    on\n", (self.tmp / "niri.kdl").read_text())
        self.assertNotIn("xray false", (self.tmp / "niri.kdl").read_text())

    def test_golden_gate_tokens(self):
        # A pack without the newer tokens gets their defaults; the legacy
        # radii.window still sets the window radius (glassless: 0).
        rc, _, err = loft("theme", "render", str(FIXTURE), str(self.tmp / "legacy"))
        self.assertEqual(rc, 0, err)
        theme = json.loads((self.tmp / "legacy" / "theme.json").read_text())
        self.assertEqual(theme["shape"], {"windowRadius": 0, "panelRadius": 18, "controlRadius": 8, "focus": "shadow"})
        self.assertEqual(theme["radii"], {"window": 0})
        self.assertEqual(theme["bar"], {"adaptiveText": True, "background": False})
        self.assertEqual(theme["glass"]["edgeDarken"], 0.18)  # light polarity
        self.assertEqual(theme["glass"]["specular"], 0.75)
        # shape.windowRadius wins over radii.window, and reaches niri + GTK.
        pack = self.tmp / "shaped"
        copy_pack(FIXTURE, pack)
        t = json.loads((pack / "theme.json").read_text())
        t["shape"] = {"windowRadius": 10}
        t["bar"] = {"background": True}
        t["glass"]["shadow"] = "#00000080"
        (pack / "theme.json").write_text(json.dumps(t))
        rc, _, err = loft("theme", "render", str(pack), str(self.tmp / "out"))
        self.assertEqual(rc, 0, err)
        theme = json.loads((self.tmp / "out" / "theme.json").read_text())
        self.assertEqual(theme["shape"]["windowRadius"], 10)
        self.assertEqual(theme["radii"]["window"], 10)
        self.assertEqual(theme["bar"], {"adaptiveText": True, "background": True})
        niri = (self.tmp / "out" / "niri.kdl").read_text()
        self.assertIn("geometry-corner-radius 10", niri)
        self.assertIn('inactive-color "#00000033"', niri)  # 0x80 * 0.4
        self.assertIn("border-radius: 10px", (self.tmp / "out" / "gtk.css").read_text())

    def test_basic_check_new_tokens(self):
        from loft.pack import _basic_check

        t = json.loads((THEMES / "latte" / "theme.json").read_text())
        self.assertEqual(_basic_check(t), [])
        t["glass"]["specular"] = 2
        t["shape"]["windowRadius"] = -1
        t["bar"]["background"] = "yes"
        errs = "\n".join(_basic_check(t))
        for key in ("glass/specular", "shape/windowRadius", "bar/background"):
            self.assertIn(key, errs)

    def test_invalid_pack(self):
        bad = self.tmp / "bad"
        bad.mkdir()
        (bad / "theme.json").write_text(json.dumps({"palette": {"bg": "red"}}))
        with self.assertRaises(PackError) as cm:
            Pack(bad).validate(THEMES / "schema.json")
        self.assertIn("palette", str(cm.exception))
        rc, _, err = loft("theme", "render", str(bad), str(self.tmp / "out"))
        self.assertEqual(rc, 1)

    @unittest.skipUnless(HAVE_JSONSCHEMA, "needs jsonschema")
    def test_schema_rejects_typos(self):
        bad = self.tmp / "typo"
        copy_pack(THEMES / "tokyonight", bad)
        t = json.loads((bad / "theme.json").read_text())
        t["glass"]["opactiy"] = 0.3
        (bad / "theme.json").write_text(json.dumps(t))
        with self.assertRaises(PackError) as cm:
            Pack(bad).validate(THEMES / "schema.json")
        self.assertIn("opactiy", str(cm.exception))

    @unittest.skipUnless(HAVE_JSONSCHEMA, "needs jsonschema")
    def test_builtins_validate(self):
        rc, out, err = loft("theme", "validate", str(THEMES / "tokyonight"), str(THEMES / "latte"), str(FIXTURE))
        self.assertEqual(rc, 0, err)


class Manager(unittest.TestCase):
    """apply/list/current/new/install/remove/export against scratch dirs."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.saved = dict(os.environ)
        self.state = self.tmp / "state"
        self.user = self.tmp / "data" / "loft" / "themes"
        os.environ.update(
            {
                "HOME": str(self.tmp / "home"),
                "XDG_DATA_HOME": str(self.tmp / "data"),
                "LOFT_STATE_DIR": str(self.state),
                "LOFT_HOOKS": "none",
                "LOFT_THEME_INDEX": "none",
            }
        )
        os.environ.pop("LOFT_THEME_PATH", None)
        os.environ.pop("LOFT_DATA_DIR", None)
        os.environ.pop("LOFT_LIBRARY", None)  # never the real ~/Documents/Themes

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.saved)
        shutil.rmtree(self.tmp)

    def test_list_and_apply(self):
        rc, out, _ = loft("theme", "list")
        self.assertEqual(out.split(), ["latte", "tokyonight"])  # `default` alias hidden

        rc, out, _ = loft("theme", "current")
        self.assertIn("none", out)

        rc, out, err = loft("theme", "apply", "default")
        self.assertEqual(rc, 0, err)
        cur = self.state / "current"
        self.assertTrue(cur.is_symlink())
        first = cur.resolve()
        self.assertEqual(first.parent, (self.state / "rendered" / "compositions").resolve())
        self.assertTrue((cur / "niri.kdl").is_file())
        self.assertEqual(loft("theme", "current")[1].strip(), "tokyonight")

        # Unchanged pack → cached render, same dir.
        loft("theme", "apply", "tokyonight")
        self.assertEqual(cur.resolve(), first)

        loft("theme", "apply", "latte")
        self.assertEqual(loft("theme", "current")[1].strip(), "latte")

    def test_edited_pack_rerenders(self):
        pack = self.tmp / "mine"
        copy_pack(THEMES / "tokyonight", pack)
        loft("theme", "apply", str(pack))
        first = (self.state / "current").resolve()
        t = json.loads((pack / "theme.json").read_text())
        t["palette"]["accent"] = "#ff0000"
        (pack / "theme.json").write_text(json.dumps(t))
        loft("theme", "apply", str(pack))
        second = (self.state / "current").resolve()
        self.assertNotEqual(first, second)
        self.assertTrue(first.exists())  # kept for switching back (GC: render/compose.py)
        self.assertIn("#ff0000", (second / "kitty.conf").read_text())

    def test_new_export_install_remove(self):
        rc, out, err = loft("theme", "new", "mytheme", "--from", "latte")
        self.assertEqual(rc, 0, err)
        mine = self.user / "mytheme"
        self.assertEqual(json.loads((mine / "manifest.json").read_text())["name"], "mytheme")
        self.assertIn("mytheme", loft("theme", "list")[1].split())

        archive = self.tmp / "mytheme.tar.gz"
        rc, _, err = loft("theme", "export", "mytheme", "-o", str(archive))
        self.assertEqual(rc, 0, err)

        rc, _, err = loft("theme", "remove", "mytheme")
        self.assertEqual(rc, 0, err)
        self.assertFalse(mine.exists())

        rc, _, err = loft("theme", "install", str(archive))
        self.assertEqual(rc, 0, err)
        self.assertTrue((mine / "theme.json").is_file())
        rc, _, err = loft("theme", "install", str(archive))
        self.assertEqual(rc, 1)  # already installed
        self.assertIn("--force", err)
        self.assertEqual(loft("theme", "install", "--force", str(archive))[0], 0)

        self.assertEqual(loft("theme", "remove", "latte")[0], 1)  # built-ins stay

    def test_install_needs_manifest(self):
        bare = self.tmp / "bare"
        bare.mkdir()
        (bare / "theme.json").write_text((THEMES / "latte" / "theme.json").read_text())
        rc, _, err = loft("theme", "install", str(bare))
        self.assertEqual(rc, 1)
        self.assertIn("manifest.json", err)

    @unittest.skipUnless(shutil.which("git"), "needs git")
    def test_install_from_git(self):
        repo = self.tmp / "repo"
        copy_pack(FIXTURE, repo / "packs" / "glassless")
        git = ["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"]
        subprocess.run(git + ["init", "-q"], check=True)
        subprocess.run(git + ["add", "."], check=True)
        subprocess.run(git + ["commit", "-qm", "pack"], check=True)
        rc, _, err = loft("theme", "install", f"file://{repo}", "--subdir", "packs/glassless")
        self.assertEqual(rc, 0, err)
        self.assertTrue((self.user / "glassless" / "wall.png").is_file())
        self.assertFalse((self.user / "glassless" / ".git").exists())


class Hooks(unittest.TestCase):
    def test_selection(self):
        self.assertEqual(hooks.selected(None, dev=False), list(hooks.ALL))
        self.assertEqual(hooks.selected(None, dev=True), ["shell", "niri", "wallpapers"])
        self.assertEqual(hooks.selected("none", dev=False), [])
        self.assertEqual(hooks.selected("kitty,gtk", dev=True), ["kitty", "gtk"])
        with self.assertRaises(ValueError):
            hooks.selected("kitty,bogus", dev=False)


if __name__ == "__main__":
    unittest.main()


class LegacyNames(unittest.TestCase):
    """studio-linux (Loft's old name): what still works under the old names."""

    def test_studio_env_vars_fall_back(self):
        env = {k: v for k, v in os.environ.items() if not k.startswith(("LOFT_", "STUDIO_"))}
        env.update(STUDIO_STATE_DIR="/old", LOFT_LIBRARY="new", STUDIO_LIBRARY="old", PYTHONPATH=str(ROOT / "cli"))
        code = "import os, loft; print(os.environ['LOFT_STATE_DIR'], os.environ['LOFT_LIBRARY'])"
        out = subprocess.run([sys.executable, "-c", code], env=env, capture_output=True, text=True, check=True).stdout
        self.assertEqual(out.split(), ["/old", "new"])

    def test_studio_lock_format_reads_as_loft(self):
        with tempfile.TemporaryDirectory() as d:
            pack = Path(d) / "oldlock"
            copy_pack(FIXTURE, pack)
            (pack / "lock").mkdir()
            (pack / "lock" / "Main.qml").write_text("import QtQuick\nItem {}\n")
            m = json.loads((pack / "manifest.json").read_text())
            m["lock"] = {"format": "studio", "path": "lock"}
            (pack / "manifest.json").write_text(json.dumps(m))
            locks = Pack(pack).lock_entries()
            self.assertEqual([lk["format"] for lk in locks], ["loft"])


class DevAlias(unittest.TestCase):
    """`loft dev …` hands everything to loft-dev."""

    def run_dev(self, *argv: str) -> list[str]:
        from unittest import mock

        from loft import cli

        with mock.patch.object(cli.shutil, "which", return_value="/bin/loft-dev"), mock.patch.object(cli.os, "execv") as execv:
            main(["dev", *argv])
        return execv.call_args.args[1]

    def test_passes_options_through(self):
        got = self.run_dev("--list")
        self.assertEqual(got, ["/bin/loft-dev", "--list"])

    def test_checkout_is_the_default_source(self):
        # Run from a checkout, it is appended when no CHECKOUT is given (the
        # Nix check's source tree has no src/, so nothing is appended there).
        is_checkout = (ROOT / "src" / "shell.qml").is_file() and (ROOT / "flake.nix").is_file()
        got = self.run_dev("--session", "agent1", "--size", "800x600")
        self.assertEqual(got, ["/bin/loft-dev", "--session", "agent1", "--size", "800x600", *([str(ROOT)] if is_checkout else [])])
        got = self.run_dev("--session", "agent1", "/some/checkout")
        self.assertEqual(got, ["/bin/loft-dev", "--session", "agent1", "/some/checkout"])
