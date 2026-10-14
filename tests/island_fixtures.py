"""Fixture data for the Dynamic Island helpers (cli/loft/island.py): fake Claude Code and Codex
logs, an ICS calendar and a download folder, all relative to a given `now` so the island shows
them as today's. Used by tests/test_island.py and for screenshots of a test session:

    python3 tests/island_fixtures.py OUTDIR      # OUTDIR/{claude,codex,calendar.ics,Downloads}

then LOFT_AI_CLAUDE_DIR=OUTDIR/claude LOFT_AI_CODEX_DIR=OUTDIR/codex LOFT_AI_PROCS=OUTDIR/procs.json,
and point Settings →
Dynamic Island at OUTDIR/calendar.ics and OUTDIR/Downloads. Nothing here is real data.
"""

from __future__ import annotations

import json
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

SECRET = "FIXTURE-SECRET-PROMPT-TEXT"


def iso(t: float) -> str:
    return datetime.fromtimestamp(t, timezone.utc).isoformat().replace("+00:00", "Z")


def claude_line(t: float, mid: str, rid: str, model: str, inp: int, out: int, cw: int = 0, cr: int = 0, text: str = "reply") -> str:
    return json.dumps(
        {
            "type": "assistant",
            "timestamp": iso(t),
            "requestId": rid,
            "sessionId": "s1",
            "cwd": "/home/me/projects/aurora",
            "message": {
                "id": mid,
                "model": model,
                "role": "assistant",
                "content": [{"type": "text", "text": text}],
                "usage": {"input_tokens": inp, "output_tokens": out, "cache_creation_input_tokens": cw, "cache_read_input_tokens": cr},
            },
        }
    )


def make_ai(root: Path, now: float) -> dict:
    """Claude: 3 responses today (one split over two lines), 1 three days ago; a user line with
    secret text. Codex: two token_count totals (one repeated) + rate limits."""
    claude = root / "claude" / "projects" / "-home-me-projects-aurora"
    claude.mkdir(parents=True, exist_ok=True)
    lines = [
        json.dumps({"type": "user", "timestamp": iso(now - 3000), "message": {"role": "user", "content": SECRET}}),
        claude_line(now - 2900, "msg_1", "req_1", "claude-opus-5-5", 1000, 500, 20000, 100000, text=SECRET),
        # The same response's second content block: counted once.
        claude_line(now - 2899, "msg_1", "req_1", "claude-opus-5-5", 1000, 500, 20000, 100000),
        claude_line(now - 1200, "msg_2", "req_2", "claude-opus-5-5", 2000, 1500, 0, 150000),
        claude_line(now - 600, "msg_3", "req_3", "claude-sonnet-5-5", 500, 800, 0, 50000),
    ]
    (claude / "session-a.jsonl").write_text("\n".join(lines) + "\n")
    old = claude / "session-b.jsonl"
    old.write_text(claude_line(now - 3 * 86400, "msg_0", "req_0", "claude-opus-5-5", 100, 100) + "\n")

    codex = root / "codex" / "sessions" / datetime.fromtimestamp(now).strftime("%Y/%m/%d")
    codex.mkdir(parents=True, exist_ok=True)

    def tc(t, total, used=12.5):
        return json.dumps(
            {
                "timestamp": iso(t),
                "type": "event_msg",
                "payload": {
                    "type": "token_count",
                    "info": {"total_token_usage": total, "last_token_usage": total},
                    "rate_limits": {
                        "primary": {"used_percent": used, "window_minutes": 300, "resets_at": int(now + 7200)},
                        "secondary": {"used_percent": 31.0, "window_minutes": 10080, "resets_at": int(now + 3 * 86400)},
                        "plan_type": "plus",
                    },
                },
            }
        )

    t1 = {"input_tokens": 10000, "cached_input_tokens": 6000, "output_tokens": 800, "reasoning_output_tokens": 300, "total_tokens": 10800}
    t2 = {"input_tokens": 25000, "cached_input_tokens": 18000, "output_tokens": 2000, "reasoning_output_tokens": 700, "total_tokens": 27000}
    clines = [
        json.dumps({"timestamp": iso(now - 1800), "type": "session_meta", "payload": {"cwd": "/home/me/projects/nimbus", "base_instructions": SECRET}}),
        json.dumps({"timestamp": iso(now - 1800), "type": "turn_context", "payload": {"model": "gpt-5-codex", "cwd": "/home/me/projects/nimbus"}}),
        json.dumps({"timestamp": iso(now - 1790), "type": "response_item", "payload": {"type": "message", "content": SECRET}}),
        tc(now - 1700, t1, 10.0),
        tc(now - 1699, t1, 10.0),  # repeated total: no new usage
        tc(now - 900, t2, 12.5),
    ]
    (codex / "rollout-fixture.jsonl").write_text("\n".join(clines) + "\n")
    return {"claude": root / "claude", "codex": root / "codex"}


def make_calendar(path: Path, now: float) -> Path:
    """Today: a meeting with a Meet link in 10 minutes, a daily standup (recurring, one day
    excluded), lunch; tomorrow: an all-day event and a moved instance of the standup."""
    lt = datetime.fromtimestamp(now).astimezone()

    def utc(d: datetime) -> str:
        return d.astimezone(timezone.utc).strftime("%Y%m%dT%H%M%SZ")

    soon = lt + timedelta(minutes=10)
    soon = soon.replace(second=0, microsecond=0)
    midnight = lt.replace(hour=0, minute=0, second=0, microsecond=0)
    standup = midnight - timedelta(days=7) + timedelta(hours=9, minutes=30)
    tomorrow = midnight + timedelta(days=1)
    moved_from = tomorrow + timedelta(hours=9, minutes=30)
    moved_to = tomorrow + timedelta(hours=11)
    excluded = midnight - timedelta(days=1) + timedelta(hours=9, minutes=30)
    later = lt.replace(minute=0, second=0, microsecond=0) + timedelta(hours=2)
    text = f"""BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Loft//fixture//EN
X-WR-CALNAME:Work
BEGIN:VEVENT
UID:design-review@fixture
DTSTART:{utc(soon)}
DTEND:{utc(soon + timedelta(minutes=30))}
SUMMARY:Design review — island
LOCATION:Studio B
DESCRIPTION:Agenda in the doc.\\nJoin: https://meet.google.com/abc-defg-hij
END:VEVENT
BEGIN:VEVENT
UID:standup@fixture
DTSTART:{utc(standup)}
DTEND:{utc(standup + timedelta(minutes=15))}
RRULE:FREQ=DAILY;COUNT=30
EXDATE:{utc(excluded)}
SUMMARY:Standup
URL:https://zoom.us/j/123456789
END:VEVENT
BEGIN:VEVENT
UID:standup@fixture
RECURRENCE-ID:{utc(moved_from)}
DTSTART:{utc(moved_to)}
DTEND:{utc(moved_to + timedelta(minutes=15))}
SUMMARY:Standup (moved)
END:VEVENT
BEGIN:VEVENT
UID:mix@fixture
DTSTART:{utc(later)}
DTEND:{utc(later + timedelta(hours=1))}
SUMMARY:Mix session — album B-sides
LOCATION:Control room
END:VEVENT
BEGIN:VEVENT
UID:cancelled@fixture
DTSTART:{utc(later + timedelta(hours=1))}
DTEND:{utc(later + timedelta(hours=2))}
SUMMARY:Cancelled thing
STATUS:CANCELLED
END:VEVENT
BEGIN:VEVENT
UID:offsite@fixture
DTSTART;VALUE=DATE:{tomorrow:%Y%m%d}
DTEND;VALUE=DATE:{tomorrow + timedelta(days=1):%Y%m%d}
SUMMARY:Team offsite
END:VEVENT
END:VCALENDAR
"""
    path.write_text(text.replace("\n", "\r\n"))
    return path


if __name__ == "__main__":
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "island-fixtures")
    now = time.time()
    make_ai(out, now)
    make_calendar(out / "calendar.ics", now)
    (out / "Downloads").mkdir(parents=True, exist_ok=True)
    # Pretend sessions (LOFT_AI_PROCS) so screenshots don't show real ones.
    (out / "procs.json").write_text(
        json.dumps(
            [
                {"pid": 1, "tool": "claude", "cwd": "/home/me/projects/aurora", "started": now - 1800},
                {"pid": 2, "tool": "claude", "cwd": "/home/me/projects/loft", "started": now - 600},
                {"pid": 3, "tool": "codex", "cwd": "/home/me/projects/nimbus", "started": now - 900},
            ]
        )
    )
    print(out.resolve())
