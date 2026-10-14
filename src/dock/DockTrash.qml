import QtQuick
import qs.components
import Quickshell
import qs.services

// The Trash, at the far end of the dock: empty / full icon; click opens it
// in the file manager; files dropped on it are moved to it (gio trash).
DockTile {
    id: root

    label: "Trash"
    lit: drop.containsDrag

    AppIcon {
        anchors.fill: parent
        sources: {
            const out = [];
            for (const n of DockData.trashFull ? ["user-trash-full", "trashcan_full", "user-trash"] : ["user-trash", "trashcan_empty", "user-trash-empty"]) {
                const p = Quickshell.iconPath(n, true);
                if (p && !out.includes(p))
                    out.push(p);
            }
            out.push("");
            return out;
        }
    }

    onClicked: DockData.openTrash()

    DropArea {
        id: drop
        anchors.fill: parent
        // Files only (a URL list); no `keys` filter: a drag started by this
        // shell carries its Drag.keys, not the MIME types, as keys.
        onEntered: d => {
            if (!d.hasUrls)
                d.accepted = false;
        }
        onDropped: d => {
            DockData.trashFiles(d.urls ?? []);
            d.accept(Qt.MoveAction);
        }
    }
}
