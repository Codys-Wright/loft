pragma Singleton

import QtQuick
import Quickshell

// App identity: maps niri app-ids to desktop entries (name, icon, launch).
Singleton {
    id: root

    // The shell's own windows (Quickshell's app-id) present as studio apps.
    readonly property var own: ({
            "org.quickshell": { name: "Settings", icon: "preferences-system" }
        })

    // niri app_id → DesktopEntry (or null). Cached; lookups are heuristic.
    property var cache: ({})

    // Entries are scanned asynchronously (and rescanned on install): drop
    // misses cached before they were there.
    Connections {
        target: DesktopEntries.applications
        function onValuesChanged() {
            root.cache = {};
        }
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
        if (own[appId])
            return Quickshell.iconPath(own[appId].icon, "application-x-executable");
        const e = entry(appId);
        return Quickshell.iconPath(e?.icon || appId || "", "application-x-executable");
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
