"""loft-fan-control: the privileged half of fan control (`loft fans …`, issue #7).

Runs as root, two ways:

  * through pkexec (the NixOS module's polkit rule lets active local users of
    one group run it without a password), to change what a fan should do:

        loft-fan-control manual hwmon3/pwm2 40 [--source hwmon4/temp1] [--allow-stop]
        loft-fan-control curve  hwmon3/pwm2 hwmon4/temp1 30:25,60:50,80:100 [--allow-stop]
        loft-fan-control auto   hwmon3/pwm2
        loft-fan-control reset                      (every fan back to automatic)

    These only validate and record the setting in <root>/var/lib/loft/fans.json
    (root-owned, world-readable); they never touch /sys themselves.

  * as the `loft-fans` system service (`run`), the only thing that writes
    /sys/class/hwmon/hwmon*/pwm[N] and pwm[N]_enable: every `interval`
    seconds it puts each configured fan in manual mode (pwm_enable = 1) and
    writes its speed. `restore` (the unit's ExecStopPost, so it runs after a
    crash or SIGKILL too) puts every fan it took back the way it found it.

Safety:
  * Writes go only to pwm[N] / pwm[N]_enable of a hwmon[N] directory that
    resolves inside <root>/sys/devices, opened O_NOFOLLOW without O_CREAT, with
    the value clamped (pwm 0..255, enable 0..5). Nothing else is writable.
  * Before the first write to a fan its original pwm_enable (and pwm) is saved
    to <root>/run/loft-fans/saved.json; leaving a fan (auto, error, SIGTERM,
    exit, crash via ExecStopPost, suspend via Conflicts=sleep.target) writes the
    original back — or 2 (automatic) when unknown, or 0 (full speed: the driver
    stops controlling it, which on hwmon means 100 %) if even that is refused.
  * Speeds are clamped to the machine's floor (minPercent, at least 10 %);
    0 % (fan stopped) needs both allowStop in /etc/loft/fans.json and
    --allow-stop on that fan.
  * Over criticalTemp (the fan's temperature source, or any CPU sensor) every
    controlled fan runs at 100 %. A curve whose temperature source can't be read
    hands its fan back to automatic.
  * Curves ramp up at once and down by at most 4 % per tick (no hunting).

<root> is /. Tests pass --root, which is refused when running as root; `run`
and `restore` are refused under pkexec (they belong to the service). Stdlib
only, so the Nix package needs nothing but python3.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import signal
import stat
import sys
import time
from dataclasses import dataclass
from pathlib import Path

HWMON = re.compile(r"^hwmon(\d+)$")
FAN_ID = re.compile(r"^(hwmon\d+)/pwm([1-9]\d?)$")
TEMP_ID = re.compile(r"^(hwmon\d+)/temp([1-9]\d?)$")
ATTR = re.compile(r"^pwm([1-9]\d?)(_enable)?$")
CPU_CHIPS = re.compile(r"^(k10temp|zenpower|coretemp|cpu_thermal)$")

ABS_FLOOR = 10  # % — no machine setting goes below this (except an allowed stop)
STEP_DOWN = 4  # % per tick a curve may slow down by
MAX_POINTS = 8
MANUAL, AUTO = 1, 2  # pwm_enable


class Refused(Exception):
    pass


# ── paths (everything under one injectable root) ──────────────────────────


class Paths:
    def __init__(self, root: Path):
        self.root = root
        self.hwmon = root / "sys/class/hwmon"
        self.devices = root / "sys/devices"
        self.policy = root / "etc/loft/fans.json"
        self.config = root / "var/lib/loft/fans.json"
        self.run = root / "run/loft-fans"

    @property
    def saved(self) -> Path:
        return self.run / "saved.json"

    @property
    def state(self) -> Path:
        return self.run / "state.json"

    @property
    def pidfile(self) -> Path:
        return self.run / "daemon.pid"


def read_text(p: Path) -> str | None:
    try:
        return p.read_text().strip()
    except (OSError, UnicodeDecodeError):
        return None


def read_int(p: Path) -> int | None:
    t = read_text(p)
    try:
        return int(t) if t is not None else None
    except ValueError:
        return None


def read_json(p: Path) -> dict | None:
    try:
        v = json.loads(p.read_text())
        return v if isinstance(v, dict) else None
    except (OSError, ValueError):
        return None


def write_json(p: Path, data: dict, mode: int = 0o644) -> None:
    """Atomic (temp + rename), fsynced: a crash leaves the old or the new file."""
    p.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    tmp = p.with_name(f".{p.name}.tmp-{os.getpid()}")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, mode)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, mode)
    os.replace(tmp, p)


# ── the machine's policy (/etc/loft/fans.json, written by the NixOS module) ─


@dataclass
class Policy:
    min_percent: int = 25
    allow_stop: bool = False
    critical_temp: float = 90.0
    interval: float = 2.0


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def policy(p: Paths) -> Policy | None:
    """None when fan control isn't enabled on this machine."""
    raw = read_json(p.policy)
    if raw is None:
        return None
    pol = Policy()
    if isinstance(raw.get("minPercent"), (int, float)) and not isinstance(raw.get("minPercent"), bool):
        pol.min_percent = int(clamp(raw["minPercent"], ABS_FLOOR, 100))
    pol.allow_stop = raw.get("allowStop") is True
    if isinstance(raw.get("criticalTemp"), (int, float)) and not isinstance(raw.get("criticalTemp"), bool):
        pol.critical_temp = float(clamp(raw["criticalTemp"], 50, 110))
    if isinstance(raw.get("interval"), (int, float)) and not isinstance(raw.get("interval"), bool):
        pol.interval = float(clamp(raw["interval"], 1, 10))
    return pol


def to_pwm(percent: float, pol: Policy, stop: bool) -> int:
    """A speed in % → the pwm value to write, never under the floor unless a
    stop is allowed by both the machine and this fan."""
    pct = clamp(float(percent), 0.0, 100.0)
    if pct == 0 and stop and pol.allow_stop:
        return 0
    pct = max(pct, pol.min_percent, ABS_FLOOR)
    return int(clamp(round(pct * 255 / 100), 0, 255))


# ── discovery ─────────────────────────────────────────────────────────────


@dataclass
class Channel:
    """A pwm output (kind "pwm") or a temperature input (kind "temp")."""

    id: str  # hwmon3/pwm2 — this boot's name
    key: str  # nct6798@platform/nct6775.656/pwm2 — stable across reboots
    hw: Path
    n: int
    chip: str
    label: str


def _chip_key(p: Paths, hw: Path) -> str:
    name = read_text(hw / "name") or hw.name
    dev = hw / "device"
    where = ""
    if dev.exists():
        real = os.path.realpath(dev)
        base = os.path.realpath(p.devices)
        where = os.path.relpath(real, base) if real.startswith(base + os.sep) else real
    return f"{name}@{where}"


def _hwmons(p: Paths) -> list[Path]:
    try:
        names = os.listdir(p.hwmon)
    except OSError:
        return []
    out = [p.hwmon / n for n in names if HWMON.match(n)]
    return sorted(out, key=lambda h: int(HWMON.match(h.name).group(1)))


def _numbered(hw: Path, prefix: str, suffix: str = "") -> list[int]:
    rx = re.compile(rf"^{prefix}([1-9]\d?){suffix}$")
    try:
        return sorted(int(m.group(1)) for n in os.listdir(hw) if (m := rx.match(n)))
    except OSError:
        return []


def pwms(p: Paths) -> list[Channel]:
    out = []
    for hw in _hwmons(p):
        chip = read_text(hw / "name") or hw.name
        ck = _chip_key(p, hw)
        for n in _numbered(hw, "pwm"):
            label = read_text(hw / f"fan{n}_label") or read_text(hw / f"pwm{n}_label") or f"Fan {n}"
            out.append(Channel(f"{hw.name}/pwm{n}", f"{ck}/pwm{n}", hw, n, chip, label))
    return out


def temps(p: Paths) -> list[Channel]:
    out = []
    for hw in _hwmons(p):
        chip = read_text(hw / "name") or hw.name
        ck = _chip_key(p, hw)
        for n in _numbered(hw, "temp", "_input"):
            label = read_text(hw / f"temp{n}_label") or f"Temp {n}"
            out.append(Channel(f"{hw.name}/temp{n}", f"{ck}/temp{n}", hw, n, chip, label))
    return out


def read_temp(c: Channel) -> float | None:
    raw = read_int(c.hw / f"temp{c.n}_input")
    # Unconnected headers read as nonsense (-62 °C, 127 °C).
    if raw is None or raw < -20000 or raw >= 127000:
        return None
    return raw / 1000


def writable(c: Channel) -> bool:
    """pwm[N] and pwm[N]_enable both exist and the driver lets their owner write."""
    for name in (f"pwm{c.n}", f"pwm{c.n}_enable"):
        try:
            st = os.stat(c.hw / name)
        except OSError:
            return False
        if not stat.S_ISREG(st.st_mode) or not st.st_mode & 0o200:
            return False
    return True


def find(chans: list[Channel], ident: str, rx: re.Pattern) -> Channel:
    if not rx.match(ident) and "@" not in ident:
        raise Refused(f"bad channel {ident!r} (want hwmonN/{'pwm' if rx is FAN_ID else 'temp'}N)")
    for c in chans:
        if ident in (c.id, c.key):
            return c
    raise Refused(f"no such channel {ident!r}")


# ── the only writes to /sys ───────────────────────────────────────────────


def write_attr(p: Paths, hwmon: str, attr: str, value: int) -> None:
    """Write `value` to <hwmon>/<attr>, attr being pwm[N] or pwm[N]_enable."""
    if not HWMON.match(hwmon):
        raise Refused(f"bad hwmon {hwmon!r}")
    m = ATTR.match(attr)
    if not m:
        raise Refused(f"refusing to write {attr!r} (only pwm[N] and pwm[N]_enable)")
    if not isinstance(value, int) or isinstance(value, bool):
        raise Refused(f"bad value {value!r}")
    if m.group(2):
        if not 0 <= value <= 5:
            raise Refused(f"bad pwm_enable {value}")
    else:
        value = clamp(value, 0, 255)
    real = os.path.realpath(p.hwmon / hwmon)
    devices = os.path.realpath(p.devices)
    if not real.startswith(devices + os.sep):
        raise Refused(f"{hwmon} doesn't resolve under {p.devices}")
    fd = os.open(os.path.join(real, attr), os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise Refused(f"{hwmon}/{attr} is not an attribute file")
        os.write(fd, f"{value}\n".encode())
    finally:
        os.close(fd)


# ── settings (/var/lib/loft/fans.json) ────────────────────────────────────


def parse_points(text: str) -> list[list[float]]:
    pts = []
    for part in text.split(","):
        t, sep, pct = part.strip().partition(":")
        if not sep:
            raise Refused(f"bad curve point {part!r} (want TEMP:PERCENT)")
        try:
            pts.append([float(t), float(pct)])
        except ValueError:
            raise Refused(f"bad curve point {part!r}") from None
    return pts


def clean_points(pts) -> list[list[float]]:
    if not isinstance(pts, list) or not 2 <= len(pts) <= MAX_POINTS:
        raise Refused(f"a curve needs 2 to {MAX_POINTS} points")
    out = []
    for pt in pts:
        if not (isinstance(pt, list) and len(pt) == 2 and all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in pt)):
            raise Refused(f"bad curve point {pt!r}")
        t, pct = float(pt[0]), float(pt[1])
        if not (0 <= t <= 110 and 0 <= pct <= 100) or t != t or pct != pct:
            raise Refused(f"curve point {pt!r} out of range (0–110 °C, 0–100 %)")
        if out and t <= out[-1][0]:
            raise Refused("curve temperatures must increase")
        out.append([round(t, 1), round(pct, 1)])
    return out


def clean_setting(s, pol: Policy) -> dict:
    """A fan's stored setting, re-checked (the daemon distrusts the file too)."""
    if not isinstance(s, dict):
        raise Refused("bad setting")
    mode = s.get("mode")
    stop = s.get("stop") is True
    if stop and not pol.allow_stop:
        raise Refused("stopping fans isn't allowed on this machine (programs.loft.fanControl.allowStop)")
    out: dict = {"mode": mode, "stop": stop}
    src = s.get("source")
    if src is not None:
        if not isinstance(src, str) or len(src) > 256:
            raise Refused("bad temperature source")
        out["source"] = src
    if mode == "manual":
        pct = s.get("percent")
        if not isinstance(pct, (int, float)) or isinstance(pct, bool) or not 0 <= pct <= 100:
            raise Refused("manual speed must be 0–100 %")
        if pct == 0 and not stop:
            raise Refused("0 % stops the fan: pass --allow-stop (and allow it on the machine) to mean that")
        out["percent"] = round(float(pct), 1)
    elif mode == "curve":
        if src is None:
            raise Refused("a curve needs a temperature source")
        out["points"] = clean_points(s.get("points"))
        if not stop and min(pt[1] for pt in out["points"]) == 0:
            raise Refused("a curve point at 0 % stops the fan: pass --allow-stop to mean that")
    else:
        raise Refused(f"bad mode {mode!r}")
    return out


def load_config(p: Paths, pol: Policy) -> dict[str, dict]:
    raw = read_json(p.config) or {}
    fans = raw.get("fans") if isinstance(raw.get("fans"), dict) else {}
    out = {}
    for key, s in fans.items():
        try:
            out[str(key)] = clean_setting(s, pol)
        except Refused as e:
            log(f"ignoring the setting for {key}: {e}")
    return out


def update_config(p: Paths, key: str, setting: dict | None) -> None:
    p.config.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    with open(p.config.with_name(".fans.lock"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        raw = read_json(p.config) or {}
        fans = raw.get("fans") if isinstance(raw.get("fans"), dict) else {}
        if key == "*":
            fans = {}
        elif setting is None:
            fans.pop(key, None)
        else:
            fans[key] = setting
        write_json(p.config, {"version": 1, "fans": fans})


def interpolate(points: list[list[float]], temp: float) -> float:
    if temp <= points[0][0]:
        return points[0][1]
    for (t0, p0), (t1, p1) in zip(points, points[1:]):
        if temp <= t1:
            return p0 + (p1 - p0) * (temp - t0) / (t1 - t0)
    return points[-1][1]


# ── the service ───────────────────────────────────────────────────────────


def log(msg: str) -> None:
    print(f"loft-fan-control: {msg}", file=sys.stderr, flush=True)


class Daemon:
    def __init__(self, p: Paths):
        self.p = p
        self.saved: dict[str, dict] = read_json(p.saved) or {}
        self.last: dict[str, float] = {}
        self.state: dict[str, dict] = {}

    def _persist_saved(self) -> None:
        write_json(self.p.saved, self.saved)

    def _take(self, c: Channel) -> None:
        """Remember how the fan was before the first write to it."""
        if c.key in self.saved:
            return
        enable = read_int(c.hw / f"pwm{c.n}_enable")
        self.saved[c.key] = {
            "hwmon": c.hw.name,
            "n": c.n,
            "enable": enable if enable is not None and 0 <= enable <= 5 else AUTO,
            "pwm": read_int(c.hw / f"pwm{c.n}"),
        }
        self._persist_saved()

    def restore(self, key: str, chans: dict[str, Channel] | None = None) -> None:
        s = self.saved.get(key)
        if s is None:
            return
        c = (chans or {}).get(key)
        hwmon, n = (c.hw.name, c.n) if c else (str(s.get("hwmon")), int(s.get("n") or 0))
        enable = s.get("enable") if isinstance(s.get("enable"), int) else AUTO
        try:
            if enable == MANUAL and isinstance(s.get("pwm"), int):
                write_attr(self.p, hwmon, f"pwm{n}", s["pwm"])
            write_attr(self.p, hwmon, f"pwm{n}_enable", enable)
        except (OSError, Refused) as e:
            log(f"restoring {key} to pwm_enable={enable} failed ({e}); trying automatic, then full speed")
            for fallback in (AUTO, 0):
                try:
                    write_attr(self.p, hwmon, f"pwm{n}_enable", fallback)
                    break
                except (OSError, Refused) as e2:
                    log(f"{key}: pwm_enable={fallback} failed too ({e2})")
        del self.saved[key]
        self.last.pop(key, None)
        self._persist_saved()

    def restore_all(self) -> None:
        chans = {c.key: c for c in pwms(self.p)}
        for key in list(self.saved):
            self.restore(key, chans)

    def tick(self) -> None:
        pol = policy(self.p)
        if pol is None:
            self.restore_all()
            self.state = {}
            return
        cfg = load_config(self.p, pol)
        chans = {c.key: c for c in pwms(self.p)}
        tchans = {c.key: c for c in temps(self.p)}
        cpu_hot = max((t for c in tchans.values() if CPU_CHIPS.match(c.chip) and (t := read_temp(c)) is not None), default=None)
        state: dict[str, dict] = {}
        wanted = set()
        for key, s in cfg.items():
            c = chans.get(key)
            if c is None or not writable(c):
                state[key] = {"error": "fan not found or not writable"}
                continue
            src = tchans.get(s.get("source", ""))
            temp = read_temp(src) if src else None
            if s["mode"] == "curve":
                if temp is None:
                    state[key] = {"error": "temperature source unreadable: back to automatic"}
                    continue
                pct = interpolate(s["points"], temp)
                prev = self.last.get(key)
                if prev is not None and pct < prev:
                    pct = max(pct, prev - STEP_DOWN)
            else:
                pct = s["percent"]
            critical = any(t is not None and t >= pol.critical_temp for t in (temp, cpu_hot))
            if critical:
                pct = 100.0
            self.last[key] = pct
            value = to_pwm(pct, pol, s["stop"])
            try:
                self._take(c)
                if read_int(c.hw / f"pwm{c.n}_enable") != MANUAL:
                    write_attr(self.p, c.hw.name, f"pwm{c.n}_enable", MANUAL)
                write_attr(self.p, c.hw.name, f"pwm{c.n}", value)
            except (OSError, Refused) as e:
                state[key] = {"error": f"the driver refused: {e}"}
                continue
            wanted.add(key)
            state[key] = {"percent": round(value * 100 / 255), "pwm": value, "temp": temp, "critical": critical}
        for key in list(self.saved):
            if key not in wanted:
                self.restore(key, chans)
        if state != self.state:
            self.state = state
            try:
                write_json(self.p.state, state)
            except OSError as e:
                log(f"can't write {self.p.state}: {e}")


def run(p: Paths, once: bool = False) -> int:
    d = Daemon(p)
    stopping = []

    def _stop(signum, _frame):
        stopping.append(signum)

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, _stop)
    p.run.mkdir(mode=0o755, parents=True, exist_ok=True)
    p.pidfile.write_text(f"{os.getpid()}\n")
    # Fans a crashed predecessor left in manual go back first.
    d.restore_all()
    try:
        while not stopping:
            try:
                d.tick()
            except Exception as e:  # noqa: BLE001 — a bug must not leave a fan pinned
                log(f"tick failed ({e!r}); restoring every fan")
                d.restore_all()
            if once:
                break
            pol = policy(p) or Policy()
            mtime = _mtime(p.config)
            deadline = time.monotonic() + pol.interval
            while not stopping and time.monotonic() < deadline and _mtime(p.config) == mtime:
                time.sleep(0.2)
    finally:
        d.restore_all()
        p.pidfile.unlink(missing_ok=True)
        p.state.unlink(missing_ok=True)
    return 0


def _mtime(f: Path) -> float:
    try:
        return f.stat().st_mtime_ns
    except OSError:
        return 0


def restore(p: Paths) -> int:
    Daemon(p).restore_all()
    p.state.unlink(missing_ok=True)
    return 0


# ── status (no privileges needed; `loft fans status` calls this) ──────────


def daemon_alive(p: Paths) -> bool:
    pid = read_int(p.pidfile)
    if not pid or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def status(p: Paths) -> dict:
    pol = policy(p)
    cfg = load_config(p, pol) if pol else {}
    applied = read_json(p.state) or {}
    fans = []
    for c in pwms(p):
        pwm = read_int(c.hw / f"pwm{c.n}")
        fans.append(
            {
                "id": c.id,
                "key": c.key,
                "chip": c.chip,
                "label": c.label,
                "writable": writable(c),
                "enable": read_int(c.hw / f"pwm{c.n}_enable"),
                "pwm": pwm,
                "percent": round(pwm * 100 / 255) if pwm is not None else None,
                "rpm": read_int(c.hw / f"fan{c.n}_input"),
                "setting": cfg.get(c.key) or {"mode": "auto"},
                "applied": applied.get(c.key),
            }
        )
    ts = []
    for c in temps(p):
        v = read_temp(c)
        if v is not None:
            ts.append({"id": c.id, "key": c.key, "chip": c.chip, "label": c.label, "value": v, "cpu": bool(CPU_CHIPS.match(c.chip))})
    return {
        "enabled": pol is not None,
        "daemon": daemon_alive(p),
        "minPercent": pol.min_percent if pol else None,
        "allowStop": pol.allow_stop if pol else False,
        "criticalTemp": pol.critical_temp if pol else None,
        "fans": fans,
        "temps": ts,
    }


# ── CLI ───────────────────────────────────────────────────────────────────


def _setting(p: Paths, args) -> tuple[str, dict | None]:
    pol = policy(p)
    if pol is None:
        raise Refused(f"fan control isn't enabled on this machine ({p.policy} missing; programs.loft.fanControl.enable)")
    if args.cmd == "reset":
        return "*", None
    if args.cmd == "auto" and "@" in args.fan and len(args.fan) <= 256:
        return args.fan, None  # a stable key: also forgets a fan that's gone
    fan = find(pwms(p), args.fan, FAN_ID)
    if args.cmd == "auto":
        return fan.key, None
    if not writable(fan):
        raise Refused(f"{fan.id} has no writable pwm{fan.n} / pwm{fan.n}_enable (read-only on this hardware)")
    s: dict = {"mode": args.cmd, "stop": bool(args.allow_stop)}
    source = getattr(args, "source", None)
    if source:
        s["source"] = find(temps(p), source, TEMP_ID).key
    if args.cmd == "manual":
        s["percent"] = args.percent
    else:
        s["points"] = parse_points(args.points)
    return fan.key, clean_setting(s, pol)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="loft-fan-control", description="set hwmon fans to manual speeds or temperature curves")
    ap.add_argument("--root", help=argparse.SUPPRESS)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("manual", help="a fixed speed")
    s.add_argument("fan", help="hwmonN/pwmN")
    s.add_argument("percent", type=float)
    s.add_argument("--source", help="hwmonN/tempN: over criticalTemp the fan runs at 100 %%")
    s.add_argument("--allow-stop", action="store_true", help="0 %% really means stopped")
    s = sub.add_parser("curve", help="speed from a temperature")
    s.add_argument("fan", help="hwmonN/pwmN")
    s.add_argument("source", help="hwmonN/tempN")
    s.add_argument("points", help="TEMP:PERCENT,… (2–8 points, temperatures increasing)")
    s.add_argument("--allow-stop", action="store_true", help="a 0 %% point really means stopped")
    s = sub.add_parser("auto", help="back to the driver / firmware's automatic control")
    s.add_argument("fan", help="hwmonN/pwmN")
    sub.add_parser("reset", help="every fan back to automatic")
    sub.add_parser("status", help="fans, temperatures and settings as JSON")
    s = sub.add_parser("run", help="the service: apply the settings until stopped")
    s.add_argument("--once", action="store_true", help=argparse.SUPPRESS)
    sub.add_parser("restore", help="put every fan the service took back the way it was")
    args = ap.parse_args(argv)
    if args.root and os.geteuid() == 0:
        print("loft-fan-control: --root is for tests only", file=sys.stderr)
        return 2
    if args.cmd in ("run", "restore") and os.environ.get("PKEXEC_UID"):
        print(f"loft-fan-control: `{args.cmd}` belongs to the loft-fans service", file=sys.stderr)
        return 2
    p = Paths(Path(args.root) if args.root else Path("/"))
    os.umask(0o022)
    try:
        if args.cmd == "status":
            print(json.dumps(status(p), indent=2))
        elif args.cmd == "run":
            return run(p, once=args.once)
        elif args.cmd == "restore":
            return restore(p)
        else:
            key, setting = _setting(p, args)
            update_config(p, key, setting)
            what = "every fan → automatic" if key == "*" else f"{key} → {(setting or {'mode': 'auto'})['mode']}"
            print(f"loft-fan-control: {what}")
    except Refused as e:
        print(f"loft-fan-control: refused: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
