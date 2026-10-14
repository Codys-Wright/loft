"""Unit tests for the Utilities window's helpers: the port manager
(cli/loft/ports.py), the flake update summary (updates.py), the cleaner
(cleaner.py) and the media tools (media.py) — against fixture /proc text,
fixture lock files, a scratch home (LOFT_TEST_HOME) and generated media.
Nothing here touches the network, the Nix store or the real home.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from loft import cleaner, media, ports, updates

TCP = """  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 111 1 0000000000000000 100 0 0 10 0
   1: 00000000:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 222 1 0000000000000000 100 0 0 10 0
   2: 0100007F:1F90 0100007F:D3A2 01 00000000:00000000 00:00000000 00000000  1000        0 333 1 0000000000000000 20 4 30 10 -1
"""
TCP6 = """  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000000000000000000001000000:14E9 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 444 1 0000000000000000 100 0 0 10 0
   1: 00000000000000000000000000000000:0016 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 555 1 0000000000000000 100 0 0 10 0
"""
UDP = """   sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode ref pointer drops
  100: 00000000:14E9 00000000:0000 07 00000000:00000000 00:00000000 00000000  1000        0 666 2 0000000000000000 0
  101: 0100007F:9C40 0100007F:0035 01 00000000:00000000 00:00000000 00000000  1000        0 777 2 0000000000000000 0
"""


def fake_proc(root: Path, uid: int) -> None:
    """A /proc with the tables above and one of our processes owning inode 111."""
    net = root / "net"
    net.mkdir(parents=True)
    (net / "tcp").write_text(TCP)
    (net / "tcp6").write_text(TCP6)
    (net / "udp").write_text(UDP)
    (net / "udp6").write_text(UDP.splitlines()[0] + "\n")
    proj = root.parent / "work" / "site"
    (proj / "src").mkdir(parents=True)
    (proj / "package.json").write_text("{}")
    p = root / "4242"
    (p / "fd").mkdir(parents=True)
    os.symlink("socket:[111]", p / "fd" / "3")
    os.symlink("/dev/null", p / "fd" / "0")
    os.symlink(str(proj / "src"), p / "cwd")
    (p / "comm").write_text("node\n")
    (p / "cmdline").write_text("node\0/home/me/site/node_modules/.bin/vite\0--port\08080\0")
    (p / "status").write_text(f"Name:\tnode\nUid:\t{uid}\t{uid}\t{uid}\t{uid}\n")
    (p / "stat").write_text("4242 (node) S 1 4242 4242 0 -1")


class PortsTest(unittest.TestCase):
    def test_parse_net(self):
        rows = ports.parse_net(TCP, "tcp", False)
        self.assertEqual([(r["address"], r["port"], r["uid"]) for r in rows], [("127.0.0.1", 8080, 1000), ("0.0.0.0", 22, 0)])
        rows6 = ports.parse_net(TCP6, "tcp", True)
        self.assertEqual([(r["address"], r["port"]) for r in rows6], [("::1", 5353), ("::", 22)])
        udp = ports.parse_net(UDP, "udp", False)
        self.assertEqual([(r["port"], r["inode"]) for r in udp], [(5353, 666)])  # the connected one is left out

    def test_listening_groups_and_owns(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc = Path(tmp) / "proc"
            fake_proc(proc, 1000)
            res = ports.listening(proc=proc, uid=1000, home=str(Path(tmp) / "home"))
            by = {(r["proto"], r["port"], r["uid"]): r for r in res["ports"]}
            dev = by[("tcp", 8080, 1000)]
            self.assertTrue(dev["mine"] and dev["dev"] and dev["http"])
            self.assertEqual(dev["pid"], 4242)
            self.assertEqual(dev["process"]["project"]["name"], "site")
            self.assertEqual(dev["process"]["name"], "node")
            self.assertEqual(dev["url"], "http://localhost:8080")
            ssh = by[("tcp", 22, 0)]
            self.assertEqual(ssh["addresses"], ["0.0.0.0", "::"])  # v4 + v6 in one row
            self.assertIsNone(ssh["pid"])
            self.assertFalse(ssh["mine"] or ssh["dev"])
            self.assertFalse(by[("udp", 5353, 1000)]["dev"])  # UDP is never a dev server
            self.assertEqual(res["ports"][0]["port"], 8080)  # dev servers first

    def test_project_stops_at_home(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            (home / ".git").mkdir()
            (home / "notes").mkdir()
            self.assertIsNone(ports.project_of(str(home / "notes"), str(home)))
            (home / "notes" / "Cargo.toml").write_text("")
            self.assertEqual(ports.project_of(str(home / "notes"), str(home))["marker"], "Cargo.toml")

    def test_stop_refuses_others(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc = Path(tmp) / "proc"
            fake_proc(proc, os.getuid() + 1)
            r = ports.stop(4242, proc=proc)
            self.assertFalse(r["ok"])
            self.assertIn("not your process", r["error"])
            self.assertFalse(ports.stop(999999, proc=proc)["ok"])

    def test_stop_checks_port(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc = Path(tmp) / "proc"
            fake_proc(proc, os.getuid())
            with mock.patch("os.kill") as kill:
                self.assertFalse(ports.stop(4242, port=9999, proc=proc)["ok"])
                kill.assert_not_called()
                self.assertTrue(ports.stop(4242, port=8080, proc=proc)["ok"])
                kill.assert_called_once()

    def test_stop_real_child(self):
        child = subprocess.Popen(["sleep", "30"])
        try:
            r = ports.stop(child.pid)
            self.assertTrue(r["ok"], r)
            child.wait(timeout=5)
        finally:
            if child.poll() is None:
                child.kill()


def lock(nodes: dict, root_inputs: dict) -> dict:
    return {"nodes": {"root": {"inputs": root_inputs}, **nodes}, "root": "root", "version": 7}


def gh(owner, repo, rev, date, nar):
    return {"locked": {"type": "github", "owner": owner, "repo": repo, "rev": rev, "lastModified": date, "narHash": nar}, "original": {"type": "github", "owner": owner, "repo": repo}}


class UpdatesTest(unittest.TestCase):
    OLD = lock(
        {
            "nixpkgs": {"locked": {"type": "tarball", "url": "https://releases.nixos.org/nixpkgs/nixpkgs-26.11pre1080803.419fe0f449b3/nixexprs.tar.zst", "narHash": "sha256-a"}, "original": {"type": "tarball"}},
            "hm": gh("nix-community", "home-manager", "a" * 40, 100, "sha256-h1"),
            "same": gh("o", "same", "c" * 40, 50, "sha256-s"),
            "dep": gh("o", "dep", "d" * 40, 10, "sha256-d1"),
            "secrets": {"locked": {"type": "git", "url": "ssh://git@github.com/me/secrets.git", "rev": "e" * 40, "narHash": "sha256-x1"}, "original": {"type": "git", "ref": "main"}},
        },
        {"nixpkgs": "nixpkgs", "home-manager": "hm", "same": "same", "secrets": "secrets", "pinned": ["home-manager", "nixpkgs"]},
    )
    NEW = lock(
        {
            "nixpkgs": {"locked": {"type": "tarball", "url": "https://releases.nixos.org/nixpkgs/nixpkgs-26.11pre1088030.8edc0c72e3aa/nixexprs.tar.zst", "narHash": "sha256-b"}, "original": {"type": "tarball"}},
            "hm": gh("nix-community", "home-manager", "b" * 40, 200, "sha256-h2"),
            "same": gh("o", "same", "c" * 40, 50, "sha256-s"),
            "dep": gh("o", "dep", "f" * 40, 20, "sha256-d2"),
            "secrets": {"locked": {"type": "git", "url": "ssh://git@github.com/me/secrets.git", "rev": "9" * 40, "narHash": "sha256-x2"}, "original": {"type": "git", "ref": "main"}},
        },
        {"nixpkgs": "nixpkgs", "home-manager": "hm", "same": "same", "secrets": "secrets", "pinned": ["home-manager", "nixpkgs"]},
    )

    def test_describe(self):
        d = updates.describe(self.OLD["nodes"]["nixpkgs"])
        self.assertEqual((d["version"], d["rev"], d["github"]), ("26.11pre1080803", "419fe0f449b3", ["NixOS", "nixpkgs"]))
        s = updates.describe(self.OLD["nodes"]["secrets"])
        self.assertEqual((s["github"], s["ref"]), (["me", "secrets"], "main"))

    def test_compare(self):
        res = updates.compare_locks(self.OLD, self.NEW)
        by = {i["name"]: i for i in res["inputs"]}
        self.assertTrue(by["nixpkgs"]["changed"] and by["home-manager"]["changed"] and by["secrets"]["changed"])
        self.assertFalse(by["same"]["changed"])
        self.assertTrue(by["pinned"]["follows"])
        self.assertFalse(by["pinned"]["changed"])  # a follows is not its own update
        self.assertEqual(res["indirectChanged"], 1)  # "dep"

    def test_summarize_offline(self):
        out = updates.summarize(self.OLD, self.NEW, Path("/nonexistent"), commits=False, packages=False)
        self.assertEqual(out["changedCount"], 3)
        self.assertEqual(out["nixpkgs"], {"old": "26.11pre1080803", "new": "26.11pre1088030", "changed": True})

    def test_commit_counts_via_gh(self):
        fake = mock.Mock(returncode=0, stdout="42\n")
        with mock.patch("shutil.which", return_value="/bin/gh"), mock.patch("subprocess.run", return_value=fake) as run:
            out = updates.summarize(self.OLD, self.NEW, Path("/nonexistent"), commits=True, packages=False)
        by = {i["name"]: i for i in out["inputs"]}
        self.assertEqual(by["home-manager"]["commits"], 42)
        self.assertEqual(by["home-manager"]["url"], f"https://github.com/nix-community/home-manager/compare/{'a' * 40}...{'b' * 40}")
        self.assertTrue(any("repos/NixOS/nixpkgs/compare/419fe0f449b3...8edc0c72e3aa" in c.args[0] for c in run.call_args_list))

    def test_parse_name_and_bumps(self):
        h = "/nix/store/" + "x" * 32
        self.assertEqual(updates.parse_name(f"{h}-firefox-142.0.1"), ("firefox", "142.0.1"))
        self.assertEqual(updates.parse_name(f"{h}-acl-2.4.0-bin"), ("acl", "2.4.0"))
        self.assertEqual(updates.parse_name(f"{h}-python3-3.12.4-env"), ("python3", "3.12.4-env"))
        self.assertIsNone(updates.parse_name(f"{h}-etc"))
        bumps = updates.package_bumps({"btop": "1.4.5", "ark": "26.08.1", "same": "1.0", "gone": "2"}, {"btop": "1.4.7", "ark": "0.1.252", "same": "1.0", "gone": None})
        self.assertEqual(bumps, [{"name": "btop", "from": "1.4.5", "to": "1.4.7", "kind": "upgrade"}])

    def test_commands_and_copy(self):
        with tempfile.TemporaryDirectory() as tmp:
            f = Path(tmp) / "flake"
            (f / "mods").mkdir(parents=True)
            (f / "flake.nix").write_text("{}")
            (f / "flake.lock").write_text("{}")
            (f / "mods" / "a.nix").write_text("{}")
            (f / "untracked.nix").write_text("{}")
            (f / "justfile").write_text("switch:\n    true\n\nupdate:\n    nix flake update\n")
            self.assertEqual(updates.update_commands(f)[1:], ["just update", "just switch"])
            subprocess.run(["git", "init", "-q", str(f)], check=True)
            subprocess.run(["git", "-C", str(f), "add", "flake.nix", "flake.lock", "mods/a.nix", "justfile"], check=True)
            dst = Path(tmp) / "copy"
            self.assertEqual(updates.copy_flake(f, dst), 4)
            self.assertTrue((dst / "mods" / "a.nix").is_file())
            self.assertFalse((dst / "untracked.nix").exists())  # nix wouldn't see it either
            self.assertFalse((dst / ".git").exists())
            (f / "justfile").unlink()
            with mock.patch("shutil.which", return_value=None):
                self.assertIn("nixos-rebuild", updates.update_commands(f)[1])


class CleanerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name) / "home"
        self.state = Path(self.tmp.name) / "state"
        self.env = mock.patch.dict(os.environ, {"LOFT_TEST_HOME": str(self.home), "XDG_CACHE_HOME": "/should/be/ignored"})
        self.env.start()
        h = self.home
        for d in (".cache/mozilla/x", ".cache/thumbnails/large", ".cache/cliphist", ".cache/olds", ".config/discord/Cache", ".config/discord/Local Storage", ".local/share/Trash/files", ".local/share/Trash/info", "Downloads/Telegram Desktop"):
            (h / d).mkdir(parents=True, exist_ok=True)
        (self.state / "cache" / "thumbs").mkdir(parents=True)
        self.write(".cache/mozilla/x/blob", 50000)
        self.write(".cache/thumbnails/large/a.png", 9000)
        self.write(".cache/cliphist/db", 100)
        self.write(".cache/olds/old.bin", 7000, age_days=40)
        self.write(".cache/olds/new.bin", 7000)
        self.write(".config/discord/Cache/data", 30000)
        self.write(".config/discord/Local Storage/keep.db", 30000)
        self.write("Downloads/Telegram Desktop/old.mp4", 20000, age_days=90)
        self.write("Downloads/Telegram Desktop/new.jpg", 2000)
        self.write(".local/share/Trash/files/t.txt", 10)
        (h / ".local/share/Trash/info/t.txt.trashinfo").write_text("[Trash Info]\nPath=/t.txt\nDeletionDate=2020-01-01T00:00:00\n")
        (self.state / "cache" / "thumbs" / "x.png").write_bytes(b"x" * 5000)
        # A symlink out of the cache must never be followed.
        self.outside = Path(self.tmp.name) / "precious"
        self.outside.mkdir()
        (self.outside / "keep.txt").write_text("keep")
        os.symlink(self.outside, h / ".cache" / "mozilla" / "link")

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def write(self, rel, size, age_days=0):
        p = self.home / rel
        p.write_bytes(os.urandom(size))
        if age_days:
            t = time.time() - age_days * 86400
            os.utime(p, (t, t))

    def test_scan(self):
        d = cleaner.scan(self.state)
        self.assertTrue(d["testHome"])
        ids = {r["id"]: r for r in d["caches"]}
        self.assertIn("cache:mozilla", ids)
        self.assertEqual(ids["cache:mozilla"]["group"], "Browsers")
        self.assertEqual(ids["electron:discord"]["paths"], [str(self.home / ".config/discord/Cache")])
        self.assertEqual(ids["cache:cliphist"]["group"], "Keep")
        self.assertEqual(ids["trash"]["files"], 1)
        self.assertIn("loft", ids)
        self.assertEqual(d["suggestedRetention"], ["~/Downloads/Telegram Desktop"])
        self.assertGreaterEqual(ids["cache:mozilla"]["bytes"], 50000)

    def test_clear(self):
        r = cleaner.clear(["cache:mozilla", "electron:discord", "cache:cliphist", "trash", "loft", "nope"], self.state)
        by = {x["id"]: x for x in r["results"]}
        self.assertEqual(list((self.home / ".cache/mozilla").iterdir()), [])
        self.assertTrue((self.outside / "keep.txt").exists())  # the symlink went, not its target
        self.assertTrue((self.home / ".config/discord/Local Storage/keep.db").exists())
        self.assertFalse((self.home / ".config/discord/Cache/data").exists())
        self.assertIn("error", by["cache:cliphist"])
        self.assertTrue((self.home / ".cache/cliphist/db").exists())
        self.assertEqual(list((self.home / ".local/share/Trash/files").iterdir()), [])
        self.assertEqual(list((self.state / "cache").iterdir()), [])
        self.assertIn("error", by["nope"])

    def test_clear_group(self):
        r = cleaner.clear(["group:Browsers", "group:Keep"], self.state)
        self.assertEqual([x["id"] for x in r["results"]], ["cache:mozilla"])
        self.assertTrue((self.home / ".cache/cliphist/db").exists())

    def test_clear_older_than(self):
        cleaner.clear(["cache:olds"], self.state, older_than_days=30)
        self.assertEqual([p.name for p in (self.home / ".cache/olds").iterdir()], ["new.bin"])

    def test_retention_moves_to_trash(self):
        cfg = cleaner.load_config()
        cfg["retention"] = [{"path": "~/Downloads/Telegram Desktop", "days": 30}]
        cleaner.save_config(cfg)
        self.assertEqual(cleaner.retention_rows(cfg)[0]["files"], 1)
        r = cleaner.clear(["retention:0"], self.state)
        self.assertEqual(r["results"][0]["items"], 1)
        self.assertEqual([p.name for p in (self.home / "Downloads/Telegram Desktop").iterdir()], ["new.jpg"])
        self.assertTrue((self.home / ".local/share/Trash/files/old.mp4").exists())
        info = (self.home / ".local/share/Trash/info/old.mp4.trashinfo").read_text()
        self.assertIn("Path=" + str(self.home / "Downloads/Telegram%20Desktop/old.mp4").replace(" ", "%20"), info)

    def test_schedule_never_calls_systemctl_in_tests(self):
        with mock.patch("subprocess.run") as run:
            s = cleaner.schedule_set("weekly", 30, ["cache:thumbnails"], 30, True)
            run.assert_not_called()
        self.assertTrue(all(x.startswith("skipped") for x in s["systemctl"]))
        unit = (self.home / ".config/systemd/user/loft-cleaner.timer").read_text()
        self.assertIn("OnCalendar=weekly", unit)
        res = cleaner.run_scheduled(self.state)
        ids = [x["id"] for x in res["results"]]
        self.assertEqual(ids, ["cache:thumbnails", "trash"])  # thumbnails are new: nothing old to delete
        self.assertTrue((self.home / ".cache/thumbnails/large/a.png").exists())
        self.assertFalse((self.home / ".local/share/Trash/files/t.txt").exists())  # deleted in 2020
        off = cleaner.schedule_off()
        self.assertEqual(off["unitFiles"], [])

    def test_generations_reads_links(self):
        prof = self.home / ".local/state/nix/profiles"
        prof.mkdir(parents=True)
        for n in (1, 2, 3):
            os.symlink(f"/nix/store/{'a' * 32}-env-{n}", prof / f"profile-{n}-link")
        os.symlink("profile-3-link", prof / "profile")
        g = {x["id"]: x for x in cleaner.generations()}["profile"]
        self.assertEqual((g["count"], g["current"], g["older"]), (3, 3, 2))


class MediaTest(unittest.TestCase):
    def test_kinds_and_ops(self):
        self.assertEqual(media.kind_of(Path("a.MOV")), "video")
        self.assertEqual(media.kind_of(Path("a.webp")), "image")
        self.assertEqual(media.ops_for("video"), ["compress", "gif", "watermark", "audio"])
        self.assertEqual(media.ops_for("other"), [])

    def test_plans(self):
        with tempfile.TemporaryDirectory() as tmp:
            v = Path(tmp) / "clip.mp4"
            v.write_bytes(b"")
            (Path(tmp) / "clip-compressed.mp4").write_bytes(b"")
            argv, out, tool = media.plan("compress", v, {"preset": "small"}, None)
            self.assertEqual(out.name, "clip-compressed-2.mp4")  # never overwrites
            self.assertIn("-crf", argv)
            self.assertEqual(argv[argv.index("-crf") + 1], "30")
            argv, out, _ = media.plan("gif", v, {"fps": 12, "width": 480, "seconds": 3}, Path(tmp) / "out")
            self.assertEqual(out, Path(tmp) / "out" / "clip.gif")
            self.assertIn("palettegen", argv[argv.index("-vf") + 1])
            argv, out, _ = media.plan("audio", v, {"format": "flac"}, None)
            self.assertEqual(out.suffix, ".flac")
            img = Path(tmp) / "p.png"
            img.write_bytes(b"")
            argv, out, tool = media.plan("convert", img, {"format": "jpg", "maxSize": 800}, None)
            self.assertEqual((tool, out.name), ("magick", "p-converted.jpg"))
            self.assertIn("800x800>", argv)
            with self.assertRaises(ValueError):
                media.plan("compress", img, {}, None)
            with self.assertRaises(ValueError):
                media.plan("watermark", img, {}, None)
            argv, out, _ = media.plan("watermark", v, {"text": "a: 'b' 50%"}, None)
            vf = argv[argv.index("-vf") + 1]
            self.assertIn("a\\: ’b’ 50\\%", vf)

    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "ffmpeg not on PATH")
    def test_real_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "t.mp4"
            subprocess.run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=10:duration=1", "-pix_fmt", "yuv420p", str(src)], check=True)
            outs = media.run("gif", [str(src)], {"width": 160}, None)
            self.assertEqual(len(outs), 1)
            self.assertGreater(Path(outs[0]).stat().st_size, 0)


if __name__ == "__main__":
    unittest.main()
