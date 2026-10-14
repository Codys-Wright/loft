pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Upcoming calendar events for the island (`loft island calendar`): khal /
// vdirsyncer calendars, else Evolution Data Server, plus the ICS files and
// URLs in Settings → Dynamic Island. Refreshed every 5 minutes and when the
// settings change; read-only.
Singleton {
    id: root

    readonly property string source: Settings.island.calendarSource
    readonly property var ics: Array.from(Settings.island.calendarIcs ?? [])
    readonly property bool enabled: source !== "none" || ics.length > 0

    // [{ id, title, start, end (ms), allDay, location, joinUrl, calendar }]
    property var events: []
    property var sources: []
    property bool loaded: false
    property real now: Date.now()

    readonly property real midnight: {
        const d = new Date(now);
        d.setHours(0, 0, 0, 0);
        return d.getTime();
    }
    readonly property var today: events.filter(e => e.start < midnight + 86400000 && e.end > now)
    readonly property var tomorrow: events.filter(e => e.start >= midnight + 86400000 && e.start < midnight + 2 * 86400000)
    // What's on now or next (timed events only), within the window.
    readonly property var next: events.find(e => !e.allDay && e.end > now) ?? null
    // The collapsed pill shows it from N minutes before until 5 minutes in.
    readonly property var soon: {
        const e = next;
        if (!e)
            return null;
        const lead = Settings.island.eventSoonMinutes * 60000;
        return e.start - now <= lead && now - e.start < 5 * 60000 ? e : null;
    }

    function refresh(force) {
        if (!enabled) {
            events = [];
            return;
        }
        const cmd = ["loft", "island", "calendar", "--json", "--source", source === "none" ? "none" : source];
        for (const s of ics)
            if (s.trim() !== "")
                cmd.push("--ics", s.trim());
        if (force)
            cmd.push("--refresh");
        // One run at a time; a change while it runs reruns after.
        if (proc.running) {
            proc.pending = cmd;
            return;
        }
        proc.command = cmd;
        proc.running = true;
    }

    // "in 12 min", "now", "10:30 AM", "All day".
    function when(e) {
        if (e.allDay)
            return "All day";
        const mins = Math.round((e.start - now) / 60000);
        if (e.start <= now)
            return e.end > now ? "Now" : "Ended";
        if (mins < 60)
            return `in ${Math.max(1, mins)} min`;
        return Qt.formatDateTime(new Date(e.start), "h:mm AP");
    }

    function timeRange(e) {
        if (e.allDay)
            return "All day";
        return `${Qt.formatDateTime(new Date(e.start), "h:mm")} – ${Qt.formatDateTime(new Date(e.end), "h:mm AP")}`;
    }

    function join(e) {
        if (e?.joinUrl)
            Quickshell.execDetached(["xdg-open", e.joinUrl]);
    }

    // Settings arrive one property at a time (and late, on first load): settle first.
    onSourceChanged: settle.restart()
    onIcsChanged: settle.restart()
    Component.onCompleted: settle.restart()
    Timer {
        id: settle
        interval: 300
        onTriggered: root.refresh(false)
    }

    Timer {
        interval: 300000
        repeat: true
        running: root.enabled
        onTriggered: root.refresh(false)
    }

    Timer {
        interval: 15000
        repeat: true
        running: true
        onTriggered: {
            const before = root.midnight;
            root.now = Date.now();
            if (root.midnight !== before)
                root.refresh(false);
        }
    }

    Process {
        id: proc
        property var pending: null
        onExited: if (pending) {
            command = pending;
            pending = null;
            running = true;
        }
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const d = JSON.parse(text);
                    root.events = (d.events ?? []).map(e => Object.assign({}, e, { start: e.start * 1000, end: e.end * 1000 }));
                    root.sources = d.sources ?? [];
                    root.loaded = true;
                } catch (e) {}
            }
        }
    }

    IpcHandler {
        target: "calendar"

        function refresh(): void {
            root.refresh(true);
        }
        function events(): string {
            return JSON.stringify(root.events.map(e => ({ title: e.title, start: e.start, allDay: e.allDay })));
        }
    }
}
