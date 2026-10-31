"""The themes index (format 2): reading, lookup and search (index.py), the
generator (indexgen.py, `loft theme index build`), `loft theme
browse/search/info` and `install NAME` (indexcmds.py).

Offline: the index is a local file (LOFT_THEME_INDEX), the importers'
upstreams and the loft-themes repo are small local git repos.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from loft import index, indexgen, palette
from test_importers import cozytile_repo, git_repo, loft, qylock_repo
from test_vibes import GREEN_DARK, PINK_DARK

ROOT = Path(__file__).resolve().parent.parent


def write(path: Path, data) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data) if isinstance(data, (dict, list)) else data)
    return path


def v1_pack(root: Path, name: str, pal: dict, polarity: str = "dark") -> Path:
    d = root / name
    write(d / "theme.json", {"polarity": polarity, "palette": pal})
    write(d / "manifest.json", {"name": name, "author": "t", "version": "1.0.0", "license": "CC0-1.0", "description": f"{name} pack"})
    return d


INDEX = {
    "version": 2,
    "repo": "https://example.invalid/loft-themes",
    "importers": {"qylock": {"source": "https://github.com/Darkkal44/qylock"}},
    "entries": [
        {"name": "moss", "title": "Moss", "collection": "loft-themes", "theme": "moss", "tags": ["green"],
         "source": {"git": "https://example.invalid/loft-themes", "rev": "main", "path": "packs/moss"}},
        {"name": "cozytile-sakura", "title": "Cozytile Sakura", "collection": "cozytile", "theme": "cozytile@sakura",
         "source": {"importer": "cozytile", "id": "Sakura"},
         "curated": {"polarity": "dark", "palette": {"accent": "#FF00AA", "bogus": "#000000", "text": "nope"}}},
        {"name": "cozytile-carbon", "title": "Cozytile Carbon", "collection": "cozytile", "theme": "cozytile@carbon",
         "source": {"importer": "cozytile", "id": "Carbon", "rev": "abc123"}},
        {"name": "qylock-pixel-sakura", "title": "pixel-sakura", "collection": "qylock", "theme": "qylock-pixel-sakura",
         "source": {"importer": "qylock", "id": "pixel-sakura"}},
        {"name": "broken"},
    ],
    "vibes": [{"name": "blossom", "packs": ["cozytile-sakura", "qylock-pixel-sakura"]}],
}  # fmt: skip


class Reading(unittest.TestCase):
    def test_entries_normalized(self):
        es = index.entries(INDEX)
        self.assertEqual([e["name"] for e in es], ["moss", "cozytile-sakura", "cozytile-carbon", "qylock-pixel-sakura"])
        self.assertEqual(es[1]["tags"], [])

    def test_v1_index_still_reads(self):
        v1 = {
            "version": 1,
            "packs": {"moss": {"source": "https://example.invalid/moss.git"}},
            "importers": {"cozytile": {"source": "x", "themes": ["Sakura", "Carbon"]}, "qylock": {"source": "y"}},
        }
        es = {e["name"]: e for e in index.entries(v1)}
        self.assertEqual(sorted(es), ["cozytile-carbon", "cozytile-sakura", "moss"])
        self.assertEqual(index.install_ref(es["moss"]), ("git", "https://example.invalid/moss.git", None, None))
        self.assertEqual(index.install_ref(es["cozytile-sakura"])[1], "cozytile:Sakura")

    def test_find(self):
        self.assertEqual(index.find(INDEX, "MOSS")["name"], "moss")
        self.assertEqual(index.find(INDEX, "cozytile@sakura")["name"], "cozytile-sakura")
        self.assertEqual(index.find(INDEX, "qylock:pixel-sakura")["name"], "qylock-pixel-sakura")
        self.assertEqual(index.find(INDEX, "pixel-sakura")["name"], "qylock-pixel-sakura")
        self.assertEqual(index.find(INDEX, "carbon")["name"], "cozytile-carbon")
        with self.assertRaisesRegex(index.IndexLookupError, "did you mean cozytile-sakura"):
            index.find(INDEX, "cozytile-sakur")
        with self.assertRaisesRegex(index.IndexLookupError, "no 'zzz'"):
            index.find(INDEX, "zzz")

    def test_find_ambiguous(self):
        idx = {"entries": [{"name": "a-x", "title": "X", "source": {"git": "u"}}, {"name": "b-x", "title": "X", "source": {"git": "u"}}]}
        with self.assertRaisesRegex(index.IndexLookupError, "ambiguous"):
            index.find(idx, "x")

    def test_install_ref(self):
        self.assertEqual(index.install_ref(index.find(INDEX, "moss")), ("git", "https://example.invalid/loft-themes", "main", "packs/moss"))
        self.assertEqual(index.install_ref(index.find(INDEX, "cozytile-carbon"))[1], "cozytile:Carbon@abc123")

    def test_search(self):
        names = lambda q, c=None: [e["name"] for e in index.search(INDEX, q, c)]  # noqa: E731
        self.assertEqual(names(""), ["moss", "cozytile-carbon", "cozytile-sakura", "qylock-pixel-sakura"])
        self.assertEqual(names("sakura"), ["cozytile-sakura", "qylock-pixel-sakura"])
        self.assertEqual(names("blossom"), ["cozytile-sakura", "qylock-pixel-sakura"])  # vibe group
        self.assertEqual(names("green"), ["moss"])  # tag
        self.assertEqual(names("sakura cozytile"), ["cozytile-sakura"])
        self.assertEqual(names("", "qylock"), ["qylock-pixel-sakura"])

    def test_curated(self):
        c = index.curated_for(INDEX, "cozytile-sakura")
        self.assertEqual(c, {"polarity": "dark", "palette": {"accent": "#ff00aa"}})
        self.assertIsNone(index.curated_for(INDEX, "moss"))
        self.assertIsNone(index.curated_for({}, "cozytile-sakura"))
        theme = index.apply_curated({"polarity": "light", "palette": dict(PINK_DARK)}, c)
        self.assertEqual((theme["polarity"], theme["palette"]["accent"], theme["palette"]["bg"]), ("dark", "#ff00aa", PINK_DARK["bg"]))


class Env(unittest.TestCase):
    """A scratch HOME / state / user theme dir; the index is a local file."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.saved = dict(os.environ)
        self.user = self.tmp / "data" / "loft" / "themes"
        self.idx = self.tmp / "index.json"
        os.environ.update(
            {
                "HOME": str(self.tmp / "home"),
                "XDG_DATA_HOME": str(self.tmp / "data"),
                "LOFT_STATE_DIR": str(self.tmp / "state"),
                "LOFT_LIBRARY": "none",
                "LOFT_HOOKS": "none",
                "LOFT_THEME_INDEX": str(self.idx),
                "LOFT_IMPORT_FORMAT": "1",
            }
        )
        for k in ("LOFT_THEME_PATH", "LOFT_DATA_DIR"):
            os.environ.pop(k, None)
        self.noff = mock.patch.object(palette, "have_ffmpeg", return_value=False)
        self.noff.start()

    def tearDown(self):
        self.noff.stop()
        os.environ.clear()
        os.environ.update(self.saved)
        shutil.rmtree(self.tmp)


@unittest.skipUnless(shutil.which("git"), "needs git")
class Generator(Env):
    def themes_repo(self) -> Path:
        repo = self.tmp / "loft-themes"
        v1_pack(repo / "packs", "moss", GREEN_DARK)
        write(repo / "packs" / "moss" / "preview.png", "png")
        write(repo / "packs" / "notapack" / "README.md", "hi")
        write(
            repo / "catalog.json",
            {
                "repo": "https://github.com/Codys-Wright/loft-themes",
                "rev": "main",
                "importers": {"cozytile": {"source": "https://github.com/Darkkal44/Cozytile"}, "qylock": {}},
                "entries": {
                    "cozytile-sakura": {"tags": ["pink"], "curated": {"palette": {"accent": "#ff00aa"}}},
                    "qylock-solid": {"hidden": True},
                    "nope": {"title": "x"},
                },
                "vibes": [{"name": "blossom", "packs": ["cozytile-sakura", "qylock-still", "absent"]}],
            },
        )
        return repo

    def test_build(self):
        os.environ["LOFT_COZYTILE_URL"] = cozytile_repo(self.tmp / "cozytile")
        os.environ["LOFT_QYLOCK_URL"] = qylock_repo(self.tmp / "qylock")
        repo = self.themes_repo()
        logs: list[str] = []
        data = indexgen.build(repo, builtin=ROOT / "packs", extract={"cozytile"}, log=logs.append)
        self.assertEqual(data["version"], 2)
        es = {e["name"]: e for e in data["entries"]}
        self.assertEqual(data["entries"][0]["name"], "moss")  # the repo's own packs first
        moss = es["moss"]
        self.assertEqual(moss["source"], {"git": "https://github.com/Codys-Wright/loft-themes", "rev": "main", "path": "packs/moss"})
        self.assertEqual(moss["preview"]["image"], "https://raw.githubusercontent.com/Codys-Wright/loft-themes/main/packs/moss/preview.png")
        self.assertEqual((moss["preview"]["palette"]["bg"], moss["preview"]["paletteFrom"]), (GREEN_DARK["bg"], "pack"))
        self.assertNotIn("notapack", es)
        # Importer entries: the v1 pack name, what it becomes in format 2, extracted palettes (cozytile only).
        self.assertEqual(es["cozytile-carbon"]["theme"], "cozytile@carbon")
        self.assertEqual(es["cozytile-carbon"]["source"], {"importer": "cozytile", "id": "Carbon"})
        self.assertEqual(es["cozytile-carbon"]["preview"]["paletteFrom"], "upstream")
        self.assertIn("qylock-still", es)
        self.assertNotIn("preview", es["qylock-still"])
        self.assertNotIn("qylock-solid", es)  # hidden
        sakura = es["cozytile-sakura"]
        self.assertEqual(sakura["curated"], {"palette": {"accent": "#ff00aa"}})
        self.assertEqual(sakura["preview"]["paletteFrom"], "upstream")  # derived; readers lay `curated` over it
        self.assertEqual((index.preview(sakura)["palette"]["accent"], index.preview(sakura)["paletteFrom"]), ("#ff00aa", "curated"))
        self.assertEqual(sakura["preview"]["palette"]["bg"], "#282738")  # the rest stays derived
        self.assertEqual(sakura["tags"], ["pink"])
        self.assertEqual(set(data["importers"]), {"cozytile", "qylock"})
        self.assertRegex(data["importers"]["qylock"]["commit"], "^[0-9a-f]{40}$")
        self.assertTrue(any("entries.nope" in m for m in logs))
        self.assertTrue(any("'absent'" in m for m in logs))

        # Through the CLI: write, then --check; a regenerated index keeps the
        # extracted palettes and is byte-identical.
        rc, out, err = loft("theme", "index", "build", str(repo), "--extract", "cozytile")
        self.assertEqual(rc, 0, err)
        first = (repo / "index.json").read_text()
        rc, out, err = loft("theme", "index", "build", str(repo), "--check")
        self.assertEqual(rc, 0, err)
        self.assertIn("up to date", out)
        # Offline: the importer entries come from the previous index.
        os.environ["LOFT_QYLOCK_URL"] = f"file://{self.tmp}/missing"
        rc, out, err = loft("theme", "index", "build", str(repo), "-o", str(self.tmp / "off.json"))
        self.assertEqual(rc, 0, err)
        self.assertIn("keeping its previous entries", err)
        self.assertEqual((self.tmp / "off.json").read_text(), first)
        self.assertEqual(loft("theme", "index", "build", str(repo), "--no-importers", "--check")[0], 0)
        write(repo / "catalog.json", dict(json.loads((repo / "catalog.json").read_text()), rev="v2"))
        rc, out, err = loft("theme", "index", "build", str(repo), "--no-importers", "--check")
        self.assertEqual(rc, 1)
        self.assertIn("out of date", err)

    def test_bad_curated(self):
        repo = self.tmp / "r"
        v1_pack(repo / "packs", "moss", GREEN_DARK)
        write(repo / "catalog.json", {"importers": {}, "entries": {"moss": {"curated": {"palette": {"accent": "red"}}}}})
        with self.assertRaisesRegex(indexgen.BuildError, "curated"):
            indexgen.build(repo, log=lambda m: None)

    def test_v2_pack(self):
        repo = self.tmp / "r"
        shutil.copytree(ROOT / "packs" / "loft", repo / "packs" / "mine")
        meta = json.loads((repo / "packs" / "mine" / "pack.json").read_text())
        write(repo / "packs" / "mine" / "pack.json", dict(meta, id="mine", name="Mine"))
        for f in (repo / "packs" / "mine" / "themes").glob("*.json"):
            f.unlink()
        theme = json.loads((ROOT / "packs" / "loft" / "themes" / "loft.json").read_text())
        write(repo / "packs" / "mine" / "themes" / "mine.json", {k: v for k, v in dict(theme, id="mine", name="Mine").items() if k != "aliases"})
        write(repo / "catalog.json", {"repo": "https://example.invalid/t", "importers": {}})
        data = indexgen.build(repo, builtin=ROOT / "packs", log=lambda m: None)
        (e,) = data["entries"]
        self.assertEqual((e["name"], e["title"], e["theme"]), ("mine", "Mine", "mine"))
        self.assertEqual(e["source"]["path"], "packs/mine")
        self.assertIn(e["preview"]["polarity"], ("dark", "light"))
        self.assertEqual(len(e["preview"]["palette"]), 10)


@unittest.skipUnless(shutil.which("git"), "needs git")
class Commands(Env):
    def setUp(self):
        super().setUp()
        os.environ["LOFT_COZYTILE_URL"] = cozytile_repo(self.tmp / "cozytile")
        os.environ["LOFT_QYLOCK_URL"] = qylock_repo(self.tmp / "qylock")
        # The loft-themes repo, with one pack of its own.
        src = self.tmp / "themes-src"
        v1_pack(src / "packs", "moss", GREEN_DARK)
        self.repo_url = git_repo(src, {"README.md": "loft-themes"})
        self.index = {
            "version": 2,
            "entries": [
                {"name": "moss", "title": "Moss", "collection": "loft-themes", "theme": "moss", "source": {"git": self.repo_url, "rev": "main", "path": "packs/moss"}},
                {"name": "cozytile-sakura", "title": "Cozytile Sakura", "collection": "cozytile", "theme": "cozytile@sakura",
                 "source": {"importer": "cozytile", "id": "Sakura"}, "curated": {"palette": {"accent": "#ff00aa"}}},
                {"name": "cozytile-carbon", "title": "Cozytile Carbon", "collection": "cozytile", "theme": "cozytile@carbon", "source": {"importer": "cozytile", "id": "Carbon"}},
            ],
            "vibes": [{"name": "blossom", "packs": ["cozytile-sakura", "moss"]}],
        }  # fmt: skip
        write(self.idx, self.index)

    def test_browse_search_info(self):
        rc, out, err = loft("theme", "browse")
        self.assertEqual(rc, 0, err)
        self.assertEqual([line.split()[0] for line in out.splitlines()], ["moss", "cozytile-carbon", "cozytile-sakura"])
        rc, out, err = loft("theme", "search", "blossom", "--json")
        self.assertEqual(rc, 0, err)
        rows = json.loads(out)
        self.assertEqual([r["name"] for r in rows], ["moss", "cozytile-sakura"])
        self.assertEqual((rows[1]["install"], rows[1]["installed"]), ("cozytile:Sakura", False))
        rc, out, err = loft("theme", "info", "cozytile@sakura")
        self.assertEqual(rc, 0, err)
        self.assertIn("install      cozytile:Sakura", out)
        self.assertIn("curated      accent", out)
        self.assertEqual(loft("theme", "info", "nothing")[0], 1)
        rc, out, err = loft("theme", "index", "where", "--json")
        self.assertEqual(json.loads(out)["entries"], 3)

    def test_install_importer_entry_with_curated_palette(self):
        rc, out, err = loft("theme", "install", "sakura")
        self.assertEqual(rc, 0, err)
        self.assertIn("from the themes index (cozytile:Sakura)", out)
        pack = self.user / "cozytile-sakura"
        theme = json.loads((pack / "theme.json").read_text())
        self.assertEqual(theme["palette"]["accent"], "#ff00aa")  # curated
        self.assertEqual(theme["palette"]["bg"], "#282738")  # derived
        manifest = json.loads((pack / "manifest.json").read_text())
        self.assertEqual(manifest["upstream"]["palette"], "curated")
        self.assertIn("moss", manifest["vibes"]["wallpapers"])
        rc, out, err = loft("theme", "browse", "--installed")
        self.assertEqual([line.split()[0] for line in out.splitlines()], ["i"])
        self.assertIn("cozytile-sakura", out)
        rc, out, err = loft("theme", "list", "--available")
        self.assertEqual([line.split()[0] for line in out.splitlines()], ["moss", "cozytile-carbon"])

    def test_install_importer_entry_format2(self):
        os.environ.pop("LOFT_IMPORT_FORMAT")
        rc, out, err = loft("theme", "install", "cozytile@sakura")
        self.assertEqual(rc, 0, err)
        self.assertTrue((self.user / "cozytile" / "pack.json").is_file())
        rc, out, err = loft("theme", "browse", "--installed", "--json")
        self.assertIn("cozytile-sakura", [r["name"] for r in json.loads(out)])

    def test_install_git_entry(self):
        rc, out, err = loft("theme", "install", "moss")
        self.assertEqual(rc, 0, err)
        self.assertTrue((self.user / "moss" / "theme.json").is_file())
        self.assertEqual(json.loads((self.user / "moss" / "theme.json").read_text())["palette"]["bg"], GREEN_DARK["bg"])
        self.assertEqual(loft("theme", "install", "moss")[0], 1)  # already installed
        self.assertEqual(loft("theme", "install", "moss", "--force")[0], 0)

    def test_install_git_entry_at_commit(self):
        src = self.tmp / "themes-src"
        commit = subprocess.run(["git", "-C", str(src), "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
        self.index["entries"][0]["source"]["rev"] = commit
        write(self.idx, self.index)
        rc, out, err = loft("theme", "install", "moss")
        self.assertEqual(rc, 0, err)
        self.assertTrue((self.user / "moss" / "manifest.json").is_file())

    def test_unknown_and_disabled(self):
        rc, out, err = loft("theme", "install", "nothing-like-it")
        self.assertEqual(rc, 1)
        self.assertIn("no 'nothing-like-it' in the themes index", err)
        os.environ["LOFT_THEME_INDEX"] = "none"
        rc, out, err = loft("theme", "install", "moss")
        self.assertEqual(rc, 1)
        self.assertIn("LOFT_THEME_INDEX=none", err)
        rc, out, err = loft("theme", "browse")
        self.assertEqual(rc, 1)
        self.assertIn("off", err)
        os.environ["LOFT_THEME_INDEX"] = str(self.tmp / "missing.json")
        self.assertIn("no themes index", loft("theme", "install", "moss")[2])

    def test_local_dir_still_wins(self):
        # A name that is also a directory is a path, not an index entry.
        local = v1_pack(self.tmp / "cwd", "moss", PINK_DARK)
        cwd = os.getcwd()
        os.chdir(self.tmp / "cwd")
        try:
            rc, out, err = loft("theme", "install", "moss")
        finally:
            os.chdir(cwd)
        self.assertEqual(rc, 0, err)
        self.assertNotIn("themes index", out)
        self.assertEqual(json.loads((self.user / "moss" / "theme.json").read_text())["palette"]["bg"], json.loads((local / "theme.json").read_text())["palette"]["bg"])


if __name__ == "__main__":
    unittest.main()
