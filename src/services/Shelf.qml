pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The Shelf: a place to park files, links and text while you go somewhere
// else to drop them (clipboard/Shelf.qml is the surface). Items persist in
// <state>/shelf.json until removed: { id, kind: "file" | "url" | "text", value, name, added }.
//
// Files are kept by path (not copied): the shelf holds a reference, like
// macOS's Dropover.
//
// IPC: shelf toggle | open | close | addClipboard | clear
Singleton {
    id: root

    readonly property bool enabled: Features.on("shelf")
    property bool open: false
    // A drag is hovering the shelf's edge handle.
    property bool dragHover: false

    readonly property var items: store.value ?? []

    JsonStore {
        id: store
        path: `${Settings.stateDir}/shelf.json`
        fallback: []
    }

    function basename(path) {
        const p = path.replace(/\/+$/, "");
        return p.substring(p.lastIndexOf("/") + 1) || p;
    }

    function itemFor(value) {
        const v = String(value).trim();
        if (v.startsWith("file://")) {
            const path = decodeURIComponent(v.slice(7));
            return {
                kind: "file",
                value: path,
                name: basename(path)
            };
        }
        if (v.startsWith("/"))
            return {
                kind: "file",
                value: v,
                name: basename(v)
            };
        if (/^[a-z][a-z0-9+.-]*:\/\/\S+$/i.test(v))
            return {
                kind: "url",
                value: v,
                name: v.replace(/^[a-z]+:\/\//i, "").replace(/\/$/, "")
            };
        return {
            kind: "text",
            value: String(value),
            name: v.split("\n")[0].slice(0, 80)
        };
    }

    function add(values) {
        const added = [];
        for (const v of values) {
            if (String(v).trim() === "")
                continue;
            const it = itemFor(v);
            if (items.some(x => x.kind === it.kind && x.value === it.value))
                continue;
            added.push(Object.assign({
                id: Clipboard.uid() + added.length,
                added: Date.now()
            }, it));
        }
        if (added.length)
            store.save(added.concat(items));
        return added.length;
    }

    // From a DropArea drop: URLs (files or links) win over the text that
    // usually accompanies them.
    function addDrop(drop) {
        if (drop.hasUrls && drop.urls.length > 0)
            return add(drop.urls.map(u => u.toString()));
        if (drop.hasText)
            return add([drop.text]);
        return 0;
    }

    function remove(id) {
        store.save(items.filter(x => x.id !== id));
    }

    function clear() {
        store.save([]);
    }

    // Park whatever is on the clipboard: copied files (text/uri-list) or text.
    function addClipboard() {
        Clipboard.sh('if wl-paste --list-types | grep -qx "text/uri-list"; then wl-paste --no-newline --type text/uri-list; else wl-paste --no-newline --type text; fi', [], (out, code) => {
            if (code !== 0)
                return;
            const lines = out.split(/\r?\n/).filter(l => l.trim() !== "" && !l.startsWith("#"));
            const uris = lines.length > 0 && lines.every(l => /^file:\/\//.test(l.trim()));
            add(uris ? lines : [out]);
        });
    }

    // Copy an item to the clipboard (files as a file list, so file managers paste them).
    function copy(item) {
        if (item.kind === "file")
            Clipboard.sh('printf "%s\\r\\n" "$1" | wl-copy --type text/uri-list >/dev/null 2>&1', ["file://" + encodeURI(item.value)]);
        else
            Clipboard.copyText(item.value);
    }

    function openItem(item) {
        if (item.kind === "text")
            return;
        Quickshell.execDetached(["xdg-open", item.kind === "file" ? item.value : item.value]);
    }

    function uriOf(item) {
        return item.kind === "file" ? "file://" + encodeURI(item.value) : item.value;
    }

    IpcHandler {
        target: "shelf"

        function toggle(): void {
            root.open = root.enabled && !root.open;
        }
        function open(): void {
            root.open = root.enabled;
        }
        function close(): void {
            root.open = false;
        }
        function addClipboard(): void {
            root.addClipboard();
            root.open = root.enabled;
        }
        function clear(): void {
            root.clear();
        }
        function list(): string {
            return root.items.map(i => `${i.kind}\t${i.value}`).join("\n");
        }
    }
}
