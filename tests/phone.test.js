// Unit tests for src/services/phone.js (the tetherd protocol behind
// Phone.qml), run by `nix flake check` (phone-protocol):
//   node tests/phone.test.js src/services/phone.js tests/fixtures/tether/session.jsonl
// The fixture is a subscribed session as tetherd 0.2.35 writes it (field
// names from upstream src/core/src/net.cpp, daemon/main.cpp,
// bluetooth/{messages,telephony,objects}.cpp, ancs/notifications.cpp), with
// the noise a real socket carries: "OK" acks and lines that aren't objects.
const fs = require("fs");
const assert = require("assert");

const src = fs.readFileSync(process.argv[2], "utf8").replace(/^\.pragma library.*$/m, "");
const P = new Function(`${src}; return { parseLine, command, bootstrap, normalizeNumber, threadKeyFor, initialState, apply, replay, device, deviceName, batteryPercent, batteryInfo, batteryText, phoneAddress, awayLock, awayLockChoices, graceLabel, signalBars, carrier, linkState, statusLine, detailLine, threadTitle, unreadCount, ringingCall, activeCall, callerName, callElapsed, formatDuration, callStateLabel, shortTime, batteryGlyph, signalGlyph };`)();
const lines = fs.readFileSync(process.argv[3], "utf8").split("\n");

const NOW = 1760000030000; // 30 s after the newest message

// ── Lines ───────────────────────────────────────────────────────────────
assert.strictEqual(P.parseLine("OK"), null);
assert.strictEqual(P.parseLine(""), null);
assert.strictEqual(P.parseLine("{broken"), null);
assert.strictEqual(P.parseLine('["x"]'), null);
assert.strictEqual(P.parseLine(undefined), null);
assert.deepStrictEqual(P.parseLine(' {"command":"bt_calls","calls":[]}\r'), { command: "bt_calls", calls: [] });

assert.strictEqual(P.command("subscribe"), '{"command":"subscribe"}\n');
assert.strictEqual(P.command("bt_send_message", { thread: "tel:+1", body: "hi\nthere", operation_id: "loft-1", skip: undefined }), '{"command":"bt_send_message","thread":"tel:+1","body":"hi\\nthere","operation_id":"loft-1"}\n');
const boot = P.bootstrap().trim().split("\n").map(l => JSON.parse(l).command);
assert.deepStrictEqual(boot, ["subscribe", "bt_status", "bt_list_devices", "bt_list_threads", "bt_list_calls", "bt_list_notifications"]);

// ── Addresses ───────────────────────────────────────────────────────────
assert.strictEqual(P.normalizeNumber("+1 (503) 555-0101"), "+15035550101");
assert.strictEqual(P.normalizeNumber("503.555.0101"), "5035550101");
assert.strictEqual(P.normalizeNumber("tel:+15035550101"), "+15035550101");
assert.strictEqual(P.normalizeNumber("ada@example.com"), "");
assert.strictEqual(P.threadKeyFor("+1 503 555 0101"), "tel:+15035550101");
assert.strictEqual(P.threadKeyFor("Ada@Example.com"), "email:ada@example.com");
assert.strictEqual(P.threadKeyFor("tel:+15035550101"), "tel:+15035550101");
assert.strictEqual(P.threadKeyFor("group:name:family"), "group:name:family");
assert.strictEqual(P.threadKeyFor("  "), "");

// ── Not connected ───────────────────────────────────────────────────────
const empty = P.initialState();
assert.strictEqual(P.linkState(empty, false), "offline");
assert.strictEqual(P.statusLine(empty, false), "Not connected");
assert.strictEqual(P.statusLine(empty, true), "No iPhone paired");
assert.strictEqual(P.batteryPercent(empty), -1);
assert.strictEqual(P.deviceName(empty), "iPhone");
assert.strictEqual(P.activeCall(empty), null);
// Unknown commands and junk leave the state as it was (same object).
assert.strictEqual(P.apply(empty, { command: "clipboard_updated", content: "x" }, NOW).state, empty);
assert.strictEqual(P.apply(empty, null, NOW).state, empty);

// ── A recorded session ─────────────────────────────────────────────────
const { state, events } = P.replay(lines, NOW);

assert.strictEqual(state.protocol, 1);
assert.ok(state.capabilities.includes("calls"));
assert.strictEqual(P.linkState(state, true), "connected");
assert.strictEqual(P.deviceName(state), "Cody's iPhone"); // the supervised one, not the headphones
assert.strictEqual(P.batteryPercent(state), 80); // HFP BattChg 4 of 5
assert.strictEqual(P.signalBars(state), 3);
assert.strictEqual(P.carrier(state), "AT&T");
assert.strictEqual(P.statusLine(state, true), "80%");
assert.strictEqual(P.detailLine(state, true), "Messages and contacts are connected.");
assert.strictEqual(state.status.version, "0.2.35");

// Threads: newest first; a message to an unknown thread makes one.
assert.deepStrictEqual(state.threads.map(t => t.thread), ["tel:+15035550101", "tel:+15035550199", "tel:+15035550142"]);
const ada = state.threads[0];
assert.strictEqual(P.threadTitle(ada), "Ada Lovelace");
assert.strictEqual(ada.preview, "No worries");
assert.strictEqual(ada.unread, 1); // the duplicate of 0103 didn't count twice; our own reply doesn't count
assert.strictEqual(P.threadTitle(state.threads[2]), "+15035550142");
assert.strictEqual(P.unreadCount(state), 2);

// Messages of the open thread: oldest first, deduplicated by handle, our send appended.
assert.deepStrictEqual(state.messages["tel:+15035550101"].map(m => m.body), ["Lunch tomorrow?", "See you at noon", "Running 5 minutes late!", "No worries"]);
assert.strictEqual(state.messages["tel:+15035550199"], undefined); // never opened: not loaded

// Events: one fresh message (the duplicate and the old backfill aren't news).
const msgEvents = events.filter(e => e.type === "message");
assert.strictEqual(msgEvents.length, 4);
assert.deepStrictEqual(msgEvents.map(e => e.fresh), [true, false, false, false]);
assert.strictEqual(msgEvents[0].message.body, "Running 5 minutes late!");

// Notifications: upserted by uid, one event, then removed.
assert.strictEqual(events.filter(e => e.type === "notification").length, 1);
assert.strictEqual(state.notifications.length, 0);

// Calls: rang once, answered, active now with a start time.
const rang = events.filter(e => e.type === "ringing");
assert.strictEqual(rang.length, 1);
assert.strictEqual(rang[0].call.number, "+15035550101");
assert.strictEqual(P.ringingCall(state), null);
const active = P.activeCall(state);
assert.strictEqual(active.state, "active");
assert.strictEqual(P.callerName(active, state), "Ada Lovelace"); // matched through the thread's number
assert.strictEqual(P.callElapsed(state, active, NOW + 75000), 75);
assert.deepStrictEqual(events.find(e => e.type === "callResult"), { type: "callResult", ok: true, action: "answer", error: "" });
assert.deepStrictEqual(events.find(e => e.type === "sendResult"), { type: "sendResult", ok: true, thread: "tel:+15035550101", error: "", operationId: "loft-1" });

// Hanging up ends it; a second identical bt_calls doesn't ring again.
let r = P.apply(state, P.parseLine('{"command":"bt_calls","calls":[]}'), NOW + 90000);
assert.deepStrictEqual(r.events, [{ type: "callEnded" }]);
assert.strictEqual(P.activeCall(r.state), null);
const ringing = '{"command":"bt_calls","calls":[{"path":"/c2","number":"","withheld":true,"name":"","state":"incoming","ringing":true,"outgoing":false,"connected":false}]}';
r = P.apply(r.state, P.parseLine(ringing), NOW);
assert.strictEqual(r.events[0].type, "ringing");
assert.strictEqual(P.callerName(P.ringingCall(r.state), r.state), "No Caller ID");
r = P.apply(r.state, P.parseLine(ringing), NOW);
assert.deepStrictEqual(r.events, []);

// An outgoing call is the active one while it rings out.
r = P.apply(P.initialState(), P.parseLine('{"command":"bt_calls","calls":[{"path":"/c3","number":"+15035550199","name":"","state":"alerting","ringing":false,"outgoing":true,"connected":false}]}'), NOW);
assert.strictEqual(P.activeCall(r.state).path, "/c3");
assert.strictEqual(P.callStateLabel(P.activeCall(r.state)), "Ringing…");
assert.strictEqual(P.callElapsed(r.state, P.activeCall(r.state), NOW + 5000), 0);

// Failures surface as lastError.
r = P.apply(P.initialState(), P.parseLine('{"command":"bt_send_result","thread":"tel:+1","success":false,"message":"Another computer holds the iPhone\'s message session."}'), NOW);
assert.strictEqual(r.events[0].ok, false);
assert.strictEqual(r.state.lastError, "Another computer holds the iPhone's message session.");

// Link states as the phone comes and goes.
const link = o => P.apply(P.initialState(), Object.assign({ command: "bt_connection_changed", device_paired: true, classic_connected: false, map_open: false, ancs_ready: false }, o), NOW).state;
assert.strictEqual(P.linkState(link({}), true), "away");
assert.strictEqual(P.statusLine(link({}), true), "Not nearby");
assert.strictEqual(P.linkState(link({ classic_connected: true }), true), "linking");
assert.strictEqual(P.linkState(link({ classic_connected: true, map_open: true }), true), "connected");
assert.strictEqual(P.statusLine(link({ classic_connected: true, map_open: true }), true), "Connected"); // no HFP: no battery
assert.strictEqual(P.batteryPercent(link({ calls: { available: false, battery: 5 } })), -1);

// ── Battery precision ───────────────────────────────────────────────────
// 0.2.35 with Hands-Free only: coarse.
assert.deepStrictEqual(P.batteryInfo(state), { percent: 80, exact: false, source: "hfp" });
assert.strictEqual(P.batteryText(P.batteryInfo(state)), "About 80%");
// BlueZ's Battery1 for the phone (the LE Battery Service) wins, exact.
assert.deepStrictEqual(P.batteryInfo(state, 87), { percent: 87, exact: true, source: "ble" });
assert.strictEqual(P.batteryText(P.batteryInfo(state, 87)), "87%");
assert.strictEqual(P.statusLine(state, true, 87), "87%");
assert.deepStrictEqual(P.batteryInfo(state, -1), P.batteryInfo(state)); // BlueZ has none
// tether ≥ 0.3.0: top-level `battery` is Battery1, else HFP × 20, else null.
const hfp4 = { available: true, battery: 4, signal: 3 };
assert.deepStrictEqual(P.batteryInfo(link({ classic_connected: true, map_open: true, battery: 63, calls: hfp4 })), { percent: 63, exact: true, source: "ble" });
assert.deepStrictEqual(P.batteryInfo(link({ classic_connected: true, map_open: true, battery: 63, calls: null })), { percent: 63, exact: true, source: "ble" });
assert.deepStrictEqual(P.batteryInfo(link({ classic_connected: true, map_open: true, battery: 80, calls: hfp4 })), { percent: 80, exact: false, source: "hfp" }); // just HFP again
assert.deepStrictEqual(P.batteryInfo(link({ classic_connected: true, map_open: true, battery: null, calls: null })), { percent: -1, exact: false, source: "" });
assert.strictEqual(P.batteryText(P.batteryInfo(P.initialState())), "");
// The phone's address: the supervised one, upper case.
assert.strictEqual(P.phoneAddress(state), state.status.device_address.toUpperCase());
assert.strictEqual(P.phoneAddress(P.initialState()), "");

// ── Away lock (tetherd's bt_set_lock_on_away) ───────────────────────────
assert.deepStrictEqual(P.awayLock(P.initialState()), { supported: false, enabled: false, seconds: 30 });
const st = o => P.apply(P.initialState(), Object.assign({ command: "bt_status", device_address: "aa:bb:cc:dd:ee:ff" }, o), NOW).state;
assert.deepStrictEqual(P.awayLock(st({ lock_on_away: false, lock_away_seconds: 30 })), { supported: true, enabled: false, seconds: 30 });
assert.deepStrictEqual(P.awayLock(st({ lock_on_away: true, lock_away_seconds: 120 })), { supported: true, enabled: true, seconds: 120 });
assert.deepStrictEqual(P.awayLock(st({})), { supported: false, enabled: false, seconds: 30 }); // an older tetherd
assert.strictEqual(P.phoneAddress(st({})), "AA:BB:CC:DD:EE:FF");
assert.strictEqual(P.command("bt_set_lock_on_away", { enabled: true, grace_seconds: 60 }), '{"command":"bt_set_lock_on_away","enabled":true,"grace_seconds":60}\n');
assert.deepStrictEqual(P.awayLockChoices().map(P.graceLabel), ["10 s", "30 s", "1 min", "2 min", "5 min"]);

// ── Formatting ──────────────────────────────────────────────────────────
assert.strictEqual(P.formatDuration(0), "0:00");
assert.strictEqual(P.formatDuration(75), "1:15");
assert.strictEqual(P.formatDuration(3725), "1:02:05");
assert.strictEqual(P.batteryGlyph(-1), "󰂑");
assert.strictEqual(P.signalGlyph(-1), "");
const today = new Date(NOW);
today.setHours(9, 41, 0, 0);
assert.strictEqual(P.shortTime(today.getTime() / 1000, NOW), "9:41 AM");
assert.strictEqual(P.shortTime(NOW / 1000 - 86400, NOW), "Yesterday");
assert.strictEqual(P.shortTime(0, NOW), "");

console.log("phone.js: all tests passed");
