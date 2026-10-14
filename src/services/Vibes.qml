pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "wallsets.js" as WallSets

// The active theme's vibe set and the user's choices from it.
//
// `loft theme vibes --json` lists the theme's own wallpapers and lock
// designs, curated ones from linked packs, then every other installed pack's
// (and the wallpaper folder's images) ranked by palette closeness
// (docs/THEME-FORMAT.md, "Vibes"). Re-read on theme switch and on demand.
//
// Choices are per theme (Settings.perTheme[<theme>]), so switching themes
// brings back that theme's wallpaper / rotation / lock; a key a theme never
// set falls back to the global Settings value.
//
// Wallpaper, per screen and its active workspace (cli/loft/wallsets.py has
// the rules and the CLI): the workspace's choice > the pack's set for it >
// with Auto on, an auto pick related to the display's image (all but the
// display's first workspace) > the display's base: its choice, the theme's
// choice, the pack's set (multi-display, no choices yet) or an auto pick >
// rotation / per-workspace through the theme's collection > the theme's
// default. "Use for all workspaces" (sameAll) skips the per-workspace steps.
// Lock: the chosen design > the theme's default (manifest) > built-in.
Singleton {
    id: root

    property var data: null
    property bool loading: false
    readonly property string theme: Theme.name

    // The last lock design that failed to load, for the Lock Screen page.
    property string lockError: ""
    property string lockErrorDesign: ""

    readonly property var wallpapers: data?.wallpapers ?? []
    readonly property var locks: data?.locks ?? []
    readonly property var themeWallpapers: wallpapers.filter(w => w.origin !== "match")
    readonly property var matchingWallpapers: wallpapers.filter(w => w.origin === "match")
    readonly property var themeLocks: locks.filter(l => l.origin !== "match")
    readonly property var matchingLocks: locks.filter(l => l.origin === "match")
    readonly property string defaultWallpaper: data?.defaults?.wallpaper ?? ""
    readonly property string defaultLock: data?.defaults?.lock ?? ""

    // Stills the image layer can show, for rotation / per-workspace.
    readonly property var collection: themeWallpapers.filter(w => w.kind === "image").map(w => w.path)

    // ── per-theme choices ───────────────────────────────────────────────
    readonly property var choices: Settings.perTheme?.[theme] ?? ({})

    function has(key) {
        return Object.prototype.hasOwnProperty.call(choices, key);
    }

    function setChoice(key, value) {
        const all = Object.assign({}, Settings.perTheme ?? {});
        const mine = Object.assign({}, all[theme] ?? {});
        mine[key] = value;
        all[theme] = mine;
        Settings.perTheme = all;
    }

    // Several keys in one write; a value of undefined removes the key.
    function setChoices(values) {
        const all = Object.assign({}, Settings.perTheme ?? {});
        const mine = Object.assign({}, all[theme] ?? {});
        for (const [k, v] of Object.entries(values)) {
            if (v === undefined)
                delete mine[k];
            else
                mine[k] = v;
        }
        all[theme] = mine;
        Settings.perTheme = all;
    }

    // "" = the theme's own default.
    readonly property string chosenWallpaper: has("wallpaper") ? choices.wallpaper : Settings.wallpaper.path
    readonly property real rotateMinutes: has("rotate") ? choices.rotate : Settings.wallpaper.rotate
    readonly property bool perWorkspace: has("perWorkspace") ? choices.perWorkspace : Settings.wallpaper.perWorkspace
    // A design dir, "builtin", or "" = the theme's default.
    readonly property string chosenLock: has("lockDesign") ? choices.lockDesign : Settings.lock.design

    function chooseWallpaper(path) {
        setChoice("wallpaper", path);
    }

    function chooseLock(path) {
        setChoice("lockDesign", path);
    }

    // ── wallpaper resolution ────────────────────────────────────────────
    property int step: 0
    onThemeChanged: {
        step = 0;
        refresh();
    }

    Timer {
        interval: Math.max(1, root.rotateMinutes) * 60000
        running: root.rotateMinutes > 0 && root.chosenWallpaper === "" && root.collection.length > 1
        repeat: true
        onTriggered: root.step++
    }

    // Per-display choices for this theme: { "<niri identity>": path } —
    // identities ("Make Model Serial") survive connector renumbering.
    readonly property var displayChoices: has("displays") ? choices.displays : ({})

    function chooseWallpaperFor(screenName, path) {
        const d = Object.assign({}, displayChoices);
        const key = identityOf(screenName);
        if (path)
            d[key] = path;
        else
            delete d[key];
        setChoice("displays", d);
    }

    // Absolute path (or "") of what a screen should show: its active workspace's.
    function wallpaperFor(screenName) {
        return wallpaperAt(screenName, activeWorkspace(screenName));
    }

    function activeWorkspace(screenName) {
        return layout.workspaces.find(w => w.output === screenName && w.active) ?? null;
    }

    // A display's niri identity (fake displays carry their own, see `layout`).
    function identityOf(screenName) {
        return layout.outputs.find(o => o.name === screenName)?.identity ?? Displays.identity(screenName);
    }

    // What a screen shows on one of its workspaces (null = its base).
    function wallpaperAt(screenName, ws) {
        const id = identityOf(screenName);
        if (ws && sameAllChoices[id] !== true) {
            const key = WallSets.wsKey({ name: ws.name ?? "", idx: ws.idx }, id);
            const w = workspaceChoices[key] || packSet?.workspaces?.[key] || (ws.idx > 1 && autoPlan?.workspaces?.[key]);
            if (w)
                return w;
        }
        const base = baseFor(screenName);
        if (base !== "")
            return base;
        const col = collection;
        if (col.length > 0 && (perWorkspace || rotateMinutes > 0)) {
            let i = step;
            if (perWorkspace)
                i += Math.max(0, ((ws ?? Niri.focusedWorkspace)?.idx ?? 1) - 1);
            return col[i % col.length];
        }
        return Theme.wallpaperImage;
    }

    // A display's own image ("" = none: rotation or the theme default).
    function baseFor(screenName) {
        const id = identityOf(screenName);
        return displayChoices[id] || displayChoices[screenName] || chosenWallpaper || packSet?.displays?.[id] || autoPlan?.displays?.[id] || "";
    }

    // Where a workspace's image comes from, for the pickers:
    // workspace | set | auto | display | theme | packset | default.
    function sourceAt(screenName, ws) {
        const id = identityOf(screenName);
        if (ws && sameAllChoices[id] !== true) {
            const key = WallSets.wsKey({ name: ws.name ?? "", idx: ws.idx }, id);
            if (workspaceChoices[key])
                return "workspace";
            if (packSet?.workspaces?.[key])
                return "packset";
            if (ws.idx > 1 && autoPlan?.workspaces?.[key])
                return "auto";
        }
        if (displayChoices[id] || displayChoices[screenName])
            return "display";
        if (chosenWallpaper)
            return "theme";
        if (packSet?.displays?.[id])
            return "packset";
        if (autoPlan?.displays?.[id])
            return "auto";
        return "default";
    }

    // ── wallpaper sets, per-workspace choices, auto (wallsets.js / .py) ──
    // { "<workspace name>" | "<identity>#<idx>": path }
    readonly property var workspaceChoices: has("workspaces") ? choices.workspaces : ({})
    // { "<identity>": true }: the display's image on every workspace.
    readonly property var sameAllChoices: has("sameAll") ? choices.sameAll : ({})
    readonly property var userSets: (has("sets") ? choices.sets : []).filter(s => s && s.name)
    readonly property string activeSet: has("activeSet") ? choices.activeSet : ""
    readonly property int autoSeed: has("autoSeed") ? choices.autoSeed : 0
    // `loft wallpaper plan --json`: auto picks, the candidate pool, framing, sets.
    property var plan: null
    property bool planning: false
    // Auto: the theme's choice, else on when the theme has enough matching images.
    readonly property bool autoOn: has("auto") ? choices.auto : (plan?.autoDefault ?? false)
    readonly property var autoPlan: autoOn && plan && plan.theme === theme ? plan : null
    readonly property bool explicit: chosenWallpaper !== "" || Object.keys(displayChoices).length > 0 || Object.keys(workspaceChoices).length > 0
    // The pack's own set for this layout, while nothing is chosen.
    readonly property var packSet: !explicit && plan && plan.theme === theme && layout.outputs.length >= 2 ? plan.packSet : null
    // The pack's sets, then saved ones: [{ name, origin: pack|user, displays: {role: path}, workspaces }].
    readonly property var sets: (plan && plan.theme === theme ? plan.sets.filter(s => s.origin === "pack") : []).map(s => s).concat(userSets.map(s => Object.assign({}, s, {
                origin: "user"
            })))
    readonly property var pool: plan && plan.theme === theme ? plan.pool : []
    readonly property string targetTone: plan?.tone ?? ""

    // The live layout, as wallsets.js and the CLI take it (+ `active` per workspace).
    // Tests only: LOFT_FAKE_DISPLAYS = {outputs, main?, workspaces} (the same
    // shape, with `active`) stands in for the screens, so a one-output test
    // session can show the multi-display page and sets; nothing is drawn on them.
    readonly property var fakeLayout: {
        const v = Quickshell.env("LOFT_FAKE_DISPLAYS") ?? "";
        if (v === "")
            return null;
        try {
            return JSON.parse(v);
        } catch (e) {
            console.warn(`Vibes: LOFT_FAKE_DISPLAYS: ${e}`);
            return null;
        }
    }
    readonly property var layout: fakeLayout ? {
        outputs: fakeLayout.outputs,
        main: fakeLayout.main ?? "",
        workspaces: fakeLayout.workspaces ?? []
    } : {
        outputs: Quickshell.screens.map(s => ({
                    name: s.name,
                    identity: Displays.identity(s.name),
                    x: s.x,
                    y: s.y,
                    width: s.width,
                    height: s.height
                })),
        main: Displays.mainScreen?.name ?? "",
        workspaces: Niri.workspaces.filter(w => w.output).map(w => ({
                    output: w.output,
                    idx: w.idx,
                    name: w.name ?? "",
                    active: w.is_active,
                    id: w.id
                }))
    }
    // What the plan depends on (not which workspace is active).
    readonly property var planLayout: ({
            outputs: layout.outputs,
            main: layout.main,
            workspaces: layout.workspaces.map(w => ({
                        output: w.output,
                        idx: w.idx,
                        name: w.name
                    }))
        })
    readonly property var roles: WallSets.roles(layout.outputs, layout.main)

    function workspacesOn(screenName) {
        return layout.workspaces.filter(w => w.output === screenName).sort((a, b) => a.idx - b.idx);
    }

    function workspaceKey(screenName, ws) {
        return WallSets.wsKey({ name: ws.name ?? "", idx: ws.idx }, identityOf(screenName));
    }

    function chooseWallpaperForWorkspace(screenName, ws, path) {
        const d = Object.assign({}, workspaceChoices);
        const key = workspaceKey(screenName, ws);
        if (path)
            d[key] = path;
        else
            delete d[key];
        setChoice("workspaces", d);
    }

    function isSameAll(screenName) {
        return sameAllChoices[identityOf(screenName)] === true;
    }

    function setSameAll(screenName, on) {
        const d = Object.assign({}, sameAllChoices);
        const id = identityOf(screenName);
        if (on)
            d[id] = true;
        else
            delete d[id];
        setChoice("sameAll", d);
    }

    function setAuto(on) {
        setChoice("auto", on);
    }

    // New auto picks for every slot without a choice.
    function shuffle() {
        setChoices({
            autoSeed: autoSeed + 1,
            auto: true
        });
    }

    // Fill every display and workspace that has no image of its own with
    // matching ones: Auto on, per-workspace choices and "same on all
    // workspaces" cleared (the displays' own images stay, as anchors).
    function autoFill() {
        setChoices({
            auto: true,
            workspaces: undefined,
            sameAll: undefined
        });
    }

    function findSet(name) {
        return sets.find(s => s.name === name) ?? null;
    }

    // A set's images by role onto this layout, replacing the display and
    // workspace choices. false when the theme has no such set.
    function applySet(name) {
        const s = findSet(name);
        if (!s)
            return false;
        const r = WallSets.resolveSet(s, layout);
        setChoices({
            displays: r.displays,
            workspaces: r.workspaces,
            activeSet: name
        });
        return true;
    }

    // What is on screen now (each display's image, each workspace's) as a set.
    function captureSet(name) {
        const eff = {
            displays: {},
            workspaces: {}
        };
        for (const o of layout.outputs) {
            eff.displays[o.identity] = baseFor(o.name) || defaultWallpaper;
            for (const w of workspacesOn(o.name))
                eff.workspaces[workspaceKey(o.name, w)] = wallpaperAt(o.name, w);
        }
        return WallSets.capture(name, layout, eff);
    }

    function saveSet(name) {
        if (!name)
            return false;
        const s = captureSet(name);
        if (Object.keys(s.displays).length === 0)
            return false;
        setChoices({
            sets: userSets.filter(x => x.name !== name).concat([s]),
            activeSet: name
        });
        return true;
    }

    function deleteSet(name) {
        if (!userSets.some(s => s.name === name))
            return false;
        setChoices({
            sets: userSets.filter(s => s.name !== name),
            activeSet: activeSet === name ? undefined : activeSet
        });
        return true;
    }

    // Where to center an image's crop (0..1), from its framing; the middle when unknown.
    function focusFor(path) {
        return plan?.framing?.[path]?.focus ?? [0.5, 0.5];
    }

    // The plan follows the theme, the layout and the choices it builds on.
    readonly property string planKey: JSON.stringify([theme, planLayout, displayChoices, workspaceChoices, sameAllChoices, chosenWallpaper, autoSeed, has("auto") ? choices.auto : null, userSets])
    onPlanKeyChanged: planTimer.restart()

    Timer {
        id: planTimer
        interval: 250
        onTriggered: if (root.planKey !== root.lastPlanKey || !root.plan)
            root.refreshPlan()
    }

    property string lastPlanKey: ""
    property bool planPending: false

    function refreshPlan() {
        if (planProc.running) {
            planPending = true;
            return;
        }
        if (!theme)
            return;
        lastPlanKey = planKey;
        planning = true;
        const mine = Object.assign({}, choices);
        mine.wallpaper = chosenWallpaper;
        planProc.command = ["loft", "wallpaper", "plan", "--json", "--theme", theme, "--layout", JSON.stringify(planLayout), "--choices", JSON.stringify(mine)];
        planProc.running = true;
    }

    Process {
        id: planProc
        stdout: StdioCollector {
            onStreamFinished: {
                if (text.trim() === "")
                    return;
                try {
                    root.plan = JSON.parse(text);
                } catch (e) {
                    console.warn(`Vibes: bad output from loft wallpaper plan: ${e}`);
                }
            }
        }
        stderr: StdioCollector {
            onStreamFinished: if (text.trim() !== "")
                console.warn(`Vibes (plan): ${text.trim()}`)
        }
        onExited: {
            root.planning = false;
            if (root.planPending || root.lastPlanKey !== root.planKey) {
                root.planPending = false;
                root.refreshPlan();
            }
        }
    }

    function url(path) {
        if (!path)
            return "";
        const abs = path.startsWith("~/") ? Quickshell.env("HOME") + path.slice(1) : path;
        return abs.startsWith("/") ? "file://" + abs : abs;
    }

    // Whether this wallpaper is what the user sees now (for pickers).
    function isCurrentWallpaper(path) {
        if (chosenWallpaper !== "")
            return chosenWallpaper === path;
        return path === defaultWallpaper && !(perWorkspace || rotateMinutes > 0);
    }

    // ── lock resolution ─────────────────────────────────────────────────
    // { builtin: true } | { path, main, format, name } | null (= the theme's default)
    readonly property var lockChoice: {
        if (chosenLock === "builtin")
            return { builtin: true };
        if (chosenLock === "")
            return null;
        return locks.find(l => l.path === chosenLock) ?? { path: chosenLock, main: chosenLock + "/Main.qml", format: "", name: chosenLock.split("/").pop() };
    }

    function isCurrentLock(path) {
        if (chosenLock === "")
            return path === (defaultLock || "builtin");
        return chosenLock === path;
    }

    // Lock now with the current choice (Lock.qml listens).
    signal lockRequested

    function previewLock() {
        lockRequested();
    }

    // ── data ────────────────────────────────────────────────────────────
    readonly property string folder: {
        const d = Settings.wallpaper.directory;
        return d.startsWith("~/") ? Quickshell.env("HOME") + d.slice(1) : d;
    }
    onFolderChanged: refresh()

    function refresh() {
        if (proc.running) {
            pending = true;
            return;
        }
        loading = true;
        proc.command = ["loft", "theme", "vibes", "--json", "--dir", folder];
        proc.running = true;
    }
    property bool pending: false

    Component.onCompleted: refresh()

    Process {
        id: proc
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.data = JSON.parse(text);
                } catch (e) {
                    console.warn(`Vibes: bad output from loft theme vibes: ${e}`);
                }
            }
        }
        stderr: StdioCollector {
            onStreamFinished: if (text.trim() !== "")
                console.warn(`Vibes: ${text.trim()}`)
        }
        onExited: {
            root.loading = false;
            if (root.pending) {
                root.pending = false;
                root.refresh();
            }
        }
    }

    IpcHandler {
        target: "vibes"

        function refresh(): void {
            root.refresh();
        }

        // Next / previous wallpaper of the theme's collection (as a choice).
        function next(): void {
            root.cycle(1);
        }

        function prev(): void {
            root.cycle(-1);
        }

        function current(): string {
            return root.wallpaperFor(Niri.focusedWorkspace?.output ?? "");
        }

        function lockDesign(): string {
            return root.chosenLock || "(theme default) " + root.defaultLock;
        }

        // Lock now with this theme's chosen design (Settings → Lock Screen → Preview).
        function previewLock(): void {
            root.previewLock();
        }
    }

    IpcHandler {
        target: "wallpaper"

        // The picker carousel.
        function toggle(): void {
            Panels.wallpaperPickerOpen = !Panels.wallpaperPickerOpen;
        }

        function next(): void {
            root.cycle(1);
        }

        function prev(): void {
            root.cycle(-1);
        }

        // Wallpaper sets of the active theme (the pack's, then saved ones).
        function sets(): string {
            return JSON.stringify(root.sets.map(s => ({
                        name: s.name,
                        origin: s.origin,
                        displays: s.displays,
                        workspaces: s.workspaces ?? {}
                    })));
        }

        function applySet(name: string): string {
            return root.applySet(name) ? "applied " + name : "no set " + name;
        }

        function saveSet(name: string): string {
            return root.saveSet(name) ? "saved " + name : "nothing saved";
        }

        function deleteSet(name: string): string {
            return root.deleteSet(name) ? "deleted " + name : "no saved set " + name;
        }

        function shuffle(): void {
            root.shuffle();
        }

        function autoFill(): void {
            root.autoFill();
        }

        function setAuto(on: bool): void {
            root.setAuto(on);
        }

        // Per display: its roles, base image and where each workspace's comes from.
        function status(): string {
            const out = {
                theme: root.theme,
                auto: root.autoOn,
                seed: root.autoSeed,
                activeSet: root.activeSet,
                packSet: root.packSet?.name ?? null,
                displays: {}
            };
            for (const o of root.layout.outputs) {
                out.displays[o.name] = {
                    identity: o.identity,
                    roles: root.roles[o.name] ?? [],
                    sameAll: root.isSameAll(o.name),
                    base: root.baseFor(o.name),
                    now: root.wallpaperFor(o.name),
                    workspaces: root.workspacesOn(o.name).map(w => ({
                                idx: w.idx,
                                name: w.name,
                                active: !!w.active,
                                source: root.sourceAt(o.name, w),
                                path: root.wallpaperAt(o.name, w)
                            }))
                };
            }
            return JSON.stringify(out);
        }

        function refreshPlan(): void {
            root.refreshPlan();
        }
    }

    function cycle(dir) {
        const col = collection;
        if (col.length === 0)
            return;
        // The theme default shows the rendered bundle's copy: find it by its pack path.
        let cur = col.indexOf(wallpaperFor(Niri.focusedWorkspace?.output ?? ""));
        if (cur < 0)
            cur = col.indexOf(defaultWallpaper);
        chooseWallpaper(col[((cur < 0 ? 0 : cur + dir) % col.length + col.length) % col.length]);
    }
}
