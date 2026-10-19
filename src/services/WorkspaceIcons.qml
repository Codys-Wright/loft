pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "wsicons.js" as WsIcons

// Icons for named niri workspaces in the menu bar (bar/Workspaces.qml,
// without Spaces): one per workspace name, so each display's bar shows
// which workspace it is on.
//
// Where an icon comes from, first match wins:
//   1. Settings → Menu Bar → Workspace Icons (Settings.menubar
//      .workspaceIconMap, { "<lowercase name>": icon }; "" = no icon);
//   2. the consumer's Nix (programs.loft.workspaceIcons → a JSON file at
//      $LOFT_WORKSPACE_ICONS);
//   3. a guess from the name (wsicons.js: music, code, notes …).
// Settings.menubar.workspaceIcons = false turns them off (plain dots).
Singleton {
    id: root

    readonly property bool enabled: Settings.menubar.workspaceIcons !== false
    readonly property var user: WsIcons.normalize(Settings.menubar.workspaceIconMap)
    property var nix: ({})

    // The icon for a workspace name ("" = none: the bar keeps its dot).
    function iconFor(name) {
        return enabled ? WsIcons.resolve(name, user, nix) : "";
    }

    // What the icon would be without a choice in Settings.
    function defaultFor(name) {
        return WsIcons.resolve(name, {}, nix);
    }

    function isCustom(name) {
        return Object.prototype.hasOwnProperty.call(user, key(name));
    }

    function key(name) {
        return String(name ?? "").trim().toLowerCase();
    }

    function setEnabled(on) {
        const m = Object.assign({}, Settings.menubar);
        m.workspaceIcons = on;
        Settings.menubar = m;
    }

    function set(name, icon) {
        const k = key(name);
        if (k === "")
            return;
        const map = Object.assign({}, Settings.menubar.workspaceIconMap ?? {});
        // Drop older spellings of the same name ("Music" vs "music").
        for (const n of Object.keys(map))
            if (key(n) === k)
                delete map[n];
        map[k] = icon;
        const m = Object.assign({}, Settings.menubar);
        m.workspaceIconMap = map;
        Settings.menubar = m;
    }

    function reset(name) {
        const k = key(name);
        const map = Object.assign({}, Settings.menubar.workspaceIconMap ?? {});
        for (const n of Object.keys(map))
            if (key(n) === k)
                delete map[n];
        const m = Object.assign({}, Settings.menubar);
        m.workspaceIconMap = map;
        Settings.menubar = m;
    }

    FileView {
        id: nixFile
        path: Quickshell.env("LOFT_WORKSPACE_ICONS") ?? ""
        printErrors: false
        onLoaded: {
            try {
                root.nix = WsIcons.normalize(JSON.parse(text()));
            } catch (e) {
                console.warn(`WorkspaceIcons: cannot parse ${path}: ${e}`);
            }
        }
    }
}
