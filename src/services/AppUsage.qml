pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Screen time per app for today, measured in-shell from niri's focus events
// (no daemon). Persisted to $STUDIO_STATE_DIR/app-usage.json so it survives
// shell reloads; resets at midnight.
Singleton {
    id: root

    readonly property string stateDir: Quickshell.env("STUDIO_STATE_DIR") || `${Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state"}/studio-linux`

    // appId → seconds, for `day`.
    property var seconds: ({})
    property string day: today()

    // Sorted [{ appId, seconds }], most used first.
    readonly property var ranked: Object.entries(seconds).map(([appId, s]) => ({ appId: appId, seconds: s })).sort((a, b) => b.seconds - a.seconds)
    readonly property real total: Object.values(seconds).reduce((a, b) => a + b, 0)

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
            store.save();
        }
    }

    FileView {
        id: store
        path: `${root.stateDir}/app-usage.json`
        // A missing file is fine (first run).
        printErrors: false
        onLoaded: {
            try {
                const data = JSON.parse(text());
                if (data.day === root.day)
                    root.seconds = data.seconds ?? {};
            } catch (e) {}
        }

        function save() {
            setText(JSON.stringify({ day: root.day, seconds: root.seconds }));
        }
    }
}
