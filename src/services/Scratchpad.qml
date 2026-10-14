pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Scratchpad: tabbed Markdown notes, autosaved to <state>/scratchpad.json
// ({ notes: [{ id, title, text, updated }], current }). The window is
// clipboard/ScratchpadWindow.qml; export writes <exportDir>/<title>.md.
//
// IPC: scratchpad toggle | open | close | newNote | exportNote
Singleton {
    id: root

    readonly property bool enabled: Features.on("scratchpad")
    property bool open: false

    readonly property var notes: doc.notes
    property int current: 0
    readonly property var note: notes[Math.min(current, notes.length - 1)] ?? null
    property string toast: ""

    // Working copy; written back to the store shortly after each edit.
    property var doc: ({
            notes: [blank(1)]
        })

    JsonStore {
        id: store
        path: `${Settings.stateDir}/scratchpad.json`
        fallback: null
        onReadyChanged: root.adopt()
        onValueChanged: root.adopt()
    }

    // Take the file's content unless we're the ones with unsaved edits.
    function adopt() {
        if (!store.ready || saveTimer.running)
            return;
        const v = store.value;
        if (v && Array.isArray(v.notes) && v.notes.length > 0) {
            doc = v;
            current = Math.max(0, Math.min(v.current ?? 0, v.notes.length - 1));
        }
    }

    function blank(n) {
        return {
            id: Date.now().toString(36) + Math.floor(Math.random() * 1e6).toString(36),
            title: `Note ${n}`,
            text: "",
            updated: Date.now()
        };
    }

    // A note's title: its first heading / line, else its stored title.
    function titleOf(n) {
        const first = (n.text ?? "").split("\n").find(l => l.trim() !== "") ?? "";
        const t = first.replace(/^#+\s*/, "").trim();
        return t !== "" ? t.slice(0, 40) : n.title;
    }

    function commit(notes, cur) {
        doc = {
            notes: notes,
            current: cur
        };
        current = cur;
        saveTimer.restart();
    }

    function setText(text) {
        if (!note || note.text === text)
            return;
        commit(notes.map((n, i) => i === current ? Object.assign({}, n, {
                text: text,
                updated: Date.now()
            }) : n), current);
    }

    function select(i) {
        if (i >= 0 && i < notes.length)
            commit(notes, i);
    }

    function newNote() {
        commit(notes.concat([blank(notes.length + 1)]), notes.length);
    }

    function closeNote(i) {
        const l = notes.filter((n, j) => j !== i);
        if (l.length === 0)
            l.push(blank(1));
        commit(l, Math.max(0, Math.min(current > i ? current - 1 : current, l.length - 1)));
    }

    Timer {
        id: saveTimer
        interval: 400
        onTriggered: store.save(root.doc)
    }

    function flush() {
        if (saveTimer.running) {
            saveTimer.stop();
            store.save(doc);
        }
    }

    function fileName(n) {
        const t = titleOf(n).replace(/[\/\\:*?"<>|]+/g, "-").replace(/\s+/g, " ").trim();
        return (t || "note") + ".md";
    }

    // Write the note to <exportDir>/<title>.md (never overwrites: adds -2, -3…).
    function exportNote(n) {
        const target = n ?? note;
        if (!target)
            return;
        const dir = ClipboardConfig.expand(ClipboardConfig.scratchpad.exportDir);
        const name = fileName(target);
        Clipboard.sh('mkdir -p "$1" || exit 1; base="${2%.md}"; f="$1/$2"; i=2; while [ -e "$f" ]; do f="$1/$base-$i.md"; i=$((i+1)); done; printf "%s" "$3" > "$f" && printf "%s" "$f"', [dir, name, target.text ?? ""], (out, code) => {
            toast = code === 0 ? `Saved ${out.replace(Quickshell.env("HOME"), "~")}` : "Export failed";
        });
    }

    IpcHandler {
        target: "scratchpad"

        function toggle(): void {
            root.open = root.enabled && !root.open;
        }
        function open(): void {
            root.open = root.enabled;
        }
        function close(): void {
            root.open = false;
        }
        function newNote(): void {
            root.newNote();
            root.open = root.enabled;
        }
        function exportNote(): void {
            root.exportNote(null);
        }
    }
}
