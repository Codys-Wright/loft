pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

// Settings → Window Rules: translucent windows ("window glass") and per-app
// niri window rules, through `loft-niri` (crates/loft-niri/src/window_rules.rs).
//
//   glass     { effective, theme, user }: on/off, focused / unfocused
//             opacity, blur. The theme's come from theme.json `windows`
//             (the material facet); the user's override them.
//   defaults  the built-in "keep opaque" list (video, games, REAPER, OBS,
//             Resolve, Blender, GIMP, Krita, image viewers …), each on/off
//   rules     the user's per-app records: { glass: opaque|custom|native,
//             opacity, opacity-unfocused, blur, open-floating, open-maximized,
//             open-fullscreen, default-column-width, square-corners,
//             block-out-from, open-on-workspace, open-on-output,
//             where it opens: open-on-activity, open-on-desktop, open-size,
//             open-position, keep-above, follow, match-title, exclude-title,
//             match-app-id, exclude-app-id (docs/KWIN.md §4.17) }
//   seed      the Nix seed's records (programs.loft.windowRules): { path, rules }
//   roles     connector → display roles (main, right, …) of the live layout
//   config    every window-rule in the niri config tree: { file, line,
//             origin (loft|theme|config), matches, excludes, settings }
//
// Writes go through NiriSettings.apply → `loft-niri apply`: stored in
// overrides/niri.json, rendered into overrides/niri.kdl, checked with
// `niri validate` (rolled back if niri rejects it), niri reloads.
//
// The rules are rendered when the shell starts and whenever the theme's
// `windows` values change (a theme apply), so the fragment always carries
// the global look and the built-in list.
Singleton {
    id: root

    property var data: ({ glass: { effective: {}, theme: {}, user: {} }, defaults: [], rules: {}, config: [] })
    property bool loaded: false
    property string error: ""

    readonly property var glass: data.glass?.effective ?? {}
    readonly property var userGlass: data.glass?.user ?? {}
    readonly property var themeGlass: data.glass?.theme ?? {}
    readonly property bool enabled: glass.enabled === true
    readonly property var rules: data.rules ?? {}
    readonly property var defaults: data.defaults ?? []
    readonly property var configRules: data.config ?? []
    readonly property var seedRules: data.seed?.rules ?? {}
    readonly property bool kwin: Compositor.backend === "kwin"
    // connector → roles, most specific first (loft-niri windows kwin-rules).
    property var roles: ({})

    // Settings → Window Rules opens on this app (the dock's "Window Rules…").
    property string focusApp: ""

    // ── Reading ──────────────────────────────────────────────────────────
    function refresh() {
        listProc.running = true;
        rolesProc.command = ["loft-niri", "--json", "windows", "kwin-rules"].concat(kwin ? ["--displays", JSON.stringify(KWin.displays ?? [])] : []);
        rolesProc.running = true;
    }

    // ── Where it opens: the pickers' choices ─────────────────────────────
    function fromNix(appId) {
        return seedRules[appId] !== undefined;
    }

    // The user's KDE Activities (by name: rules name them, ids differ per
    // machine), in Loft's order (their "Switch to activity" keys).
    function activityOptions() {
        const names = Compositor.activityList.map(a => a.name).filter(n => n);
        return [{ value: "", label: "Wherever it opens" }].concat(names.map(n => ({ value: n, label: n })));
    }

    // KWin: desktops by number (1 = first), with their names; niri: named workspaces.
    function desktopOptions() {
        const out = [{ value: "", label: "Wherever it opens" }];
        const seen = new Set();
        if (kwin) {
            const ws = Compositor.workspaces.slice().sort((a, b) => a.idx - b.idx);
            for (const w of ws) {
                if (seen.has(w.kwin_desktop))
                    continue;
                seen.add(w.kwin_desktop);
                out.push({ value: w.idx, label: w.name ? `${w.idx} · ${w.name}` : `Desktop ${w.idx}` });
            }
        } else {
            for (const w of Compositor.workspaces)
                if (w.name && !seen.has(w.name) && !w.name.startsWith("hidden-")) {
                    seen.add(w.name);
                    out.push({ value: w.name, label: w.name });
                }
        }
        return out;
    }

    // Display roles of the live layout (a rule naming a role follows the
    // display when connectors change), then the connectors themselves.
    function monitorOptions(current) {
        const out = [{ value: "", label: "Wherever it opens" }];
        const label = r => r.replace(/^./, c => c.toUpperCase()).replace(/-(\d+)$/, " $1");
        const entries = Object.entries(roles);
        for (const [conn, rs] of entries) {
            const r = rs[0];
            if (r && r !== "*" && !/^display-|^(portrait|landscape|ultrawide)$/.test(r))
                out.push({ value: r, label: `${label(r)} (${conn})` });
        }
        for (const [conn] of entries)
            out.push({ value: conn, label: conn });
        if (current && !out.some(o => o.value === current))
            out.push({ value: current, label: `${current} (not connected)` });
        return out;
    }

    // The niri app id behind a dock / launcher id: a window's, else the id.
    function niriId(appId) {
        const w = DockData.windowsOf(appId)[0];
        return w?.app_id || appId;
    }

    function matches(regex, s) {
        try {
            return new RegExp(regex).test(s);
        } catch (e) {
            return false;
        }
    }

    // The built-in entry for an app id, or null.
    function builtinFor(appId) {
        return defaults.find(d => (d.app_ids ?? []).some(r => matches(r, appId))) ?? null;
    }

    function rule(appId) {
        return rules[appId] ?? {};
    }

    // "opaque" | "custom" | "native" | "" (the global look), with the
    // built-in list applied.
    function glassMode(appId) {
        const g = rule(appId).glass;
        if (g)
            return g;
        const d = builtinFor(appId);
        return d && d.on ? "opaque" : "";
    }

    function isOpaque(appId) {
        return glassMode(appId) === "opaque";
    }

    // Blur behind the app's window: an explicit per-app choice, else off on
    // the built-in list, else the global value.
    function blurOn(appId) {
        const r = rule(appId);
        return r.blur !== undefined ? r.blur === true : blurDefault(appId);
    }

    // …without the app's own blur choice.
    function blurDefault(appId) {
        const m = glassMode(appId);
        if (m === "native" || m === "custom")
            return true;
        if (m === "opaque")
            return !(builtinFor(appId)?.on);
        return enabled && glass.blur === true;
    }

    // Config rules (any origin) whose matches name this app.
    function configRulesFor(appId) {
        return configRules.filter(r => (r.app_ids ?? []).some(x => matches(x, appId)));
    }

    // Apps that have something: a rule of yours, a running window, a config rule.
    function knownApps() {
        const ids = new Set(Object.keys(rules));
        for (const w of Compositor.windows)
            if (w.app_id && Apps.own[w.app_id] === undefined)
                ids.add(w.app_id);
        for (const r of configRules)
            for (const a of r.app_ids ?? []) {
                const lit = literal(a);
                if (lit)
                    ids.add(lit);
            }
        return [...ids];
    }

    // `^org\.gnome\.Nautilus$` → org.gnome.Nautilus; null for a real regex.
    function literal(regex) {
        const m = /^\^((?:\\.|[^\\.+*?()|\[\]{}^$])+)\$$/.exec(regex);
        return m ? m[1].replace(/\\(.)/g, "$1") : null;
    }

    // Short words for a rule (the list's badges).
    function summary(appId) {
        const r = rule(appId);
        const out = [];
        const m = glassMode(appId);
        if (m === "opaque")
            out.push(r.glass ? "Opaque" : "Opaque (built-in)");
        else if (m === "custom")
            out.push(`${Math.round((r.opacity ?? glass.focused) * 100)}%`);
        else if (m === "native")
            out.push("App's own transparency");
        if (r.blur === false)
            out.push("No blur");
        else if (r.blur === true)
            out.push("Blur");
        if (r["open-floating"] === true)
            out.push("Floating");
        if (r["open-maximized"] === true)
            out.push("Maximized");
        if (r["open-fullscreen"] === true)
            out.push("Full screen");
        if (r["default-column-width"])
            out.push(`${Math.round(r["default-column-width"] * 100)}% wide`);
        if (r["square-corners"])
            out.push("Square corners");
        if (r["block-out-from"])
            out.push("Hidden from capture");
        if (r["open-on-workspace"])
            out.push(`On “${r["open-on-workspace"]}”`);
        if (r["open-on-activity"])
            out.push(r["open-on-activity"]);
        if (r["open-on-desktop"])
            out.push(typeof r["open-on-desktop"] === "number" ? `Desktop ${r["open-on-desktop"]}` : `On “${r["open-on-desktop"]}”`);
        if (r["open-on-output"])
            out.push(`${r["open-on-output"]} display`);
        if (r["open-size"])
            out.push(r["open-size"]);
        if (r["keep-above"])
            out.push("Keep above");
        if (r["follow"] === true)
            out.push("Follows");
        if (fromNix(appId))
            out.push("Nix");
        return out;
    }

    // ── Writing ──────────────────────────────────────────────────────────
    function apply(batch, done) {
        error = "";
        NiriSettings.apply(batch, r => {
            if (!r.ok)
                root.error = r.error ?? "loft-niri failed";
            root.refresh();
            if (done)
                done(r);
        });
    }

    // fields: { field: value | null }.
    function setRule(appId, fields, done) {
        const b = { window_rules: {} };
        b.window_rules[appId] = fields;
        apply(b, done);
    }

    function setField(appId, field, value) {
        const f = {};
        f[field] = value;
        setRule(appId, f);
    }

    function removeRule(appId) {
        const b = { window_rules: {} };
        b.window_rules[appId] = null;
        apply(b);
    }

    // { enabled, focused, unfocused, blur } — null = the theme's.
    function setGlass(fields) {
        apply({ window_glass: fields });
    }

    function setDefaultOn(id, on) {
        const off = defaults.filter(d => !d.on && d.id !== id).map(d => d.id);
        if (!on)
            off.push(id);
        apply({ window_glass: { "defaults-off": off } });
    }

    // Keep an app opaque (or not): through its built-in entry when it has
    // one (and no per-app glass choice), else its own record (loft-niri's
    // opaque_batch, mirrored).
    function setOpaque(appId, on) {
        const g = rule(appId).glass;
        const d = builtinFor(appId);
        if (d && (!g || g === "opaque")) {
            const off = defaults.filter(x => !x.on && x.id !== d.id).map(x => x.id);
            if (!on)
                off.push(d.id);
            const b = { window_glass: { "defaults-off": off } };
            if (g) {
                b.window_rules = {};
                b.window_rules[appId] = { glass: null };
            }
            apply(b);
        } else if (on || g === "opaque") {
            setField(appId, "glass", on ? "opaque" : null);
        }
    }

    // Back to "no choice" when the default already gives this answer.
    function setBlur(appId, on) {
        setField(appId, "blur", blurDefault(appId) === on ? null : on);
    }

    function reset() {
        apply({ reset_window_rules: true });
    }

    function openSettings(appId) {
        focusApp = "";
        focusApp = appId ?? "";
        Panels.settingsSection = "windowrules";
        Panels.settingsOpen = true;
    }

    // ── Menus (the dock's Window Rules ▸, the app menu) ──────────────────
    function menuItems(appId) {
        const id = niriId(appId);
        const opaque = isOpaque(id);
        const blur = blurOn(id);
        const floating = rule(id)["open-floating"] === true;
        return [
            { key: "wr-opaque", label: "Keep Opaque", enabled: true, toggle: "check", checked: opaque, run: () => root.setOpaque(id, !opaque) },
            { key: "wr-blur", label: "Blur Behind Window", enabled: true, toggle: "check", checked: blur, run: () => root.setBlur(id, !blur) },
            { key: "wr-float", label: "Always Open Floating", enabled: true, toggle: "check", checked: floating, run: () => root.setField(id, "open-floating", floating ? null : true) },
            { key: "s-wr", separator: true, label: "", enabled: true },
            { key: "wr-glass", label: "Translucent Windows", enabled: true, toggle: "check", checked: root.enabled, run: () => root.setGlass({ enabled: !root.enabled }) },
            { key: "wr-open", label: "Window Rules…", enabled: true, run: () => root.openSettings(id) },
            { key: "wr-keys", label: "Keyboard Remaps…", enabled: true, run: () => KeyRemaps.openSettings(id) }
        ];
    }

    // ── Plumbing ─────────────────────────────────────────────────────────
    Process {
        id: listProc
        command: ["loft-niri", "--json", "windows", "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const r = JSON.parse(text);
                    if (r.ok === false) {
                        root.error = r.error;
                        return;
                    }
                    root.data = r;
                    root.loaded = true;
                } catch (e) {
                    console.warn(`WindowRules: bad list: ${e}`);
                }
            }
        }
    }

    Process {
        id: rolesProc
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const r = JSON.parse(text);
                    if (r.roles)
                        root.roles = r.roles;
                } catch (e) {}
            }
        }
    }

    // Render the fragment (no-op when unchanged): on start and when the
    // theme's `windows` values change.
    readonly property string themeWindows: JSON.stringify(Theme.windows ?? {})
    onThemeWindowsChanged: renderTimer.restart()
    Component.onCompleted: renderTimer.restart()

    Timer {
        id: renderTimer
        interval: 800
        onTriggered: renderProc.running = true
    }

    Process {
        id: renderProc
        command: ["loft-niri", "--json", "render"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const r = JSON.parse(text);
                    if (r.ok === false)
                        console.warn(`WindowRules: render: ${r.error}`);
                } catch (e) {}
            }
        }
        onExited: root.refresh()
    }

    Connections {
        target: Compositor
        function onConfigLoaded() {
            root.refresh();
        }
    }

    // `qs ipc call windowrules …` (also `loft windows …`, which talks to
    // loft-niri directly).
    IpcHandler {
        target: "windowrules"

        function status(): string {
            return JSON.stringify(root.glass);
        }
        function glassOn(): void {
            root.setGlass({ enabled: true });
        }
        function glassOff(): void {
            root.setGlass({ enabled: false });
        }
        function toggleGlass(): void {
            root.setGlass({ enabled: !root.enabled });
        }
        function opaque(appId: string): void {
            root.setOpaque(appId, true);
        }
        function translucent(appId: string): void {
            root.setOpaque(appId, false);
        }
        // The focused window's app: Keep Opaque on/off.
        function toggleOpaqueFocused(): void {
            const w = Compositor.windows.find(x => x.is_focused);
            if (w?.app_id)
                root.setOpaque(w.app_id, !root.isOpaque(w.app_id));
        }
        function open(appId: string): void {
            root.openSettings(appId);
        }
    }
}
