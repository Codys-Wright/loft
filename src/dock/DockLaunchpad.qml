import QtQuick
import qs.components
import Quickshell
import qs.services

// Launchpad, the dock's second icon (macOS): toggles the app grid on this
// dock's screen.
DockTile {
    id: root

    property string screenName: ""

    label: "Launchpad"
    running: Launchpad.output === screenName

    AppIcon {
        anchors.fill: parent
        glyph: "󰀻"
        sources: {
            const out = [];
            for (const n of ["launchpad", "view-app-grid", "applications-all", "view-grid", "start-here"]) {
                const p = Quickshell.iconPath(n, true);
                if (p && !out.includes(p))
                    out.push(p);
            }
            out.push("");
            return out;
        }
    }

    onClicked: Launchpad.toggle(screenName)
}
