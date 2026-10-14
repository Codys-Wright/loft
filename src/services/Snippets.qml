pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Text snippets: a store of { id, trigger, name, text } in
// <state>/snippets.json (edited in Settings → Clipboard), a picker
// (clipboard/SnippetPicker.qml) and expansion: the text, with variables
// filled in, typed into the focused app with wtype.
//
// Variables: {clipboard} {date} {time} {datetime} {weekday} {user}; {{ }}
// for literal braces. The trigger is what you type in the picker to find a
// snippet (";sig" + Enter) — there's no system-wide as-you-type expansion,
// which would need an input hook (keyd/espanso) outside the shell.
//
// IPC: snippets toggle | open | close | settings
Singleton {
    id: root

    readonly property bool enabled: Features.on("snippets")
    property bool pickerOpen: false

    readonly property var items: store.value ?? []

    readonly property var variables: ["clipboard", "date", "time", "datetime", "weekday", "user"]

    JsonStore {
        id: store
        path: `${Settings.stateDir}/snippets.json`
        fallback: [
            {
                id: "example-date",
                trigger: ";date",
                name: "Today's date",
                text: "{date}"
            },
            {
                id: "example-quote",
                trigger: ";quote",
                name: "Quote the clipboard",
                text: "> {clipboard}"
            }
        ]
    }

    function add() {
        const s = {
            id: Clipboard.uid(),
            trigger: "",
            name: "New snippet",
            text: ""
        };
        store.save(items.concat([s]));
        return s;
    }

    function update(id, patch) {
        store.save(items.map(s => s.id === id ? Object.assign({}, s, patch) : s));
    }

    function remove(id) {
        store.save(items.filter(s => s.id !== id));
    }

    // Best matches first: exact trigger, trigger prefix, then name/text.
    function search(query) {
        const q = query.trim().toLowerCase();
        if (q === "")
            return items;
        const score = s => {
            const t = (s.trigger ?? "").toLowerCase();
            if (t === q)
                return 0;
            if (t.startsWith(q))
                return 1;
            if ((s.name ?? "").toLowerCase().includes(q))
                return 2;
            if ((s.text ?? "").toLowerCase().includes(q) || t.includes(q))
                return 3;
            return -1;
        };
        return items.map(s => ({
                    s: s,
                    k: score(s)
                })).filter(x => x.k >= 0).sort((a, b) => a.k - b.k).map(x => x.s);
    }

    // Fill in the variables; clipboard is the current clipboard text.
    function render(text, clipboard) {
        const now = new Date();
        const values = {
            clipboard: clipboard ?? "",
            date: Qt.formatDate(now, Qt.ISODate),
            time: Qt.formatTime(now, "HH:mm"),
            datetime: Qt.formatDateTime(now, "yyyy-MM-dd HH:mm"),
            weekday: Qt.formatDate(now, "dddd"),
            user: Quickshell.env("USER") ?? ""
        };
        return text.replace(/\{\{|\}\}|\{(\w+)\}/g, (m, name) => {
            if (m === "{{")
                return "{";
            if (m === "}}")
                return "}";
            return values[name] !== undefined ? values[name] : m;
        });
    }

    property string pendingText: ""

    // Type a snippet into the focused app (after the picker closed).
    function expand(snippet) {
        pickerOpen = false;
        const text = snippet.text ?? "";
        if (text.includes("{clipboard}")) {
            Clipboard.run(["wl-paste", "--no-newline", "--type", "text"], (out, code) => {
                pendingText = render(text, code === 0 ? out : "");
                typeDelay.restart();
            });
        } else {
            pendingText = render(text, "");
            typeDelay.restart();
        }
    }

    Timer {
        id: typeDelay
        interval: 180
        onTriggered: if (root.pendingText !== "")
            Quickshell.execDetached(["wtype", "--", root.pendingText])
    }

    IpcHandler {
        target: "snippets"

        function toggle(): void {
            // The ⌘⇧. bind; apps left alone (Shortcuts.qml) don't get it.
            if (!root.pickerOpen && Shortcuts.skip("Snippets"))
                return;
            root.pickerOpen = root.enabled && !root.pickerOpen;
        }
        function open(): void {
            root.pickerOpen = root.enabled;
        }
        function close(): void {
            root.pickerOpen = false;
        }
        // Settings → Snippets (the editor).
        function settings(): void {
            Panels.settingsSection = "snippets";
            Panels.settingsOpen = true;
        }
    }
}
