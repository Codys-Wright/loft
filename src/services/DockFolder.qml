import QtQuick
import Quickshell
import Quickshell.Io

// One watched folder for the dock (DockData): `loft dock folder …` (sorted entries
// with kinds, icons, cached thumbnails) re-run whenever inotify reports a
// change. `trash` mode only counts ($XDG_DATA_HOME/Trash/files).
Scope {
    id: root

    // "xdg:DOWNLOAD", "~/Documents/Loft", an absolute path; ignored for trash.
    property string spec: ""
    property string sort: "added"
    property bool trash: false
    property int limit: 60

    // { path, name, exists, count, items: [{ path, name, dir, mime, icon, generic, thumb?, added, modified }] }
    property var listing: ({ path: "", name: "", exists: false, count: 0, items: [] })
    readonly property string path: listing.path ?? ""
    readonly property int count: listing.count ?? 0
    readonly property var items: listing.items ?? []

    function refresh() {
        if (list.running) {
            again = true;
            return;
        }
        list.command = trash ? ["loft", "dock", "trash"] : ["loft", "dock", "folder", spec, "--sort", sort, "--limit", String(limit)];
        list.running = true;
    }
    property bool again: false

    onSpecChanged: refresh()
    onSortChanged: refresh()
    Component.onCompleted: refresh()

    Process {
        id: list
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const v = JSON.parse(text);
                    root.listing = root.trash ? { path: v.path, name: "Trash", exists: true, count: v.count, items: [] } : v;
                } catch (e) {
                    console.warn(`dock: bad folder listing for ${root.spec}: ${e}`);
                }
            }
        }
        onExited: {
            if (root.again) {
                root.again = false;
                root.refresh();
            }
        }
    }

    // Changes inside the folder → re-list (debounced: a download writes a lot).
    Process {
        id: watch
        running: root.path !== "" && (root.listing.exists ?? false)
        command: ["inotifywait", "-m", "-q", "-e", "create,delete,moved_to,moved_from,close_write,attrib", "--format", "%e", root.path]
        stdout: SplitParser {
            onRead: debounce.restart()
        }
        // The folder vanished or inotify isn't there: poll instead.
        onExited: poll.running = true
    }

    Timer {
        id: debounce
        interval: 400
        onTriggered: root.refresh()
    }

    Timer {
        id: poll
        interval: 30000
        repeat: true
        onTriggered: {
            root.refresh();
            if (root.listing.exists && !watch.running) {
                running = false;
                watch.running = true;
            }
        }
    }
}
