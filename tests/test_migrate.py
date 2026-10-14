"""Phase C (docs/THEME-ARCHITECTURE.md §5): `loft library migrate`, pack v2
install / export / remove, and the importers writing v2.

The fixtures in tests/fixtures/migrate/Packs are six real packs from a
library (qylock osu + osumania, material-you + material-you-dark, cozytile
carbon + sakura), copied with their media stubbed (a few bytes carrying the
original's hash, so identical files stay identical). Together they cover
every grouping rule.

Run: PYTHONPATH=cli python3 -m unittest tests.test_migrate -v
Everything runs against scratch HOME / XDG / state dirs, hooks off.
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

from loft import migrate, palette
from loft.cli import main
from loft.facets import appearance as A
from loft.pack import validate_v2

try:  # `discover -s tests` (nix flake check) or `-m unittest tests.test_migrate`
    import test_importers as TI
except ImportError:
    from tests import test_importers as TI

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "tests" / "fixtures" / "migrate" / "Packs"
BUILTIN = ROOT / "packs"
PACKS = sorted(d.name for d in FIXTURES.iterdir())
OLD_NAMES = ["tokyonight", "latte", *PACKS]


def loft(*argv: str) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = main(list(argv))
    return rc, out.getvalue(), err.getvalue()


def tree(root: Path) -> dict[str, bytes]:
    return {str(p.relative_to(root)): p.read_bytes() for p in sorted(root.rglob("*")) if p.is_file()}


class Home(unittest.TestCase):
    """A scratch HOME with the fixture library at ~/Documents/Themes (where
    it is before the migration) and a state dir."""

    def setUp(self):
        # The stubbed media are tiny: hard-link them all the same.
        self.hl = mock.patch.object(migrate, "HARDLINK_MIN", 1)
        self.hl.start()
        self.addCleanup(self.hl.stop)
        self.tmp = Path(tempfile.mkdtemp())
        self.saved = dict(os.environ)
        self.home = self.tmp / "home"
        self.old = self.home / "Documents" / "Themes"
        self.new = self.home / "Documents" / "Loft"
        self.state = self.home / ".local" / "state" / "loft"
        shutil.copytree(FIXTURES, self.old / "Packs")
        for q in [self.old, *self.old.rglob("*")]:  # the Nix store's copy is read-only
            q.chmod(q.stat().st_mode | 0o200)
        topic = self.old / "Wallpapers" / "Topics" / "Avatar"
        topic.mkdir(parents=True)
        (topic / "aang.jpg").write_bytes(b"\xff\xd8\xff\xe0aang")
        os.environ.update(
            {
                "HOME": str(self.home),
                "XDG_DATA_HOME": str(self.home / ".local" / "share"),
                "XDG_STATE_HOME": str(self.home / ".local" / "state"),
                "LOFT_STATE_DIR": str(self.state),
                "LOFT_HOOKS": "none",
                "LOFT_THEME_INDEX": "none",
            }
        )
        for k in ("LOFT_LIBRARY", "LOFT_THEME_PATH", "LOFT_DATA_DIR", "LOFT_THEME_ENGINE", "LOFT_IMPORT_FORMAT"):
            os.environ.pop(k, None)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.saved)
        shutil.rmtree(self.tmp)

    def shell_json(self, extra: dict | None = None) -> None:
        old = str(self.old)
        doc = {
            "appearance": {"barAdaptiveText": -1, "barBackground": 0, "blur": -1, "glass": 0.35000000000000003, "glassOpacity": -1, "reduceTransparency": False},
            "wallpaper": {"directory": "~/Pictures/Wallpapers", "path": "", "perWorkspace": False, "rotate": 300},
            "lock": {"design": ""},
            "perTheme": {
                "tokyonight": {
                    "wallpaper": f"{old}/Wallpapers/Topics/Avatar/aang.jpg",
                    "displays": {"Microstep MPG491CX OLED Unknown": f"{old}/Wallpapers/Topics/Avatar/aang.jpg"},
                    "lockDesign": f"{old}/Packs/qylock-osu/lock/qylock",
                },
                "qylock-osumania": {"auto": True, "autoSeed": 3, "sets": [{"name": "Pair", "displays": {"main": f"{old}/Wallpapers/Topics/Avatar/aang.jpg"}, "workspaces": {}}]},
                "cozytile-sakura": {"lockDesign": "builtin"},
                "gone-theme": {"wallpaper": "/x.jpg"},
            },
            "dock": {"keep": True},
            **(extra or {}),
        }
        f = self.state / "overrides" / "shell.json"
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(json.dumps(doc))

    def render_all(self, out: Path, *extra: str) -> None:
        for n in OLD_NAMES:
            rc, _, err = loft("theme", "render", n, str(out / n), *extra)
            self.assertEqual(rc, 0, f"{n}: {err}")


class Migrate(Home):
    def test_plan_groups_and_counts(self):
        p = migrate.plan(self.state, BUILTIN)
        s = migrate.summary(p, BUILTIN)
        themes = {g.theme: g for g in p.groups}
        self.assertEqual(sorted(themes), ["cozytile", "qylock-material-you", "qylock-osu"])
        cz = themes["cozytile"]
        self.assertEqual((cz.rule, cz.base["id"], [v for _, v, _ in cz.members]), ("rice", "sakura", ["sakura", "carbon"]))
        self.assertEqual((themes["qylock-osu"].rule, [v for _, v, _ in themes["qylock-osu"].members]), ("declared", ["osu", "mania"]))
        self.assertEqual([v for _, v, _ in themes["qylock-material-you"].members], ["light", "dark"])
        self.assertEqual(
            p.aliases,
            {
                "cozytile-carbon": "cozytile@carbon", "cozytile-sakura": "cozytile",
                "qylock-material-you": "qylock-material-you", "qylock-material-you-dark": "qylock-material-you@dark",
                "qylock-osu": "qylock-osu", "qylock-osumania": "qylock-osu@mania",
            },
        )  # fmt: skip
        # 4 themes (with loft), 4 variants (loft 1, cozytile 1, material-you 1, osu 1);
        # osu / osumania share colors and wallpapers, so 2 + 5 colors and 5 wallpapers.
        self.assertEqual((s["themes"], s["variants"], s["chips"]), (4, 4, 8))
        self.assertEqual(s["facets"]["colors"], 7)
        self.assertEqual(s["facets"]["wallpapers"], 5)
        self.assertEqual(s["facets"]["lock"], 7)
        self.assertEqual(s["facets"]["material"], 3)  # liquid-glass (loft), imported, imported-dense
        self.assertEqual(s["oldNames"], 8)
        self.assertTrue(p.hardlinks)  # osu / osumania ship the same backgrounds
        self.assertFalse(self.new.exists(), "a dry run changes nothing")

    def test_apply_keeps_every_render(self):
        """M1 (§9) with renders: every old name renders the same after the
        migration, through its alias, once the library root is swapped. The
        one exception is by design: osumania's wallpapers are osu's now (the
        same images, merged into one facet; manifest.json and wallpapers.json)."""
        pre = self.tmp / "pre"
        self.render_all(pre)
        # The facet engine's v1 adapter = the v1 engine, before anything moves.
        os.environ["LOFT_THEME_ENGINE"] = "v1"
        for n in OLD_NAMES:
            self.assertEqual(loft("theme", "render", n, str(self.tmp / "v1" / n))[0], 0)
        del os.environ["LOFT_THEME_ENGINE"]
        self.assertEqual(tree(pre), tree(self.tmp / "v1"))

        rc, out, err = loft("library", "migrate", "--apply")
        self.assertEqual(rc, 0, err)
        self.assertTrue(self.old.is_symlink())
        self.assertEqual(Path(os.readlink(self.old)), self.new)
        self.assertTrue((self.new / "Packs" / "cozytile" / "themes" / "cozytile.json").is_file())
        self.assertTrue((self.new / "Packs" / "qylock-osu" / "theme.json").is_file(), "v1 files stay for the v1 readers")
        for d in (self.new / "Packs").iterdir():
            self.assertEqual(validate_v2(d, BUILTIN, [self.new / "Packs"]), [], d.name)

        post = self.tmp / "post"
        self.render_all(post, "--no-user")
        a, b = str(self.old).encode(), str(self.new).encode()
        for n in OLD_NAMES:
            before = {k: v.replace(a, b) for k, v in tree(pre / n).items()}
            after = tree(post / n)
            self.assertEqual(sorted(before), sorted(after), n)
            differ = [k for k in before if before[k] != after[k]]
            if n != "qylock-osumania":
                self.assertEqual(differ, [], n)
                continue
            self.assertEqual(sorted(differ), ["manifest.json", "wallpapers.json"])
            # wallpapers.json: the same collection, at osu's copies.
            w = json.loads(before["wallpapers.json"].replace(b"/qylock-osumania/", b"/qylock-osu/"))
            for e in w["collection"]:
                e["source_pack"] = "qylock-osu"
            self.assertEqual(w, json.loads(after["wallpapers.json"]))
            x, y = json.loads(before["manifest.json"]), json.loads(after["manifest.json"])
            for w in x["wallpapers"]:
                w["path"] = w["path"].replace("/qylock-osumania/", "/qylock-osu/")
                w["source_pack"] = "qylock-osu"
            x["defaults"]["wallpaper"] = x["defaults"]["wallpaper"].replace("/qylock-osumania/", "/qylock-osu/")
            self.assertEqual(x, y)
            for w in y["wallpapers"]:  # the same images (now hard links)
                twin = Path(w["path"].replace("/qylock-osu/", "/qylock-osumania/"))
                self.assertEqual(os.stat(w["path"]).st_ino, os.stat(twin).st_ino)

        # A second run has nothing left to do.
        p = migrate.plan(self.state, BUILTIN)
        self.assertTrue(migrate.nothing_to_do(p), migrate.render_report(p, migrate.summary(p, BUILTIN), False))

    def test_user_state(self):
        self.shell_json()
        niri = self.state / "overrides" / "niri.json"
        niri.write_text(json.dumps({"animations": {"slowdown": 2}}))
        A.save(self.state, dict(A.empty(), theme="loft", mode="dark"))
        rc, out, err = loft("library", "migrate", "--apply")
        self.assertEqual(rc, 0, err)
        st = json.loads((self.state / "appearance.json").read_text())
        new = str(self.new)
        self.assertEqual((st["theme"], st["mode"]), ("loft", "dark"))  # kept
        self.assertEqual(
            st["pins"],
            {
                "material": {"patch": {"glass": {"opacity": 0.35}, "menuBar": {"background": False}}},
                "wallpapers": {"patch": {"behavior": {"rotate": 300}}},
                "motion": {"patch": {"speed": 0.5}},
            },
        )
        c = st["customizations"]
        self.assertEqual(
            c["loft"]["dark"],
            {
                "wallpapers": {"patch": {"arrangement": {
                    "wallpaper": f"{new}/Wallpapers/Topics/Avatar/aang.jpg",
                    "displays": {"Microstep MPG491CX OLED Unknown": f"{new}/Wallpapers/Topics/Avatar/aang.jpg"},
                }}},
                "lock": "lock:qylock-osu/osu",
            },
        )  # fmt: skip
        self.assertEqual(c["qylock-osu"]["mania"], {"wallpapers": {"patch": {"arrangement": {"auto": True, "autoSeed": 3}}}})
        self.assertEqual(c["cozytile"]["sakura"], {"lock": "lock:loft"})
        self.assertEqual(c["gone-theme"]["*"]["wallpapers"]["patch"]["arrangement"]["wallpaper"], "/x.jpg")
        sets = json.loads((self.new / "Wallpapers" / "Sets" / "qylock-osu-pair.json").read_text())
        self.assertEqual(sets["data"]["sets"][0]["displays"], {"main": f"{new}/Wallpapers/Topics/Avatar/aang.jpg"})
        # Originals kept beside, and still in place (the shell reads them until phase E).
        for f in ("shell", "niri"):
            self.assertTrue((self.state / "overrides" / f"{f}{migrate.BACKUP_SUFFIX}").is_file())
        self.assertIn("perTheme", json.loads((self.state / "overrides" / "shell.json").read_text()))
        self.assertTrue((self.state / f"appearance{migrate.BACKUP_SUFFIX}").is_file())

        # The pins and customizations resolve: the 0.35 glass on every theme,
        # tokyonight's choices on loft@dark only.
        rc, out, err = loft("theme", "state", "loft@dark", "--compact")
        self.assertEqual(rc, 0, err)
        s = json.loads(out)
        self.assertEqual((s["facets"]["material"]["glass"]["opacity"], s["errors"]), (0.35, []))
        self.assertEqual(s["facets"]["lock"]["path"], str((self.new / "Packs" / "qylock-osu" / "lock" / "qylock").resolve()))
        self.assertEqual(s["customized"], ["wallpapers", "lock"])
        s = json.loads(loft("theme", "state", "latte", "--compact")[1])
        self.assertEqual((s["ref"], s["customized"], s["facets"]["material"]["glass"]["opacity"]), ("loft@light", [], 0.35))
        s = json.loads(loft("theme", "state", "qylock-osumania", "--compact")[1])
        self.assertEqual((s["ref"], s["facets"]["wallpapers"]["arrangement"]["autoSeed"]), ("qylock-osu@mania", 3))

        # Idempotent: nothing more to do, nothing rewritten.
        before = (self.state / "appearance.json").read_text()
        rc, out, _ = loft("library", "migrate", "--apply")
        self.assertIn("nothing left to do", out)
        self.assertEqual((self.state / "appearance.json").read_text(), before)

    def test_undo(self):
        self.shell_json()
        A.save(self.state, dict(A.empty(), theme="loft"))
        share = self.home / ".local" / "share" / "loft"
        share.mkdir(parents=True)
        (share / "themes").symlink_to(self.old / "Packs")
        snapshot = tree(self.home)
        self.assertEqual(loft("library", "migrate", "--apply")[0], 0)
        self.assertEqual(os.readlink(share / "themes"), str(self.new / "Packs"))
        rc, out, err = loft("library", "migrate", "--undo")
        self.assertEqual(rc, 0, err)
        self.assertTrue(self.old.is_dir() and not self.old.is_symlink())
        self.assertFalse(self.new.exists())
        self.assertEqual(os.readlink(share / "themes"), str(self.old / "Packs"))
        after = {k: v for k, v in tree(self.home).items() if "/migration/" not in k}
        self.assertEqual(after, snapshot)

    def test_library_root(self):
        from loft import library

        # Before the migration the old root is used; after, the new one.
        self.assertEqual(library.root(), self.old)
        os.environ["LOFT_LIBRARY"] = str(self.new)
        self.assertEqual(library.root(), self.old)
        self.assertEqual(loft("library", "migrate", "--apply")[0], 0)
        self.assertEqual(library.root(), self.new)
        del os.environ["LOFT_LIBRARY"]
        self.assertEqual(library.root(), self.new)
        os.environ["LOFT_LIBRARY"] = "none"
        self.assertIsNone(library.root())


class PackV2(Home):
    """Pack v2 round trips: migrate → export (with the packs it uses) →
    install elsewhere → the same render; remove by theme or old name."""

    def test_export_install_remove(self):
        self.assertEqual(loft("library", "migrate", "--apply")[0], 0)
        ref = self.tmp / "ref"
        self.assertEqual(loft("theme", "render", "cozytile@carbon", str(ref))[0], 0)
        archive = self.tmp / "cozytile.tar.gz"
        rc, out, err = loft("theme", "export", "cozytile", "-o", str(archive))
        self.assertEqual(rc, 0, err)
        self.assertIn("cozytile-carbon", err)  # with the packs its variants use

        # Another machine: an empty library.
        other = self.tmp / "other"
        os.environ["HOME"] = str(other / "home")
        os.environ["LOFT_LIBRARY"] = str(other / "lib")
        os.environ["LOFT_STATE_DIR"] = str(other / "state")
        (other / "lib" / "Packs").mkdir(parents=True)
        rc, out, err = loft("theme", "install", str(archive))
        self.assertEqual(rc, 0, err)
        self.assertEqual(sorted(p.name for p in (other / "lib" / "Packs").iterdir()), ["cozytile", "cozytile-carbon", "cozytile-sakura"])
        self.assertEqual(loft("theme", "install", str(archive))[0], 1)  # installed already
        self.assertEqual(loft("theme", "install", "--force", str(archive))[0], 0)
        got = self.tmp / "got"
        rc, _, err = loft("theme", "render", "cozytile-carbon", str(got))
        self.assertEqual(rc, 0, err)
        a, b = str(self.new.resolve()).encode(), str((other / "lib").resolve()).encode()
        self.assertEqual({k: v.replace(a, b) for k, v in tree(ref).items()}, tree(got))
        rc, out, err = loft("theme", "validate", "cozytile")
        self.assertEqual(rc, 0, err)

        # A pack a theme uses goes only with the theme; by an old name, the theme.
        rc, out, err = loft("theme", "remove", "cozytile-sakura")
        self.assertEqual(rc, 1)
        self.assertIn("cozytile-sakura is cozytile now", err)
        rc, out, err = loft("theme", "remove", "cozytile")
        self.assertEqual(rc, 0, err)
        self.assertIn("--with-deps", out)
        self.assertFalse((other / "lib" / "Packs" / "cozytile").exists())
        self.assertEqual(loft("theme", "install", str(archive))[0], 1)  # cozytile-* are still there
        self.assertEqual(loft("theme", "install", "--force", str(archive))[0], 0)
        self.assertEqual(loft("theme", "remove", "--with-deps", "cozytile")[0], 0)
        self.assertEqual(list((other / "lib" / "Packs").iterdir()), [])

    def test_validate_reports_problems(self):
        self.assertEqual(loft("library", "migrate", "--apply")[0], 0)
        pack = self.new / "Packs" / "qylock-osumania"
        bad = pack / "facets" / "lock" / "osumania.json"
        doc = json.loads(bad.read_text())
        doc["data"]["path"] = "lock/missing"
        doc["kind"] = "colors"
        bad.write_text(json.dumps(doc))
        errs = validate_v2(pack, BUILTIN, [self.new / "Packs"])
        self.assertTrue(any("doesn't match its folder" in e for e in errs), errs)
        self.assertTrue(any("lock/missing not found" in e for e in errs), errs)


def _pair_repo(root: Path) -> str:
    """qylock upstream with a declared pair (osu / osumania: one background,
    two lock designs) and a single theme."""
    git_repo, make_png, two_tone = TI.git_repo, TI.make_png, TI.two_tone
    bg = make_png(32, 32, two_tone)
    files = {"README.md": "qylock"}
    for name, qml in (("osu", "Item {}"), ("osumania", "Item { id: mania }"), ("still", "Item {}")):
        files[f"themes/{name}/Main.qml"] = "import QtQuick\n" + qml + "\n"
        files[f"themes/{name}/metadata.desktop"] = f"[SddmGreeterTheme]\nName={name}\nMainScript=Main.qml\n"
        files[f"themes/{name}/theme.conf"] = "[General]\nbackground=bg.png\n"
        files[f"themes/{name}/bg.png"] = bg if name != "still" else make_png(32, 32, lambda x, y: (240, 240, 230))
    return git_repo(root, files)


class ImportV2(Home):
    """The importers write v2: cozytile → one theme with variants, qylock →
    a theme per design with VARIANT_OF pairs as variants."""

    def setUp(self):
        super().setUp()
        cozytile_repo = TI.cozytile_repo
        shutil.rmtree(self.old)  # an empty machine: packs go to the data dir
        self.user = self.home / ".local" / "share" / "loft" / "themes"
        os.environ["LOFT_COZYTILE_URL"] = cozytile_repo(self.tmp / "cozytile")
        os.environ["LOFT_QYLOCK_URL"] = _pair_repo(self.tmp / "qylock")
        self.noff = mock.patch.object(palette, "have_ffmpeg", return_value=False)
        self.noff.start()

    def tearDown(self):
        self.noff.stop()
        super().tearDown()

    def theme(self, pack: str) -> dict:
        return json.loads((self.user / pack / "themes" / f"{pack}.json").read_text())

    def test_cozytile(self):
        rc, out, err = loft("theme", "install", "--list", "cozytile:")
        self.assertEqual([line.split()[0] for line in out.splitlines()], ["cozytile@carbon", "cozytile"])
        # A variant brings its theme's base (Sakura: the first of the rice upstream has).
        rc, out, err = loft("theme", "install", "cozytile:carbon")
        self.assertEqual(rc, 0, err)
        self.assertEqual(sorted(p.name for p in self.user.iterdir()), ["cozytile"])
        t = self.theme("cozytile")
        self.assertEqual((t["base"]["id"], [v["id"] for v in t["variants"]]), ("sakura", ["carbon"]))
        self.assertEqual(t["appearance"], {"dark": "sakura", "light": "carbon"})
        self.assertEqual(t["aliases"], ["cozytile-sakura", "cozytile-carbon@carbon"])
        self.assertEqual(t["facets"]["material"], "material:imported")
        pack = self.user / "cozytile"
        self.assertFalse((pack / "sakura" / "theme.json").exists(), "no v1 files in a v2 pack")
        self.assertTrue((pack / "sakura" / "apps" / "spicetify.ini").is_file())
        colors = json.loads((pack / "facets" / "colors" / "sakura.json").read_text())
        self.assertEqual(colors["apps"], "sakura/apps")
        self.assertEqual(validate_v2(pack, BUILTIN), [])
        # The palette's Spotify scheme travels with the variant's colors.
        out_dir = self.tmp / "r"
        self.assertEqual(loft("theme", "render", "cozytile-sakura", str(out_dir))[0], 0)
        self.assertIn("[sakura]", (out_dir / "spicetify.ini").read_text())
        self.assertEqual(json.loads((out_dir / "manifest.json").read_text())["name"], "cozytile-sakura")
        self.assertEqual(loft("theme", "render", "cozytile@carbon", str(self.tmp / "c"))[0], 0)

        rc, out, _ = loft("theme", "install", "cozytile:all")
        self.assertIn("skipped", out)
        rc, _, err = loft("theme", "install", "cozytile:carbon")
        self.assertEqual(rc, 1)
        self.assertIn("--force", err)
        (pack / "marker").write_text("x")
        self.assertEqual(loft("theme", "install", "--force", "cozytile:Carbon")[0], 0)
        self.assertFalse((pack / "marker").exists())
        self.assertEqual(loft("theme", "update", "cozytile")[0], 0)
        self.assertEqual([p.name for p in self.user.iterdir()], ["cozytile"])  # no staging leftovers
        self.assertEqual(loft("theme", "apply", "cozytile@carbon")[0], 0)
        self.assertEqual(loft("theme", "current")[1].strip(), "cozytile-carbon")

    def test_qylock_pairs(self):
        rc, out, err = loft("theme", "install", "qylock:osumania")
        self.assertEqual(rc, 0, err)
        self.assertEqual(sorted(p.name for p in self.user.iterdir()), ["qylock-osu"])
        t = self.theme("qylock-osu")
        self.assertEqual((t["base"]["id"], [v["id"] for v in t["variants"]]), ("osu", ["mania"]))
        # Same background → the same colors and wallpapers: only the lock differs.
        self.assertEqual(list(t["variants"][0]["facets"]), ["lock"])
        self.assertEqual(t["aliases"], ["qylock-osumania@mania"])
        self.assertEqual(t["facets"]["material"], "material:imported-dense")
        self.assertTrue((self.user / "qylock-osu" / "lock" / "qylock" / "Main.qml").is_file())
        self.assertTrue((self.user / "qylock-osu" / "mania" / "lock" / "qylock" / "Main.qml").is_file())
        self.assertEqual(validate_v2(self.user / "qylock-osu", BUILTIN), [])
        self.assertEqual(loft("theme", "install", "qylock:all")[0], 0)
        self.assertEqual(sorted(p.name for p in self.user.iterdir()), ["qylock-osu", "qylock-still"])
        self.assertNotIn("variants", self.theme("qylock-still"))
        rc, _, err = loft("theme", "render", "qylock-osumania", str(self.tmp / "m"))
        self.assertEqual(rc, 0, err)
        m = json.loads((self.tmp / "m" / "manifest.json").read_text())
        self.assertEqual((m["name"], m["lock"]["path"]), ("qylock-osumania", str((self.user / "qylock-osu" / "mania" / "lock" / "qylock").resolve())))

    def test_v1_fallback(self):
        rc, _, err = loft("theme", "install", "--v1", "qylock:still")
        self.assertEqual(rc, 0, err)
        self.assertTrue((self.user / "qylock-still" / "theme.json").is_file())
        self.assertFalse((self.user / "qylock-still" / "pack.json").exists())


if __name__ == "__main__":
    unittest.main()
