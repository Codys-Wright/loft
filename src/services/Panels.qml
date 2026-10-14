pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Which popup panels are open, and on which screen. Bar buttons and IPC
// (`qs ipc call controlcenter toggle`, bindable from niri) drive it.
Singleton {
    id: root

    property bool controlCenterOpen: false
    property bool wallpaperPickerOpen: false
    property bool settingsOpen: false
    property bool doNotDisturb: false
    // Inhibit idle (screen blank / lock) — applied by the bar's IdleInhibitor.
    property bool caffeine: false
    // Output name the panel opens on; empty = the focused one.
    property string controlCenterScreen: ""

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
    }
}
