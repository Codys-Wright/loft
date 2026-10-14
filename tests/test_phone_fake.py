"""The fake tetherd (tests/fake_tetherd.py) speaks tetherd's socket protocol.

Loft's headless phone tests run the shell against the fake, so it has to
answer the way the real daemon does: the subscribe preamble, list replies on
the same connection, "OK" acks, broadcasts for sends and calls — with the
fields of the recorded session in tests/fixtures/tether/session.jsonl (which
tests/phone.test.js replays through src/services/phone.js).
"""

import json
import os
import socket
import tempfile
import threading
import unittest
from pathlib import Path

import fake_tetherd as F

FIXTURE = Path(__file__).parent / "fixtures" / "tether" / "session.jsonl"


def fixture_keys():
    """command → the set of top-level keys the fixture's lines carry."""
    keys = {}
    for line in FIXTURE.read_text().splitlines():
        try:
            m = json.loads(line)
        except ValueError:
            continue
        if isinstance(m, dict):
            keys.setdefault(m["command"], set()).update(m.keys())
    return keys


class Client:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(3)
        self.s.connect(path)
        self.buf = b""

    def send(self, **m):
        self.s.sendall((json.dumps(m) + "\n").encode())

    def line(self):
        while b"\n" not in self.buf:
            chunk = self.s.recv(65536)
            if not chunk:
                raise EOFError
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return line.decode()

    def obj(self):
        """The next JSON object, skipping "OK" acks."""
        while True:
            line = self.line()
            if line != "OK":
                return json.loads(line)

    def until(self, command):
        while True:
            m = self.obj()
            if m.get("command") == command:
                return m

    def close(self):
        self.s.close()


class FakeTetherdTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "tetherd.sock")
        self.daemon = F.Daemon(self.path, F.Phone("connected", now=lambda: 1760000000))
        srv = self.daemon.start()
        self.thread = threading.Thread(target=srv.serve_forever, daemon=True)
        self.thread.start()
        self.c = Client(self.path)
        self.c.send(command="subscribe")

    def tearDown(self):
        self.c.close()
        self.daemon.stop()
        self.tmp.cleanup()

    def test_subscribe_preamble(self):
        self.assertEqual(self.c.obj()["command"], "protocol_info")
        self.assertEqual(self.c.obj()["command"], "state_snapshot")
        link = self.c.obj()
        self.assertEqual(link["command"], "bt_connection_changed")
        self.assertTrue(link["map_open"])
        self.assertEqual(link["calls"]["battery"], 4)

    def test_shapes_match_the_fixture(self):
        want = fixture_keys()
        self.c.send(command="bt_status")
        self.c.send(command="bt_list_devices")
        self.c.send(command="bt_list_threads")
        self.c.send(command="bt_list_messages", thread="tel:+15035550101")
        self.c.send(command="fake_inject", kind="message")
        self.c.send(command="fake_inject", kind="notification")
        self.c.send(command="fake_inject", kind="call")
        got = {}
        while len(got) < 10:
            m = self.c.obj()
            got.setdefault(m["command"], m)
            if m["command"] == "bt_calls":
                break
        for command, m in got.items():
            if command not in want:
                continue
            missing = want[command] - set(m.keys())
            self.assertFalse(missing, f"{command} lacks {missing}")
        for d in got["bt_devices"]["devices"]:
            self.assertEqual(set(d), set(json.loads(FIXTURE.read_text().splitlines()[4])["devices"][1]))
        for t in got["bt_threads"]["threads"]:
            self.assertTrue({"thread", "name", "address", "preview", "timestamp", "unread", "count"} <= set(t))
        for m in got["bt_messages"]["messages"]:
            self.assertEqual(set(m), {"handle", "thread", "address", "name", "body", "timestamp", "outgoing", "read", "folder"})
        call = got["bt_calls"]["calls"][0]
        self.assertEqual(set(call), {"path", "number", "withheld", "name", "incoming_line", "state", "multiparty", "ringing", "outgoing", "connected"})

    def test_send_message_broadcasts(self):
        self.c.until("bt_connection_changed")
        other = Client(self.path)
        other.send(command="subscribe")
        other.until("bt_connection_changed")
        self.c.send(command="bt_send_message", thread="tel:+15035550101", body="On my way", operation_id="loft-7")
        self.assertEqual(self.c.line(), "OK")
        for client in (self.c, other):
            sent = client.until("bt_message")
            self.assertTrue(sent["outgoing"])
            self.assertEqual(sent["body"], "On my way")
            res = client.until("bt_send_result")
            self.assertEqual(res, {"command": "bt_send_result", "thread": "tel:+15035550101", "operation_id": "loft-7", "success": True})
        other.close()

    def test_call_answer_and_hang_up(self):
        self.c.until("bt_connection_changed")
        self.c.send(command="fake_inject", kind="call")
        ringing = self.c.until("bt_calls")["calls"][0]
        self.assertTrue(ringing["ringing"])
        self.c.send(command="bt_call_action", action="answer", path=ringing["path"])
        calls = self.c.until("bt_calls")["calls"]
        self.assertEqual(calls[0]["state"], "active")
        self.assertTrue(calls[0]["connected"])
        self.assertEqual(self.c.until("bt_call_result"), {"command": "bt_call_result", "action": "answer", "success": True})
        self.c.send(command="bt_call_action", action="hangup", path=ringing["path"])
        self.assertEqual(self.c.until("bt_calls")["calls"], [])
        # Nothing left to hang up. (Like tetherd, a subscriber gets each result
        # twice: broadcast and as the reply.)
        self.c.send(command="bt_call_action", action="hangup", path=ringing["path"])
        results = [self.c.until("bt_call_result") for _ in range(4)]
        self.assertEqual([r["success"] for r in results], [True, True, False, False])

    def test_away_has_no_telephony(self):
        self.c.until("bt_connection_changed")
        self.c.send(command="fake_inject", kind="away")
        link = self.c.until("bt_connection_changed")
        self.assertFalse(link["classic_connected"])
        self.assertIsNone(link["calls"])

    def test_garbage_is_ignored(self):
        self.c.until("bt_connection_changed")
        self.c.s.sendall(b"not json\n[1,2]\n")
        self.c.send(command="bt_list_calls")
        self.assertEqual(self.c.obj(), {"command": "bt_calls", "calls": []})


if __name__ == "__main__":
    unittest.main()
