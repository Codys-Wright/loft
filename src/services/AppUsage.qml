pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Screen time per app for today, measured in-shell from niri's focus events
// (no daemon). Persisted to $LOFT_STATE_DIR/app-usage.json so it survives
// shell reloads; resets at midnight.
Singleton {
    id: root

    readonly property string stateDir: Quickshell.env("LOFT_STATE_DIR") || `${Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state"}/loft`

    // appId → seconds, for `day`.
    property var seconds: ({})
    property string day: today()

    // Sorted [{ appId, seconds }], most used first.
    readonly property var ranked: Object.entries(seconds).map(([appId, s]) => ({ appId: appId, seconds: s })).sort((a, b) => b.seconds - a.seconds)
    readonly property real total: Object.values(seconds).reduce((a, b) => a + b, 0)

    // appId → when it was last used (ms since epoch): focused, or had a
    // window open. Kept across days, for the dock's recent apps.
    property var lastUsed: ({})

    // Apps used most recently first, skipping `exclude` (app ids).
    function recentApps(n, exclude) {
        const ex = exclude ?? [];
        return Object.entries(lastUsed).filter(([a]) => !ex.includes(a)).sort((x, y) => y[1] - x[1]).slice(0, n).map(([a]) => a);
    }

    // Drop an app from the recent list (the dock's "Remove from Dock").
    function forget(appId) {
        const m = Object.assign({}, lastUsed);
        delete m[appId];
        lastUsed = m;
        if (store.ready)
            store.save();
    }

    function touch(apps) {
        const now = Date.now();
        let m = null;
        for (const a of apps) {
            // A minute's resolution is plenty (and keeps writes rare).
            if (!a || now - (lastUsed[a] ?? 0) < 60000)
                continue;
            m = m ?? Object.assign({}, lastUsed);
            m[a] = now;
        }
        if (!m)
            return;
        // Keep the newest 60.
        const keep = Object.entries(m).sort((x, y) => y[1] - x[1]).slice(0, 60);
        const kept = {};
        for (const [a, t] of keep)
            kept[a] = t;
        lastUsed = kept;
        // Not before the file is read: that would drop today's screen time.
        if (store.ready)
            store.save();
    }

    Connections {
        target: Niri
        function onWindowsChanged() {
            root.touch(Niri.windows.map(w => w.app_id));
        }
    }

    function today() {
        return Qt.formatDate(new Date(), "yyyy-MM-dd");
    }

    function format(s) {
        const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
        return h > 0 ? `${h}h ${m}m` : m > 0 ? `${m}m` : `${Math.floor(s)}s`;
    }

    // Credit the focused app every 10 s (cheap; precise enough for screen time).
    Timer {
        interval: 10000
        running: true
        repeat: true
        onTriggered: {
            if (root.today() !== root.day) {
                root.day = root.today();
                root.seconds = {};
            }
            const app = Niri.focusedWindow?.app_id;
            if (!app)
                return;
            const s = Object.assign({}, root.seconds);
            s[app] = (s[app] ?? 0) + interval / 1000;
            root.seconds = s;
            const lu = Object.assign({}, root.lastUsed);
            lu[app] = Date.now();
            root.lastUsed = lu;
            store.save();
        }
    }

    FileView {
        id: store
        path: `${root.stateDir}/app-usage.json`
        // A missing file is fine (first run).
        printErrors: false
        property bool ready: false
        onLoadFailed: ready = true
        onLoaded: {
            ready = true;
            try {
                const data = JSON.parse(text());
                if (data.day === root.day)
                    root.seconds = data.seconds ?? {};
                root.lastUsed = Object.assign({}, data.lastUsed ?? {}, root.lastUsed);
            } catch (e) {}
        }

        function save() {
            setText(JSON.stringify({ day: root.day, seconds: root.seconds, lastUsed: root.lastUsed }));
        }
    }
}
