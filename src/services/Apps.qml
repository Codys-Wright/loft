pragma Singleton

import QtQuick
import Quickshell

// App identity: maps niri app-ids to desktop entries (name, icon, launch).
Singleton {
    id: root

    // niri app_id → DesktopEntry (or null). Cached; lookups are heuristic.
    property var cache: ({})

    function entry(appId) {
        if (!appId)
            return null;
        if (cache[appId] === undefined)
            cache[appId] = DesktopEntries.byId(appId) ?? DesktopEntries.heuristicLookup(appId) ?? null;
        return cache[appId];
    }

    function name(appId) {
        const e = entry(appId);
        return e?.name || prettify(appId);
    }

    function icon(appId) {
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
