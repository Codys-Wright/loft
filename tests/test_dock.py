"""Unit tests for the dock helpers (cli/loft/dock.py): Exec parsing, recent
files per app (recently-used.xbel), docked folders, the trash and Open at
Login — all against scratch XDG dirs, never the real ones.
"""

from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from loft import dock


def xbel(entries) -> str:
    out = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<xbel version="1.0" xmlns:bookmark="http://www.freedesktop.org/standards/desktop-bookmarks" '
        'xmlns:mime="http://www.freedesktop.org/standards/shared-mime-info">',
    ]
    for path, mime, when, app, exe in entries:
        out.append(
            f'<bookmark href="file://{path}" added="{when}" modified="{when}" visited="{when}"><info>'
            f'<metadata owner="http://freedesktop.org"><mime:mime-type type="{mime}"/><bookmark:applications>'
            f'<bookmark:application name="{app}" exec="{exe}" modified="{when}" count="1"/>'
            "</bookmark:applications></metadata></info></bookmark>"
        )
    out.append("</xbel>")
    return "\n".join(out)


class Scratch(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="loft-dock-"))
        self.home = self.tmp / "home"
        self.data = self.tmp / "data"
        self.config = self.tmp / "config"
        for d in (self.home, self.data / "applications", self.config):
            d.mkdir(parents=True)
        env = {
            "HOME": str(self.home),
            "XDG_DATA_HOME": str(self.data),
            "XDG_CONFIG_HOME": str(self.config),
            "XDG_CACHE_HOME": str(self.tmp / "cache"),
            "XDG_DATA_DIRS": str(self.tmp / "sys"),
            "XDG_CONFIG_DIRS": str(self.tmp / "sysconf"),
            "XDG_RUNTIME_DIR": str(self.tmp / "run"),
        }
        (self.tmp / "run").mkdir()
        p = mock.patch.dict(os.environ, env)
        p.start()
        self.addCleanup(p.stop)

    def desktop(self, did, **keys):
        lines = ["[Desktop Entry]", "Type=Application"] + [f"{k}={v}" for k, v in keys.items()]
        f = self.data / "applications" / f"{did}.desktop"
        f.write_text("\n".join(lines) + "\n")
        return f


class ExecTest(unittest.TestCase):
    def test_exec_bin(self):
        self.assertEqual(dock.exec_bin("'org.gnome.Decibels %U'"), "org.gnome.Decibels")
        self.assertEqual(dock.exec_bin("'foot --app-id=x -e less %f'"), "foot")
        self.assertEqual(dock.exec_bin("env FOO=1 /nix/store/abc/bin/code %F"), "code")
        self.assertEqual(dock.exec_bin("flatpak run --branch=stable org.x.Y %U"), "org.x.Y")
        self.assertEqual(dock.exec_bin(""), "")

    def test_expand_exec(self):
        self.assertEqual(dock.expand_exec("app --x %F", ["/a b", "/c"]), [["app", "--x", "/a b", "/c"]])
        # %f with several files: one process each
        self.assertEqual(dock.expand_exec("app %f", ["/a", "/b"]), [["app", "/a"], ["app", "/b"]])
        self.assertEqual(dock.expand_exec("app %U", ["/a b"]), [["app", "file:///a%20b"]])
        self.assertEqual(dock.expand_exec("app %f", []), [["app"]])
        self.assertEqual(dock.expand_exec("app %i %c", [], name="App", icon="ic"), [["app", "--icon", "ic", "App"]])


class RecentsTest(Scratch):
    def test_matches_the_app_that_opened_the_file(self):
        notes = self.home / "notes.txt"
        notes.write_text("x")
        other = self.home / "plan.md"
        other.write_text("x")
        gone = self.home / "deleted.txt"
        self.desktop("org.test.Notes", Name="Notes", Exec="notes-app %F", MimeType="text/plain;")
        self.desktop("org.test.Files", Name="Files", Exec="files-app %U")
        self.desktop("org.test.Viewer", Name="Viewer", Exec="viewer %f", MimeType="text/markdown;")
        (self.data / "recently-used.xbel").write_text(
            xbel([
                # A file manager opening notes.txt with Notes: credit Notes, not the file manager.
                (notes, "text/plain", "2026-10-13T10:00:00Z", "org.test.Files", "&apos;notes-app %F&apos;"),
                (gone, "text/plain", "2026-10-13T11:00:00Z", "org.test.Notes", "notes-app %F"),
                # Opened with "the default app": nobody in particular.
                (other, "text/markdown", "2026-10-13T12:00:00Z", "browser", "gio open %u"),
            ])
        )  # fmt: skip
        (self.config / "mimeapps.list").write_text("[Default Applications]\ntext/markdown=org.test.Viewer.desktop\n")
        by = dock.recents()["byApp"]
        self.assertEqual([x["name"] for x in by["org.test.Notes"]], ["notes.txt"])  # deleted file dropped
        self.assertEqual(by["org.test.Notes"][0]["source"], "app")
        self.assertNotIn("org.test.Files", by)
        # Viewer is the default for Markdown: plan.md fills its list by type.
        self.assertEqual([(x["name"], x["source"]) for x in by["org.test.Viewer"]], [("plan.md", "type")])


class FolderTest(Scratch):
    def test_folder_listing_and_sorts(self):
        dl = self.home / "Downloads"
        dl.mkdir()
        (self.config / "user-dirs.dirs").write_text('XDG_DOWNLOAD_DIR="$HOME/Downloads"\n')
        for i, name in enumerate(["b.txt", "a.zip", "c.pdf"]):
            f = dl / name
            f.write_text("x")
            os.utime(f, (1000 + i, 1000 + i))
        (dl / ".hidden").write_text("x")
        (dl / "Sub").mkdir()
        res = dock.folder("xdg:DOWNLOAD", sort="name", thumbs=0)
        self.assertEqual(res["path"], str(dl))
        self.assertEqual(res["count"], 4)
        self.assertEqual([x["name"] for x in res["items"]], ["Sub", "a.zip", "b.txt", "c.pdf"])
        zipped = next(x for x in res["items"] if x["name"] == "a.zip")
        self.assertEqual((zipped["mime"], zipped["generic"]), ("application/zip", "package-x-generic"))
        res = dock.folder(str(dl), sort="modified", limit=2, thumbs=0)
        self.assertEqual([x["name"] for x in res["items"]][:1], ["Sub"])  # newest mtime first
        self.assertEqual(len(res["items"]), 2)
        self.assertFalse(dock.folder(str(self.home / "nope"))["exists"])

    def test_trash_count_and_empty(self):
        t = self.data / "Trash"
        (t / "files").mkdir(parents=True)
        (t / "info").mkdir()
        (t / "files" / "a.txt").write_text("x")
        (t / "files" / "dir").mkdir()
        (t / "info" / "a.txt.trashinfo").write_text("x")
        self.assertEqual(dock.trash_info()["count"], 2)
        res = dock.trash_empty()
        self.assertEqual(res["count"], 0)
        self.assertEqual(list((t / "info").iterdir()), [])


class AutostartTest(Scratch):
    def test_on_off_and_run(self):
        self.desktop("org.test.App", Name="App", Exec="true %U", Actions="x;")
        self.assertFalse(dock.autostart_enabled("org.test.App"))
        dock.autostart_set("org.test.App", True)
        f = self.config / "autostart" / "org.test.App.desktop"
        self.assertTrue(f.is_file())
        self.assertIn(f"{dock.MARK}=true", f.read_text())
        self.assertNotIn("Actions=", f.read_text())
        self.assertEqual(dock.autostart_list()["enabled"], ["org.test.App"])
        with mock.patch.object(dock, "_have", return_value=False):
            run = dock.autostart_run(once="sock", dry_run=True)
        self.assertEqual(run["started"], ["org.test.App"])
        dock.autostart_set("org.test.App", False)
        self.assertFalse(f.exists())

    def test_legacy_mark_is_still_ours(self):
        # Entries studio-linux (Loft's old name) wrote: run, and removed on off.
        self.desktop("org.test.Old", Name="Old", Exec="old")
        f = self.config / "autostart" / "org.test.Old.desktop"
        f.parent.mkdir(parents=True)
        f.write_text(f"[Desktop Entry]\nType=Application\nName=Old\nExec=old\n{dock.LEGACY_MARK}=true\n")
        with mock.patch.object(dock, "_have", return_value=False):
            self.assertEqual(dock.autostart_run(dry_run=True)["started"], ["org.test.Old"])
        dock.autostart_set("org.test.Old", False)
        self.assertFalse(f.exists())

    def test_users_own_and_system_entries_are_shadowed_not_deleted(self):
        self.desktop("org.test.Own", Name="Own", Exec="own")
        own = self.config / "autostart" / "org.test.Own.desktop"
        own.parent.mkdir(parents=True)
        own.write_text("[Desktop Entry]\nType=Application\nName=Own\nExec=own --minimized\n")
        dock.autostart_set("org.test.Own", False)
        self.assertIn("Hidden=true", own.read_text())
        self.assertIn("--minimized", own.read_text())
        dock.autostart_set("org.test.Own", True)
        self.assertNotIn("Hidden=true", own.read_text())

        sysdir = self.tmp / "sysconf" / "autostart"
        sysdir.mkdir(parents=True)
        (sysdir / "org.test.Sys.desktop").write_text("[Desktop Entry]\nType=Application\nName=Sys\nExec=sys\n")
        self.assertTrue(dock.autostart_enabled("org.test.Sys"))
        dock.autostart_set("org.test.Sys", False)
        self.assertFalse(dock.autostart_enabled("org.test.Sys"))
        self.assertTrue((sysdir / "org.test.Sys.desktop").is_file())
        dock.autostart_set("org.test.Sys", True)
        self.assertTrue(dock.autostart_enabled("org.test.Sys"))
        self.assertFalse((self.config / "autostart" / "org.test.Sys.desktop").exists())


class CliTest(Scratch):
    def test_cli_prints_json(self):
        from loft import cli

        out = []
        with mock.patch("builtins.print", lambda s, *a, **k: out.append(s)):
            self.assertEqual(cli.main(["dock", "trash"]), 0)
        self.assertEqual(json.loads(out[0])["count"], 0)


if __name__ == "__main__":
    unittest.main()
