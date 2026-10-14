#!/usr/bin/env python3
"""A fake tetherd: the iPhone bridge's local socket protocol, with canned data.

Loft's Phone service (src/services/Phone.qml) talks to tetherd
(github.com/zackb/tether) over $XDG_RUNTIME_DIR/tetherd.sock: newline-delimited
JSON, `{"command":"subscribe"}` for the event stream, list commands answered on
the same connection, fire-and-forget commands acked with a bare "OK" line, and
results broadcast to every subscriber (upstream src/core/src/net.cpp,
UnixServer::handle_client). This fake speaks that protocol with no Bluetooth
at all, so the shell can be developed and tested in a `loft-dev --session`
without a phone, and tests/test_phone_fake.py checks it against the fixture.

    fake_tetherd.py serve [--socket PATH] [--state away|unpaired|connected] [--notify]
    fake_tetherd.py inject KIND [--socket PATH] [--text TEXT]
        KIND: message | notification | call | outgoing | answer | hangup | away | back | otp

--notify also raises the freedesktop notifications tetherd itself raises
(libnotify, app "Tether", hints desktop-entry=tether-gtk, x-kde-origin-name=iPhone,
x-kde-display-appname=<app>), through `gdbus` on the session bus in
DBUS_SESSION_BUS_ADDRESS — run it inside a test session only.

The socket defaults to $XDG_RUNTIME_DIR/tetherd.sock, which in a loft-dev
session is the session's private runtime dir.
"""

import argparse
import json
import os
import socketserver
import subprocess
import sys
import threading
import time

PHONE = "AA:BB:CC:DD:EE:FF"
TELEPHONY = f"/org/bluez/hci0/dev_{PHONE.replace(':', '_')}/telephony0"


def default_socket():
    return os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "tetherd.sock")


class Phone:
    """The iPhone's side, as tetherd would report it."""

    def __init__(self, link="connected", now=None):
        self.now = now or time.time
        self.link = link
        self.calls_enabled = True
        self.call_seq = 0
        self.handle_seq = 200
        self.uid_seq = 40
        t = int(self.now())
        self.threads = {
            "tel:+15035550101": {"name": "Ada Lovelace", "address": "+15035550101", "group": False},
            "tel:+15035550199": {"name": "Grace Hopper", "address": "+15035550199", "group": False},
            "email:alan@example.com": {"name": "Alan Turing", "address": "alan@example.com", "group": False},
        }
        self.messages = {
            "tel:+15035550101": [
                self.msg("tel:+15035550101", "Lunch tomorrow?", t - 7200, read=True),
                self.msg("tel:+15035550101", "Sure — noon at the usual place?", t - 7100, outgoing=True, read=True),
                self.msg("tel:+15035550101", "See you at noon", t - 7000, read=True),
            ],
            "tel:+15035550199": [
                self.msg("tel:+15035550199", "Found the bug.", t - 90000, read=True),
                self.msg("tel:+15035550199", "It was a moth.", t - 89990, read=True),
            ],
            "email:alan@example.com": [
                self.msg("email:alan@example.com", "Can machines think?", t - 300000, read=True),
            ],
        }
        self.calls = []
        self.notifications = []

    def msg(self, thread, body, ts, outgoing=False, read=False):
        self.handle_seq += 1
        info = self.threads[thread]
        return {
            "handle": "" if outgoing else f"04000000000{self.handle_seq:05d}",
            "thread": thread,
            "address": info["address"],
            "name": info["name"],
            "body": body,
            "timestamp": ts,
            "outgoing": outgoing,
            "read": read,
            "folder": "sent" if outgoing else "inbox",
        }

    # ── Replies, shaped like upstream's builders ────────────────────────
    def connection(self):
        up = self.link == "connected"
        paired = self.link != "unpaired"
        calls = None
        if up and self.calls_enabled:
            calls = {
                "available": True, "path": TELEPHONY, "state": "connected", "operator": "Loft Mobile",
                "signal": 4, "battery": 4, "service": True, "roaming": False, "inband_ringtone": False,
                "address": PHONE, "calls": len(self.calls), "backend": "bluez", "indicators": True, "audio": "",
                "reason": "Calls are controlled here; the audio plays on the iPhone.",
            }
        return {
            "command": "bt_connection_changed",
            "device_present": paired, "device_paired": paired, "classic_connected": up,
            "le_available": up, "le_connected": up, "map_open": up, "pbap_open": up,
            "map_error": "none", "pbap_error": "none", "ancs_ready": up, "ancs_reason": "",
            "link_reason": "Connected." if up else ("The iPhone is out of range." if paired else "No iPhone is paired."),
            "profile_reason": "Messages and contacts are connected." if up else "",
            "calls": calls,
        }

    def status(self):
        return {
            "command": "bt_status", "available": True,
            "device_address": PHONE if self.link != "unpaired" else "",
            "ancs_enabled": True, "adapter": "", "ancs_content_enabled": True,
            "calls_enabled": self.calls_enabled, "enabled": True, "retention": "encrypted",
            "retention_ready": True, "desktop_popups_enabled": True, "airpods_enabled": False,
            "airpods_pause": "never", "airpods_handoff": False, "lock_on_away": False,
            "lock_away_seconds": 30, "version": "0.2.35-fake",
            "capability": {"mode": "full", "bearer_api": True, "powered": True, "le_central": True,
                           "le_peripheral": True, "advertising": True, "class_ok": True, "reasons": []},
            "adapters": [], "apple_device_id": False,
        }

    def devices(self):
        up = self.link == "connected"
        devs = []
        if self.link != "unpaired":
            devs.append({
                "path": f"/org/bluez/hci0/dev_{PHONE.replace(':', '_')}", "adapter": "/org/bluez/hci0",
                "address": PHONE, "name": "Test iPhone", "paired": True, "bonded": True, "trusted": True,
                "connected": up, "classic_connected": up, "le_bearer": True, "le_bonded": True,
                "le_connected": up, "preferred_bearer": "bredr", "map": True, "pbap": True, "ancs": True,
                "ancs_notifying": up, "services_resolved": up, "iphone": True, "apple_nearby": up, "airpods": False,
            })
        return {"command": "bt_devices", "devices": devs}

    def thread_list(self):
        out = []
        for key, info in self.threads.items():
            msgs = self.messages.get(key, [])
            last = msgs[-1] if msgs else {"body": "", "timestamp": 0}
            out.append({
                "thread": key, "name": info["name"], "address": info["address"],
                "preview": last["body"], "timestamp": last["timestamp"],
                "unread": sum(1 for m in msgs if not m["read"] and not m["outgoing"]),
                "count": len(msgs), "group": info["group"], "repliable": not info["group"],
            })
        out.sort(key=lambda t: -t["timestamp"])
        return {"command": "bt_threads", "threads": out}

    def call(self, number, name, state):
        self.call_seq += 1
        return {
            "path": f"{TELEPHONY}/call{self.call_seq}", "number": number, "withheld": False, "name": name,
            "incoming_line": "", "state": state, "multiparty": False,
            "ringing": state in ("incoming", "waiting"), "outgoing": state in ("dialing", "alerting"),
            "connected": state in ("active", "held"),
        }

    @staticmethod
    def set_state(call, state):
        call.update(state=state, ringing=state in ("incoming", "waiting"),
                    outgoing=state in ("dialing", "alerting"), connected=state in ("active", "held"))


class Daemon:
    def __init__(self, path, phone, notify=False, log=None):
        self.path = path
        self.phone = phone
        self.notify = notify
        self.log = log or (lambda *_: None)
        self.lock = threading.Lock()
        self.subscribers = set()
        self.server = None

    # ── Plumbing ────────────────────────────────────────────────────────
    def send(self, conn, obj):
        data = (obj if isinstance(obj, str) else json.dumps(obj)) + "\n"
        try:
            conn.sendall(data.encode())
        except OSError:
            with self.lock:
                self.subscribers.discard(conn)

    def broadcast(self, obj):
        with self.lock:
            subs = list(self.subscribers)
        for c in subs:
            self.send(c, obj)

    def desktop_notification(self, app_name, summary, body, icon, actions=()):
        """What tetherd's DesktopNotifier raises (daemon/notification.cpp)."""
        if not self.notify:
            return
        acts = []
        for ident, label in actions:
            acts += [ident, label]
        hints = {"desktop-entry": "<'tether-gtk'>", "x-kde-display-appname": f"<{json.dumps(app_name)}>",
                 "x-kde-origin-name": "<'iPhone'>"}
        hint_str = "{" + ", ".join(f"'{k}': {v}" for k, v in hints.items()) + "}"
        cmd = ["gdbus", "call", "--session", "--dest", "org.freedesktop.Notifications",
               "--object-path", "/org/freedesktop/Notifications",
               "--method", "org.freedesktop.Notifications.Notify", "--",
               "Tether", "0", icon, summary, body, json.dumps(acts), hint_str, "-1"]
        try:
            r = subprocess.run(cmd, check=False, timeout=5, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
            if r.returncode != 0:
                self.log(f"notify failed: {r.stderr.strip().splitlines()[0] if r.stderr.strip() else r.returncode}")
        except (OSError, subprocess.TimeoutExpired) as e:
            self.log(f"notify failed: {e}")

    # ── Commands (net.cpp's dispatch) ───────────────────────────────────
    def handle(self, conn, m):
        p = self.phone
        cmd = m.get("command")
        if cmd == "subscribe":
            with self.lock:
                self.subscribers.add(conn)
            self.send(conn, {"command": "protocol_info", "version": 1,
                             "capabilities": ["bluetooth", "calls", "files", "messages", "notifications"]})
            self.send(conn, {"command": "state_snapshot", "paired_devices": [], "pending_pairs": [],
                             "connected_clients": []})
            self.send(conn, p.connection())
            return
        if cmd == "unsubscribe":
            with self.lock:
                self.subscribers.discard(conn)
            self.send(conn, {"command": "unsubscribed"})
            return
        if cmd == "protocol_info":
            return self.send(conn, {"command": "protocol_info", "version": 1, "capabilities": ["bluetooth"]})
        if cmd == "bt_status":
            return self.send(conn, p.status())
        if cmd == "bt_connection":
            return self.send(conn, p.connection())
        if cmd == "bt_list_devices":
            return self.send(conn, p.devices())
        if cmd == "bt_list_threads":
            return self.send(conn, p.thread_list())
        if cmd == "bt_list_messages" and "thread" in m:
            return self.send(conn, {"command": "bt_messages", "thread": m["thread"],
                                    "messages": list(p.messages.get(m["thread"], []))})
        if cmd == "bt_list_calls":
            return self.send(conn, {"command": "bt_calls", "calls": p.calls})
        if cmd == "bt_list_notifications":
            return self.send(conn, {"command": "bt_notifications", "notifications": p.notifications})
        if cmd == "bt_list_contacts":
            q = str(m.get("query", "")).lower()
            contacts = [{"name": i["name"], "addresses": [k]} for k, i in p.threads.items()
                        if q in i["name"].lower() or q in k]
            return self.send(conn, {"command": "bt_contacts", "query": q, "contacts": contacts})
        if cmd == "bt_call_dial" and "number" in m:
            ok = p.link == "connected" and p.calls_enabled
            res = {"command": "bt_call_result", "action": "dial", "success": ok}
            if ok:
                p.calls = [p.call(m["number"], "", "alerting")]
                self.broadcast({"command": "bt_calls", "calls": p.calls})
            else:
                res["message"] = "The iPhone has not connected Hands-Free to this computer."
            self.broadcast(res)
            return self.send(conn, res)
        if cmd == "bt_call_action" and "action" in m:
            return self.call_action(conn, m.get("action"), m.get("path", ""))
        if cmd == "bt_send_message" and "thread" in m and "body" in m:
            self.send(conn, "OK")
            thread, body = m["thread"], m["body"]
            res = {"command": "bt_send_result", "thread": thread}
            if m.get("operation_id"):
                res["operation_id"] = m["operation_id"]
            ok = p.link == "connected"
            res["success"] = ok
            if ok:
                if thread not in p.threads:
                    p.threads[thread] = {"name": "", "address": thread.split(":", 1)[-1], "group": False}
                sent = p.msg(thread, body, int(p.now()), outgoing=True, read=True)
                p.messages.setdefault(thread, []).append(sent)
                self.broadcast(dict(sent, command="bt_message"))
            else:
                res["message"] = "The iPhone isn't connected."
            self.broadcast(res)
            return
        if cmd == "bt_mark_read":
            handles = m.get("handles") or [m.get("handle")]
            for msgs in p.messages.values():
                for x in msgs:
                    if x["handle"] in handles:
                        x["read"] = bool(m.get("read", True))
            self.send(conn, "OK")
            return self.broadcast({"command": "bt_message_read", "success": True})
        if cmd == "bt_set_calls":
            p.calls_enabled = bool(m.get("enabled", False))
            self.send(conn, "OK")
            self.broadcast(p.status())
            return self.broadcast(p.connection())
        if cmd == "bt_notification_action" and "uid" in m:
            self.send(conn, "OK")
            p.notifications = [n for n in p.notifications if n["uid"] != m["uid"]]
            self.broadcast({"command": "bt_notification_action_result", "uid": m["uid"], "success": True})
            return self.broadcast({"command": "bt_notification_removed", "uid": m["uid"]})
        if cmd == "fake_inject":
            self.send(conn, "OK")
            return self.inject(m.get("kind", ""), m.get("text"))
        # Anything else tetherd accepts and acks.
        self.send(conn, "OK")

    def call_action(self, conn, action, path):
        p = self.phone
        res = {"command": "bt_call_result", "action": action, "success": False}
        target = next((c for c in p.calls if c["path"] == path), None) or (p.calls[0] if len(p.calls) == 1 else None)
        if action == "answer" and target:
            Phone.set_state(target, "active")
            res["success"] = True
        elif action in ("hangup", "hangup_all") and (target or (action == "hangup_all" and p.calls)):
            p.calls = [] if action == "hangup_all" else [c for c in p.calls if c is not target]
            res["success"] = True
        else:
            res["message"] = "No call named." if not p.calls else "That call is no longer active."
        if res["success"]:
            self.broadcast({"command": "bt_calls", "calls": p.calls})
        self.broadcast(res)
        self.send(conn, res)

    # ── Canned events ───────────────────────────────────────────────────
    def inject(self, kind, text=None):
        p = self.phone
        now = int(p.now())
        if kind == "message":
            thread = "tel:+15035550101"
            m = p.msg(thread, text or "Running 5 minutes late — order me the soup?", now)
            p.messages[thread].append(m)
            self.broadcast(dict(m, command="bt_message"))
            # tetherd's own popup for it (Messages over MAP, with Reply).
            self.desktop_notification("Messages", p.threads[thread]["name"], m["body"],
                                      "phone", [("default", "default"), ("reply", "Reply")])
        elif kind == "notification":
            p.uid_seq += 1
            n = {"uid": p.uid_seq, "app_id": "com.burbn.instagram", "app_name": "Instagram",
                 "title": "alan.turing", "subtitle": "", "body": text or "liked your photo.",
                 "category": 4, "timestamp": now, "silent": False,
                 "positive_action": False, "negative_action": True}
            p.notifications.insert(0, n)
            self.broadcast(dict(n, command="bt_notification"))
            self.desktop_notification("Instagram", n["title"], n["body"], "instagram",
                                      [("open-app", "Open in Instagram")])
        elif kind == "otp":
            self.broadcast({"command": "otp_available", "otp": "482913", "source": "Messages"})
        elif kind == "call":
            p.calls = [p.call("+15035550199", "", "incoming")]
            self.broadcast({"command": "bt_calls", "calls": p.calls})
        elif kind == "outgoing":
            p.calls = [p.call("+15035550101", "", "alerting")]
            self.broadcast({"command": "bt_calls", "calls": p.calls})
        elif kind == "answer":
            # The phone answered it (on the handset).
            for c in p.calls:
                Phone.set_state(c, "active")
            self.broadcast({"command": "bt_calls", "calls": p.calls})
        elif kind == "hangup":
            p.calls = []
            self.broadcast({"command": "bt_calls", "calls": p.calls})
        elif kind in ("away", "back"):
            p.link = "away" if kind == "away" else "connected"
            self.broadcast(p.connection())
        else:
            self.log(f"unknown inject kind {kind!r}")

    # ── Server ──────────────────────────────────────────────────────────
    def start(self):
        daemon = self
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass

        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                conn = self.request
                buf = b""
                try:
                    while True:
                        chunk = conn.recv(65536)
                        if not chunk:
                            break
                        buf += chunk
                        while b"\n" in buf:
                            line, buf = buf.split(b"\n", 1)
                            try:
                                m = json.loads(line)
                            except ValueError:
                                continue  # tetherd ignores what isn't JSON
                            if isinstance(m, dict):
                                daemon.log(f"<- {m.get('command')}")
                                daemon.handle(conn, m)
                except OSError:
                    pass
                finally:
                    with daemon.lock:
                        daemon.subscribers.discard(conn)

        class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
            daemon_threads = True

        self.server = Server(self.path, Handler)
        return self.server

    def stop(self):
        if self.server:
            self.server.shutdown()
            self.server.server_close()
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass


def inject(path, kind, text=None):
    import socket
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(path)
    msg = {"command": "fake_inject", "kind": kind}
    if text:
        msg["text"] = text
    s.sendall((json.dumps(msg) + "\n").encode())
    s.settimeout(2)
    try:
        s.recv(64)
    except OSError:
        pass
    s.close()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sv = sub.add_parser("serve")
    sv.add_argument("--socket", default=default_socket())
    sv.add_argument("--state", choices=["connected", "away", "unpaired"], default="connected")
    sv.add_argument("--notify", action="store_true", help="raise tetherd's fd.o notifications via gdbus")
    ij = sub.add_parser("inject")
    ij.add_argument("kind")
    ij.add_argument("--socket", default=default_socket())
    ij.add_argument("--text")
    a = ap.parse_args(argv)
    if a.cmd == "inject":
        inject(a.socket, a.kind, a.text)
        return 0
    d = Daemon(a.socket, Phone(a.state), notify=a.notify,
               log=lambda s: print(f"fake-tetherd: {s}", file=sys.stderr, flush=True))
    srv = d.start()
    print(f"fake-tetherd: listening on {a.socket}", file=sys.stderr, flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        d.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
