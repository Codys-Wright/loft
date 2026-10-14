import QtQuick
import Quickshell
import Quickshell.Io
import qs.menubar
import qs.palette
import qs.services

// The everyday window and power modules in one place for shell.qml:
// Cleaning Mode, Keep Awake rules, Quit on close, Quit protection (hold
// ⌘Q) and the Arrange palette. Each is gated by its feature (Features.qml).
Scope {
    id: root

    // Lazy singletons that must run from startup (they watch niri / power).
    readonly property var services: [KeepAwake, QuitOnClose, Cleaning]

    LazyLoader {
        // Kept while active so switching the feature off mid-clean can't
        // strand a lock.
        active: Features.on("cleaningMode") || Cleaning.active
        CleaningMode {}
    }

    Variants {
        model: Features.on("quitProtection") ? Quickshell.screens : []
        QuitPill {}
    }

    // ── Spotlight: "Cleaning Mode" as an app ─────────────────────────────
    // A desktop entry Spotlight's app search finds, calling this shell's IPC
    // (its path changes with every package build, so it's rewritten at
    // startup and removed when the feature is off). Not in dev sessions:
    // they share $HOME with the real desktop.
    readonly property string appsDir: `${Quickshell.env("XDG_DATA_HOME") || Quickshell.env("HOME") + "/.local/share"}/applications`
    readonly property string cleaningEntry: `${appsDir}/loft-cleaning-mode.desktop`
    readonly property bool writeEntries: Quickshell.env("LOFT_DEV") !== "1"

    function syncEntries() {
        if (!writeEntries)
            return;
        if (Features.on("cleaningMode")) {
            const exec = `quickshell ipc --any-display --path ${Quickshell.shellDir} call cleaning start`;
            mkApps.text = ["[Desktop Entry]", "Type=Application", "Name=Cleaning Mode", "Comment=Lock the keyboard and mouse while you clean them", "Keywords=clean;wipe;keyboard;screen;lock;", "Icon=edit-clear-all", `Exec=${exec}`, "Categories=Utility;", "X-Loft-Generated=true", ""].join("\n");
            mkApps.running = true;
        } else
            Quickshell.execDetached(["rm", "-f", cleaningEntry]);
    }

    Component.onCompleted: syncEntries()
    Connections {
        target: Settings
        function onFeaturesChanged() {
            root.syncEntries();
        }
    }

    Process {
        id: mkApps
        property string text: ""
        command: ["mkdir", "-p", root.appsDir]
        onExited: entryFile.setText(text)
    }
    FileView {
        id: entryFile
        path: root.writeEntries ? root.cleaningEntry : ""
        printErrors: false
        blockLoading: false
    }

    // ── IPC ──────────────────────────────────────────────────────────────
    // The ⌘Q bind (niri/shell-binds.kdl.in). Always answers, so the bind's
    // `|| niri msg action close-window` fallback only runs without a shell.
    IpcHandler {
        target: "quit"

        function key(): void {
            // An app left alone (Settings → Keyboard Shortcuts): ⌘Q does
            // nothing rather than closing the game / VM / remote desktop.
            if (!Shortcuts.skip("⌘Q"))
                QuitGuard.key();
        }
        function status(): string {
            return QuitGuard.phase || "idle";
        }
    }

    // Custom shortcuts (Settings → Keyboard Shortcuts) that run a Quick
    // Panel action: `action run <id>` (palette/Actions.qml ids). Window and
    // text actions skip apps left alone.
    IpcHandler {
        target: "action"

        function run(id: string): void {
            const e = Actions.entry(id);
            if (!e)
                return;
            if (["Windows", "Clipboard & text", "Snippets"].includes(e.group) && Shortcuts.skip(e.label))
                return;
            Actions.run(id, {});
        }
        function list(): string {
            return Actions.all().map(e => `${e.id}\t${e.label}`).join("\n");
        }
    }

    IpcHandler {
        target: "arrange"

        // The palette: the Arrange menu at the focused window (floating:
        // its centre; tiled: niri reports no position → the display's centre).
        function open(): void {
            if (!Shortcuts.skip("Arrange"))
                root.openPalette();
        }
        // A preset by name on the focused window (Arrange.floatPresets,
        // columnPresets, or center, fullscreen, maximizeColumn, …).
        function apply(name: string): bool {
            return Arrange.apply(name, null);
        }
    }

    function openPalette() {
        if (!Features.on("arrange"))
            return;
        const w = AppMenu.activeWindow;
        if (!w)
            return;
        const out = Niri.workspaceMap[w.workspace_id]?.output ?? Niri.focusedWorkspace?.output ?? "";
        const screen = Quickshell.screens.find(s => s.name === out);
        if (!screen)
            return;
        let x = screen.width / 2;
        let y = screen.height / 2;
        const pos = w.layout?.tile_pos_in_workspace_view;
        const size = w.layout?.tile_size;
        if (w.is_floating && pos && size) {
            x = pos[0] + size[0] / 2;
            y = pos[1] + size[1] / 2;
        }
        MenuState.openContext(out, x, y, "center", () => Arrange.items(w));
        MenuState.target = w;
        const items = MenuState.itemsAt(0);
        const f = MenuState.nextSelectable(items, -1, 1);
        if (f >= 0)
            MenuState.path = [MenuState.keyOf(items[f])];
    }
}
