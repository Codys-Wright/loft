import QtQuick
import Quickshell
import Quickshell.Io

// A JSON document kept in a file: `value` is its parsed content (`fallback`
// while the file is missing or broken), save(v) writes it (creating the
// directory). Edits made outside the shell are picked up (watched).
// Used for data the user builds up — clipboard pins, snippets, the shelf,
// scratchpad notes — as opposed to settings (ClipboardConfig, Settings).
FileView {
    id: store

    property var fallback: null
    property var value: fallback
    property bool ready: false

    printErrors: false
    watchChanges: true
    atomicWrites: true
    onFileChanged: reload()
    onLoaded: {
        try {
            value = JSON.parse(text());
        } catch (e) {
            console.warn(`JsonStore: ${path} is not valid JSON: ${e}`);
            value = fallback;
        }
        ready = true;
    }
    onLoadFailed: error => {
        value = fallback;
        ready = true;
    }

    property string pending: ""

    function save(v) {
        value = v;
        pending = JSON.stringify(v, null, 2) + "\n";
        mkdir.command = ["mkdir", "-p", path.substring(0, path.lastIndexOf("/"))];
        mkdir.running = true;
    }

    property Process mkdir: Process {
        onExited: store.setText(store.pending)
    }
}
