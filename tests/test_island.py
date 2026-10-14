"""Unit tests for the Dynamic Island helpers (cli/loft/island.py): AI usage from fixture Claude
Code / Codex logs (counts only, incremental, deduplicated), the ICS parser and recurrence
expansion, join links, the download watcher, LRC parsing and timer durations. Scratch dirs
only — never the real ~/.claude, ~/.codex, calendars or Downloads.
"""

from __future__ import annotations

import io
import json
import os
import struct
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from unittest import mock

import island_fixtures as fx

from loft import island


def noon_today() -> float:
    return datetime.now().replace(hour=12, minute=0, second=0, microsecond=0).timestamp()


class Scratch(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="loft-island-"))
        self.env = mock.patch.dict(os.environ, {"LOFT_STATE_DIR": str(self.tmp / "state"), "HOME": str(self.tmp / "home"), "XDG_CONFIG_HOME": str(self.tmp / "config")})
        self.env.start()

    def tearDown(self):
        self.env.stop()


class AiUsage(Scratch):
    def setUp(self):
        super().setUp()
        self.now = noon_today()
        dirs = fx.make_ai(self.tmp / "ai", self.now)
        os.environ["LOFT_AI_CLAUDE_DIR"] = str(dirs["claude"])
        os.environ["LOFT_AI_CODEX_DIR"] = str(dirs["codex"])
        self.cache = self.tmp / "cache.json"

    def summary(self, now=None):
        return island.ai_summary(self.cache, now=now or self.now, procs=[])

    def test_claude_counts_each_response_once(self):
        c = self.summary()["claude"]
        self.assertTrue(c["available"])
        self.assertEqual(c["today"]["n"], 3)
        self.assertEqual(c["today"]["in"], 1000 + 2000 + 500)
        self.assertEqual(c["today"]["out"], 500 + 1500 + 800)
        self.assertEqual(c["today"]["cr"], 300000)
        self.assertEqual(c["today"]["total"], 3500 + 2800 + 20000 + 300000)
        self.assertGreater(c["today"]["cost"], 0)
        self.assertEqual(c["models"][0]["model"], "opus-5-5")
        # The 3-day-old response is in the week only when the week reaches back that far.
        self.assertGreaterEqual(c["week"]["n"], 3)
        self.assertIsNotNone(c["block"])
        self.assertLessEqual(c["block"]["start"], self.now - 2900)

    def test_cost_estimate(self):
        # Opus 5.5: $4 in, $20 out, $0.20 cache read, cache write 1.25× input.
        u = {"input_tokens": 1_000_000, "output_tokens": 1_000_000, "cache_creation_input_tokens": 1_000_000, "cache_read_input_tokens": 1_000_000}
        self.assertAlmostEqual(island.claude_cost("claude-opus-5-5", u), 4 + 20 + 5 + 0.2)
        self.assertAlmostEqual(island.claude_cost("claude-sonnet-4-5-20250929", {"input_tokens": 1_000_000}), 3)

    def test_incremental_and_no_double_count(self):
        first = self.summary()["claude"]["today"]
        again = self.summary()["claude"]["today"]
        self.assertEqual(first, again)
        # Append a new response; only it is read.
        f = next((self.tmp / "ai" / "claude" / "projects").glob("*/session-a.jsonl"))
        with f.open("a") as fh:
            fh.write(fx.claude_line(self.now - 60, "msg_9", "req_9", "claude-opus-5-5", 10, 20) + "\n")
        after = self.summary()["claude"]["today"]
        self.assertEqual(after["n"], first["n"] + 1)
        self.assertEqual(after["in"], first["in"] + 10)
        state = json.loads(self.cache.read_text())
        self.assertEqual(state["files"][str(f)]["offset"], f.stat().st_size)

    def test_partial_line_waits(self):
        self.summary()
        f = next((self.tmp / "ai" / "claude" / "projects").glob("*/session-a.jsonl"))
        line = fx.claude_line(self.now - 30, "msg_p", "req_p", "claude-opus-5-5", 7, 7)
        with f.open("a") as fh:
            fh.write(line[:40])
        n = self.summary()["claude"]["today"]["n"]
        with f.open("a") as fh:
            fh.write(line[40:] + "\n")
        self.assertEqual(self.summary()["claude"]["today"]["n"], n + 1)

    def test_codex_deltas_and_limits(self):
        x = self.summary()["codex"]
        self.assertEqual(x["today"]["n"], 2)  # the repeated total is skipped
        self.assertEqual(x["today"]["cr"], 18000)
        self.assertEqual(x["today"]["in"], 25000 - 18000)
        self.assertEqual(x["today"]["out"], 2000)
        self.assertEqual(x["limits"]["primary"]["usedPercent"], 12.5)
        self.assertEqual(x["limits"]["primary"]["windowMinutes"], 300)
        self.assertEqual(x["limits"]["secondary"]["usedPercent"], 31.0)
        self.assertEqual(x["limits"]["plan"], "plus")
        self.assertEqual(x["models"][0]["model"], "gpt-5-codex")

    def test_output_has_no_content(self):
        out = json.dumps(self.summary())
        self.assertNotIn(fx.SECRET, out)
        self.assertNotIn(fx.SECRET, self.cache.read_text())
        self.assertNotIn("aurora", out)  # no sessions passed → no project names

    def test_sessions_report_project_name_only(self):
        procs = [{"pid": 42, "tool": "claude", "cwd": "/home/me/projects/aurora", "started": self.now - 100}]
        r = island.ai_summary(self.cache, now=self.now, procs=procs)
        s = r["claude"]["sessions"][0]
        self.assertEqual(s["project"], "aurora")
        self.assertNotIn("/home/me", json.dumps(r))

    def test_blocks(self):
        b = {str(h): dict(island._empty_bucket(), n=1, out=10) for h in (100, 101, 104, 105, 111)}
        bl = island.blocks(b)
        self.assertEqual([x["start"] // 3600 for x in bl], [100, 105, 111])
        self.assertEqual(bl[0]["total"], 30)

    def test_agent_kind(self):
        self.assertEqual(island.agent_kind(["/nix/store/x-claude-code/bin/.claude-wrapped", "--resume"]), "claude")
        self.assertEqual(island.agent_kind(["claude"]), "claude")
        self.assertEqual(island.agent_kind(["node", "/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js"]), "claude")
        self.assertEqual(island.agent_kind(["/usr/bin/codex"]), "codex")
        self.assertEqual(island.agent_kind(["node", "/usr/lib/node_modules/@openai/codex/bin/codex.js"]), "codex")
        self.assertIsNone(island.agent_kind(["bash", "-c", "claude"]))
        self.assertIsNone(island.agent_kind(["vim", "claude.md"]))


class Calendar(Scratch):
    def setUp(self):
        super().setUp()
        self.now = noon_today()
        self.ics = fx.make_calendar(self.tmp / "work.ics", self.now)

    def events(self, days=2):
        return island.agenda("none", [str(self.ics)], days=days, now=self.now)

    def test_today_and_tomorrow(self):
        r = self.events()
        self.assertEqual(r["sources"], ["ics"])
        titles = [e["title"] for e in r["events"]]
        self.assertIn("Design review — island", titles)
        self.assertIn("Mix session — album B-sides", titles)
        self.assertIn("Team offsite", titles)
        self.assertNotIn("Cancelled thing", titles)
        # Standup today; tomorrow's is moved to 11:00.
        stand = [e for e in r["events"] if e["title"].startswith("Standup")]
        self.assertEqual([e["title"] for e in stand], ["Standup", "Standup (moved)"])
        moved = datetime.fromtimestamp(stand[1]["start"])
        self.assertEqual((moved.hour, moved.minute), (11, 0))
        self.assertEqual(r["calendars"], ["Work"])

    def test_join_links_and_all_day(self):
        ev = {e["title"]: e for e in self.events()["events"]}
        self.assertEqual(ev["Design review — island"]["joinUrl"], "https://meet.google.com/abc-defg-hij")
        self.assertEqual(ev["Standup"]["joinUrl"], "https://zoom.us/j/123456789")
        self.assertEqual(ev["Mix session — album B-sides"]["joinUrl"], "")
        self.assertTrue(ev["Team offsite"]["allDay"])
        self.assertEqual(ev["Design review — island"]["location"], "Studio B")
        self.assertNotIn("Agenda", json.dumps(ev))  # descriptions aren't passed on

    def test_exdate(self):
        r = island.agenda("none", [str(self.ics)], days=1, now=self.now - 86400)
        self.assertNotIn("Standup", [e["title"] for e in r["events"]])

    def test_rrule_weekly_monthly(self):
        start = datetime(2026, 1, 5, 10, 0).astimezone()  # a Monday
        lo, hi = start, start + timedelta(days=21)
        occ = island.expand_rrule(start, "FREQ=WEEKLY;BYDAY=MO,WE", lo, hi, set())
        self.assertEqual([d.day for d in occ], [5, 7, 12, 14, 19, 21])
        occ = island.expand_rrule(start, "FREQ=MONTHLY;BYDAY=-1FR;COUNT=3", lo, start + timedelta(days=100), set())
        self.assertEqual([(d.month, d.day) for d in occ], [(1, 30), (2, 27), (3, 27)])
        occ = island.expand_rrule(start, "FREQ=DAILY;INTERVAL=2;UNTIL=20260111T235959Z", lo, hi, set())
        self.assertEqual([d.day for d in occ], [5, 7, 9, 11])

    def test_folding_and_escapes(self):
        text = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:x\r\nDTSTART:20260105T100000Z\r\nSUMMARY:Long\r\n  title\\, with comma\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        _name, evs = island.parse_ics(text)
        self.assertEqual(island._text(evs[0], "SUMMARY"), "Long title, with comma")

    def test_khal_vdirs(self):
        cal = self.tmp / "cals" / "personal"
        cal.mkdir(parents=True)
        (cal / "a.ics").write_text(self.ics.read_text())
        conf = Path(os.environ["XDG_CONFIG_HOME"]) / "khal" / "config"
        conf.parent.mkdir(parents=True)
        conf.write_text(f"[calendars]\n[[mine]]\npath = {self.tmp}/cals/*\ntype = discover\n")
        r = island.agenda("khal", [], days=2, now=self.now)
        self.assertEqual(r["sources"], ["khal"])
        self.assertIn("Standup", [e["title"] for e in r["events"]])


class Downloads(Scratch):
    def test_progress_then_finished(self):
        d = self.tmp / "dl"
        d.mkdir()
        w = island.DownloadWatcher(d, totals=False)
        (d / "song.flac.crdownload").write_bytes(b"x" * 1000)
        active, done = w.scan(100.0)
        self.assertEqual(active[0]["name"], "song.flac")
        self.assertEqual(active[0]["size"], 1000)
        self.assertEqual(done, [])
        (d / "song.flac.crdownload").write_bytes(b"x" * 3000)
        active, _ = w.scan(101.0)
        self.assertEqual(active[0]["speed"], 2000)
        (d / "song.flac.crdownload").rename(d / "song.flac")
        active, done = w.scan(102.0)
        self.assertEqual(active, [])
        self.assertEqual(done, [{"name": "song.flac", "path": str(d / "song.flac"), "size": 3000}])

    def test_firefox_part_and_cancel(self):
        d = self.tmp / "dl"
        d.mkdir()
        w = island.DownloadWatcher(d, totals=False)
        (d / "a.zip").write_bytes(b"")
        (d / "a.zip.part").write_bytes(b"y" * 10)
        (d / "b.iso.part").write_bytes(b"y" * 10)
        active, _ = w.scan(1.0)
        self.assertEqual(sorted(a["name"] for a in active), ["a.zip", "b.iso"])
        (d / "a.zip").write_bytes(b"z" * 20)
        (d / "a.zip.part").unlink()
        (d / "b.iso.part").unlink()  # cancelled: no final file
        _, done = w.scan(2.0)
        self.assertEqual([x["name"] for x in done], ["a.zip"])

    def test_aria2_total(self):
        d = self.tmp / "dl"
        d.mkdir()
        (d / "big.bin").write_bytes(b"q" * 500)
        ctl = struct.pack(">HII", 1, 0, 0) + struct.pack(">IQ", 1 << 20, 2000)
        (d / "big.bin.aria2").write_bytes(ctl)
        active, _ = island.DownloadWatcher(d).scan(5.0)
        self.assertEqual(active[0]["total"], 2000)
        self.assertEqual(active[0]["progress"], 0.25)

    def test_watch_once_prints_a_line(self):
        d = self.tmp / "dl"
        d.mkdir()
        buf = io.StringIO()
        island.watch_downloads(d, once=True, out=buf)
        self.assertEqual(json.loads(buf.getvalue())["active"], [])


class Misc(Scratch):
    def test_durations(self):
        p = island.parse_duration_spec
        self.assertEqual(p("25m"), 1500)
        self.assertEqual(p("1h30m"), 5400)
        self.assertEqual(p("90s"), 90)
        self.assertEqual(p("1:30"), 90)
        self.assertEqual(p("1:00:00"), 3600)
        self.assertEqual(p("10"), 600)
        self.assertEqual(p("2 min"), 120)
        self.assertIsNone(p("tea"))
        self.assertIsNone(p(""))

    def test_lrc(self):
        lines = island.parse_lrc("[00:01.50] first\n[00:03.00][00:10.00] chorus\nno stamp\n")
        self.assertEqual(lines, [[1500, "first"], [3000, "chorus"], [10000, "chorus"]])

    def test_lyrics_cached(self):
        calls = []

        def fetch(url):
            calls.append(url)
            return {"syncedLyrics": "[00:01.00] hi", "plainLyrics": "hi", "instrumental": False}

        r = island.lyrics("A", "B", duration=200, cache_dir=self.tmp / "ly", fetch=fetch)
        self.assertEqual(r["synced"], [[1000, "hi"]])
        island.lyrics("A", "B", duration=200, cache_dir=self.tmp / "ly", fetch=fetch)
        self.assertEqual(len(calls), 1)
        self.assertIn("artist_name=A", calls[0])


if __name__ == "__main__":
    unittest.main()
