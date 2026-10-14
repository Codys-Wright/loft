pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications

// Countdown timers and stopwatches — several at once — shown as a live
// activity in the island and on its Timers page (next to the focus timer,
// which stays its own thing). Kept in <state>/timers.json against wall-clock
// times, so they survive reloads and restarts. A finished countdown rings
// (freedesktop alarm sound, Settings.island.timerSound) and banners with
// Repeat / Stop, through Do Not Disturb.
//
// IPC: timers start SPEC LABEL ("25m", "1h30m", "90s", "1:30", "10" = min) |
// stopwatch LABEL | pause ID | stop ID | clear | list.
// CLI: loft island timer 25m tea · loft island stopwatch.
Singleton {
    id: root

    // [{ id, label, kind: "timer"|"stopwatch", duration (s), endsAt (ms,
    //    running timer), left (s, paused timer), startedAt (ms, running
    //    stopwatch), elapsed (s, banked stopwatch time), paused }]
    readonly property var timers: store.value ?? []
    readonly property bool active: timers.length > 0
    readonly property bool running: timers.some(t => !t.paused)
    property real now: Date.now()

    // The one the collapsed island shows: the countdown ending first, else a
    // running stopwatch, else whatever is paused.
    readonly property var primary: {
        const live = timers.filter(t => !t.paused);
        const cd = live.filter(t => t.kind === "timer").sort((a, b) => a.endsAt - b.endsAt);
        return cd[0] ?? live[0] ?? timers[0] ?? null;
    }

    property string alarmFile: ""

    JsonStore {
        id: store
        path: `${Settings.stateDir}/timers.json`
        fallback: []
    }

    function save(list) {
        store.save(list);
    }

    function uid() {
        return Date.now().toString(36) + Math.floor(Math.random() * 1296).toString(36);
    }

    // Seconds from "25m", "1h30m", "90s", "1:30", "1:00:00", "10" (minutes).
    function parse(spec) {
        const s = String(spec ?? "").trim().toLowerCase().replace(/\s+/g, "");
        if (s === "")
            return 0;
        if (/^\d+(\.\d+)?$/.test(s))
            return Math.round(parseFloat(s) * 60);
        if (/^\d+(:\d{1,2}){1,2}$/.test(s)) {
            const p = s.split(":").map(Number);
            while (p.length < 3)
                p.unshift(0);
            return p[0] * 3600 + p[1] * 60 + p[2];
        }
        const m = s.match(/^(?:(\d+(?:\.\d+)?)h(?:ours?|rs?)?)?(?:(\d+(?:\.\d+)?)m(?:in(?:utes?|s)?)?)?(?:(\d+)s(?:ec(?:onds?|s)?)?)?$/);
        if (!m || !(m[1] || m[2] || m[3]))
            return 0;
        return Math.round((parseFloat(m[1] || 0) * 3600) + (parseFloat(m[2] || 0) * 60) + parseInt(m[3] || 0));
    }

    function start(seconds, label) {
        if (!(seconds > 0))
            return "";
        const id = uid();
        now = Date.now();
        save(timers.concat([{ id: id, label: label ?? "", kind: "timer", duration: seconds, endsAt: now + seconds * 1000, paused: false }]));
        return id;
    }

    function stopwatch(label) {
        const id = uid();
        now = Date.now();
        save(timers.concat([{ id: id, label: label ?? "", kind: "stopwatch", startedAt: now, elapsed: 0, paused: false }]));
        return id;
    }

    function find(id) {
        return timers.find(t => t.id === id) ?? null;
    }

    function update(id, fn) {
        save(timers.map(t => t.id === id ? fn(Object.assign({}, t)) : t));
    }

    function pause(id) {
        const t0 = Date.now();
        update(id, t => {
            if (t.kind === "timer") {
                if (t.paused)
                    t.endsAt = t0 + t.left * 1000;
                else
                    t.left = Math.max(0, (t.endsAt - t0) / 1000);
            } else {
                if (t.paused)
                    t.startedAt = t0;
                else
                    t.elapsed = (t.elapsed ?? 0) + (t0 - t.startedAt) / 1000;
            }
            t.paused = !t.paused;
            return t;
        });
        now = t0;
    }

    function addTime(id, seconds) {
        update(id, t => {
            if (t.kind !== "timer")
                return t;
            t.duration += seconds;
            if (t.paused)
                t.left += seconds;
            else
                t.endsAt += seconds * 1000;
            return t;
        });
    }

    function stop(id) {
        save(timers.filter(t => t.id !== id));
    }

    function clear() {
        save([]);
    }

    // Seconds left (timers) or elapsed (stopwatches), live.
    function remaining(t) {
        return !t ? 0 : t.paused ? t.left : Math.max(0, (t.endsAt - now) / 1000);
    }
    function elapsed(t) {
        return !t ? 0 : (t.elapsed ?? 0) + (t.paused ? 0 : Math.max(0, (now - t.startedAt) / 1000));
    }
    function value(t) {
        return t?.kind === "stopwatch" ? elapsed(t) : remaining(t);
    }
    function progress(t) {
        return !t ? 0 : t.kind === "stopwatch" ? (elapsed(t) % 60) / 60 : 1 - remaining(t) / Math.max(1, t.duration);
    }
    function title(t) {
        return t?.label || (t?.kind === "stopwatch" ? "Stopwatch" : "Timer");
    }

    // 4:05, 1:02:03 (countdowns round up so 0:00 means done).
    function format(seconds, up) {
        const s = up ? Math.ceil(seconds) : Math.floor(seconds);
        const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = s % 60;
        const mm = h > 0 ? String(m).padStart(2, "0") : String(m);
        return `${h > 0 ? h + ":" : ""}${mm}:${String(r).padStart(2, "0")}`;
    }
    function display(t) {
        return format(value(t), t?.kind === "timer");
    }

    // A short "25 min" / "1 h 30 min" / "45 s" for a duration.
    function describe(seconds) {
        const h = Math.floor(seconds / 3600), m = Math.floor((seconds % 3600) / 60), s = Math.round(seconds % 60);
        const parts = [];
        if (h)
            parts.push(`${h} h`);
        if (m)
            parts.push(`${m} min`);
        if (s && !h)
            parts.push(`${s} s`);
        return parts.join(" ") || "0 s";
    }

    Timer {
        interval: 250
        repeat: true
        running: root.running
        onTriggered: {
            root.now = Date.now();
            const done = root.timers.filter(t => t.kind === "timer" && !t.paused && t.endsAt <= root.now);
            if (done.length === 0)
                return;
            root.save(root.timers.filter(t => !done.includes(t)));
            for (const t of done)
                root.ring(t);
        }
    }

    // ── Done ─────────────────────────────────────────────────────────────
    property int rings: 0

    function ring(t) {
        Notifications.show({
            appName: "Timer",
            appIcon: "alarm-symbolic",
            summary: title(t),
            body: `${describe(t.duration)} timer is done.`,
            image: "",
            glyph: "󰔛",
            glyphColor: Theme.warn,
            urgency: NotificationUrgency.Critical,
            actions: [
                {
                    identifier: "default",
                    text: "",
                    invoke: () => root.silence()
                },
                {
                    identifier: "repeat",
                    text: "Repeat",
                    invoke: () => {
                        root.silence();
                        root.start(t.duration, t.label);
                    }
                },
                {
                    identifier: "stop",
                    text: "Stop",
                    invoke: () => root.silence()
                }
            ]
        });
        if (Settings.island.timerSound && alarmFile !== "") {
            rings = 3;
            sound.running = true;
        }
    }

    function silence() {
        rings = 0;
        sound.running = false;
    }

    // The freedesktop alarm (sound-theme-freedesktop): $LOFT_ALARM_SOUND, else
    // the first data dir that has it.
    Process {
        running: true
        command: ["sh", "-c", 'f="${LOFT_ALARM_SOUND:-}"; [ -f "$f" ] && { echo "$f"; exit; }; IFS=:; for d in ${XDG_DATA_DIRS:-}:$HOME/.nix-profile/share:/run/current-system/sw/share:/usr/share; do f="$d/sounds/freedesktop/stereo/alarm-clock-elapsed.oga"; [ -f "$f" ] && { echo "$f"; exit; }; done']
        stdout: StdioCollector {
            onStreamFinished: root.alarmFile = text.trim()
        }
    }

    Process {
        id: sound
        command: ["sh", "-c", 'exec pw-play "$1" 2>/dev/null || exec paplay "$1"', "sh", root.alarmFile]
        onExited: {
            if (--root.rings > 0)
                running = true;
        }
    }

    IpcHandler {
        target: "timers"

        function start(spec: string, label: string): string {
            return root.start(root.parse(spec), label);
        }
        function stopwatch(label: string): string {
            return root.stopwatch(label);
        }
        function pause(id: string): void {
            root.pause(id || (root.primary?.id ?? ""));
        }
        function stop(id: string): void {
            root.stop(id || (root.primary?.id ?? ""));
        }
        function clear(): void {
            root.clear();
        }
        function silence(): void {
            root.silence();
        }
        function list(): string {
            return JSON.stringify(root.timers.map(t => ({ id: t.id, label: root.title(t), kind: t.kind, value: Math.round(root.value(t)), paused: t.paused })));
        }
    }
}
