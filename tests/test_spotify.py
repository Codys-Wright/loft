"""Spotify themed by Loft (cli/loft/spotify.py): the palette → text-scheme
mapping, the writable copy (wrapper rewriting, version-change detection),
setup with a fake spicetify, and the `spotify` reload hook. Everything runs
against scratch dirs and fake Spotify / spicetify trees; nothing is launched
except the copied launcher, which is a shell script here.
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
from unittest import mock

from loft import color, render, spotify
from loft.cli import main
from loft.pack import Pack, normalize

ROOT = Path(__file__).resolve().parent.parent
THEMES = ROOT / "themes"
GOLDEN = ROOT / "tests" / "golden"
FIXTURE = ROOT / "tests" / "fixtures" / "glassless"

HASH = "0" * 32


def loft(*argv: str) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = main(list(argv))
    return rc, out.getvalue(), err.getvalue()


def wrapper(pkg: Path, target: str) -> str:
    """A nixpkgs makeWrapper script like Spotify's bin/spotify."""
    return (
        "#! /bin/sh -e\n"
        f"LD_LIBRARY_PATH='{pkg}/lib/spotify'${{LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}}\n"
        "export LD_LIBRARY_PATH\n"
        f"export XDG_DATA_DIRS='{pkg}/share'${{XDG_DATA_DIRS:+:$XDG_DATA_DIRS}}\n"
        'if [ "${NIXOS_OZONE_WL:-default}" = "1" ]; then unset DISPLAY; fi\n'
        f'exec -a "$0" "{pkg}/share/spotify/{target}"  "$@" \n'
    )


def fake_spotify(store: Path, version: str = "1.2.95.453.g0eeebbed") -> Path:
    """A Spotify package tree: the binary (a script printing where it runs
    from and its environment), Apps/, big files, a nested wrapper."""
    pkg = store / f"{HASH}-spotify-{version}"
    share = pkg / "share" / "spotify"
    (share / "Apps").mkdir(parents=True)
    (share / "Apps" / "xpui.spa").write_bytes(b"PK\x03\x04 stock xpui " + version.encode())
    (share / "Apps" / "login.spa").write_bytes(b"PK\x03\x04 login")
    (share / "locales").mkdir()
    (share / "locales" / "en-US.pak").write_bytes(b"pak")
    (share / "libcef.so").write_bytes(b"\x7fELF big")
    (share / "icudtl.dat").write_bytes(b"icu")
    (share / ".spotify-wrapped").write_text('#!/bin/sh\necho "exe=$0"\necho "ld=$LD_LIBRARY_PATH"\necho "args=$*"\n')
    (share / "spotify").write_text(wrapper(pkg, ".spotify-wrapped"))
    (pkg / "bin").mkdir()
    (pkg / "bin" / "spotify").write_text(wrapper(pkg, ".spotify-wrapped"))
    (pkg / "lib" / "spotify").mkdir(parents=True)
    for p in [pkg, *pkg.rglob("*")]:
        p.chmod(0o555 if p.is_dir() or p.name in ("spotify", ".spotify-wrapped") else 0o444)
    return pkg


FAKE_SPICETIFY = r"""#!PYTHON
# Records its argv and env, and does what `spicetify -n [backup] apply` does to the tree.
import json, os, sys
from pathlib import Path
cfg = Path(os.environ["SPICETIFY_CONFIG"])
state = Path(os.environ["SPICETIFY_STATE"])
log = Path(os.environ["FAKE_SPICETIFY_LOG"])
calls = json.loads(log.read_text()) if log.exists() else []
calls.append({"argv": sys.argv[1:], "config": str(cfg), "state": str(state)})
log.write_text(json.dumps(calls))
ini = (cfg / "config-xpui.ini").read_text()
app = Path([l.split("=", 1)[1].strip() for l in ini.splitlines() if l.startswith("spotify_path")][0])
if "backup" in sys.argv:
    (state / "Backup").mkdir(parents=True, exist_ok=True)
    (state / "Backup" / "xpui.spa").write_bytes((app / "Apps" / "xpui.spa").read_bytes())
if "apply" in sys.argv:
    xpui = app / "Apps" / "xpui"
    (xpui / "extensions").mkdir(parents=True, exist_ok=True)
    for e in (cfg / "Extensions").iterdir():
        (xpui / "extensions" / e.name).write_bytes(e.read_bytes())
    (xpui / "index.html").write_text("<link rel='stylesheet' class='userCSS' href='colors.css'>")
    (xpui / "user.css").write_text((cfg / "Themes" / "text" / "user.css").read_text())
    (xpui / "colors.css").write_text(":root {}\n")
    (app / "Apps" / "xpui.spa").unlink(missing_ok=True)
"""

UPSTREAM_INI = """; upstream text theme
[Spotify]
accent             = 1db954
main               = 121212
text               = FFFFFF

[TokyoNight]
;https://github.com/enkia/tokyo-night-vscode-theme
accent             = 9ece6a
main               = 1a1b26
text               = a9b1d6
"""


class Mapping(unittest.TestCase):
    """The palette → `text` scheme mapping (the spicetify.ini render unit)."""

    def scheme(self, pack: Path) -> dict[str, str]:
        norm, _ = normalize(Pack(pack))
        return render.spicetify_scheme(norm["palette"], norm["polarity"] != "light")

    def test_every_key(self):
        s = self.scheme(THEMES / "tokyonight")
        self.assertEqual(set(s), set(spotify.SCHEME_KEYS))
        for k, v in s.items():
            self.assertRegex(v, r"^[0-9a-f]{6}$", k)
        # The text theme's own keys and Spicetify's base colors are all there.
        self.assertTrue(set(spotify.TEXT_KEYS) <= set(s) and set(spotify.BASE_COLORS) <= set(s))

    def test_roles(self):
        pal = json.loads((THEMES / "tokyonight" / "theme.json").read_text())["palette"]
        s = self.scheme(THEMES / "tokyonight")
        self.assertEqual(s["main"], pal["bg"].lstrip("#"))
        self.assertEqual(s["text"], pal["text"].lstrip("#"))
        self.assertEqual(s["accent"], pal["accent"].lstrip("#"))
        self.assertEqual(s["button-active"], s["accent"])
        self.assertEqual(s["notification-error"], pal["urgent"].lstrip("#"))

    def test_contrast(self):
        for pack in (THEMES / "tokyonight", THEMES / "latte", FIXTURE):
            s = self.scheme(pack)
            main_ = "#" + s["main"]
            with self.subTest(pack=pack.name):
                self.assertGreaterEqual(color.contrast("#" + s["text"], main_), 7.0)
                self.assertGreaterEqual(color.contrast("#" + s["subtext"], main_), 4.5)
                for k in ("accent", "accent-active", "button", "banner", "header", "notification-error"):
                    self.assertGreaterEqual(color.contrast("#" + s[k], main_), 3.0, k)
                # Card fills / hairlines visibly differ from the background.
                self.assertGreaterEqual(color.contrast("#" + s["border-inactive"], main_), 1.1)

    def test_light_theme(self):
        s = self.scheme(THEMES / "latte")
        self.assertGreater(color.luminance("#" + s["main"]), 0.7)
        self.assertLess(color.luminance("#" + s["text"]), 0.2)
        # The derived surfaces stay on the light side too.
        for k in ("sidebar", "player", "card", "main-elevated", "accent-inactive", "highlight"):
            self.assertGreater(color.luminance("#" + s[k]), 0.5, k)

    def test_golden(self):
        """tests/golden/<t>/spicetify.ini (the theme-golden check diffs it
        byte for byte against the built-ins; this checks what it says)."""
        for t in ("tokyonight", "latte"):
            schemes = spotify.parse_ini((GOLDEN / t / "spicetify.ini").read_text())
            self.assertEqual(list(schemes), ["loft"])
            self.assertEqual(schemes["loft"], self.scheme(THEMES / t))
        latte = spotify.parse_ini((GOLDEN / "latte" / "spicetify.ini").read_text())["loft"]
        self.assertEqual((latte["main"], latte["text"], latte["accent"]), ("eff1f5", "4c4f69", "1e66f5"))
        tn = spotify.parse_ini((GOLDEN / "tokyonight" / "spicetify.ini").read_text())["loft"]
        self.assertEqual((tn["main"], tn["text"], tn["accent"]), ("1a1b26", "c0caf5", "7aa2f7"))


class Ini(unittest.TestCase):
    def test_parse_and_format(self):
        s = spotify.parse_ini(UPSTREAM_INI + "\n[odd]\nmain=#ABCDEF ; comment\nbad = nope\n")
        self.assertEqual(list(s), ["Spotify", "TokyoNight", "odd"])
        self.assertEqual(s["Spotify"]["text"], "ffffff")
        self.assertEqual(s["odd"], {"main": "abcdef"})
        self.assertEqual(spotify.parse_ini(spotify.format_ini(s, "hdr")), s)

    def test_merge(self):
        up = spotify.parse_ini(UPSTREAM_INI)
        merged = spotify.merge_schemes(up, {"loft": {"main": "000000"}, "Spotify": {"main": "111111"}})
        self.assertEqual(list(merged), ["TokyoNight", "loft", "Spotify"])
        self.assertEqual(merged["Spotify"], {"main": "111111"})

    def test_colors_css(self):
        css = spotify.colors_css({"main": "1a1b26"})
        self.assertIn("--spice-main: #1a1b26;", css)
        self.assertIn("--spice-rgb-main: 26,27,38;", css)
        # Missing keys get Spicetify's base colors, as `spicetify apply` does.
        self.assertIn("--spice-button: #1db954;", css)
        self.assertEqual(css.count("--spice-rgb-"), len(spotify.BASE_COLORS))

    def test_choose(self):
        av = {"loft": {}, "TokyoNight": {}, "cozy": {}}
        follow = {"follow": True, "scheme": "TokyoNight"}
        fixed = {"follow": False, "scheme": "TokyoNight"}
        self.assertEqual(spotify.choose_scheme(follow, {"cozy": {}}, av, None), "cozy")
        self.assertEqual(spotify.choose_scheme(follow, {}, av, None), "loft")
        self.assertEqual(spotify.choose_scheme(fixed, {"cozy": {}}, av, "loft"), "TokyoNight")
        self.assertEqual(spotify.choose_scheme({"follow": False, "scheme": "gone"}, {}, av, "cozy"), "cozy")

    def test_store_version(self):
        self.assertEqual(spotify.store_version(Path(f"/nix/store/{HASH}-spotify-1.2.95.453.g0eeebbed")), "1.2.95.453.g0eeebbed")
        self.assertEqual(spotify.store_version(Path("/opt/spotify")), "")


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.saved = dict(os.environ)
        self.store = self.tmp / "store"
        self.store.mkdir()
        self.root = self.tmp / "data" / "loft" / "spotify"
        self.state = self.tmp / "state" / "loft"
        os.environ.update(
            {
                "HOME": str(self.tmp / "home"),
                "XDG_DATA_HOME": str(self.tmp / "data"),
                "XDG_CONFIG_HOME": str(self.tmp / "config"),
                "LOFT_STATE_DIR": str(self.state),
                "LOFT_HOOKS": "spotify",
                "LOFT_THEME_INDEX": "none",
                "LOFT_LIBRARY": "none",
                "LOFT_THEME_PATH": f"{self.tmp / 'packs'}:{THEMES}",
                "FAKE_SPICETIFY_LOG": str(self.tmp / "spicetify.json"),
            }
        )
        for k in ("LOFT_SPOTIFY_DIR", "LOFT_SPOTIFY_CONFIG", "LOFT_DATA_DIR", "SPICETIFY_CONFIG", "SPICETIFY_STATE"):
            os.environ.pop(k, None)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.saved)
        for p in [self.tmp, *self.tmp.rglob("*")]:
            if p.is_dir() and not p.is_symlink():
                p.chmod(0o755)
        shutil.rmtree(self.tmp)


class Copy(Base):
    def test_rewrite_wrapper(self):
        pkg = Path(f"/nix/store/{HASH}-spotify-1")
        text = wrapper(pkg, ".spotify-wrapped")
        out = spotify.rewrite_wrapper(text, pkg / "share" / "spotify", Path("/w/app"))
        self.assertIn('exec -a "$0" "/w/app/.spotify-wrapped"  "$@"', out)
        # The environment it sets up is untouched (libraries stay in the store).
        self.assertIn(f"LD_LIBRARY_PATH='{pkg}/lib/spotify'", out)
        self.assertIn(f"XDG_DATA_DIRS='{pkg}/share'", out)
        self.assertEqual(out.count("/w/app"), 1)
        with self.assertRaises(spotify.SpotifyError):
            spotify.rewrite_wrapper("#!/bin/sh\nexec /usr/bin/spotify\n", pkg / "share" / "spotify", Path("/w"))

    def test_copy_tree_and_launcher(self):
        pkg = fake_spotify(self.store)
        app, launcher = self.tmp / "app", self.tmp / "bin" / "spotify"
        spotify.copy_spotify(pkg, app, launcher)
        src = pkg / "share" / "spotify"
        # Real, writable: Apps/ (Spicetify's target) and the binary.
        self.assertFalse((app / "Apps").is_symlink())
        self.assertTrue(os.access(app / "Apps" / "xpui.spa", os.W_OK))
        self.assertFalse((app / ".spotify-wrapped").is_symlink())
        # The wrapper inside the tree (what `spicetify restart` runs) execs the copy.
        self.assertFalse((app / "spotify").is_symlink())
        self.assertIn(f'"{app}/.spotify-wrapped"', (app / "spotify").read_text())
        # Everything else points into the store.
        for name in ("libcef.so", "icudtl.dat", "locales"):
            self.assertEqual(os.readlink(app / name), str(src / name), name)
        # The launcher runs the copy, with the package's environment.
        r = subprocess.run([str(launcher), "--flag"], capture_output=True, text=True, check=True)
        self.assertIn(f"ld={pkg}/lib/spotify", r.stdout)
        self.assertIn("args=--flag", r.stdout)
        r = subprocess.run([str(app / "spotify")], capture_output=True, text=True, check=True)
        self.assertIn(f"ld={pkg}/lib/spotify", r.stdout)
        with self.assertRaises(spotify.SpotifyError):
            spotify.copy_spotify(self.tmp, self.tmp / "app2", self.tmp / "l2")


class Setup(Base):
    def setUp(self):
        super().setUp()
        self.pkg = fake_spotify(self.store)
        sp = self.store / f"{HASH}-spicetify-cli-2.45.3" / "bin"
        sp.mkdir(parents=True)
        (sp / "spicetify").write_text(FAKE_SPICETIFY.replace("PYTHON", sys.executable, 1))
        (sp / "spicetify").chmod(0o755)
        self.text = self.store / f"{HASH}-spicetify-text"
        self.text.mkdir()
        (self.text / "user.css").write_text(":root { --spice-sidebar: var(--spice-main); }\n")
        (self.text / "color.ini").write_text(UPSTREAM_INI)
        self.ext = self.store / f"{HASH}-ext" / "adblock.js"
        self.ext.parent.mkdir()
        self.ext.write_text("// adblock\n")
        self.market = self.store / f"{HASH}-marketplace"
        self.market.mkdir()
        (self.market / "index.js").write_text("// marketplace\n")
        self.write_config()

    def write_config(self, **over):
        cfg = {
            "package": str(self.pkg),
            "spicetify": str(self.store / f"{HASH}-spicetify-cli-2.45.3"),
            "textTheme": str(self.text),
            "extensions": [str(self.ext)],
            "customApps": {"marketplace": str(self.market)},
        }
        cfg.update(over)
        f = self.tmp / "config" / "loft" / "spotify.json"
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(json.dumps(cfg))

    def calls(self) -> list[dict]:
        f = self.tmp / "spicetify.json"
        return json.loads(f.read_text()) if f.exists() else []

    def colors(self) -> str:
        return (self.root / "app" / "Apps" / "xpui" / "colors.css").read_text()

    def test_hook_noop_when_not_set_up(self):
        rc, _, err = loft("theme", "apply", "tokyonight")
        self.assertEqual(rc, 0, err)
        self.assertFalse(self.root.exists())
        self.assertIsNone(spotify.sync(self.root, self.state, self.state / "current"))
        rc, out, _ = loft("spotify", "sync")
        self.assertEqual(rc, 0)
        self.assertIn("isn't set up", out)

    def test_setup_and_sync(self):
        self.assertEqual(loft("theme", "apply", "tokyonight")[0], 0)
        rc, out, err = loft("spotify", "setup")
        self.assertEqual(rc, 0, err)
        self.assertIn("copied", out)
        calls = self.calls()
        self.assertEqual([c["argv"] for c in calls], [["-n", "backup", "apply"]])
        # Loft's own config/state dirs, never ~/.config/spicetify.
        self.assertEqual(calls[0]["config"], str(self.root / "spicetify"))
        self.assertEqual(calls[0]["state"], str(self.root / "spicetify-state"))
        self.assertFalse((self.tmp / "home" / ".config" / "spicetify").exists())

        ini = (self.root / "spicetify" / "config-xpui.ini").read_text()
        self.assertIn(f"spotify_path = {self.root / 'app'}", ini.replace("  ", " ").replace("  ", " "))
        self.assertRegex(ini, r"(?m)^extensions\s*=\s*loft-live\.js\|adblock\.js$")
        self.assertRegex(ini, r"(?m)^custom_apps\s*=\s*marketplace$")
        self.assertRegex(ini, r"(?m)^color_scheme\s*=\s*loft$")
        self.assertRegex(ini, r"(?m)^check_spicetify_update\s*=\s*0$")
        sp = self.root / "spicetify"
        self.assertTrue((sp / "Extensions" / "loft-live.js").is_file())
        self.assertEqual((sp / "Extensions" / "adblock.js").read_text(), "// adblock\n")
        self.assertTrue((sp / "CustomApps" / "marketplace" / "index.js").is_file())
        self.assertEqual((self.root / "prefs").read_text(), 'app.last-launched-version="1.2.95.453.g0eeebbed"\n')
        # color.ini: upstream's schemes, then the theme's; colors.css = the theme's.
        schemes = spotify.parse_ini((sp / "Themes" / "text" / "color.ini").read_text())
        self.assertEqual(list(schemes), ["Spotify", "TokyoNight", "loft"])
        self.assertIn("--spice-main: #1a1b26;", self.colors())
        self.assertIn("--spice-text: #c0caf5;", self.colors())

        # Idempotent: nothing to do, spicetify not run again.
        rc, out, _ = loft("spotify", "setup")
        self.assertIn("up-to-date", out)
        self.assertEqual(len(self.calls()), 1)

        # The hook: a theme switch recolors without spicetify.
        self.assertEqual(loft("theme", "apply", "latte")[0], 0)
        self.assertIn("--spice-main: #eff1f5;", self.colors())
        self.assertEqual(len(self.calls()), 1)

        # A fixed scheme: theme switches leave it alone; `theme` follows again.
        self.assertEqual(loft("spotify", "scheme", "TokyoNight")[0], 0)
        self.assertIn("--spice-main: #1a1b26;", self.colors())
        self.assertRegex((sp / "config-xpui.ini").read_text(), r"(?m)^color_scheme\s*=\s*TokyoNight$")
        self.assertEqual(loft("theme", "apply", "latte")[0], 0)
        self.assertIn("--spice-main: #1a1b26;", self.colors())
        self.assertEqual(loft("spotify", "scheme", "nope")[0], 1)
        self.assertEqual(loft("spotify", "scheme", "theme")[0], 0)
        self.assertIn("--spice-main: #eff1f5;", self.colors())
        self.assertEqual(loft("spotify", "follow", "off")[0], 0)
        self.assertEqual(loft("theme", "apply", "tokyonight")[0], 0)
        self.assertIn("--spice-main: #eff1f5;", self.colors(), "not following: kept")
        self.assertEqual(loft("spotify", "follow", "on")[0], 0)
        self.assertIn("--spice-main: #1a1b26;", self.colors())

        rc, out, _ = loft("spotify", "status", "--json")
        st = json.loads(out)
        self.assertTrue(st["setUp"] and st["configured"])
        self.assertIsNone(st["pending"])
        self.assertEqual(st["activeScheme"], "loft")
        # The colors that showed when following was turned off stay available.
        self.assertEqual(st["schemes"][:4], ["loft", "pinned", "Spotify", "TokyoNight"])
        self.assertEqual(json.loads((self.state / "overrides" / "spotify.json").read_text())["pinned"]["main"], "eff1f5")

    def test_version_change(self):
        cfg = spotify.load_config(ROOT)
        self.assertEqual(spotify.needs(self.root, cfg), "copy")
        self.assertEqual(spotify.setup(self.root, cfg, self.state, log=lambda *_: None), "copied")
        self.assertIsNone(spotify.needs(self.root, cfg))

        # An extension changed: re-apply only (keeps the copy and the backup).
        self.ext.write_text("// adblock v2\n")
        self.assertEqual(spotify.needs(self.root, cfg), "apply")
        marker = self.root / "app" / "marker"
        marker.write_text("x")
        self.assertEqual(spotify.setup(self.root, cfg, self.state, log=lambda *_: None), "applied")
        self.assertTrue(marker.exists())
        self.assertEqual(self.calls()[-1]["argv"], ["-n", "apply"])
        self.assertRegex((self.root / "spicetify" / "config-xpui.ini").read_text(), r"(?m)^\[Backup\]")

        # Nix updated Spotify: a new store path → re-copy, new backup, new version.
        new = fake_spotify(self.store, "1.2.96.100.gabcdef01")
        self.write_config(package=str(new))
        cfg = spotify.load_config(ROOT)
        self.assertEqual(spotify.needs(self.root, cfg), "copy")
        # ... but not while Spotify runs from the old copy.
        with mock.patch.object(spotify, "running_pids", return_value=[4242]):
            self.assertEqual(spotify.setup(self.root, cfg, self.state, log=lambda *_: None), "deferred")
        self.assertTrue(marker.exists())
        self.assertEqual(spotify.setup(self.root, cfg, self.state, log=lambda *_: None), "copied")
        self.assertFalse(marker.exists())
        self.assertEqual(self.calls()[-1]["argv"], ["-n", "backup", "apply"])
        self.assertIn("1.2.96.100.gabcdef01", (self.root / "prefs").read_text())
        self.assertIn(str(new), (self.root / "bin" / "spotify").read_text())
        self.assertEqual(json.loads((self.root / "installed.json").read_text())["version"], "1.2.96.100.gabcdef01")
        self.assertEqual((self.root / "spicetify-state" / "Backup" / "xpui.spa").read_bytes(), b"PK\x03\x04 stock xpui 1.2.96.100.gabcdef01")
        # No leftovers of the swap.
        self.assertEqual(sorted(p.name for p in self.root.iterdir() if p.name.startswith(".")), [".lock"])

    def test_pack_scheme(self):
        """A pack's apps/spicetify.ini (Cozytile's) wins over the generated one."""
        pack = self.tmp / "packs" / "cozyish"
        shutil.copytree(THEMES / "tokyonight", pack)
        for q in [pack, *pack.rglob("*")]:  # read-only in the Nix check
            q.chmod(q.stat().st_mode | 0o200)
        (pack / "manifest.json").write_text(json.dumps({"name": "cozyish", "author": "t", "version": "1", "license": "MIT", "source": "x"}))
        (pack / "apps").mkdir()
        (pack / "apps" / "spicetify.ini").write_text("[cozy]\naccent=CAA9E0\nmain=282738\ntext=FFFFFF\n")
        self.assertEqual(loft("spotify", "setup")[0], 0)
        rc, _, err = loft("theme", "apply", "cozyish")
        self.assertEqual(rc, 0, err)
        self.assertIn("--spice-main: #282738;", self.colors())
        self.assertIn("--spice-accent: #caa9e0;", self.colors())
        schemes = spotify.parse_ini((self.root / "spicetify" / "Themes" / "text" / "color.ini").read_text())
        self.assertEqual(list(schemes), ["Spotify", "TokyoNight", "cozy", "loft"])

    def test_run_falls_back(self):
        """`loft spotify run` execs the patched copy; without a working setup,
        the plain package (music first)."""
        self.write_config(textTheme=str(self.tmp / "missing"))
        out = subprocess.run(
            [sys.executable, "-m", "loft", "spotify", "run", "--", "--x"],
            env=dict(os.environ, PYTHONPATH=str(ROOT / "cli")),
            capture_output=True,
            text=True,
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("starting it unthemed", out.stderr)
        self.assertIn(f"exe={self.pkg}/share/spotify/.spotify-wrapped", out.stdout)
        self.write_config()
        out = subprocess.run(
            [sys.executable, "-m", "loft", "spotify", "run", "--", "--x"],
            env=dict(os.environ, PYTHONPATH=str(ROOT / "cli")),
            capture_output=True,
            text=True,
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn(f"exe={self.root}/app/.spotify-wrapped", out.stdout)
        self.assertIn("args=--x", out.stdout)


if __name__ == "__main__":
    unittest.main()
