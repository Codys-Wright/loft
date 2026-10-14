pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Spaces (docs/SPACES.md): functional desktops across every display.
//
// The index comes from `loft-niri space list --json` (the library, else the
// built-ins). Activation is loft-niri's (`space focus|next|prev`, also what
// the generated Mod+1…9 binds spawn); the shell never plans it. It derives
// the active space from niri's events instead: the owner of the main
// display's active workspace, else of the focused one, else the last one.
// An activation sends a burst of WorkspaceActivated / WindowFocusChanged
// events (§3.4), so the active space is only re-derived once niri has been
// quiet for a moment, and while the shell itself runs an activation
// (`settling`) not at all.
//
// On a change: `activated(space, previous)` → the island banner, and the
// per-space settings (§5) — dock (DockData.profileFor), menu bar extras
// (Controls.barShown), the bar (Bar.qml), Do Not Disturb (here). Theme per
// space is P5: see applyTheme().
//
// When the outputs change, `space render` (re-resolves roles → spaces.kdl;
// a no-op when nothing moved) and `space ensure <active>` (puts the active
// space's workspaces back on their displays, §3.3). Only once spaces are in
// use, i.e. `overrides/spaces.kdl` exists: until then nothing is rendered
// behind the user's back.
//
// IPC: spaces focus <id|n> | next | prev | list | active | switcher | reload.
Singleton {
    id: root

    readonly property string stateDir: Quickshell.env("LOFT_STATE_DIR") || `${Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state"}/loft`
    readonly property string spacesKdl: `${stateDir}/overrides/spaces.kdl`
    // Where the space JSON lives (loft-niri's library_dir), for display.
    readonly property string libraryDir: Quickshell.env("LOFT_SPACES_DIR") || "~/Documents/Loft/Spaces"

    readonly property bool enabled: Features.on("spaces")

    // Every space, in order: { id, name, icon, order, position (1…9 or
    // null), template, archived, displays: { role: workspace | "keep" },
    // doc } (loft-niri's JSON). `spaces` leaves out the archived ones.
    property var all: []
    readonly property var spaces: all.filter(s => !s.archived)
    property var problems: []
    property bool loaded: false

    // workspace name → space id.
    readonly property var owners: {
        const m = {};
        for (const s of spaces)
            for (const ws of Object.values(s.displays ?? {}))
                if (ws && ws !== "keep" && m[ws] === undefined)
                    m[ws] = s.id;
        return m;
    }

    function find(key) {
        const k = String(key ?? "");
        return spaces.find(s => s.id === k) ?? spaces.find(s => String(s.position) === k) ?? null;
    }

    // A space's badge color (Theme.badgeColor): its own `color`, else one
    // per built-in, else by position.
    function badgeFor(space) {
        if (!space)
            return "gray";
        if (space.doc?.color)
            return space.doc.color;
        const builtin = { main: "blue", music: "pink", video: "orange", comms: "green", gaming: "purple", task: "indigo" }[space.id];
        if (builtin)
            return builtin;
        if (space.template === "project")
            return "teal";
        const cycle = ["cyan", "mint", "yellow", "red", "brown"];
        return cycle[Math.max(0, spaces.indexOf(space)) % cycle.length];
    }

    function ownerOf(workspaceName) {
        return workspaceName ? (owners[workspaceName] ?? "") : "";
    }

    // The space's workspaces that are on `output` right now (usually one;
    // several when a display folded into this one, §3.3).
    function workspacesOf(spaceId, output) {
        return Niri.workspaces.filter(w => w.name && owners[w.name] === spaceId && (output === undefined || w.output === output));
    }

    // Workspaces of `output` that no space owns (`hidden-*` parking excluded).
    function unownedOn(output) {
        return Niri.workspacesOn(output).filter(w => !(w.name && owners[w.name] !== undefined) && !(w.name ?? "").startsWith("hidden-"));
    }

    function windowCount(spaceId) {
        const ids = workspacesOf(spaceId).map(w => w.id);
        return Niri.windows.filter(w => ids.includes(w.workspace_id)).length;
    }

    // ── The active space ────────────────────────────────────────────────
    property alias activeId: persist.activeId
    readonly property var active: find(activeId)
    // The shell is running an activation; focus/workspace events mid-way
    // aren't the user's.
    property bool settling: false

    signal activated(var space, var previous)

    function derive() {
        if (!loaded || settling)
            return;
        const main = Displays.mainScreen?.name ?? "";
        const mainWs = Niri.workspaces.find(w => w.output === main && w.is_active);
        const id = ownerOf(mainWs?.name) || ownerOf(Niri.focusedWorkspace?.name) || activeId;
        if (id === activeId || !find(id))
            return;
        const prev = active;
        activeId = id;
        // The first space found after a (re)start isn't a switch.
        if (persist.announced) {
            activated(active, prev);
            // Without the island, the on-screen pill says it (Osd.qml).
            if (!Features.on("island"))
                Sound.announced(active.icon || "󰕰", active.name);
        }
        persist.announced = true;
        apply();
    }

    Timer {
        id: quiet
        interval: 140
        onTriggered: root.derive()
    }

    Connections {
        target: Niri
        function onWorkspaceMapChanged() {
            quiet.restart();
        }
    }
    onOwnersChanged: quiet.restart()

    // ── Per-space settings (§5) ─────────────────────────────────────────
    // The dock layer DockData.profileFor puts between Settings.dock and a
    // display's own prefs: { pinned, mode, visible } or null.
    readonly property var dock: enabled ? (active?.doc?.dock ?? null) : null
    // Status item ids the menu bar keeps (null = all of them).
    readonly property var menubarExtras: {
        const e = enabled ? active?.doc?.menubar?.extras : null;
        return Array.isArray(e) ? e : null;
    }
    readonly property var focusPolicy: enabled ? (active?.doc?.focus ?? null) : null
    // Apps that break through a space's Do Not Disturb (by app name).
    readonly property var dndAllow: focusPolicy?.dnd ? (focusPolicy.allow ?? []) : []

    // Bar hidden on this output: the active space asks for it (`bar.hidden`)
    // and the output shows one of its workspaces.
    function barHiddenOn(output) {
        if (!enabled || !active?.doc?.bar?.hidden)
            return false;
        const ws = Niri.workspaces.find(w => w.output === output && w.is_active);
        return !!ws && ownerOf(ws.name) === active.id;
    }

    function apply() {
        applyFocus();
        applyTheme();
    }

    // Do Not Disturb: a space with `focus.dnd` turns it on and remembers
    // what it was; leaving it restores that, unless the user changed it in
    // the meantime.
    function applyFocus() {
        const want = !!focusPolicy?.dnd;
        if (want && !persist.dndBySpace) {
            persist.dndBefore = Panels.doNotDisturb;
            persist.dndBySpace = true;
            Panels.doNotDisturb = true;
        } else if (!want && persist.dndBySpace) {
            persist.dndBySpace = false;
            if (Panels.doNotDisturb)
                Panels.doNotDisturb = persist.dndBefore;
        }
    }

    Connections {
        target: Panels
        function onDoNotDisturbChanged() {
            // Turned off by hand while a space had it on: the space lets go.
            if (!Panels.doNotDisturb && persist.dndBySpace)
                persist.dndBySpace = false;
        }
    }

    // P5 (THEME-ARCHITECTURE §3.4): a space's `theme` selects the theme
    // while it is active, applied after the workspaces switched. The hook
    // is here; the resolver's `space` layer isn't wired yet.
    function applyTheme() {
        const t = active?.doc?.theme ?? null;
        if (t)
            console.info(`Spaces: ${active.id} asks for theme ${JSON.stringify(t)} (per-space themes arrive with SPACES P5)`);
    }

    // ── Actions ─────────────────────────────────────────────────────────
    property var queue: []

    function run(args) {
        queue = queue.concat([["loft-niri", "space"].concat(args)]);
        if (!runner.running)
            next();
    }

    function next() {
        if (queue.length === 0)
            return;
        const cmd = queue[0];
        queue = queue.slice(1);
        const activation = ["focus", "next", "prev"].includes(cmd[2]);
        if (activation)
            settling = true;
        runner.activation = activation;
        runner.command = cmd;
        runner.running = true;
    }

    function focus(key) {
        const s = find(key);
        if (s)
            run(["focus", s.id]);
    }

    function step(delta) {
        run([delta > 0 ? "next" : "prev"]);
    }

    // `loft-niri space open` (P3): gather + start the space's apps, activate.
    function open(key) {
        const s = find(key);
        if (s)
            run(["open", s.id]);
    }

    property string lastError: ""

    Process {
        id: runner
        property bool activation: false
        stderr: StdioCollector {
            id: runErr
        }
        onExited: code => {
            root.lastError = code === 0 ? "" : (runErr.text.trim().split("\n").pop() || `loft-niri exited with ${code}`);
            if (code !== 0)
                console.warn(`Spaces: ${runner.command.join(" ")}: ${root.lastError}`);
            if (activation)
                settle.restart();
            root.next();
        }
    }

    // niri applies a pipelined activation within a few ms; let its events
    // land, then derive once.
    Timer {
        id: settle
        interval: 120
        onTriggered: {
            root.settling = false;
            root.derive();
        }
    }

    // ── The index ───────────────────────────────────────────────────────
    function reload() {
        lister.running = true;
    }

    Process {
        id: lister
        command: ["loft-niri", "space", "list", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const v = JSON.parse(text);
                    root.all = v.spaces ?? [];
                    root.problems = v.problems ?? [];
                    root.loaded = true;
                    quiet.restart();
                } catch (e) {
                    console.warn(`Spaces: can't read the space list: ${e}`);
                }
            }
        }
    }

    // Is P3's `space open` there? (Settings → Spaces shows Open only then.)
    property bool canOpen: false
    Process {
        id: probe
        command: ["loft-niri", "space", "open", "--help"]
        onExited: code => root.canOpen = code === 0
    }

    Component.onCompleted: {
        reload();
        probe.running = true;
        rerender.restart();
    }

    // ── Outputs changed → render + ensure ──────────────────────────────
    Connections {
        target: Niri
        function onOutputsChanged() {
            rerender.restart();
        }
    }

    Timer {
        id: rerender
        interval: 800
        onTriggered: {
            if (!root.enabled || renderer.running)
                return;
            renderer.command = ["sh", "-c", '[ -f "$1" ] || exit 0; loft-niri space render || exit; [ -n "$2" ] && loft-niri space ensure "$2"; exit 0', "loft-spaces", root.spacesKdl, root.activeId];
            renderer.running = true;
        }
    }

    Process {
        id: renderer
        stderr: StdioCollector {
            onStreamFinished: if (text.trim())
                console.info(`Spaces: render/ensure: ${text.trim()}`)
        }
        onExited: root.reload()
    }

    // ── Space switcher overlay (Mod+Ctrl+S) ────────────────────────────
    // The output it opens on ("" = closed); SpaceSwitcher.qml per screen.
    property string switcherOutput: ""

    function toggleSwitcher(output) {
        if (switcherOutput !== "") {
            switcherOutput = "";
            return;
        }
        reload();
        switcherOutput = output || Niri.focusedWorkspace?.output || Displays.activeName;
    }

    PersistentProperties {
        id: persist
        reloadableId: "spaces"

        property string activeId: ""
        property bool announced: false
        property bool dndBySpace: false
        property bool dndBefore: false
    }

    IpcHandler {
        target: "spaces"

        function focus(space: string): void {
            root.focus(space);
        }
        function next(): void {
            root.step(1);
        }
        function prev(): void {
            root.step(-1);
        }
        function list(): string {
            return JSON.stringify(root.spaces.map(s => ({
                        id: s.id,
                        name: s.name,
                        icon: s.icon,
                        position: s.position,
                        active: s.id === root.activeId,
                        displays: s.displays
                    })));
        }
        function active(): string {
            return root.activeId;
        }
        function switcher(): void {
            root.toggleSwitcher("");
        }
        function reload(): void {
            root.reload();
        }
    }
}
