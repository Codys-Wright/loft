.pragma library

// Where an app's icon may be (Apps.qml iconSources); tested by
// tests/appicons.test.js.
//
// Theme lookups (Quickshell.iconPath(name, true) → QIcon::fromTheme) are
// synchronous and a miss walks every directory of every theme in the
// inheritance chain, plus Qt's dash fallbacks (nm-connection-editor →
// nm-connection → nm): thousands of stat()s. So: each name is looked up at
// most once (hits and misses cached by the caller's `themed`), the names are
// deduplicated, the app's names stop at the first hit, and only one generic
// icon is looked up.

// Themed names an app's icon may go by, best first, without repeats:
// desktop Icon= (and without an extension) → app_id → lowercase /
// last-component / dashed / reverse-DNS variants → StartupWMClass → desktop id.
function candidateNames(appId, entry) {
    const out = [];
    const add = n => {
        if (n && !out.includes(n))
            out.push(n);
    };
    const declared = entry?.icon ?? "";
    if (declared && !declared.startsWith("/")) {
        add(declared);
        add(declared.replace(/\.(png|svg|xpm)$/, ""));
    }
    if (appId) {
        const parts = appId.split(".");
        const last = parts.filter(p => p !== "").pop() ?? "";
        add(appId);
        add(appId.toLowerCase());
        add(last);
        add(last.toLowerCase());
        // Dotted ids only (not ".blueman-manager-wrapped", NixOS's wrapper).
        if (parts.length > 1 && parts.every(p => p !== "")) {
            add(appId.replace(/\./g, "-").toLowerCase());
            add(parts.reverse().join(".").toLowerCase());
        }
    }
    if (entry?.startupClass) {
        add(entry.startupClass);
        add(entry.startupClass.toLowerCase());
    }
    if (entry?.id) {
        add(entry.id);
        add(entry.id.toLowerCase());
    }
    return out;
}

// Candidate sources for AppIcon, which steps to the next on a load error and
// ends on "" (a drawn glyph): an absolute Icon=, the first themed name that
// exists, unthemed files in pixmaps dirs (not checkable from QML), the first
// generic app icon that exists, "".
//   opts: { themed: name → path | "" (cached by the caller), ownIcon: a
//           themed name for the shell's own windows, pixmapDirs, genericIcons }
function sources(appId, entry, opts) {
    const out = [];
    const push = p => {
        if (p && !out.includes(p))
            out.push(p);
    };
    const firstThemed = names => {
        for (const n of names) {
            const p = opts.themed(n);
            if (p)
                return p;
        }
        return "";
    };
    if (opts.ownIcon) {
        push(firstThemed([opts.ownIcon]));
    } else {
        const declared = entry?.icon ?? "";
        if (declared.startsWith("/"))
            push("file://" + declared);
        push(firstThemed(candidateNames(appId, entry)));
        if (declared && !declared.startsWith("/")) {
            const base = declared.replace(/\.(png|svg|xpm)$/, "");
            for (const d of opts.pixmapDirs ?? [])
                for (const ext of [".png", ".svg"])
                    push(`file://${d}/${base}${ext}`);
        }
    }
    push(firstThemed(opts.genericIcons ?? []));
    out.push("");
    return out;
}

// What the icon lookups and app lists depend on in the desktop entries,
// independent of their order. Quickshell rescans on any change in (or above) the
// applications dirs — $HOME, /nix/store … — and its model diff can reorder
// rows, emitting valuesChanged once per moved row although nothing changed:
// compare this instead of dropping caches on every signal.
function signature(entries) {
    const rows = [];
    for (const e of entries ?? [])
        rows.push(`${e.id}\u0001${e.name ?? ""}\u0001${e.icon ?? ""}\u0001${e.startupClass ?? ""}`);
    rows.sort();
    return rows.join("\u0002");
}
