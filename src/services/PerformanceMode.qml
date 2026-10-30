pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Performance mode: give back the GPU memory the desktop's looks cost.
//
//   "off"          everything as configured
//   "performance"  live wallpapers show their still frame with no video open
//                  (no decoder frame pools: ~0.3–0.5 GB per playing screen),
//                  and one wallpaper surface per screen instead of one per
//                  nearby workspace (WorkspaceWallpapers steps aside; the
//                  wallpaper swaps on switch instead of sliding)
//   "ultra"        no wallpaper images at all: each screen is one flat
//                  surface in the theme's background color, and the shell's
//                  surfaces stop asking niri for blur (blurring a flat color
//                  shows nothing; Theme.blur)
//
// Persists in Settings.performance.mode. Control Center tile `performanceMode`,
// Settings → Wallpaper, `qs ipc call performancemode set ultra`.
Singleton {
    id: root

    readonly property var modes: ["off", "performance", "ultra"]
    readonly property string mode: modes.includes(Settings.performance.mode) ? Settings.performance.mode : "off"
    // Any performance mode: no videos, one surface per screen.
    readonly property bool on: mode !== "off"
    // Flat colors, no blur.
    readonly property bool ultra: mode === "ultra"
    readonly property string label: ultra ? "Ultra Performance" : on ? "Performance" : "Off"

    function set(m) {
        if (modes.includes(m))
            Settings.performance.mode = m;
    }
    // Off → Performance → Ultra → Off.
    function cycle() {
        set(modes[(modes.indexOf(mode) + 1) % modes.length]);
    }

    IpcHandler {
        target: "performancemode"

        function get(): string {
            return root.mode;
        }
        // off | performance | ultra
        function set(mode: string): string {
            if (!root.modes.includes(mode))
                return `unknown mode ${mode} (off, performance, ultra)`;
            root.set(mode);
            return root.mode;
        }
        function cycle(): string {
            root.cycle();
            return root.mode;
        }
    }
}
