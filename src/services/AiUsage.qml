pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Claude Code and Codex at a glance (`loft island ai`): sessions running
// now, tokens and estimated cost today / this week, the current 5-hour
// window, and Codex's own rate-limit windows. The CLI reads the agents'
// local logs incrementally and outputs aggregate counts only — no prompts,
// replies or paths (a session shows its project folder's name). Off with
// Settings → Dynamic Island → AI Agents.
Singleton {
    id: root

    readonly property bool enabled: Settings.island.ai
    // Faster while the AI page is on screen (the island binds it).
    property bool watching: false

    property var data: null
    readonly property var claude: data?.claude ?? null
    readonly property var codex: data?.codex ?? null
    readonly property bool available: (claude?.available ?? false) || (codex?.available ?? false)
    readonly property var sessions: (claude?.sessions ?? []).concat(codex?.sessions ?? [])
    readonly property int busy: sessions.filter(s => s.busy).length

    function refresh() {
        if (enabled && !proc.running)
            proc.running = true;
    }

    // 1.2K, 34M, 2.9B
    function tokens(n) {
        n = n ?? 0;
        const u = [[1e9, "B"], [1e6, "M"], [1e3, "K"]];
        for (const [v, s] of u)
            if (n >= v)
                return `${(n / v) >= 100 ? Math.round(n / v) : (n / v).toFixed(1)}${s}`;
        return String(Math.round(n));
    }

    function cost(usd) {
        return usd >= 100 ? `$${Math.round(usd)}` : `$${(usd ?? 0).toFixed(2)}`;
    }

    // "2 h 14 min" until a time (ms or s).
    function until(t) {
        if (!t)
            return "";
        const ms = (t < 1e12 ? t * 1000 : t) - Date.now();
        if (ms <= 0)
            return "now";
        const m = Math.round(ms / 60000), h = Math.floor(m / 60), d = Math.floor(h / 24);
        return d >= 2 ? `${d} days` : h > 0 ? `${h} h ${m % 60} min` : `${m} min`;
    }

    onEnabledChanged: if (enabled)
        refresh()
    else
        data = null
    Component.onCompleted: refresh()

    Timer {
        interval: root.watching ? 10000 : 60000
        repeat: true
        running: root.enabled
        onTriggered: root.refresh()
    }

    Process {
        id: proc
        command: ["loft", "island", "ai", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.data = JSON.parse(text);
                } catch (e) {}
            }
        }
    }

    IpcHandler {
        target: "ai"

        function refresh(): void {
            root.refresh();
        }
    }
}
