.pragma library

// The iPhone bridge's protocol: tetherd (github.com/zackb/tether, nixpkgs
// `tether` 0.2.35) on its Unix socket, $XDG_RUNTIME_DIR/tetherd.sock.
// Newline-delimited JSON both ways (docs/PROTOCOL.md §4 and §6 upstream;
// src/core/src/net.cpp UnixServer::handle_client):
//
//   → {"command":"subscribe"}   turns the connection into an event stream. The
//     daemon answers protocol_info, state_snapshot, (otp_available,) and
//     bt_connection_changed, then broadcasts every local event to it.
//   → any other command on the same connection: list commands answer on it
//     (bt_threads, bt_messages, bt_calls, …); fire-and-forget commands get a
//     bare "OK" line; results that a second client would care about
//     (bt_send_result, bt_message, bt_call_result, …) are broadcast.
//
// Pure JS so it can be unit-tested outside Quickshell (tests/phone.test.js
// replays tests/fixtures/tether/*.jsonl). Phone.qml owns the socket and the
// state; everything here is a function of (state, line).

// ── Lines ───────────────────────────────────────────────────────────────

// One line from the socket → an object, or null for anything that isn't a
// JSON object ("OK" acks, a partial write, garbage). Never throws.
function parseLine(line) {
    const s = String(line === undefined || line === null ? "" : line).trim();
    if (s === "" || s[0] !== "{")
        return null;
    try {
        const m = JSON.parse(s);
        return m && typeof m === "object" && !Array.isArray(m) ? m : null;
    } catch (e) {
        return null;
    }
}

// A command line to write: {"command": name, ...fields} + "\n".
function command(name, fields) {
    const m = { command: name };
    if (fields)
        for (const k in fields)
            if (fields[k] !== undefined)
                m[k] = fields[k];
    return JSON.stringify(m) + "\n";
}

// What a fresh subscription asks for, so the UI has everything at once.
function bootstrap() {
    return [command("subscribe"), command("bt_status"), command("bt_list_devices"), command("bt_list_threads"), command("bt_list_calls"), command("bt_list_notifications")].join("");
}

// ── Addresses and thread keys ───────────────────────────────────────────

// "+1 (503) 555-0101" → "+15035550101"; "" when it isn't a number.
function normalizeNumber(s) {
    const raw = String(s || "").replace(/^tel:/i, "").trim();
    if (!/^[+\d][\d\s().-]*$/.test(raw))
        return "";
    const plus = raw.startsWith("+");
    const digits = raw.replace(/\D/g, "");
    return digits ? (plus ? "+" : "") + digits : "";
}

// What `phone send` / the composer accept, as a thread key tetherd routes:
// a key as is (tel:, email:, group:), a number → tel:, an Apple ID → email:.
function threadKeyFor(to) {
    const s = String(to || "").trim();
    if (s === "")
        return "";
    if (/^(tel|email|group):/i.test(s))
        return s;
    if (s.includes("@"))
        return "email:" + s.toLowerCase();
    const n = normalizeNumber(s);
    return n ? "tel:" + n : s;
}

// The last 10 digits, for matching a caller's number against threads.
function numberTail(s) {
    const d = String(s || "").replace(/\D/g, "");
    return d.length > 10 ? d.slice(-10) : d;
}

function sameAddress(a, b) {
    return String(a || "").toLowerCase() === String(b || "").toLowerCase() && String(a || "") !== "";
}

// ── State ───────────────────────────────────────────────────────────────

function initialState() {
    return {
        protocol: 0, // protocol_info.version
        capabilities: [],
        link: null, // bt_connection_changed
        status: null, // bt_status
        devices: [], // bt_devices
        wifiPeers: [], // state_snapshot.paired_devices (the tether iOS app)
        threads: [], // bt_threads, newest first
        messages: ({}), // thread key → [message], oldest first
        calls: [], // bt_calls
        callStarted: ({}), // call path → ms when it became active (local clock)
        notifications: [], // bt_notifications (ANCS), newest first
        otp: "",
        lastError: ""
    };
}

function copy(o) {
    return Object.assign({}, o);
}

function sortThreads(list) {
    return list.slice().sort((a, b) => (b.timestamp || 0) - (a.timestamp || 0));
}

function upsertMessage(list, m) {
    const out = (list || []).filter(x => !(m.handle && x.handle === m.handle));
    out.push(m);
    out.sort((a, b) => (a.timestamp || 0) - (b.timestamp || 0));
    return out;
}

// Apply one parsed message. Returns { state, events } — events are what the
// UI reacts to once (a banner, a ringing call):
//   { type: "message", message, fresh }     fresh = incoming, unread, recent
//   { type: "ringing", call }  { type: "callEnded" }
//   { type: "sendResult", ok, thread, error, operationId }
//   { type: "callResult", ok, action, error }
//   { type: "notification", notification }
//   { type: "connection", link }
// `now` is ms since the epoch (Date.now() in QML; fixed in tests).
function apply(state, m, now) {
    const events = [];
    if (!m || typeof m.command !== "string")
        return { state: state, events: events };
    const s = copy(state);
    switch (m.command) {
    case "protocol_info":
        s.protocol = m.version || 0;
        s.capabilities = Array.isArray(m.capabilities) ? m.capabilities : [];
        break;
    case "state_snapshot":
        s.wifiPeers = Array.isArray(m.paired_devices) ? m.paired_devices : [];
        break;
    case "bt_connection":
    case "bt_connection_changed":
        {
            const link = copy(m);
            delete link.command;
            s.link = link;
            events.push({ type: "connection", link: link });
            break;
        }
    case "bt_status":
        {
            const st = copy(m);
            delete st.command;
            s.status = st;
            break;
        }
    case "bt_devices":
        s.devices = Array.isArray(m.devices) ? m.devices : [];
        break;
    case "bt_threads":
        s.threads = sortThreads(Array.isArray(m.threads) ? m.threads : []);
        break;
    case "bt_messages":
        {
            const msgs = copy(s.messages);
            msgs[m.thread] = (Array.isArray(m.messages) ? m.messages : []).slice().sort((a, b) => (a.timestamp || 0) - (b.timestamp || 0));
            s.messages = msgs;
            break;
        }
    case "bt_message":
        {
            const msg = copy(m);
            delete msg.command;
            const key = msg.thread || threadKeyFor(msg.address);
            msg.thread = key;
            // Seen before (a loaded thread already has this handle): no news.
            const known = !!msg.handle && s.messages[key] !== undefined && s.messages[key].some(x => x.handle === msg.handle);
            if (s.messages[key] !== undefined) {
                const msgs = copy(s.messages);
                msgs[key] = upsertMessage(msgs[key], msg);
                s.messages = msgs;
            }
            const threads = s.threads.slice();
            const i = threads.findIndex(t => t.thread === key);
            const incomingUnread = !msg.outgoing && !msg.read;
            if (known) {
                // Only the content can change.
            } else if (i >= 0) {
                const t = copy(threads[i]);
                if ((msg.timestamp || 0) >= (t.timestamp || 0)) {
                    t.preview = msg.body || "";
                    t.timestamp = msg.timestamp || t.timestamp;
                }
                if (incomingUnread)
                    t.unread = (t.unread || 0) + 1;
                t.count = (t.count || 0) + 1;
                threads[i] = t;
            } else {
                threads.push({
                    thread: key,
                    name: msg.name || "",
                    address: msg.address || "",
                    preview: msg.body || "",
                    timestamp: msg.timestamp || 0,
                    unread: incomingUnread ? 1 : 0,
                    count: 1,
                    group: key.startsWith("group:"),
                    repliable: !key.startsWith("group:")
                });
            }
            if (!known)
                s.threads = sortThreads(threads);
            // tetherd replays the journal (backfill) as bt_message too: only
            // a new, unread, incoming message from the last few minutes is news.
            const recent = !msg.timestamp || Math.abs(now / 1000 - msg.timestamp) < 300;
            events.push({ type: "message", message: msg, fresh: incomingUnread && recent && !known });
            break;
        }
    case "bt_message_read":
        break;
    case "bt_send_result":
        events.push({ type: "sendResult", ok: m.success === true, thread: m.thread || "", error: m.message || "", operationId: m.operation_id || "" });
        if (m.success !== true)
            s.lastError = m.message || "Couldn't send the message.";
        break;
    case "bt_calls":
        {
            const calls = Array.isArray(m.calls) ? m.calls : [];
            const before = s.calls;
            const started = {};
            for (const c of calls) {
                const was = before.find(b => b.path === c.path);
                if (c.connected)
                    started[c.path] = s.callStarted[c.path] || now;
                if (c.ringing && !(was && was.ringing))
                    events.push({ type: "ringing", call: c });
            }
            if (before.length > 0 && calls.length === 0)
                events.push({ type: "callEnded" });
            s.calls = calls;
            s.callStarted = started;
            break;
        }
    case "bt_call_result":
        events.push({ type: "callResult", ok: m.success === true, action: m.action || "", error: m.message || "" });
        if (m.success !== true)
            s.lastError = m.message || "The call action failed.";
        break;
    case "bt_notifications":
        s.notifications = (Array.isArray(m.notifications) ? m.notifications : []).slice().sort((a, b) => (b.timestamp || 0) - (a.timestamp || 0));
        break;
    case "bt_notification":
        {
            const n = copy(m);
            delete n.command;
            const had = s.notifications.some(x => x.uid === n.uid);
            s.notifications = [n].concat(s.notifications.filter(x => x.uid !== n.uid));
            if (!had)
                events.push({ type: "notification", notification: n });
            break;
        }
    case "bt_notification_removed":
        s.notifications = s.notifications.filter(x => x.uid !== m.uid);
        break;
    case "otp_available":
        s.otp = m.otp || "";
        break;
    case "error":
        s.lastError = m.message || "tetherd reported an error.";
        break;
    default:
        return { state: state, events: events };
    }
    return { state: s, events: events };
}

// Feed a whole recorded session (tests; replaying a capture).
function replay(lines, now) {
    let st = initialState();
    const events = [];
    for (const line of lines) {
        const r = apply(st, parseLine(line), now);
        st = r.state;
        for (const e of r.events)
            events.push(e);
    }
    return { state: st, events: events };
}

// ── Derived ─────────────────────────────────────────────────────────────

// The iPhone tetherd supervises (bt_status.device_address), else the first
// paired phone that speaks MAP / ANCS.
function device(state) {
    const addr = state.status ? state.status.device_address : "";
    const d = state.devices.find(x => sameAddress(x.address, addr));
    if (d)
        return d;
    return state.devices.find(x => x.paired && (x.iphone || x.map || x.ancs)) || null;
}

function deviceName(state) {
    const d = device(state);
    return d && d.name ? d.name : "iPhone";
}

// HFP's indicators (BlueZ Telephony1: BattChg and Signal, 0–5). Present only
// while tetherd's call control is on (`bt_set_calls`) and the phone has
// connected Hands-Free.
function telephony(state) {
    const t = state.link ? state.link.calls : null;
    return t && typeof t === "object" ? t : null;
}

function batteryPercent(state) {
    const t = telephony(state);
    if (!t || !t.available || typeof t.battery !== "number")
        return -1;
    return Math.max(0, Math.min(100, Math.round(t.battery * 20)));
}

function signalBars(state) {
    const t = telephony(state);
    if (!t || !t.available || typeof t.signal !== "number")
        return -1;
    return Math.max(0, Math.min(5, t.signal));
}

function carrier(state) {
    const t = telephony(state);
    return t && t.available ? (t.operator || "") : "";
}

// One of: "offline" (no daemon), "unpaired", "away" (paired, not linked),
// "linking" (linked, profiles not up), "connected".
function linkState(state, socketUp) {
    if (!socketUp)
        return "offline";
    const l = state.link;
    if (!l || !l.device_paired)
        return "unpaired";
    if (!l.classic_connected)
        return "away";
    if (!l.map_open && !l.ancs_ready)
        return "linking";
    return "connected";
}

// One short line for tiles and the menu bar.
function statusLine(state, socketUp) {
    switch (linkState(state, socketUp)) {
    case "offline":
        return "Not connected";
    case "unpaired":
        return "No iPhone paired";
    case "away":
        return "Not nearby";
    case "linking":
        return "Connecting…";
    }
    const b = batteryPercent(state);
    return b >= 0 ? `${b}%` : "Connected";
}

// The sentence tetherd wrote for display about what is (not) working.
function detailLine(state, socketUp) {
    if (!socketUp)
        return "tetherd isn't running (no socket).";
    const l = state.link;
    if (!l)
        return "";
    return l.profile_reason || l.link_reason || "";
}

function threadTitle(t) {
    if (!t)
        return "";
    if (t.name)
        return t.name;
    if (t.address)
        return t.address;
    return String(t.thread || "").replace(/^(tel|email):/, "");
}

function unreadCount(state) {
    return state.threads.reduce((n, t) => n + (t.unread || 0), 0);
}

function ringingCall(state) {
    return state.calls.find(c => c.ringing) || null;
}

// The call on the line: connected (active / held) first, then one being placed.
function activeCall(state) {
    return state.calls.find(c => c.connected && c.state === "active") || state.calls.find(c => c.connected) || state.calls.find(c => c.outgoing) || null;
}

// Who's calling: the HFP name, a thread whose number matches, the number.
function callerName(call, state) {
    if (!call)
        return "";
    if (call.name)
        return call.name;
    if (call.withheld)
        return "No Caller ID";
    const tail = numberTail(call.number);
    if (tail && state) {
        const t = state.threads.find(x => x.name && numberTail(x.address || x.thread) === tail);
        if (t)
            return t.name;
    }
    return call.number || "Unknown";
}

function callElapsed(state, call, now) {
    if (!call || !call.connected)
        return 0;
    const t0 = state.callStarted[call.path];
    return t0 ? Math.max(0, Math.floor((now - t0) / 1000)) : 0;
}

// 75 → "1:15", 3725 → "1:02:05".
function formatDuration(sec) {
    const s = Math.max(0, Math.floor(sec || 0));
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const r = String(s % 60).padStart(2, "0");
    return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${r}` : `${m}:${r}`;
}

function callStateLabel(call) {
    if (!call)
        return "";
    switch (call.state) {
    case "incoming":
        return "Incoming call";
    case "waiting":
        return "Call waiting";
    case "dialing":
        return "Calling…";
    case "alerting":
        return "Ringing…";
    case "held":
        return "On hold";
    }
    return "iPhone";
}

// A message timestamp (seconds) → "9:41 AM" today, "Yesterday", or a date.
function shortTime(ts, nowMs) {
    if (!ts)
        return "";
    const d = new Date(ts * 1000);
    const n = new Date(nowMs);
    const sameDay = d.toDateString() === n.toDateString();
    if (sameDay) {
        let h = d.getHours();
        const ap = h >= 12 ? "PM" : "AM";
        h = h % 12 || 12;
        return `${h}:${String(d.getMinutes()).padStart(2, "0")} ${ap}`;
    }
    const y = new Date(nowMs - 86400000);
    if (d.toDateString() === y.toDateString())
        return "Yesterday";
    return `${d.getMonth() + 1}/${d.getDate()}/${String(d.getFullYear()).slice(-2)}`;
}

// ── Glyphs (Nerd Font, Material Design) ─────────────────────────────────

function batteryGlyph(p) {
    if (p < 0)
        return "󰂑";
    return p > 90 ? "󰁹" : p > 70 ? "󰂁" : p > 40 ? "󰁾" : p > 20 ? "󰁼" : "󰁺";
}

function signalGlyph(bars) {
    if (bars < 0)
        return "";
    return bars >= 4 ? "󰢾" : bars >= 3 ? "󰢽" : bars >= 1 ? "󰢼" : "󰢿";
}

function phoneGlyph(linkStateName) {
    return linkStateName === "connected" ? "󰄜" : linkStateName === "offline" || linkStateName === "unpaired" ? "󰥐" : "󰄜";
}
