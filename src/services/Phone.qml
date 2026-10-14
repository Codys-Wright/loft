pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "phone.js" as P

// The iPhone, through tetherd (github.com/zackb/tether): it presents this
// machine to the phone as a Bluetooth hands-free accessory and gets messages
// (MAP), contacts (PBAP), app notifications (ANCS) and call control (HFP).
// One subscribed connection to its socket ($XDG_RUNTIME_DIR/tether/tetherd.sock,
// JSON lines; the protocol and all parsing are in phone.js) carries the
// events and our commands. Feature "phone" (off by default); with no socket
// it just says "Not connected" and retries quietly.
//
// App notifications reach Loft without this service: tetherd raises them as
// freedesktop notifications (Notifications.qml tags them as from iPhone).
// Messages and calls are drawn from the socket: the Messages panel
// (src/everyday/MessagesPanel.qml), island banners with Reply, the call live
// activity, the Control Center tile and Settings → Phone.
//
// IPC: phone status|send TO BODY|answer|decline|hangup|dial NUMBER|messages|
//      thread KEY|refresh
Singleton {
    id: root

    readonly property bool enabled: Features.on("phone")
    readonly property string socketPath: Quickshell.env("LOFT_TETHER_SOCKET") || PhoneConfig.socketPath || `${Quickshell.env("XDG_RUNTIME_DIR")}/tether/tetherd.sock`

    // ── State (phone.js) ────────────────────────────────────────────────
    property var state: P.initialState()
    readonly property bool up: sock.connected
    readonly property string link: P.linkState(state, up)
    readonly property bool connected: link === "connected"
    readonly property string deviceName: P.deviceName(state)
    readonly property string statusLine: enabled ? P.statusLine(state, up) : "Off"
    readonly property string detail: P.detailLine(state, up)
    readonly property int battery: P.batteryPercent(state)
    readonly property int signal: P.signalBars(state)
    readonly property string carrier: P.carrier(state)
    readonly property string version: state.status?.version ?? ""
    readonly property bool callControl: state.status?.calls_enabled ?? false
    readonly property var threads: state.threads
    readonly property int unread: P.unreadCount(state)
    readonly property var notifications: state.notifications
    readonly property var ringingCall: enabled && PhoneConfig.calls ? P.ringingCall(state) : null
    readonly property var activeCall: enabled && PhoneConfig.calls ? P.activeCall(state) : null
    readonly property string lastError: state.lastError
    readonly property string glyph: P.phoneGlyph(link)

    // A clock for the call timer and "9:41 AM" stamps; ticks while a call is up.
    property real now: Date.now()
    readonly property int callSeconds: P.callElapsed(state, activeCall, now)
    readonly property string callTime: P.formatDuration(callSeconds)

    function callerName(call) {
        return P.callerName(call, state);
    }
    function callStateLabel(call) {
        return P.callStateLabel(call);
    }
    function threadTitle(t) {
        return P.threadTitle(t);
    }
    function thread(key) {
        return threads.find(t => t.thread === key) ?? null;
    }
    function messagesFor(key) {
        return state.messages[key] ?? [];
    }
    function shortTime(ts) {
        return P.shortTime(ts, now);
    }
    function batteryGlyph() {
        return P.batteryGlyph(battery);
    }
    function signalGlyph() {
        return P.signalGlyph(signal);
    }

    // ── Messages panel ──────────────────────────────────────────────────
    property bool panelOpen: false
    // The open conversation ("" = none; compose = a new message).
    property string currentThread: ""
    property bool composing: false
    // Bumped to focus the reply box (Reply on a banner).
    property int focusReply: 0

    function openMessages(key) {
        if (!enabled)
            return;
        Panels.controlCenterOpen = false;
        panelOpen = true;
        if (key)
            openThread(key);
        else if (currentThread === "" && threads.length > 0)
            openThread(threads[0].thread);
    }

    function openThread(key) {
        composing = false;
        currentThread = key;
        write(P.command("bt_list_messages", { thread: key }));
        markThreadRead(key);
    }

    function reply(key) {
        openMessages(key);
        focusReply++;
    }

    function compose() {
        openMessages("");
        composing = true;
        currentThread = "";
    }

    // A thread by its display name (a tetherd Messages notification has the
    // sender's name as its summary).
    function openByName(name) {
        const t = threads.find(x => P.threadTitle(x) === name);
        openMessages(t ? t.thread : "");
    }

    // ── Commands ────────────────────────────────────────────────────────
    property int seq: 0

    function write(line) {
        if (!sock.connected)
            return false;
        sock.write(line);
        sock.flush();
        return true;
    }

    // `to`: a thread key, a number or an Apple ID. Returns the thread key.
    function send(to, body) {
        const key = P.threadKeyFor(to);
        const text = String(body ?? "");
        if (key === "" || text.trim() === "")
            return "";
        seq++;
        if (!write(P.command("bt_send_message", { thread: key, body: text, operation_id: `loft-${seq}` })))
            return "";
        return key;
    }

    function answer() {
        const c = P.ringingCall(state);
        return c ? write(P.command("bt_call_action", { action: "answer", path: c.path })) : false;
    }

    function decline() {
        const c = P.ringingCall(state);
        return c ? write(P.command("bt_call_action", { action: "hangup", path: c.path })) : false;
    }

    function hangup() {
        const c = P.activeCall(state) ?? P.ringingCall(state);
        if (c)
            return write(P.command("bt_call_action", { action: "hangup", path: c.path }));
        return state.calls.length > 0 ? write(P.command("bt_call_action", { action: "hangup_all" })) : false;
    }

    function dial(number) {
        const n = P.normalizeNumber(number);
        return n ? write(P.command("bt_call_dial", { number: n })) : false;
    }

    // tetherd's call control (HFP). Off in tetherd by default; persisted there.
    function setCallControl(on) {
        write(P.command("bt_set_calls", { enabled: on }));
    }

    // Ask the phone to re-offer the Messages / Contacts / notification toggles.
    function solicit() {
        write(P.command("bt_solicit"));
    }

    function notificationAction(uid, positive) {
        write(P.command("bt_notification_action", { uid: uid, action: positive ? "positive" : "negative" }));
    }

    function refresh() {
        write(P.bootstrap().split("\n").slice(1).join("\n"));
    }

    // Reading a conversation reads its messages on the phone too.
    property var markedRead: ({})
    function markThreadRead(key) {
        const handles = messagesFor(key).filter(m => !m.outgoing && !m.read && m.handle && !markedRead[m.handle]).map(m => m.handle);
        const t = thread(key);
        if (t && t.unread > 0) {
            const s = Object.assign({}, state);
            s.threads = state.threads.map(x => x.thread === key ? Object.assign({}, x, { unread: 0 }) : x);
            state = s;
        }
        if (handles.length === 0)
            return;
        const marked = Object.assign({}, markedRead);
        for (const h of handles)
            marked[h] = true;
        markedRead = marked;
        write(P.command("bt_mark_read", { handles: handles, read: true }));
    }

    // ── Events ──────────────────────────────────────────────────────────
    function feed(line) {
        const m = P.parseLine(line);
        if (!m)
            return;
        const r = P.apply(state, m, Date.now());
        state = r.state;
        for (const e of r.events)
            handle(e);
        if (panelOpen && currentThread !== "" && (m.command === "bt_messages" || m.command === "bt_message"))
            markThreadRead(currentThread);
    }

    function handle(e) {
        switch (e.type) {
        case "message":
            if (e.fresh && PhoneConfig.messages && !(panelOpen && currentThread === e.message.thread))
                bannerFor(e.message);
            break;
        case "sendResult":
            if (!e.ok)
                Notifications.show({
                    appName: "Messages · iPhone",
                    glyph: "󰍩",
                    glyphColor: Theme.urgent,
                    summary: "Not delivered",
                    body: e.error || "The iPhone didn't take the message.",
                    actions: []
                });
            break;
        case "ringing":
            now = Date.now();
            break;
        }
    }

    function bannerFor(msg) {
        const key = msg.thread;
        const who = P.threadTitle(thread(key) ?? msg);
        Notifications.show({
            appName: "Messages",
            phone: true,
            glyph: "󰍩",
            glyphColor: "#34c759",
            summary: who,
            body: PhoneConfig.previews ? msg.body : "New message",
            phoneThread: key,
            actions: [
                {
                    identifier: "default",
                    text: "",
                    invoke: () => root.openMessages(key)
                },
                {
                    identifier: "reply",
                    text: "Reply",
                    invoke: () => root.reply(key)
                }
            ]
        });
    }

    // ── Socket ──────────────────────────────────────────────────────────
    Socket {
        id: sock
        path: root.socketPath
        parser: SplitParser {
            onRead: data => root.feed(data)
        }
        onConnectionStateChanged: {
            if (connected) {
                retry.interval = 2000;
                root.state = P.initialState();
                root.markedRead = ({});
                sock.write(P.bootstrap());
                sock.flush();
                if (root.currentThread !== "")
                    root.write(P.command("bt_list_messages", { thread: root.currentThread }));
            } else {
                // Calls and the link are live state: gone with the daemon.
                const s = Object.assign({}, root.state);
                s.calls = [];
                s.link = null;
                root.state = s;
            }
        }
        onError: error => {}
    }

    // Connect, and retry with a growing interval while there's no daemon.
    Timer {
        id: retry
        interval: 2000
        repeat: true
        triggeredOnStart: true
        running: root.enabled && !sock.connected
        onTriggered: {
            interval = Math.min(30000, interval * 2);
            if (!probe.running)
                probe.running = true;
        }
    }

    // Connecting to a missing socket makes Quickshell log a warning, so look
    // for it first: "no tetherd" stays silent.
    Process {
        id: probe
        command: ["test", "-S", root.socketPath]
        onExited: code => {
            if (code === 0 && root.enabled && !sock.connected) {
                sock.connected = false;
                sock.connected = true;
            }
        }
    }

    onEnabledChanged: if (!enabled) {
        sock.connected = false;
        panelOpen = false;
    }
    onSocketPathChanged: if (sock.connected) {
        sock.connected = false;
    }

    Timer {
        running: root.activeCall !== null || root.panelOpen
        interval: 1000
        repeat: true
        triggeredOnStart: true
        onTriggered: root.now = Date.now()
    }

    IpcHandler {
        target: "phone"

        // One JSON object: what the UI shows.
        function status(): string {
            const c = root.activeCall ?? root.ringingCall;
            return JSON.stringify({
                enabled: root.enabled,
                socket: root.socketPath,
                daemon: root.up,
                link: root.link,
                status: root.statusLine,
                detail: root.detail,
                device: root.deviceName,
                version: root.version,
                battery: root.battery,
                signal: root.signal,
                carrier: root.carrier,
                callControl: root.callControl,
                threads: root.threads.length,
                unread: root.unread,
                notifications: root.notifications.length,
                call: c ? {
                    state: c.state,
                    caller: root.callerName(c),
                    seconds: root.callSeconds
                } : null,
                lastError: root.lastError
            });
        }
        function send(to: string, body: string): string {
            return root.send(to, body);
        }
        function answer(): bool {
            return root.answer();
        }
        function decline(): bool {
            return root.decline();
        }
        function hangup(): bool {
            return root.hangup();
        }
        function dial(number: string): bool {
            return root.dial(number);
        }
        function messages(): void {
            // Off: where to turn it on.
            if (!root.enabled) {
                Panels.settingsSection = "features";
                Panels.settingsOpen = true;
                return;
            }
            if (root.panelOpen)
                root.panelOpen = false;
            else
                root.openMessages("");
        }
        function thread(key: string): void {
            root.openMessages(key);
        }
        function close(): void {
            root.panelOpen = false;
        }
        function refresh(): void {
            root.refresh();
        }
    }
}
