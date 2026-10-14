"""The Dynamic Island's helpers (`loft island …`): data the shell shows but can't cheaply
compute in QML. Everything prints JSON for the shell.

  ai         Claude Code / Codex usage from their local logs: aggregate token counts and
             estimated cost (today, this week, the current 5-hour window), Codex's rate-limit
             windows, and the sessions running now. Read-only; prompt and reply content is never
             read into the output (only `usage` / `token_count` fields, model names and the
             project folder's name). Incremental: a cache keeps each log's read offset.
  calendar   upcoming events from local calendars: khal / vdirsyncer vdirs, Evolution Data
             Server's stores, and ICS files or URLs (fetched + cached). Recurrences expanded.
  downloads  watch a folder for browser downloads in progress (.crdownload, .part, …): one
             JSON line per change, then a `finished` entry when the file lands.
  lyrics     synced lyrics for a track from LRCLIB (lrclib.net; opt-in in the shell — this
             sends the artist, title, album and duration there). Cached.
  timer      start a countdown / stopwatch in the running shell (IPC `timers`).
"""

from __future__ import annotations

import calendar as _cal
import ctypes
import ctypes.util
import hashlib
import json
import os
import re
import select
import shutil
import sqlite3
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover
    ZoneInfo = None  # type: ignore

DAY = 86400
HOUR = 3600
# Hour buckets older than this are dropped from the AI cache (a week + today).
RETAIN_HOURS = 9 * 24
BLOCK_HOURS = 5


def _home() -> Path:
    return Path(os.environ.get("HOME") or Path.home())


def state_dir() -> Path:
    s = os.environ.get("LOFT_STATE_DIR")
    if s:
        return Path(s)
    return Path(os.environ.get("XDG_STATE_HOME") or _home() / ".local" / "state") / "loft"


def config_home() -> Path:
    return Path(os.environ.get("XDG_CONFIG_HOME") or _home() / ".config")


def _write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, separators=(",", ":")))
    os.replace(tmp, path)


def _read_json(path: Path, fallback):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return fallback


def _parse_ts(s) -> float | None:
    """ISO-8601 ('2026-10-14T09:30:00.123Z') → epoch seconds."""
    if not isinstance(s, str) or not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def local_midnight(now: float) -> float:
    d = datetime.fromtimestamp(now)
    return d.replace(hour=0, minute=0, second=0, microsecond=0).timestamp()


def week_start(now: float) -> float:
    """Monday 00:00, local time."""
    d = datetime.fromtimestamp(now).replace(hour=0, minute=0, second=0, microsecond=0)
    return (d - timedelta(days=d.weekday())).timestamp()


# ── AI usage ────────────────────────────────────────────────────────────────

# USD per million tokens: input, output, cache read. Cache writes cost 1.25× input
# (5-minute TTL) or 2× (1-hour TTL). Estimates of the API-equivalent price — a
# subscription doesn't pay these; the island labels them "≈".
CLAUDE_PRICES: list[tuple[str, tuple[float, float, float]]] = [
    ("fable", (10.0, 50.0, 0.25)),
    ("mythos", (10.0, 50.0, 0.25)),
    ("opus-5-5", (4.0, 20.0, 0.20)),
    ("opus-5", (5.0, 25.0, 0.50)),
    ("opus-4-8", (5.0, 25.0, 0.50)),
    ("opus-4-7", (5.0, 25.0, 0.50)),
    ("opus-4-6", (5.0, 25.0, 0.50)),
    ("opus-4-5", (5.0, 25.0, 0.50)),
    ("opus", (15.0, 75.0, 1.50)),  # Opus 4 / 4.1, Claude 3 Opus
    ("sonnet-5", (2.0, 10.0, 0.20)),
    ("sonnet", (3.0, 15.0, 0.30)),
    ("haiku-5", (0.10, 0.50, 0.01)),
    ("haiku-4", (1.0, 5.0, 0.10)),
    ("haiku", (0.80, 4.0, 0.08)),
]
CLAUDE_DEFAULT = (5.0, 25.0, 0.50)

# OpenAI models Codex uses: input, output, cached input.
CODEX_PRICES: list[tuple[str, tuple[float, float, float]]] = [
    ("mini", (0.25, 2.0, 0.025)),
    ("nano", (0.05, 0.40, 0.005)),
    ("gpt-5", (1.25, 10.0, 0.125)),
    ("o4", (1.10, 4.40, 0.275)),
    ("o3", (2.0, 8.0, 0.50)),
    ("gpt-4.1", (2.0, 8.0, 0.50)),
]
CODEX_DEFAULT = (1.25, 10.0, 0.125)


def _price(table, default, model: str) -> tuple[float, float, float]:
    m = (model or "").lower().replace(".", "-") if table is CLAUDE_PRICES else (model or "").lower()
    for key, p in table:
        if key in m:
            return p
    return default


def claude_cost(model: str, u: dict) -> float:
    pin, pout, pread = _price(CLAUDE_PRICES, CLAUDE_DEFAULT, model)
    cc = u.get("cache_creation") or {}
    w1h = int(cc.get("ephemeral_1h_input_tokens") or 0)
    w5m = int(u.get("cache_creation_input_tokens") or 0) - w1h
    return (
        int(u.get("input_tokens") or 0) * pin
        + int(u.get("output_tokens") or 0) * pout
        + max(0, w5m) * pin * 1.25
        + w1h * pin * 2
        + int(u.get("cache_read_input_tokens") or 0) * pread
    ) / 1e6


def ai_dirs() -> tuple[Path, Path]:
    claude = os.environ.get("LOFT_AI_CLAUDE_DIR") or os.environ.get("CLAUDE_CONFIG_DIR") or str(_home() / ".claude")
    codex = os.environ.get("LOFT_AI_CODEX_DIR") or os.environ.get("CODEX_HOME") or str(_home() / ".codex")
    return Path(claude).expanduser(), Path(codex).expanduser()


def _empty_bucket() -> dict:
    return {"in": 0, "out": 0, "cw": 0, "cr": 0, "cost": 0.0, "n": 0}


def _add(bucket: dict, **kw) -> None:
    for k, v in kw.items():
        bucket[k] = bucket.get(k, 0) + v


class AiCache:
    """Per-file read offsets + hourly buckets per tool, persisted between runs."""

    VERSION = 2

    def __init__(self, path: Path):
        self.path = path
        data = _read_json(path, {})
        if data.get("version") != self.VERSION:
            data = {}
        self.files: dict = data.get("files", {})
        self.hours: dict = data.get("hours", {"claude": {}, "codex": {}})
        self.seen: dict = data.get("seen", {})
        self.limits: dict = data.get("limits", {})
        self.models: dict = data.get("models", {"claude": {}, "codex": {}})

    def bucket(self, tool: str, ts: float) -> dict:
        h = str(int(ts // HOUR))
        return self.hours.setdefault(tool, {}).setdefault(h, _empty_bucket())

    def model_day(self, tool: str, ts: float, model: str, tokens: int) -> None:
        day = str(int(local_midnight(ts)))
        d = self.models.setdefault(tool, {}).setdefault(day, {})
        d[model] = d.get(model, 0) + tokens

    def prune(self, now: float) -> None:
        cutoff = int(now // HOUR) - RETAIN_HOURS
        for tool in self.hours:
            self.hours[tool] = {h: b for h, b in self.hours[tool].items() if int(h) >= cutoff}
        self.seen = {k: h for k, h in self.seen.items() if h >= cutoff}
        dcut = now - RETAIN_HOURS * HOUR
        for tool in self.models:
            self.models[tool] = {d: m for d, m in self.models[tool].items() if float(d) >= dcut}
        # Logs that are gone.
        self.files = {p: s for p, s in self.files.items() if os.path.exists(p)}

    def save(self) -> None:
        _write_json(
            self.path,
            {"version": self.VERSION, "files": self.files, "hours": self.hours, "seen": self.seen, "limits": self.limits, "models": self.models},
        )


def _new_lines(path: str, st: os.stat_result, cache: AiCache, kind: str):
    """Yield the complete lines appended to `path` since the last run (and remember where we
    stopped). A replaced or truncated file is read again from the start."""
    rec = cache.files.get(path)
    if rec is None or rec.get("ino") != st.st_ino or st.st_size < rec.get("offset", 0):
        rec = {"ino": st.st_ino, "offset": 0, "kind": kind}
        cache.files[path] = rec
    if st.st_size == rec["offset"]:
        return
    with open(path, "rb") as f:
        f.seek(rec["offset"])
        data = f.read()
    end = data.rfind(b"\n")
    if end < 0:
        return
    rec["offset"] += end + 1
    for raw in data[: end + 1].splitlines():
        if raw.strip():
            yield raw, rec


def _scan(root: Path, pattern: str, now: float):
    """Log files under root modified within the retention window."""
    if not root.is_dir():
        return
    cutoff = now - RETAIN_HOURS * HOUR
    for p in root.glob(pattern):
        try:
            st = p.stat()
        except OSError:
            continue
        if st.st_mtime >= cutoff:
            yield str(p), st


def read_claude(root: Path, cache: AiCache, now: float) -> dict:
    """Claude Code transcripts: ~/.claude/projects/<project>/<session>.jsonl (and subagent
    logs below them). Assistant lines carry message.usage; one API response can span several
    lines (one per content block) with the same message id + request id, counted once."""
    projects = root / "projects"
    activity: dict[str, float] = {}
    for path, st in _scan(projects, "**/*.jsonl", now):
        rel = Path(path).relative_to(projects)
        proj = rel.parts[0] if rel.parts else ""
        activity[proj] = max(activity.get(proj, 0), st.st_mtime)
        for raw, _rec in _new_lines(path, st, cache, "claude"):
            if b'"usage"' not in raw:
                continue
            try:
                o = json.loads(raw)
            except ValueError:
                continue
            if o.get("type") != "assistant":
                continue
            m = o.get("message") or {}
            u = m.get("usage")
            ts = _parse_ts(o.get("timestamp"))
            if not isinstance(u, dict) or ts is None:
                continue
            model = m.get("model") or ""
            if model == "<synthetic>":
                continue
            mid, rid = m.get("id"), o.get("requestId")
            if mid:
                key = hashlib.sha1(f"{mid}:{rid}".encode()).hexdigest()[:16]
                if key in cache.seen:
                    continue
                cache.seen[key] = int(ts // HOUR)
            tin = int(u.get("input_tokens") or 0)
            tout = int(u.get("output_tokens") or 0)
            tcw = int(u.get("cache_creation_input_tokens") or 0)
            tcr = int(u.get("cache_read_input_tokens") or 0)
            cost = o.get("costUSD")
            cost = float(cost) if isinstance(cost, (int, float)) else claude_cost(model, u)
            _add(cache.bucket("claude", ts), **{"in": tin, "out": tout, "cw": tcw, "cr": tcr, "cost": cost, "n": 1})
            cache.model_day("claude", ts, _short_model(model), tin + tout + tcw + tcr)
    return activity


def _short_model(model: str) -> str:
    m = re.sub(r"^claude-", "", model or "unknown")
    return re.sub(r"-\d{8}$", "", m)


TOKEN_FIELDS = ("input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens")


def read_codex(root: Path, cache: AiCache, now: float) -> None:
    """Codex rollouts: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl. token_count events carry
    the session's running total (deltas between them are this turn's usage; repeats are
    skipped) and the account's rate-limit windows."""
    for path, st in _scan(root / "sessions", "**/*.jsonl", now):
        for raw, rec in _new_lines(path, st, cache, "codex"):
            if b"token_count" not in raw and b"turn_context" not in raw:
                continue
            try:
                o = json.loads(raw)
            except ValueError:
                continue
            p = o.get("payload") or {}
            if not isinstance(p, dict):
                continue
            ts = _parse_ts(o.get("timestamp"))
            if o.get("type") == "turn_context":
                if isinstance(p.get("model"), str):
                    rec["model"] = p["model"]
                continue
            if p.get("type") != "token_count" or ts is None:
                continue
            rl = p.get("rate_limits")
            if isinstance(rl, dict) and ts >= cache.limits.get("ts", 0):
                cache.limits = {"ts": ts, "rate_limits": _codex_limits(rl, ts)}
            info = p.get("info")
            if not isinstance(info, dict):
                continue
            total = info.get("total_token_usage") or {}
            cur = {k: int(total.get(k) or 0) for k in TOKEN_FIELDS}
            prev = rec.get("total")
            if prev == cur:
                continue
            if prev and all(cur[k] >= prev.get(k, 0) for k in TOKEN_FIELDS):
                d = {k: cur[k] - prev.get(k, 0) for k in TOKEN_FIELDS}
            else:
                last = info.get("last_token_usage") or total
                d = {k: int(last.get(k) or 0) for k in TOKEN_FIELDS}
            rec["total"] = cur
            model = rec.get("model", "")
            cached = d["cached_input_tokens"]
            fresh = max(0, d["input_tokens"] - cached)
            pin, pout, pread = _price(CODEX_PRICES, CODEX_DEFAULT, model)
            cost = (fresh * pin + cached * pread + d["output_tokens"] * pout + d["cache_write_input_tokens"] * pin) / 1e6
            _add(
                cache.bucket("codex", ts),
                **{"in": fresh, "out": d["output_tokens"], "cw": d["cache_write_input_tokens"], "cr": cached, "cost": cost, "n": 1},
            )
            cache.model_day("codex", ts, model or "unknown", fresh + cached + d["output_tokens"])


def _codex_limits(rl: dict, ts: float) -> dict:
    out = {}
    for name in ("primary", "secondary"):
        w = rl.get(name)
        if not isinstance(w, dict):
            continue
        resets = w.get("resets_at")
        if not isinstance(resets, (int, float)) and isinstance(w.get("resets_in_seconds"), (int, float)):
            resets = ts + w["resets_in_seconds"]
        out[name] = {
            "usedPercent": float(w.get("used_percent") or 0),
            "windowMinutes": int(w.get("window_minutes") or 0),
            "resetsAt": float(resets) if isinstance(resets, (int, float)) else None,
        }
    if isinstance(rl.get("plan_type"), str):
        out["plan"] = rl["plan_type"]
    return out


def _sum(buckets: dict, lo: float, hi: float) -> dict:
    s = _empty_bucket()
    for h, b in buckets.items():
        t = int(h) * HOUR
        if lo <= t < hi:
            for k in s:
                s[k] += b.get(k, 0)
    s["total"] = s["in"] + s["out"] + s["cw"] + s["cr"]
    s["cost"] = round(s["cost"], 4)
    return s


def blocks(buckets: dict) -> list[dict]:
    """5-hour windows as Claude's plans count them: a window starts at the hour of the first
    message after the previous one ended, and lasts five hours."""
    out: list[dict] = []
    for h in sorted(int(k) for k, b in buckets.items() if b.get("n")):
        if not out or h >= out[-1]["h"] + BLOCK_HOURS:
            out.append({"h": h, "b": _empty_bucket()})
        b = buckets[str(h)]
        for k in out[-1]["b"]:
            out[-1]["b"][k] += b.get(k, 0)
    res = []
    for blk in out:
        b = blk["b"]
        res.append({"start": blk["h"] * HOUR, "end": (blk["h"] + BLOCK_HOURS) * HOUR, "total": b["in"] + b["out"] + b["cw"] + b["cr"], "cost": round(b["cost"], 4), "n": b["n"]})
    return res


def _hourly_today(buckets: dict, now: float) -> list[int]:
    lo = local_midnight(now)
    vals = [0] * 24
    for h, b in buckets.items():
        t = int(h) * HOUR
        if lo <= t < lo + DAY:
            i = int((t - lo) // HOUR)
            if 0 <= i < 24:
                vals[i] += b["in"] + b["out"] + b["cw"] + b["cr"]
    return vals


# ── running sessions (/proc) ────────────────────────────────────────────────


def _cmdline(pid: str) -> list[str]:
    try:
        return [a for a in Path(f"/proc/{pid}/cmdline").read_bytes().decode(errors="replace").split("\0") if a]
    except OSError:
        return []


def agent_kind(argv: list[str]) -> str | None:
    """'claude' / 'codex' when a command line is one of the agents' CLIs (not a tool
    process they spawned)."""
    if not argv:
        return None
    exe = os.path.basename(argv[0]).lstrip(".")
    exe = exe[: -len("-wrapped")] if exe.endswith("-wrapped") else exe
    if exe in ("claude", "claude-code"):
        return "claude"
    if exe == "codex" or exe.startswith("codex-x86_64") or exe.startswith("codex-aarch64"):
        return "codex"
    if exe in ("node", "bun") and len(argv) > 1:
        script = argv[1]
        if "claude-code" in script or os.path.basename(script) == "claude":
            return "claude"
        if "@openai/codex" in script or os.path.basename(script) == "codex":
            return "codex"
    return None


def _proc_stat(pid: str) -> tuple[int, int] | None:
    """(ppid, start time in clock ticks since boot)."""
    try:
        s = Path(f"/proc/{pid}/stat").read_text()
    except OSError:
        return None
    rest = s[s.rfind(")") + 2 :].split()
    try:
        return int(rest[1]), int(rest[19])
    except (IndexError, ValueError):
        return None


def running_sessions() -> list[dict]:
    uid = os.getuid()
    found: dict[int, dict] = {}
    try:
        boot = float(next(l.split()[1] for l in Path("/proc/stat").read_text().splitlines() if l.startswith("btime")))
    except (OSError, StopIteration, ValueError):
        boot = 0.0
    hz = os.sysconf("SC_CLK_TCK") if hasattr(os, "sysconf") else 100
    for d in Path("/proc").iterdir():
        if not d.name.isdigit():
            continue
        try:
            if d.stat().st_uid != uid:
                continue
        except OSError:
            continue
        kind = agent_kind(_cmdline(d.name))
        if not kind:
            continue
        st = _proc_stat(d.name)
        if st is None:
            continue
        try:
            cwd = os.readlink(f"/proc/{d.name}/cwd")
        except OSError:
            cwd = ""
        found[int(d.name)] = {"pid": int(d.name), "ppid": st[0], "tool": kind, "cwd": cwd, "started": boot + st[1] / hz}
    # A launcher and the binary it runs (node → native) are one session.
    out = []
    for pid, s in found.items():
        parent = found.get(s["ppid"])
        if parent and parent["tool"] == s["tool"]:
            continue
        out.append(s)
    return sorted(out, key=lambda s: s["started"])


def _procs_override() -> list[dict] | None:
    """$LOFT_AI_PROCS: "none" = don't look; a JSON file = these sessions instead (screenshots,
    tests). Unset = scan /proc."""
    v = os.environ.get("LOFT_AI_PROCS")
    if not v:
        return None
    if v == "none":
        return []
    data = _read_json(Path(v), [])
    return data if isinstance(data, list) else []


def _claude_project_key(cwd: str) -> str:
    # Claude Code names a project's folder after its path, non-alphanumerics → '-'.
    return re.sub(r"[^A-Za-z0-9]", "-", cwd)


def ai_summary(cache_path: Path | None = None, now: float | None = None, procs: list[dict] | None = None) -> dict:
    now = time.time() if now is None else now
    claude_root, codex_root = ai_dirs()
    cache = AiCache(cache_path or state_dir() / "cache" / "island-ai.json")
    activity = read_claude(claude_root, cache, now)
    read_codex(codex_root, cache, now)
    cache.prune(now)
    cache.save()

    today, week = local_midnight(now), week_start(now)
    if procs is None:
        procs = _procs_override()
    procs = running_sessions() if procs is None else procs
    sessions = []
    for s in procs:
        proj = os.path.basename(s.get("cwd", "").rstrip("/")) or "~"
        last = activity.get(_claude_project_key(s.get("cwd", ""))) if s["tool"] == "claude" else None
        sessions.append(
            {
                "tool": s["tool"],
                "project": proj,
                "pid": s.get("pid"),
                "started": s.get("started"),
                # Working = its transcript changed in the last minute.
                "busy": bool(last and now - last < 60),
            }
        )

    def tool_summary(tool: str, root: Path) -> dict:
        b = cache.hours.get(tool, {})
        models_today = cache.models.get(tool, {}).get(str(int(today)), {})
        out = {
            "available": root.is_dir(),
            "today": _sum(b, today, today + DAY),
            "week": _sum(b, week, week + 7 * DAY),
            "hourly": _hourly_today(b, now),
            "models": sorted(({"model": k, "tokens": v} for k, v in models_today.items()), key=lambda m: -m["tokens"])[:4],
            "sessions": [s for s in sessions if s["tool"] == tool],
        }
        bl = blocks(b)
        cur = bl[-1] if bl and bl[-1]["end"] > now else None
        done = [x for x in bl if x is not cur]
        busiest = max((x["total"] for x in done), default=0)
        out["block"] = cur and dict(cur, busiest=busiest, ofBusiest=round(cur["total"] / busiest, 3) if busiest else None)
        return out

    res = {"generated": now, "claude": tool_summary("claude", claude_root), "codex": tool_summary("codex", codex_root)}
    lim = cache.limits.get("rate_limits")
    if lim:
        # Drop windows that already reset.
        res["codex"]["limits"] = {k: v for k, v in lim.items() if not isinstance(v, dict) or not v.get("resetsAt") or v["resetsAt"] > now}
        res["codex"]["limitsAt"] = cache.limits.get("ts")
    return res


# ── calendar ────────────────────────────────────────────────────────────────

JOIN_RE = re.compile(
    r"https?://[^\s\"'<>\\]*(?:zoom\.us/(?:j|my|s|w)/|meet\.google\.com/|teams\.microsoft\.com/l/meetup-join|teams\.live\.com/meet|"
    r"webex\.com/|whereby\.com/|meet\.jit\.si/|gotomeeting\.com/|global\.gotomeeting|bluejeans\.com/|chime\.aws/|"
    r"facetime\.apple\.com/|discord\.(?:gg|com)/|meet\.around\.co/|app\.slack\.com/huddle)[^\s\"'<>\\]*",
    re.I,
)
WEEKDAYS = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]


def unfold(text: str) -> list[str]:
    out: list[str] = []
    for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if line[:1] in (" ", "\t") and out:
            out[-1] += line[1:]
        elif line:
            out.append(line)
    return out


def _unescape(v: str) -> str:
    return re.sub(r"\\([\\;,nN])", lambda m: "\n" if m.group(1) in "nN" else m.group(1), v)


def parse_prop(line: str) -> tuple[str, dict, str]:
    # NAME;PARAM=a;PARAM="b:c":value
    i, inq = 0, False
    while i < len(line):
        c = line[i]
        if c == '"':
            inq = not inq
        elif c == ":" and not inq:
            break
        i += 1
    head, value = line[:i], line[i + 1 :]
    parts = re.findall(r'(?:[^;"]|"[^"]*")+', head)
    name = parts[0].upper() if parts else ""
    params = {}
    for p in parts[1:]:
        if "=" in p:
            k, v = p.split("=", 1)
            params[k.upper()] = v.strip('"')
    return name, params, value


def parse_ics(text: str) -> tuple[str, list[dict]]:
    """(calendar name, VEVENTs as {PROP: [(params, value), …]})."""
    name = ""
    events: list[dict] = []
    stack: list[str] = []
    cur: dict | None = None
    for line in unfold(text):
        n, params, value = parse_prop(line)
        if n == "BEGIN":
            stack.append(value.upper())
            if value.upper() == "VEVENT" and stack.count("VEVENT") == 1:
                cur = {}
            continue
        if n == "END":
            if stack and stack[-1] == value.upper():
                stack.pop()
            if value.upper() == "VEVENT" and cur is not None:
                events.append(cur)
                cur = None
            continue
        if cur is not None and stack and stack[-1] == "VEVENT":
            cur.setdefault(n, []).append((params, value))
        elif stack == ["VCALENDAR"] and n == "X-WR-CALNAME":
            name = _unescape(value)
    return name, events


def _tz(tzid: str | None):
    if not tzid:
        return None
    if ZoneInfo is None:
        return None
    try:
        return ZoneInfo(tzid.strip().lstrip("/"))
    except Exception:
        return None


def parse_dt(params: dict, value: str) -> tuple[datetime, bool]:
    """(aware datetime, all-day). Floating times and unknown TZIDs are local time."""
    v = value.strip()
    if params.get("VALUE", "").upper() == "DATE" or re.fullmatch(r"\d{8}", v):
        d = datetime.strptime(v[:8], "%Y%m%d")
        return d.astimezone(), True  # local midnight
    utc = v.endswith("Z")
    d = datetime.strptime(v.rstrip("Z")[:15], "%Y%m%dT%H%M%S")
    if utc:
        return d.replace(tzinfo=timezone.utc), False
    tz = _tz(params.get("TZID"))
    return (d.replace(tzinfo=tz) if tz else d.astimezone()), False


def parse_duration(v: str) -> timedelta:
    m = re.fullmatch(r"([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?", v.strip())
    if not m:
        return timedelta(0)
    sign = -1 if m.group(1) == "-" else 1
    w, d, h, mi, s = (int(x or 0) for x in m.groups()[1:])
    return sign * timedelta(weeks=w, days=d, hours=h, minutes=mi, seconds=s)


def _add_months(d: datetime, n: int) -> datetime | None:
    y, m = divmod(d.month - 1 + n, 12)
    y += d.year
    if d.day > _cal.monthrange(y, m + 1)[1]:
        return None  # RFC 5545: invalid dates are skipped
    return d.replace(year=y, month=m + 1)


def _nth_weekdays(year: int, month: int, spec: str) -> list[int]:
    """Days of the month matching a BYDAY item: 'MO', '2TU', '-1FR'."""
    m = re.fullmatch(r"([+-]?\d+)?([A-Z]{2})", spec)
    if not m or m.group(2) not in WEEKDAYS:
        return []
    wd = WEEKDAYS.index(m.group(2))
    days = [d for d in range(1, _cal.monthrange(year, month)[1] + 1) if date(year, month, d).weekday() == wd]
    if m.group(1):
        n = int(m.group(1))
        try:
            return [days[n - 1 if n > 0 else n]]
        except IndexError:
            return []
    return days


def expand_rrule(start: datetime, rule: str, lo: datetime, hi: datetime, exdates: set, limit: int = 5000) -> list[datetime]:
    """Occurrence starts of an RRULE in [lo, hi). Supports FREQ DAILY / WEEKLY / MONTHLY /
    YEARLY with INTERVAL, COUNT, UNTIL, BYDAY, BYMONTHDAY and BYMONTH — what calendar apps
    write in practice."""
    r = dict(p.split("=", 1) for p in rule.upper().split(";") if "=" in p)
    freq = r.get("FREQ", "")
    interval = max(1, int(r.get("INTERVAL", "1") or 1))
    count = int(r["COUNT"]) if r.get("COUNT", "").isdigit() else None
    until = None
    if r.get("UNTIL"):
        try:
            until, _ = parse_dt({}, r["UNTIL"])
            if len(r["UNTIL"]) == 8:
                until = until + timedelta(days=1) - timedelta(seconds=1)
        except ValueError:
            until = None
    byday = [x for x in r.get("BYDAY", "").split(",") if x]
    bymonthday = [int(x) for x in r.get("BYMONTHDAY", "").split(",") if x.lstrip("-").isdigit()]
    bymonth = [int(x) for x in r.get("BYMONTH", "").split(",") if x.isdigit()]

    def candidates():
        """Every rule instance in order, from the start's period on."""
        i = 0
        while True:
            if freq == "DAILY":
                d = start + timedelta(days=i * interval)
                if (not byday or WEEKDAYS[d.weekday()] in [b[-2:] for b in byday]) and (not bymonth or d.month in bymonth):
                    yield d
            elif freq == "WEEKLY":
                week0 = start - timedelta(days=start.weekday())
                wk = week0 + timedelta(weeks=i * interval)
                days = sorted({WEEKDAYS.index(b[-2:]) for b in byday if b[-2:] in WEEKDAYS}) or [start.weekday()]
                for wd in days:
                    yield wk + timedelta(days=wd)
            elif freq == "MONTHLY":
                base = _add_months(start.replace(day=1), i * interval)
                if base is None:
                    i += 1
                    continue
                if byday:
                    days = sorted({d for b in byday for d in _nth_weekdays(base.year, base.month, b)})
                elif bymonthday:
                    last = _cal.monthrange(base.year, base.month)[1]
                    days = sorted({(d if d > 0 else last + d + 1) for d in bymonthday if 1 <= (d if d > 0 else last + d + 1) <= last})
                else:
                    days = [start.day] if start.day <= _cal.monthrange(base.year, base.month)[1] else []
                for d in days:
                    yield base.replace(day=d)
            elif freq == "YEARLY":
                y = start.year + i * interval
                months = bymonth or [start.month]
                for mo in months:
                    if byday:
                        for d in sorted({d for b in byday for d in _nth_weekdays(y, mo, b)}):
                            yield start.replace(year=y, month=mo, day=d)
                    elif start.day <= _cal.monthrange(y, mo)[1]:
                        yield start.replace(year=y, month=mo)
            else:
                yield start
                return
            i += 1

    out = []
    n = 0
    for steps, d in enumerate(candidates()):
        if steps > limit or d >= hi:
            break
        if d < start:
            continue
        if until is not None and d > until:
            break
        n += 1
        if count is not None and n > count:
            break
        if d >= lo and _key(d) not in exdates:
            out.append(d)
    return out


def _key(d: datetime) -> int:
    return int(d.timestamp())


def _text(ev: dict, name: str) -> str:
    v = ev.get(name)
    return _unescape(v[0][1]) if v else ""


def join_link(ev: dict) -> str:
    for prop in ("X-GOOGLE-CONFERENCE", "X-MICROSOFT-SKYPETEAMSMEETINGURL", "URL", "LOCATION", "DESCRIPTION", "X-ALT-DESC"):
        for _params, v in ev.get(prop, []):
            m = JOIN_RE.search(_unescape(v))
            if m:
                return m.group(0).rstrip(".,;)>")
    return ""


def occurrences(cal_name: str, events: list[dict], lo: datetime, hi: datetime) -> list[dict]:
    """Expanded instances overlapping [lo, hi), with RECURRENCE-ID overrides applied."""
    overrides: dict[tuple[str, int], dict] = {}
    masters = []
    for ev in events:
        if "RECURRENCE-ID" in ev:
            p, v = ev["RECURRENCE-ID"][0]
            try:
                rid, _ = parse_dt(p, v)
            except ValueError:
                continue
            overrides[(_text(ev, "UID"), _key(rid))] = ev
        else:
            masters.append(ev)

    out = []

    def emit(ev: dict, start: datetime, all_day: bool, dur: timedelta, uid: str) -> None:
        if _text(ev, "STATUS").upper() == "CANCELLED":
            return
        end = start + dur
        if end <= lo or start >= hi:
            return
        out.append(
            {
                "id": f"{uid}@{_key(start)}",
                "title": _text(ev, "SUMMARY") or "(No title)",
                "start": _key(start),
                "end": _key(end),
                "allDay": all_day,
                "location": _text(ev, "LOCATION").split("\n")[0][:120],
                "joinUrl": join_link(ev),
                "calendar": cal_name,
            }
        )

    def timing(ev: dict):
        p, v = ev["DTSTART"][0]
        start, all_day = parse_dt(p, v)
        if "DTEND" in ev:
            ep, evv = ev["DTEND"][0]
            end, _ = parse_dt(ep, evv)
            dur = end - start
        elif "DURATION" in ev:
            dur = parse_duration(ev["DURATION"][0][1])
        else:
            dur = timedelta(days=1) if all_day else timedelta(0)
        return start, all_day, dur

    for ev in masters:
        if "DTSTART" not in ev:
            continue
        try:
            start, all_day, dur = timing(ev)
        except ValueError:
            continue
        uid = _text(ev, "UID") or hashlib.sha1(json.dumps(ev, sort_keys=True).encode()).hexdigest()[:12]
        rrule = _text(ev, "RRULE")
        if not rrule:
            emit(ev, start, all_day, dur, uid)
            continue
        exdates = set()
        for p, v in ev.get("EXDATE", []):
            for part in v.split(","):
                try:
                    exdates.add(_key(parse_dt(p, part)[0]))
                except ValueError:
                    pass
        for occ in expand_rrule(start, rrule, lo - dur - timedelta(days=1), hi, exdates):
            ov = overrides.pop((uid, _key(occ)), None)
            if ov is not None and "DTSTART" in ov:
                try:
                    s2, ad2, d2 = timing(ov)
                except ValueError:
                    continue
                emit(ov, s2, ad2, d2, uid)
            else:
                emit(ev, occ, all_day, dur, uid)
    # Moved instances whose original slot is outside the window.
    for (uid, _k), ov in overrides.items():
        if "DTSTART" in ov:
            try:
                s2, ad2, d2 = timing(ov)
            except ValueError:
                continue
            emit(ov, s2, ad2, d2, uid)
    return out


# Calendar sources.


def _ini_sections(path: Path) -> list[tuple[str, dict]]:
    """Loose INI reader for khal's configobj files and vdirsyncer's config: [sections],
    [[subsections]], key = value (quotes stripped)."""
    out: list[tuple[str, dict]] = []
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return out
    cur: dict | None = None
    for line in lines:
        s = line.strip()
        if not s or s.startswith("#") or s.startswith(";"):
            continue
        m = re.fullmatch(r"(\[+)\s*([^\]]+?)\s*\]+", s)
        if m:
            cur = {}
            out.append((("  " * (len(m.group(1)) - 1)) + m.group(2), cur))
            continue
        if cur is not None and "=" in s:
            k, v = s.split("=", 1)
            cur[k.strip()] = v.strip().strip('"').strip("'")
    return out


def khal_vdirs() -> list[tuple[str, Path]]:
    """(name, collection dir) from khal's config ([calendars] → [[name]] path, type)."""
    out = []
    for f in (config_home() / "khal" / "config", _home() / ".khal" / "khal.conf", _home() / ".khalrc"):
        if not f.is_file():
            continue
        top = ""
        for name, kv in _ini_sections(f):
            if not name.startswith("  "):
                top = name
                continue
            if top != "calendars" or "path" not in kv:
                continue
            base = os.path.expanduser(kv["path"])
            if kv.get("type") == "discover":
                import glob

                for p in sorted(glob.glob(base)):
                    if os.path.isdir(p):
                        out.append((os.path.basename(p.rstrip("/")), Path(p)))
            else:
                out.append((name.strip(), Path(base)))
        break
    return out


def vdirsyncer_vdirs() -> list[tuple[str, Path]]:
    out = []
    f = config_home() / "vdirsyncer" / "config"
    if not f.is_file():
        f = _home() / ".vdirsyncer" / "config"
    for name, kv in _ini_sections(f):
        if not name.startswith("storage ") or kv.get("type") != "filesystem" or kv.get("fileext", ".ics") != ".ics":
            continue
        base = Path(os.path.expanduser(kv.get("path", "")))
        if not base.is_dir():
            continue
        cols = [p for p in base.iterdir() if p.is_dir()] or [base]
        for c in sorted(cols):
            out.append((c.name, c))
    return out


def read_vdir(name: str, d: Path) -> tuple[str, list[dict]]:
    display = name
    try:
        display = (d / "displayname").read_text().strip() or name
    except OSError:
        pass
    events: list[dict] = []
    for f in sorted(d.glob("*.ics")):
        try:
            _, evs = parse_ics(f.read_text(errors="replace"))
        except OSError:
            continue
        events.extend(evs)
    return display, events


def _keyfile(path: Path) -> dict[str, dict[str, str]]:
    """GLib keyfile → {section: {key: value}} (unlocalized keys only)."""
    out: dict[str, dict[str, str]] = {}
    cur = None
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError:
        return out
    for line in lines:
        line = line.strip()
        if line.startswith("[") and line.endswith("]"):
            cur = out.setdefault(line[1:-1], {})
        elif cur is not None and "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            if "[" not in k:
                cur[k.strip()] = v.strip()
    return out


def _eds_cache_objects(db: Path) -> list[str]:
    """iCalendar components from an EDS backend cache (ECalCache: ECacheObjects.ECacheOBJ).
    The live db may be locked, so a private copy is read."""
    try:
        with tempfile.TemporaryDirectory(prefix="loft-eds-") as tmp:
            for suffix in ("", "-wal"):
                src = Path(str(db) + suffix)
                if src.exists():
                    shutil.copyfile(src, Path(tmp) / ("cache.db" + suffix))
            con = sqlite3.connect(f"file:{tmp}/cache.db?mode=ro", uri=True, timeout=1)
            try:
                # State 3 = deleted locally, not yet synced.
                return [r[0] for r in con.execute("SELECT ECacheOBJ FROM ECacheObjects WHERE ECacheState IS NOT 3") if isinstance(r[0], str)]
            finally:
                con.close()
    except (OSError, sqlite3.Error):
        return []


def eds_calendars() -> list[tuple[str, list[dict]]] | None:
    """Evolution Data Server's calendars (GNOME Online Accounts, CalDAV, local), read from its
    stores, read-only and offline: sources in ~/.config/evolution/sources/*.source (enabled,
    [Calendar], selected), events in ~/.local/share/evolution/calendar/<uid>/calendar.ics
    (local) or the backend's cache ~/.cache/evolution/calendar/<uid>/cache.db (remote, as
    last synced by EDS). None when there's no EDS data. (Not over D-Bus: EDS closes a
    calendar when the connection that opened it goes away, and Python's stdlib has no D-Bus
    client to keep one.)"""
    src_dir = config_home() / "evolution" / "sources"
    data_dir = Path(os.environ.get("XDG_DATA_HOME") or _home() / ".local" / "share") / "evolution" / "calendar"
    cache_dir = Path(os.environ.get("XDG_CACHE_HOME") or _home() / ".cache") / "evolution" / "calendar"
    if not src_dir.is_dir() and not data_dir.is_dir():
        return None
    sources: dict[str, str] = {}
    if (data_dir / "system" / "calendar.ics").is_file():
        sources["system"] = "Personal"  # the built-in local calendar
    for f in sorted(src_dir.glob("*.source")) if src_dir.is_dir() else []:
        kf = _keyfile(f)
        ds, cal = kf.get("Data Source", {}), kf.get("Calendar")
        if cal is None or ds.get("Enabled", "true") == "false" or cal.get("Enabled", "true") == "false" or cal.get("Selected", "true") == "false":
            continue
        if cal.get("BackendName") == "contacts":
            continue  # birthdays are derived from the address book
        uid = f.stem
        sources["system" if uid == "system-calendar" else uid] = ds.get("DisplayName") or uid
    out = []
    for uid, name in sources.items():
        events: list[dict] = []
        ics = data_dir / uid / "calendar.ics"
        if ics.is_file():
            try:
                events = parse_ics(ics.read_text(errors="replace"))[1]
            except OSError:
                pass
        else:
            db = cache_dir / uid / "cache.db"
            if db.is_file():
                for comp in _eds_cache_objects(db):
                    text = comp if "BEGIN:VCALENDAR" in comp else f"BEGIN:VCALENDAR\n{comp}\nEND:VCALENDAR"
                    events.extend(parse_ics(text)[1])
        out.append((name, events))
    return out


def fetch_ics(spec: str, cache_dir: Path, max_age: float = 900, refresh: bool = False) -> str | None:
    """An ICS URL (http, https, webcal) through a cache, or a local file."""
    if not re.match(r"^(https?|webcal)://", spec, re.I):
        try:
            return Path(os.path.expanduser(spec)).read_text(errors="replace")
        except OSError:
            return None
    url = re.sub(r"^webcal://", "https://", spec, flags=re.I)
    f = cache_dir / (hashlib.sha1(url.encode()).hexdigest() + ".ics")
    try:
        fresh = not refresh and time.time() - f.stat().st_mtime < max_age
    except OSError:
        fresh = False
    if not fresh:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Loft-island/1 (calendar)"})
            with urllib.request.urlopen(req, timeout=15) as r:
                body = r.read(20 * 1024 * 1024).decode("utf-8", errors="replace")
            if "BEGIN:VCALENDAR" in body:
                f.parent.mkdir(parents=True, exist_ok=True)
                f.write_text(body)
                return body
        except (OSError, ValueError):
            pass  # stale cache below
    try:
        return f.read_text(errors="replace")
    except OSError:
        return None


def agenda(source: str = "auto", ics: list[str] | None = None, days: int = 2, now: float | None = None, refresh: bool = False) -> dict:
    now = time.time() if now is None else now
    lo = datetime.fromtimestamp(local_midnight(now)).astimezone()
    hi = lo + timedelta(days=max(1, days))
    cals: list[tuple[str, list[dict]]] = []
    used: list[str] = []
    if source in ("auto", "khal", "vdirsyncer"):
        vdirs = []
        if source in ("auto", "khal"):
            vdirs = khal_vdirs()
            if vdirs:
                used.append("khal")
        if not vdirs and source in ("auto", "vdirsyncer"):
            vdirs = vdirsyncer_vdirs()
            if vdirs:
                used.append("vdirsyncer")
        cals += [read_vdir(n, d) for n, d in vdirs]
    if source == "eds" or (source == "auto" and not used):
        e = eds_calendars()
        if e is not None:
            used.append("eds")
            cals += e
    cache_dir = state_dir() / "cache" / "calendar"
    for spec in ics or []:
        text = fetch_ics(spec, cache_dir, refresh=refresh)
        if text is None:
            continue
        name, evs = parse_ics(text)
        cals.append((name or os.path.basename(spec.rstrip("/")) or "Calendar", evs))
        if "ics" not in used:
            used.append("ics")
    events = []
    for name, evs in cals:
        events += occurrences(name, evs, lo, hi)
    seen = set()
    uniq = []
    for e in sorted(events, key=lambda e: (e["start"], not e["allDay"], e["title"])):
        k = (e["title"], e["start"], e["end"])
        if k in seen:
            continue
        seen.add(k)
        uniq.append(e)
    return {"generated": now, "sources": used, "calendars": sorted({n for n, _ in cals}), "events": uniq}


# ── downloads ───────────────────────────────────────────────────────────────

# Temp suffixes browsers and download managers write while a file is in flight.
TEMP_SUFFIXES = (".crdownload", ".part", ".download", ".partial", ".opdownload", ".!qB", ".tmp-download")


def temp_target(name: str) -> str | None:
    """The final name for an in-progress temp name, else None."""
    if name.startswith("Unconfirmed ") and name.endswith(".crdownload"):
        return ""  # Chrome's placeholder before it knows the name
    for s in TEMP_SUFFIXES:
        if name.endswith(s) and len(name) > len(s):
            return name[: -len(s)]
    return None


def aria2_total(control: Path) -> int | None:
    """Total length from an aria2 control file (VER 0/1: big-endian when version is 1)."""
    try:
        b = control.read_bytes()[:4096]
        ver = struct.unpack(">H", b[:2])[0]
        endian = ">" if ver == 1 else "<"
        ih_len = struct.unpack(endian + "I", b[6:10])[0]
        off = 10 + ih_len
        off += 4  # piece length
        return struct.unpack(endian + "Q", b[off : off + 8])[0]
    except (OSError, struct.error):
        return None


CHROMIUM_DIRS = ("google-chrome", "google-chrome-beta", "chromium", "BraveSoftware/Brave-Browser", "vivaldi", "microsoft-edge")


def chromium_total(path: str) -> int | None:
    """Expected size of a Chromium download in progress: its History db's downloads row for
    this temp path (only total_bytes is read). The live db is locked, so a private copy is read."""
    for d in CHROMIUM_DIRS:
        root = config_home() / d
        if not root.is_dir():
            continue
        for hist in root.glob("*/History"):
            try:
                if hist.stat().st_size > 64 * 1024 * 1024:
                    continue  # too big to copy every few seconds
                with tempfile.TemporaryDirectory(prefix="loft-dl-") as tmp:
                    for suffix in ("", "-wal"):
                        src = Path(str(hist) + suffix)
                        if src.exists():
                            shutil.copyfile(src, Path(tmp) / ("History" + suffix))
                    con = sqlite3.connect(f"file:{tmp}/History?mode=ro", uri=True, timeout=1)
                    try:
                        row = con.execute("SELECT total_bytes FROM downloads WHERE current_path = ? ORDER BY id DESC LIMIT 1", (path,)).fetchone()
                    finally:
                        con.close()
                if row and row[0] and row[0] > 0:
                    return int(row[0])
            except (OSError, sqlite3.Error):
                continue
    return None


class Inotify:
    """Directory change notifications via libc (no dependency); fileno() for select."""

    IN_MODIFY, IN_MOVED_FROM, IN_MOVED_TO, IN_CREATE, IN_DELETE = 0x2, 0x40, 0x80, 0x100, 0x200

    def __init__(self, path: str):
        libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6", use_errno=True)
        self.fd = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
        if self.fd < 0:
            raise OSError(ctypes.get_errno(), "inotify_init1")
        mask = self.IN_MOVED_FROM | self.IN_MOVED_TO | self.IN_CREATE | self.IN_DELETE
        if libc.inotify_add_watch(self.fd, os.fsencode(path), mask) < 0:
            os.close(self.fd)
            raise OSError(ctypes.get_errno(), "inotify_add_watch")

    def fileno(self) -> int:
        return self.fd

    def drain(self) -> None:
        try:
            while os.read(self.fd, 65536):
                pass
        except BlockingIOError:
            pass


class DownloadWatcher:
    def __init__(self, folder: Path, totals: bool = True):
        self.folder = folder
        self.totals = totals
        self.active: dict[str, dict] = {}

    def scan(self, now: float) -> tuple[list[dict], list[dict]]:
        try:
            names = os.listdir(self.folder)
        except OSError:
            names = []
        present = set(names)
        current: dict[str, dict] = {}
        for n in names:
            target = temp_target(n)
            control = None
            if target is None and n + ".aria2" in present:
                target, control = n, self.folder / (n + ".aria2")
            if target is None:
                continue
            p = self.folder / n
            try:
                st = p.stat()
            except OSError:
                continue
            prev = self.active.get(n)
            size = st.st_size if p.is_file() else _dir_size(p)
            rec = {
                "name": target or n.replace(".crdownload", ""),
                "temp": n,
                "path": str(self.folder / target) if target else "",
                "size": size,
                "total": prev["total"] if prev else None,
                "started": prev["started"] if prev else now,
                "speed": 0.0,
                "t": now,
            }
            if prev:
                dt = now - prev["t"]
                if dt > 0:
                    inst = max(0.0, (size - prev["size"]) / dt)
                    rec["speed"] = inst if not prev["speed"] else prev["speed"] * 0.6 + inst * 0.4
                rec["_checked"] = prev.get("_checked", 0)
            # Look the total up a few times (the browser writes its row soon after starting).
            if prev:
                rec["_tries"] = prev.get("_tries", 0)
            if self.totals and rec["total"] is None and rec.get("_tries", 0) < 3 and ("_checked" not in rec or now - rec["_checked"] > 5):
                rec["_checked"] = now
                rec["_tries"] = rec.get("_tries", 0) + 1
                if control is not None:
                    rec["total"] = aria2_total(control)
                elif n.endswith(".crdownload"):
                    rec["total"] = chromium_total(str(p))
            current[n] = rec
        finished = []
        for n, rec in self.active.items():
            if n in current:
                continue
            final = rec["path"]
            if final and os.path.isfile(final) and os.path.getsize(final) > 0:
                finished.append({"name": os.path.basename(final), "path": final, "size": os.path.getsize(final)})
        self.active = current
        return [self.public(r) for r in current.values()], finished

    @staticmethod
    def public(r: dict) -> dict:
        out = {k: v for k, v in r.items() if not k.startswith("_") and k != "t"}
        out["speed"] = round(out["speed"])
        if out["total"] and out["total"] > 0:
            out["progress"] = round(min(1.0, out["size"] / out["total"]), 4)
        return out


def _dir_size(p: Path) -> int:
    total = 0
    for root, _dirs, files in os.walk(p):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(root, f))
            except OSError:
                pass
    return total


def watch_downloads(folder: Path, interval: float = 1.0, once: bool = False, out=None) -> None:
    out = out or sys.stdout
    w = DownloadWatcher(folder)
    try:
        ino = Inotify(str(folder))
    except OSError:
        ino = None
    last = None
    while True:
        active, finished = w.scan(time.time())
        line = json.dumps({"folder": str(folder), "active": active, "finished": finished})
        if line != last or finished:
            out.write(line + "\n")
            out.flush()
            last = line
        if once:
            return
        timeout = interval if (active or ino is None) else None
        if ino is not None:
            r, _, _ = select.select([ino], [], [], timeout)
            if r:
                ino.drain()
                time.sleep(0.05)  # coalesce a burst (create + rename)
        else:
            time.sleep(timeout or interval)
        if not folder.is_dir():
            time.sleep(5)


# ── lyrics ──────────────────────────────────────────────────────────────────


def parse_lrc(text: str) -> list[list]:
    """[[ms, line], …] from LRC text ('[01:02.34] words'; several stamps per line allowed)."""
    out = []
    for raw in (text or "").splitlines():
        stamps = re.findall(r"\[(\d+):(\d+(?:\.\d+)?)\]", raw)
        if not stamps:
            continue
        words = re.sub(r"\[[^\]]*\]", "", raw).strip()
        for m, s in stamps:
            out.append([int((int(m) * 60 + float(s)) * 1000), words])
    return sorted(out, key=lambda x: x[0])


def lyrics(artist: str, title: str, album: str = "", duration: float = 0, cache_dir: Path | None = None, fetch=None) -> dict:
    key = hashlib.sha1(json.dumps([artist.lower(), title.lower(), album.lower(), round(duration)]).encode()).hexdigest()
    cache_dir = cache_dir or state_dir() / "cache" / "lyrics"
    f = cache_dir / f"{key}.json"
    cached = _read_json(f, None)
    if cached is not None and (cached.get("synced") or time.time() - cached.get("fetched", 0) < DAY):
        return cached

    def get(path: str, params: dict):
        url = f"https://lrclib.net/api/{path}?" + urllib.parse.urlencode({k: v for k, v in params.items() if v})
        if fetch:
            return fetch(url)
        req = urllib.request.Request(url, headers={"User-Agent": "Loft island (https://github.com/Codys-Wright/loft)"})
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            raise

    res = {"artist": artist, "title": title, "synced": [], "plain": False, "instrumental": False, "fetched": time.time()}
    try:
        hit = get("get", {"artist_name": artist, "track_name": title, "album_name": album, "duration": round(duration) if duration else ""})
        if not hit or not hit.get("syncedLyrics"):
            found = get("search", {"artist_name": artist, "track_name": title}) or []
            hit = next((h for h in found if h.get("syncedLyrics")), hit or (found[0] if found else None))
    except (OSError, ValueError) as e:
        res["error"] = str(e)
        return res  # not cached: try again next time
    if hit:
        res["synced"] = parse_lrc(hit.get("syncedLyrics") or "")
        res["plain"] = bool(hit.get("plainLyrics")) and not res["synced"]
        res["instrumental"] = bool(hit.get("instrumental"))
    try:
        _write_json(f, res)
    except OSError:
        pass
    return res


# ── timers ──────────────────────────────────────────────────────────────────


def parse_duration_spec(spec: str) -> int | None:
    """Seconds from '25m', '1h30m', '90s', '1:30' (m:s), '1:00:00', '10' (minutes)."""
    s = spec.strip().lower().replace(" ", "")
    if not s:
        return None
    if re.fullmatch(r"\d+(\.\d+)?", s):
        return round(float(s) * 60)
    if re.fullmatch(r"\d+(:\d{1,2}){1,2}", s):
        parts = [int(p) for p in s.split(":")]
        while len(parts) < 3:
            parts.insert(0, 0)
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    m = re.fullmatch(r"(?:(\d+(?:\.\d+)?)h(?:ours?|rs?)?)?(?:(\d+(?:\.\d+)?)m(?:in(?:utes?|s)?)?)?(?:(\d+)s(?:ec(?:onds?|s)?)?)?", s)
    if not m or not any(m.groups()):
        return None
    h, mi, se = (float(x) if x else 0 for x in m.groups())
    return round(h * 3600 + mi * 60 + se)


def shell_ipc(shell_path: str, target: str, fn: str, *args: str) -> int:
    cmd = ["quickshell", "ipc", "--any-display", "--path", shell_path, "call", target, fn, *args]
    try:
        return subprocess.run(cmd, timeout=5).returncode
    except (OSError, subprocess.TimeoutExpired) as e:
        print(f"loft: {e}", file=sys.stderr)
        return 1


# ── CLI ─────────────────────────────────────────────────────────────────────


def add_parser(top, shell_path_of) -> None:
    isl = top.add_parser("island", help="data for the Dynamic Island (JSON) and timers")
    sub = isl.add_subparsers(dest="cmd", required=True)

    def out(v):
        print(json.dumps(v))

    s = sub.add_parser(
        "ai",
        help="Claude Code / Codex usage (aggregate counts only) and running sessions",
        description="Reads ~/.claude/projects/**/*.jsonl (usage fields) and ~/.codex/sessions/**/*.jsonl (token_count "
        "events) incrementally; $LOFT_AI_CLAUDE_DIR / $LOFT_AI_CODEX_DIR point elsewhere. Never prints content.",
    )
    s.add_argument("--json", action="store_true", help="(default) machine-readable")
    s.add_argument("--cache", help="cache file (default <state>/cache/island-ai.json)")
    s.add_argument("--no-procs", action="store_true", help="don't look for running sessions")

    def _ai(ctx, a):
        r = ai_summary(Path(a.cache) if a.cache else None, procs=[] if a.no_procs else None)
        out(r)

    s.set_defaults(fn=_ai)

    s = sub.add_parser("calendar", help="today's and upcoming events (khal / vdirsyncer, EDS, ICS)")
    s.add_argument("--json", action="store_true", help="(default) machine-readable")
    s.add_argument("--source", choices=["auto", "khal", "vdirsyncer", "eds", "none"], default="auto")
    s.add_argument("--ics", action="append", default=[], metavar="URL|FILE", help="also read this ICS (repeatable)")
    s.add_argument("--days", type=int, default=2, help="from today's midnight (default 2: today + tomorrow)")
    s.add_argument("--refresh", action="store_true", help="refetch ICS URLs now")
    s.set_defaults(fn=lambda ctx, a: out(agenda(a.source, a.ics, a.days, refresh=a.refresh)))

    s = sub.add_parser("downloads", help="in-progress downloads in a folder (JSON lines with --watch)")
    s.add_argument("folder", nargs="?", help="default: the XDG download dir")
    s.add_argument("--watch", action="store_true", help="keep running, one line per change")
    s.add_argument("--interval", type=float, default=1.0)

    def _dl(ctx, a):
        if a.folder:
            folder = Path(os.path.expanduser(a.folder))
        else:
            from .dock import user_dir

            folder = user_dir("DOWNLOAD")
        try:
            watch_downloads(folder, a.interval, once=not a.watch)
        except (KeyboardInterrupt, BrokenPipeError):
            pass

    s.set_defaults(fn=_dl)

    s = sub.add_parser("lyrics", help="synced lyrics from lrclib.net (sends artist/title there)")
    s.add_argument("--artist", required=True)
    s.add_argument("--title", required=True)
    s.add_argument("--album", default="")
    s.add_argument("--duration", type=float, default=0, help="seconds")
    s.add_argument("--json", action="store_true", help="(default) machine-readable")
    s.set_defaults(fn=lambda ctx, a: out(lyrics(a.artist, a.title, a.album, a.duration)))

    s = sub.add_parser("timer", help="start a countdown in the shell: timer 25m tea, timer 1:30, timer 1h")
    s.add_argument("duration")
    s.add_argument("label", nargs="*")

    def _timer(ctx, a):
        if parse_duration_spec(a.duration) is None:
            raise SystemExit(f"loft: can't read a duration from '{a.duration}' (25m, 1h30m, 90s, 1:30)")
        raise SystemExit(shell_ipc(shell_path_of(ctx), "timers", "start", a.duration, " ".join(a.label)))

    s.set_defaults(fn=_timer)

    s = sub.add_parser("stopwatch", help="start a stopwatch in the shell")
    s.add_argument("label", nargs="*")

    def _stopwatch(ctx, a):
        raise SystemExit(shell_ipc(shell_path_of(ctx), "timers", "stopwatch", " ".join(a.label)))

    s.set_defaults(fn=_stopwatch)
