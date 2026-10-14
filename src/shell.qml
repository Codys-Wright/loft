//@ pragma UseQApplication
import QtQuick
import Quickshell
import qs.services
import qs.background
import qs.bar
import qs.dock
import qs.controlcenter
import qs.island
import qs.osd
import qs.switcher

// Entry point: instantiate per-screen surfaces only. Logic lives in services/.
ShellRoot {
    // Background services are lazy singletons; touch them so they run from
    // startup (screen time, Bluetooth banners).
    readonly property var services: [AppUsage, DeviceEvents]
    Variants {
        model: Quickshell.screens
        Wallpaper {}
    }

    Variants {
        model: Quickshell.screens
        Bar {}
    }

    Variants {
        model: Quickshell.screens
        Dock {}
    }

    Variants {
        model: Quickshell.screens
        ControlCenter {}
    }

    Variants {
        model: Quickshell.screens
        Island {}
    }

    Variants {
        model: Quickshell.screens
        Osd {}
    }

    Variants {
        model: Quickshell.screens
        Switcher {}
    }
}
