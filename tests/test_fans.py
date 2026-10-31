"""Fan control (cli/loft/fans.py) and its privileged helper
(cli/loft/fan_helper.py), against a fake sysfs tree: the helper runs
unprivileged with --root, the CLI reaches it through LOFT_FAN_HELPER instead
of pkexec. Nothing here touches the real /sys."""

from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

from loft import fan_helper
from loft.cli import main

HELPER = Path(fan_helper.__file__)
NCT = "nct6798@platform/nct6775.656"
K10 = "k10temp@pci0000:00/0000:00:18.3"


def fake_sysfs(root: Path, *, renumber: bool = False) -> None:
    """A Super I/O chip with two pwm outputs (pwm2 read-only), a CPU sensor
    and an amdgpu without pwm — the class links resolve into sys/devices like
    the real thing."""
    devices = root / "sys/devices"
    cls = root / "sys/class/hwmon"
    cls.mkdir(parents=True, exist_ok=True)

    def chip(n: int, dev: str, files: dict[str, str]) -> Path:
        d = devices / dev / "hwmon" / f"hwmon{n}"
        d.mkdir(parents=True)
        os.symlink(os.path.relpath(devices / dev, d), d / "device")
        for name, value in files.items():
            (d / name).write_text(value + "\n")
        os.symlink(os.path.relpath(d, cls), cls / f"hwmon{n}")
        return d

    a, b = (5, 2) if renumber else (2, 5)
    nct = chip(
        a,
        "platform/nct6775.656",
        {
            "name": "nct6798",
            "pwm1": "120",
            "pwm1_enable": "5",
            "fan1_input": "900",
            "fan1_label": "CPU fan",
            "pwm2": "255",
            "pwm2_enable": "2",
            "fan2_input": "0",
            "temp1_input": "41000",
        },
    )
    os.chmod(nct / "pwm2", 0o444)
    chip(b, "pci0000:00/0000:00:18.3", {"name": "k10temp", "temp1_input": "45000", "temp1_label": "Tctl"})
    chip(7, "pci0000:00/0000:03:00.0", {"name": "amdgpu", "temp1_input": "50000"})


def policy(root: Path, **kw) -> None:
    p = root / "etc/loft/fans.json"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps({"helper": "x", "minPercent": 20, "allowStop": False, "criticalTemp": 90, **kw}))


def run_helper(root: Path, *argv: str) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = fan_helper.main(["--root", str(root), *argv])
    return rc, out.getvalue(), err.getvalue()


class Base(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        fake_sysfs(self.root)
        policy(self.root)
        self.p = fan_helper.Paths(self.root)

    def tearDown(self):
        shutil.rmtree(self.root)

    def hw(self, n: int) -> Path:
        return self.root / "sys/class/hwmon" / f"hwmon{n}"

    def attr(self, n: int, name: str) -> int:
        return int((self.hw(n) / name).read_text())

    def set_temp(self, n: int, celsius: float) -> None:
        (self.hw(n) / "temp1_input").write_text(f"{int(celsius * 1000)}\n")

    def ok(self, *argv: str) -> str:
        rc, out, err = run_helper(self.root, *argv)
        self.assertEqual(rc, 0, err)
        return out

    def refused(self, *argv: str, why: str = "") -> None:
        before = self.p.config.read_bytes() if self.p.config.exists() else None
        rc, _, err = run_helper(self.root, *argv)
        self.assertEqual(rc, 1, err)
        self.assertIn(why, err)
        after = self.p.config.read_bytes() if self.p.config.exists() else None
        self.assertEqual(before, after)  # a refusal never changes the settings


class Writes(Base):
    def test_only_pwm_attrs_inside_devices(self):
        fan_helper.write_attr(self.p, "hwmon2", "pwm1", 300)
        self.assertEqual(self.attr(2, "pwm1"), 255)  # clamped
        fan_helper.write_attr(self.p, "hwmon2", "pwm1", -4)
        self.assertEqual(self.attr(2, "pwm1"), 0)
        for hwmon, attr, value in [
            ("hwmon2", "fan1_input", 1),
            ("hwmon2", "temp1_input", 1),
            ("hwmon2", "name", 1),
            ("hwmon2", "pwm1/../name", 1),
            ("hwmon2", "../hwmon5/pwm1", 1),
            ("../../etc", "pwm1", 1),
            ("hwmon2", "pwm1_enable", 9),  # not a pwm_enable value
            ("hwmon2", "pwm1", "128"),  # not an int
        ]:
            with self.assertRaises(fan_helper.Refused, msg=f"{hwmon}/{attr}={value!r}"):
                fan_helper.write_attr(self.p, hwmon, attr, value)
        self.assertEqual((self.hw(2) / "name").read_text(), "nct6798\n")

    def test_never_creates_or_follows(self):
        with self.assertRaises(FileNotFoundError):
            fan_helper.write_attr(self.p, "hwmon2", "pwm3", 100)
        self.assertFalse((self.hw(2) / "pwm3").exists())
        # A planted link where an attribute should be is refused (O_NOFOLLOW).
        victim = self.root / "victim"
        victim.write_text("keep\n")
        os.symlink(victim, self.hw(2) / "pwm4")
        with self.assertRaises(OSError):
            fan_helper.write_attr(self.p, "hwmon2", "pwm4", 100)
        self.assertEqual(victim.read_text(), "keep\n")
        # A hwmon link that escapes sys/devices is refused.
        outside = self.root / "elsewhere"
        outside.mkdir()
        (outside / "pwm1").write_text("0\n")
        os.symlink(outside, self.root / "sys/class/hwmon/hwmon9")
        with self.assertRaises(fan_helper.Refused):
            fan_helper.write_attr(self.p, "hwmon9", "pwm1", 100)
        self.assertEqual((outside / "pwm1").read_text(), "0\n")

    def test_clamping(self):
        pol = fan_helper.Policy(min_percent=20)
        self.assertEqual(fan_helper.to_pwm(5, pol, stop=False), 51)  # the floor
        self.assertEqual(fan_helper.to_pwm(0, pol, stop=True), 51)  # stop needs the machine's allowStop
        self.assertEqual(fan_helper.to_pwm(150, pol, stop=False), 255)
        self.assertEqual(fan_helper.to_pwm(50, pol, stop=False), 128)
        pol.allow_stop = True
        self.assertEqual(fan_helper.to_pwm(0, pol, stop=True), 0)
        self.assertEqual(fan_helper.to_pwm(0, pol, stop=False), 51)
        self.assertEqual(fan_helper.to_pwm(3, pol, stop=True), 51)  # only exactly 0 stops
        # A policy file can't lower the floor under ABS_FLOOR.
        policy(self.root, minPercent=0)
        self.assertEqual(fan_helper.policy(self.p).min_percent, fan_helper.ABS_FLOOR)

    def test_interpolate(self):
        pts = [[30, 20], [60, 50], [80, 100]]
        self.assertEqual(fan_helper.interpolate(pts, 10), 20)
        self.assertEqual(fan_helper.interpolate(pts, 45), 35)
        self.assertEqual(fan_helper.interpolate(pts, 70), 75)
        self.assertEqual(fan_helper.interpolate(pts, 95), 100)


class Settings(Base):
    def config(self) -> dict:
        return json.loads(self.p.config.read_text())["fans"]

    def test_set_and_status(self):
        self.ok("manual", "hwmon2/pwm1", "40", "--source", "hwmon5/temp1")
        self.assertEqual(
            self.config()[f"{NCT}/pwm1"], {"mode": "manual", "percent": 40.0, "stop": False, "source": f"{K10}/temp1"}
        )
        self.ok("curve", "hwmon2/pwm1", "hwmon5/temp1", "30:20,60:50,80:100")
        s = self.config()[f"{NCT}/pwm1"]
        self.assertEqual(s["mode"], "curve")
        self.assertEqual(s["points"], [[30, 20], [60, 50], [80, 100]])
        st = fan_helper.status(self.p)
        self.assertTrue(st["enabled"])
        self.assertFalse(st["daemon"])
        fans = {f["id"]: f for f in st["fans"]}
        self.assertEqual(sorted(fans), ["hwmon2/pwm1", "hwmon2/pwm2"])
        self.assertTrue(fans["hwmon2/pwm1"]["writable"])
        self.assertEqual(fans["hwmon2/pwm1"]["label"], "CPU fan")
        self.assertEqual(fans["hwmon2/pwm1"]["rpm"], 900)
        self.assertEqual(fans["hwmon2/pwm1"]["setting"]["mode"], "curve")
        self.assertFalse(fans["hwmon2/pwm2"]["writable"])  # read-only shows, not fails
        self.assertEqual(fans["hwmon2/pwm2"]["setting"], {"mode": "auto"})
        self.assertIn("hwmon5/temp1", [t["id"] for t in st["temps"]])
        self.ok("auto", "hwmon2/pwm1")
        self.assertEqual(self.config(), {})
        self.ok("manual", "hwmon2/pwm1", "40")
        self.ok("reset")
        self.assertEqual(self.config(), {})
        # Setting a mode writes nothing to /sys: that's the service's job.
        self.assertEqual(self.attr(2, "pwm1_enable"), 5)
        self.assertEqual(self.attr(2, "pwm1"), 120)

    def test_refusals(self):
        self.refused("manual", "hwmon2/pwm2", "50", why="read-only")
        self.refused("manual", "hwmon2/pwm3", "50", why="no such channel")
        self.refused("manual", "hwmon2/fan1", "50", why="bad channel")
        self.refused("manual", "../../etc/pwm1", "50", why="bad channel")
        self.refused("manual", "hwmon2/pwm1", "0", why="stops the fan")
        self.refused("manual", "hwmon2/pwm1", "0", "--allow-stop", why="isn't allowed on this machine")
        self.refused("manual", "hwmon2/pwm1", "101", why="0–100")
        self.refused("manual", "hwmon2/pwm1", "nan", why="0–100")
        self.refused("curve", "hwmon2/pwm1", "hwmon5/temp1", "30:20", why="2 to")
        self.refused("curve", "hwmon2/pwm1", "hwmon5/temp1", "60:20,30:50", why="increase")
        self.refused("curve", "hwmon2/pwm1", "hwmon5/temp1", "30:20,200:50", why="out of range")
        self.refused("curve", "hwmon2/pwm1", "hwmon5/temp1", "30:0,60:50", why="stops the fan")
        self.refused("curve", "hwmon2/pwm1", "hwmon5/temp9", "30:20,60:50", why="no such channel")
        self.refused("curve", "hwmon2/pwm1", "hwmon5/temp1", "x", why="bad curve point")
        os.unlink(self.p.policy)
        self.refused("manual", "hwmon2/pwm1", "50", why="isn't enabled")

    def test_allow_stop(self):
        policy(self.root, allowStop=True)
        self.ok("manual", "hwmon2/pwm1", "0", "--allow-stop")
        self.assertTrue(self.config()[f"{NCT}/pwm1"]["stop"])

    def test_service_commands_refused_under_pkexec(self):
        os.environ["PKEXEC_UID"] = "1000"
        try:
            for cmd in ("run", "restore"):
                rc, _, err = run_helper(self.root, cmd)
                self.assertEqual(rc, 2, err)
        finally:
            del os.environ["PKEXEC_UID"]

    def test_root_flag_refused_as_root(self):
        if os.geteuid() != 0:
            self.skipTest("only meaningful as root")
        self.assertEqual(fan_helper.main(["--root", str(self.root), "status"]), 2)


class Service(Base):
    def tick(self, d: fan_helper.Daemon | None = None) -> fan_helper.Daemon:
        d = d or fan_helper.Daemon(self.p)
        d.tick()
        return d

    def test_manual_then_auto_restores_original(self):
        self.ok("manual", "hwmon2/pwm1", "40")
        d = self.tick()
        self.assertEqual(self.attr(2, "pwm1_enable"), 1)
        self.assertEqual(self.attr(2, "pwm1"), 102)
        saved = json.loads(self.p.saved.read_text())
        self.assertEqual(saved[f"{NCT}/pwm1"]["enable"], 5)  # the original, saved before the first write
        self.assertEqual(json.loads(self.p.state.read_text())[f"{NCT}/pwm1"]["percent"], 40)
        self.ok("auto", "hwmon2/pwm1")
        self.tick(d)
        self.assertEqual(self.attr(2, "pwm1_enable"), 5)
        self.assertEqual(json.loads(self.p.saved.read_text()), {})

    def test_floor_and_critical(self):
        self.ok("manual", "hwmon2/pwm1", "20", "--source", "hwmon2/temp1")
        d = self.tick()
        self.assertEqual(self.attr(2, "pwm1"), 51)
        # A hand-edited config under the floor is clamped by the service too.
        cfg = json.loads(self.p.config.read_text())
        cfg["fans"][f"{NCT}/pwm1"]["percent"] = 1
        self.p.config.write_text(json.dumps(cfg))
        self.tick(d)
        self.assertEqual(self.attr(2, "pwm1"), 51)
        self.set_temp(2, 95)  # the fan's own source
        self.tick(d)
        self.assertEqual(self.attr(2, "pwm1"), 255)
        self.set_temp(2, 40)
        self.set_temp(5, 92)  # any CPU sensor
        self.tick(d)
        self.assertEqual(self.attr(2, "pwm1"), 255)
        self.assertTrue(json.loads(self.p.state.read_text())[f"{NCT}/pwm1"]["critical"])

    def test_curve_ramps_down_slowly(self):
        self.ok("curve", "hwmon2/pwm1", "hwmon5/temp1", "40:20,80:100")
        self.set_temp(5, 80)
        d = self.tick()
        self.assertEqual(self.attr(2, "pwm1"), 255)
        self.set_temp(5, 40)
        self.tick(d)
        self.assertEqual(self.attr(2, "pwm1"), round(96 * 255 / 100))  # at most STEP_DOWN per tick
        self.tick(d)
        self.assertEqual(self.attr(2, "pwm1"), round(92 * 255 / 100))
        self.set_temp(5, 80)  # up: at once
        self.tick(d)
        self.assertEqual(self.attr(2, "pwm1"), 255)

    def test_unreadable_source_goes_automatic(self):
        self.ok("curve", "hwmon2/pwm1", "hwmon5/temp1", "40:20,80:100")
        d = self.tick()
        self.assertEqual(self.attr(2, "pwm1_enable"), 1)
        (self.hw(5) / "temp1_input").write_text("garbage\n")
        self.tick(d)
        self.assertEqual(self.attr(2, "pwm1_enable"), 5)
        self.assertIn("unreadable", json.loads(self.p.state.read_text())[f"{NCT}/pwm1"]["error"])

    def test_policy_removed_restores(self):
        self.ok("manual", "hwmon2/pwm1", "60")
        d = self.tick()
        os.unlink(self.p.policy)
        self.tick(d)
        self.assertEqual(self.attr(2, "pwm1_enable"), 5)

    def test_refused_enable_falls_back(self):
        """A driver that won't take the original value back: automatic, else full speed."""
        self.ok("manual", "hwmon2/pwm1", "60")
        d = self.tick()
        d.saved[f"{NCT}/pwm1"]["enable"] = 4
        real = fan_helper.write_attr
        calls = []

        def picky(p, hwmon, attr, value):
            calls.append((attr, value))
            if attr.endswith("_enable") and value != 0:
                raise OSError(22, "Invalid argument")
            real(p, hwmon, attr, value)

        fan_helper.write_attr = picky
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                d.restore_all()
        finally:
            fan_helper.write_attr = real
        self.assertEqual(calls, [("pwm1_enable", 4), ("pwm1_enable", 2), ("pwm1_enable", 0)])
        self.assertEqual(self.attr(2, "pwm1_enable"), 0)

    def test_stable_keys_survive_renumbering(self):
        self.ok("manual", "hwmon2/pwm1", "60", "--source", "hwmon5/temp1")
        shutil.rmtree(self.root / "sys")
        fake_sysfs(self.root, renumber=True)  # next boot: nct6798 is hwmon5, k10temp hwmon2
        self.tick()
        self.assertEqual(self.attr(5, "pwm1"), 153)
        self.assertEqual(self.attr(5, "pwm1_enable"), 1)

    def test_crash_then_restore(self):
        """SIGKILL leaves the fan in manual; `restore` (ExecStopPost) puts it back."""
        self.ok("manual", "hwmon2/pwm1", "60")
        self.tick()  # the "crashed" daemon never restores
        self.assertEqual(self.attr(2, "pwm1_enable"), 1)
        self.ok("restore")
        self.assertEqual(self.attr(2, "pwm1_enable"), 5)
        self.assertEqual(json.loads(self.p.saved.read_text()), {})

    def test_daemon_sigterm_restores(self):
        self.ok("manual", "hwmon2/pwm1", "60")
        env = {**os.environ, "PYTHONPATH": str(HELPER.parent.parent)}
        proc = subprocess.Popen([sys.executable, "-B", str(HELPER), "--root", str(self.root), "run"], env=env, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 10
            while self.attr(2, "pwm1_enable") != 1 and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertEqual(self.attr(2, "pwm1"), 153)
            self.assertTrue(fan_helper.status(self.p)["daemon"])
            # A new setting is picked up at once (config mtime).
            self.ok("manual", "hwmon2/pwm1", "80")
            deadline = time.monotonic() + 5
            while self.attr(2, "pwm1") != 204 and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertEqual(self.attr(2, "pwm1"), 204)
        finally:
            proc.send_signal(signal.SIGTERM)
            _, err = proc.communicate(timeout=10)
        self.assertEqual(proc.returncode, 0, err)
        self.assertEqual(self.attr(2, "pwm1_enable"), 5)
        self.assertFalse(self.p.pidfile.exists())


def loft(*argv: str) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = main(list(argv))
    return rc, out.getvalue(), err.getvalue()


class Cli(Base):
    def setUp(self):
        super().setUp()
        self.saved_env = dict(os.environ)
        os.environ["LOFT_FAN_ROOT"] = str(self.root)
        os.environ["LOFT_FAN_HELPER"] = f"{sys.executable} -B {HELPER} --root {self.root}"

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.saved_env)
        super().tearDown()

    def test_cli_through_helper(self):
        rc, out, err = loft("fans", "curve", "hwmon2/pwm1", "hwmon5/temp1", "40:25,70:60,85:100")
        self.assertEqual(rc, 0, err)
        rc, out, _ = loft("fans", "status", "--json")
        s = json.loads(out)
        self.assertEqual({f["id"]: f["setting"]["mode"] for f in s["fans"]}, {"hwmon2/pwm1": "curve", "hwmon2/pwm2": "auto"})
        rc, out, err = loft("fans", "manual", "hwmon2/pwm2", "50")
        self.assertEqual(rc, 1)
        self.assertIn("read-only", err)
        rc, out, _ = loft("fans", "status")
        self.assertIn("[read-only]", out)
        self.assertEqual(loft("fans", "reset")[0], 0)

    def test_not_set_up(self):
        del os.environ["LOFT_FAN_HELPER"]
        os.unlink(self.p.policy)
        rc, out, err = loft("fans", "manual", "hwmon2/pwm1", "50")
        self.assertEqual(rc, 1)
        self.assertIn("programs.loft.fanControl", err)
        rc, out, _ = loft("fans", "status", "--json")
        self.assertFalse(json.loads(out)["enabled"])


if __name__ == "__main__":
    unittest.main()
