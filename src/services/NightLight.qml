pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Night light: a warm color temperature via gammastep (wlr-gamma-control).
// The temperature holds while the process runs; stopping it restores the
// screen. Needs a compositor with gamma control (not available when niri
// runs nested as a window).
Singleton {
    id: root

    property bool enabled: false
    property int temperature: 4000

    Process {
        running: root.enabled
        command: ["gammastep", "-m", "wayland", "-O", String(root.temperature), "-P"]
    }
}
