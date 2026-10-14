pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The shell side of Settings → Keyboard Shortcuts:
//
//   leaveAlone            Apps to leave alone (niri app ids): Loft's window
//                         shortcuts (⌘Q / hold to quit, Paste as Plain Text,
//                         Snippets, Quick Panel, Radial Menu, Arrange, custom
//                         shortcuts' window actions) do nothing while one of
//                         them is focused, and `loft keys xremap` turns the
//                         list into xremap's config (cli/loft/keys.py) when the
//                         consumer wired xremap to it.
//   pauseShellShortcuts   whether the shell part applies (the xremap part
//                         always does)
//
// Stored in <state>/overrides/keyboard.json. The keybinds themselves are
// niri's (NiriSettings → loft-niri, overrides/niri.kdl).
//
// Custom shortcuts that run a Quick Panel action call this shell over IPC
// (`… ipc --path <shell> call action run <id>`, everyday/Everyday.qml); the
// path changes with every package, so they're rewritten when it did.
Singleton {
    id: root

    readonly property string file: `${Settings.stateDir}/overrides/keyboard.json`

    readonly property alias leaveAlone: cfg.leaveAlone
    readonly property alias pauseShellShortcuts: cfg.pauseShellShortcuts

    function isLeftAlone(appId) {
        return !!appId && Array.from(cfg.leaveAlone ?? []).includes(appId);
    }

    function setLeaveAlone(list) {
        cfg.leaveAlone = list;
    }

    function setPause(on) {
        cfg.pauseShellShortcuts = on;
    }

    // A Loft shortcut fired: ignore it when the focused app is left alone.
    function skip(what) {
        const w = Niri.focusedWindow;
        if (!cfg.pauseShellShortcuts || !w || !isLeftAlone(w.app_id))
            return false;
        console.info(`Shortcuts: ${what} left alone in ${w.app_id}`);
        return true;
    }

    // ── xremap ───────────────────────────────────────────────────────────
    // `loft keys xremap`: rewrites <state>/xremap/config.json from the base
    // config the xremap service recorded (nothing until it did).
    property string xremapStatus: ""

    function syncXremap() {
        xremapProc.running = false;
        xremapProc.running = true;
    }

    Process {
        id: xremapProc
        command: ["loft", "keys", "xremap"]
        stdout: StdioCollector {
            onStreamFinished: root.xremapStatus = text.trim()
        }
    }

    // ── Custom shortcuts that run a Loft action ─────────────────────────
    property string qsExe: ""
    readonly property var ipcPrefix: qsExe ? [qsExe, "ipc", "--any-display", "--path", Quickshell.shellDir, "call"] : []

    // The bind record for a Quick Panel action (palette/Actions.qml id).
    function actionRecord(id, label) {
        return {
            action: "spawn",
            args: ipcPrefix.concat(["action", "run", id]),
            title: label,
            loft: id
        };
    }

    // Once per shell path (a failing apply mustn't retry in a loop).
    property string refreshedFor: ""

    function refreshLoftBinds() {
        const shortcuts = NiriSettings.bindsData.shortcuts ?? [];
        const key = JSON.stringify(ipcPrefix);
        if (ipcPrefix.length === 0 || shortcuts.length === 0 || refreshedFor === key)
            return;
        refreshedFor = key;
        const ops = [];
        for (const s of shortcuts) {
            if (!s.loft || !s.combo || !s.id.startsWith("c:"))
                continue;
            const want = ipcPrefix.concat(["action", "run", s.loft]);
            if (JSON.stringify(s.args) !== JSON.stringify(want))
                ops.push({
                    op: "add",
                    combo: s.combo,
                    record: Object.assign({}, s.record, { args: want })
                });
        }
        if (ops.length > 0)
            NiriSettings.bindOps(ops);
    }

    Process {
        id: whichQs
        command: ["sh", "-c", "command -v quickshell"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                root.qsExe = text.trim();
                NiriSettings.refreshBinds();
            }
        }
    }

    Connections {
        target: NiriSettings
        function onBindsDataChanged() {
            root.refreshLoftBinds();
        }
    }

    // ── Storage ──────────────────────────────────────────────────────────
    FileView {
        id: view
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onAdapterUpdated: writeAdapter()
        onLoadFailed: error => {
            if (error === FileViewError.FileNotFound)
                mkdir.running = true;
        }

        JsonAdapter {
            id: cfg
            property list<string> leaveAlone: []
            property bool pauseShellShortcuts: true
            onLeaveAloneChanged: root.syncXremap()
        }
    }

    Component.onCompleted: view.path = file

    Process {
        id: mkdir
        command: ["mkdir", "-p", `${Settings.stateDir}/overrides`]
        onExited: {
            view.writeAdapter();
            view.path = "";
            view.path = root.file;
        }
    }
}
