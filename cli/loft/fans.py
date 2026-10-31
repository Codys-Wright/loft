"""Fan control (`loft fans …`, System Monitor → Disks & Sensors, issue #7).

  status   every hwmon pwm output (writable or read-only), its setting and
           what the loft-fans service last applied, and the temperatures a
           curve can follow — JSON for the shell (src/services/Fans.qml)
  manual / curve / auto / reset
           change a fan's setting through the privileged helper
           (fan_helper.py, `loft-fan-control`) run by pkexec

The shell never writes /sys and never runs as root: the helper validates the
request and records it, the root `loft-fans` service applies it. Both come
from the NixOS module's programs.loft.fanControl, which also writes
/etc/loft/fans.json (the helper's path and the machine's limits). Without
it, `status` still lists the fans, read-only.

Tests: LOFT_FAN_ROOT points status at a fake sysfs tree, LOFT_FAN_HELPER
replaces the pkexec command line.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

from . import fan_helper


class FanError(Exception):
    pass


def root() -> Path:
    return Path(os.environ.get("LOFT_FAN_ROOT") or "/")


def _helper_argv() -> list[str]:
    if os.environ.get("LOFT_FAN_HELPER"):  # tests: run the helper directly
        return os.environ["LOFT_FAN_HELPER"].split()
    p = fan_helper.Paths(root())
    helper = (fan_helper.read_json(p.policy) or {}).get("helper")
    if not helper:
        raise FanError(f"fan control isn't set up on this machine ({p.policy} missing); enable programs.loft.fanControl in the NixOS config (nixosModules.default)")
    pkexec = "/run/wrappers/bin/pkexec"
    if not Path(pkexec).exists():
        raise FanError(f"{pkexec} is missing (security.polkit.enablePkexecWrapper, set by programs.loft.fanControl)")
    return [pkexec, helper]


def helper(*argv: str) -> str:
    # pkexec refuses to run when $SHELL isn't listed in /etc/shells; the helper never uses it.
    r = subprocess.run([*_helper_argv(), *argv], capture_output=True, text=True, env={**os.environ, "SHELL": "/bin/sh"})
    if r.returncode != 0:
        msg = (r.stderr or r.stdout).strip() or f"exit {r.returncode}"
        raise FanError(msg.removeprefix("loft-fan-control: "))
    return r.stdout.strip()


def cmd_status(ctx, args) -> None:
    s = fan_helper.status(fan_helper.Paths(root()))
    if args.json:
        print(json.dumps(s))
        return
    if not s["enabled"]:
        print("fan control: off on this machine (programs.loft.fanControl) — read-only")
    elif not s["daemon"]:
        print("fan control: on, but the loft-fans service isn't running")
    if not s["fans"]:
        print("no fans with a pwm output")
    for f in s["fans"]:
        rpm = f" {f['rpm']} RPM" if f["rpm"] is not None else ""
        mode = f["setting"]["mode"] if f["writable"] else "read-only"
        print(f"{f['id']:<14} {f['chip']} {f['label']}: {f['percent']}%{rpm} [{mode}]")


def _run(*argv: str) -> None:
    print(helper(*argv).removeprefix("loft-fan-control: "))


def add_parser(top) -> None:
    g = top.add_parser("fans", help="fan speeds: manual or a temperature curve (pkexec helper)")
    sub = g.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("status", help="fans, their settings and the temperatures")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_status)

    s = sub.add_parser("manual", help="a fixed speed (percent; the machine's floor applies)")
    s.add_argument("fan", help="hwmonN/pwmN")
    s.add_argument("percent", type=float)
    s.add_argument("--source", help="hwmonN/tempN watched for criticalTemp")
    s.add_argument("--allow-stop", action="store_true")
    s.set_defaults(
        fn=lambda ctx, a: _run(
            "manual", a.fan, str(a.percent), *(["--source", a.source] if a.source else []), *(["--allow-stop"] if a.allow_stop else [])
        )
    )

    s = sub.add_parser("curve", help="speed follows a temperature")
    s.add_argument("fan", help="hwmonN/pwmN")
    s.add_argument("source", help="hwmonN/tempN")
    s.add_argument("points", help="TEMP:PERCENT,… e.g. 40:25,60:45,80:100")
    s.add_argument("--allow-stop", action="store_true")
    s.set_defaults(fn=lambda ctx, a: _run("curve", a.fan, a.source, a.points, *(["--allow-stop"] if a.allow_stop else [])))

    s = sub.add_parser("auto", help="back to automatic (the driver / firmware)")
    s.add_argument("fan", help="hwmonN/pwmN")
    s.set_defaults(fn=lambda ctx, a: _run("auto", a.fan))

    s = sub.add_parser("reset", help="every fan back to automatic")
    s.set_defaults(fn=lambda ctx, a: _run("reset"))
