pragma Singleton

import QtQuick
import Quickshell
import "appicons.js" as AppIcons

// App identity: maps niri app-ids to desktop entries (name, icon, launch).
Singleton {
    id: root

    // The shell's own windows (Quickshell's app-id) present as Loft apps.
    readonly property var own: ({
            "org.quickshell": { name: "Settings", icon: "preferences-system" }
        })

    // niri app_id → DesktopEntry (or null). Cached; lookups are heuristic.
    property var cache: ({})

    // Entries are scanned asynchronously and rescanned whenever anything
    // changes in (or above) an applications dir — $HOME, /nix/store … — with
    // a valuesChanged per moved row, often with nothing actually changed.
    // At most every 400 ms, drop the cached lookups (one notification each)
    // only when the entries' ids / names / icons / WM classes differ
    // (appicons.js signature).
    property string signature: ""
    // DesktopEntries.applications.values as of the last real change: bind
    // app lists (pickers) to this, not to the raw model and its bursts.
    property var entries: []
    Connections {
        target: DesktopEntries.applications
        // Not restart(): rescans can come back to back for as long as a
        // build churns /nix/store, and a debounce would never fire.
        function onValuesChanged() {
            if (!settle.running)
                settle.start();
        }
    }
    Timer {
        id: settle
        interval: 400
        onTriggered: root.sync()
    }
    // A reloaded shell finds the entries already scanned (no signal).
    Component.onCompleted: sync()

    function sync() {
        const sig = AppIcons.signature(DesktopEntries.applications.values);
        if (sig === signature)
            return;
        signature = sig;
        entries = DesktopEntries.applications.values.slice();
        themedCache = {};
        cache = {};
        iconCache = {};
    }

    function entry(appId) {
        if (!appId)
            return null;
        if (cache[appId] === undefined)
            cache[appId] = DesktopEntries.byId(appId) ?? DesktopEntries.heuristicLookup(appId) ?? null;
        return cache[appId];
    }

    function name(appId) {
        if (own[appId])
            return own[appId].name;
        const e = entry(appId);
        return e?.name || prettify(appId);
    }

    function icon(appId) {
        return iconSources(appId)[0];
    }

    // Generic application icons, tried in order (themes name it differently).
    readonly property var genericIcons: ["application-x-executable", "applications-other", "application-default-icon", "exec", "system-run"]
    property var iconCache: ({})
    // Themed name → path, "" for a miss: each name is looked up once.
    // Quickshell.iconPath(name, true) is synchronous (QIcon::fromTheme: a
    // miss walks every theme directory, 20–90 ms with MacTahoe and 12 data
    // dirs on THEBATTLESHIP), so the shell's other theme lookups
    // (notifications, banners, process rows, stacks) go through here too
    // instead of paying it per delegate and refresh (#16).
    property var themedCache: ({})

    function themed(n) {
        let p = themedCache[n];
        if (p === undefined) {
            p = Quickshell.iconPath(n, true) || "";
            themedCache[n] = p;
        }
        return p;
    }

    // Where an app's icon may be, best first — for AppIcon, which steps to
    // the next on a load error and never shows Qt's missing-image pattern
    // (appicons.js sources). "" = draw a glyph.
    function iconSources(appId) {
        const key = appId ?? "";
        const hit = iconCache[key];
        if (hit !== undefined)
            return hit;
        const out = AppIcons.sources(key, own[key] ? null : entry(key), {
            themed: n => root.themed(n),
            ownIcon: own[key]?.icon ?? "",
            pixmapDirs: pixmapDirs,
            genericIcons: genericIcons
        });
        // Like `cache`: filled in place, so lookups don't re-notify bindings.
        iconCache[key] = out;
        return out;
    }

    readonly property var pixmapDirs: {
        const dirs = (Quickshell.env("XDG_DATA_DIRS") || "/usr/local/share:/usr/share").split(":").filter(d => d !== "");
        return dirs.map(d => d + "/pixmaps").concat(["/usr/share/pixmaps"]);
    }

    function launch(appId) {
        const e = entry(appId);
        if (e)
            e.execute();
        else
            Quickshell.execDetached([appId]);
    }

    // "org.gnome.Nautilus" → "Nautilus", "foot" → "Foot"
    function prettify(appId) {
        if (!appId)
            return "";
        const last = appId.split(".").pop();
        return last.charAt(0).toUpperCase() + last.slice(1);
    }
}
