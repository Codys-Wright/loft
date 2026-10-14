pragma Singleton

import QtQuick
import Quickshell

// App identity: maps niri app-ids to desktop entries (name, icon, launch).
Singleton {
    id: root

    // The shell's own windows (Quickshell's app-id) present as Loft apps.
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
            root.iconCache = {};
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
        return iconSources(appId)[0];
    }

    // Generic application icons, tried in order (themes name it differently).
    readonly property var genericIcons: ["application-x-executable", "applications-other", "application-default-icon", "exec", "system-run"]
    property var iconCache: ({})

    // Where an app's icon may be, best first — for AppIcon, which steps to
    // the next on a load error and never shows Qt's missing-image pattern.
    // Themed names are checked (iconPath(…, true)); files can't be, so they
    // come as candidates: an absolute Icon=, then pixmaps dirs.
    // Order: desktop Icon= → app_id → lowercase / reverse-DNS variants →
    // StartupWMClass → desktop id → a generic app icon. "" = draw a glyph.
    function iconSources(appId) {
        const key = appId ?? "";
        if (iconCache[key] !== undefined)
            return iconCache[key];
        const out = [];
        const themed = n => {
            if (!n)
                return;
            const p = Quickshell.iconPath(n, true);
            if (p && !out.includes(p))
                out.push(p);
        };
        if (own[key]) {
            themed(own[key].icon);
        } else {
            const e = entry(key);
            const declared = e?.icon ?? "";
            const names = [];
            if (declared.startsWith("/"))
                out.push("file://" + declared);
            else if (declared)
                names.push(declared, declared.replace(/\.(png|svg|xpm)$/, ""));
            if (key) {
                const last = key.split(".").pop();
                names.push(key, key.toLowerCase(), last, last.toLowerCase(), key.replace(/\./g, "-").toLowerCase(), key.split(".").reverse().join(".").toLowerCase());
            }
            if (e?.startupClass)
                names.push(e.startupClass, e.startupClass.toLowerCase());
            if (e?.id)
                names.push(e.id, e.id.toLowerCase());
            for (const n of names)
                themed(n);
            // Unthemed icons in pixmaps dirs (not checkable from QML).
            if (declared && !declared.startsWith("/")) {
                const base = declared.replace(/\.(png|svg|xpm)$/, "");
                for (const d of pixmapDirs)
                    for (const ext of [".png", ".svg"])
                        out.push(`file://${d}/${base}${ext}`);
            }
        }
        for (const g of genericIcons)
            themed(g);
        out.push("");
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
