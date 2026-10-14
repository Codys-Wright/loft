pragma Singleton

import QtQuick
import Quickshell

// The Utilities window (src/utilities/): which page shows and whether it is
// open. Its pages — Ports, Updates, Cleaner, Media Tools — are separate
// features (Features.qml, group "Apps"); the window loads while any is on.
// Open with IPC `utilities open|ports|updates|cleaner|media`, `loft utilities
// open [page]`, the "Utilities" desktop entry (Spotlight), or for files
// `media open OP PATHS` / `loft media open FILES` / the dock's Quick Actions.
Singleton {
    id: root

    property bool open: false
    property string section: "ports"

    readonly property var sections: [
        {
            id: "ports",
            feature: "portManager",
            badge: "blue",
            icon: "󰒍",
            label: "Ports"
        },
        {
            id: "updates",
            feature: "flakeUpdates",
            badge: "green",
            icon: "󰚰",
            label: "Updates"
        },
        {
            id: "cleaner",
            feature: "cleaner",
            badge: "orange",
            icon: "󰃢",
            label: "Cleaner"
        },
        {
            id: "media",
            feature: "mediaTools",
            badge: "purple",
            icon: "󰕧",
            label: "Media Tools"
        }
    ]

    readonly property var shown: sections.filter(s => Features.on(s.feature))
    readonly property bool available: shown.length > 0

    function show(id) {
        const s = shown.find(x => x.id === id) ?? shown[0];
        if (!s)
            return;
        section = s.id;
        open = true;
    }

    function toggle() {
        if (open)
            open = false;
        else
            show(section);
    }
}
