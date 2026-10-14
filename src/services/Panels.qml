pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Which popup panels are open, and on which screen. Bar buttons and IPC
// (`qs ipc call controlcenter toggle`, bindable from niri) drive it.
// Kept across hot reloads (PersistentProperties), so editing a panel's QML
// doesn't close it or lose the Settings page you're designing.
Singleton {
    id: root

    property alias controlCenterOpen: persist.controlCenterOpen
    property alias wallpaperPickerOpen: persist.wallpaperPickerOpen
    property alias settingsOpen: persist.settingsOpen
    property alias settingsSection: persist.settingsSection
    property alias doNotDisturb: persist.doNotDisturb
    // Inhibit idle (screen blank / lock) — applied by the bar's IdleInhibitor.
    property alias caffeine: persist.caffeine
    // Output name the panel opens on; empty = the focused one.
    property alias controlCenterScreen: persist.controlCenterScreen
    // The Control Center's expanded module ("" = the grid) and Edit mode.
    property alias ccExpanded: persist.ccExpanded
    property alias ccEditing: persist.ccEditing

    PersistentProperties {
        id: persist
        reloadableId: "panels"

        property bool controlCenterOpen: false
        property bool wallpaperPickerOpen: false
        property bool settingsOpen: false
        property string settingsSection: "appearance"
        property bool doNotDisturb: false
        property bool caffeine: false
        property string controlCenterScreen: ""
        property string ccExpanded: ""
        property bool ccEditing: false
    }

    function toggleControlCenter(screenName) {
        if (controlCenterOpen && (screenName ?? "") === controlCenterScreen) {
            controlCenterOpen = false;
            return;
        }
        controlCenterScreen = screenName ?? (Niri.focusedWorkspace?.output ?? "");
        controlCenterOpen = true;
    }

    IpcHandler {
        target: "controlcenter"

        function toggle(): void {
            root.toggleControlCenter(Niri.focusedWorkspace?.output ?? "");
        }

        function close(): void {
            root.controlCenterOpen = false;
        }

        // Open with a module expanded (or in Edit mode) — keyboard
        // shortcuts and screenshots.
        function expand(panel: string): void {
            if (!root.controlCenterOpen)
                root.toggleControlCenter(Niri.focusedWorkspace?.output ?? "");
            root.ccEditing = false;
            root.ccExpanded = panel;
        }
        function wifi(): void {
            expand("wifi");
        }
        function bluetooth(): void {
            expand("bluetooth");
        }
        function sound(): void {
            expand("sound");
        }
        function display(): void {
            expand("display");
        }
        function focus(): void {
            expand("focus");
        }
        function nowPlaying(): void {
            expand("nowPlaying");
        }
        function back(): void {
            root.ccExpanded = "";
        }
        function edit(): void {
            if (!root.controlCenterOpen)
                root.toggleControlCenter(Niri.focusedWorkspace?.output ?? "");
            root.ccExpanded = "";
            root.ccEditing = !root.ccEditing;
        }
    }
}
