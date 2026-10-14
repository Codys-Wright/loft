//@ pragma UseQApplication
import QtQuick
import Quickshell
import qs.services
import qs.background
import qs.bar
import qs.dock
import qs.controlcenter
import qs.island
import qs.lock
import qs.osd
import qs.switcher
import qs.wallpaper
import qs.settings
import qs.clipboard

// Entry point: instantiate per-screen surfaces only. Logic lives in services/.
// Optional modules are gated by the feature registry (services/Features.qml).
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
        model: Features.on("dock") ? Quickshell.screens : []
        Dock {}
    }

    Variants {
        model: Features.on("controlcenter") ? Quickshell.screens : []
        ControlCenter {}
    }

    Variants {
        model: Features.on("island") ? Quickshell.screens : []
        Island {}
    }

    Variants {
        model: Features.on("osd") ? Quickshell.screens : []
        Osd {}
    }

    Variants {
        model: Features.on("switcher") ? Quickshell.screens : []
        Switcher {}
    }

    Variants {
        model: Features.on("wallpaperPicker") ? Quickshell.screens : []
        WallpaperPicker {}
    }

    SettingsApp {}

    Lock {}

    Variants {
        model: Features.on("clipboard") ? Quickshell.screens : []
        ClipboardPanel {}
    }

    Variants {
        model: Features.on("snippets") ? Quickshell.screens : []
        SnippetPicker {}
    }

    Variants {
        model: Features.on("shelf") ? Quickshell.screens : []
        ShelfPanel {}
    }

    LazyLoader {
        active: Features.on("scratchpad")
        ScratchpadWindow {}
    }
}
