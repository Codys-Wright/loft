//@ pragma UseQApplication
import QtQuick
import Quickshell
import qs.services
import qs.background
import qs.capture
import qs.bar
import qs.dock
import qs.controlcenter
import qs.island
import qs.lock
import qs.osd
import qs.switcher
import qs.wallpaper
import qs.audio
import qs.settings
import qs.devtools
import qs.monitor
import qs.clipboard
import qs.desktopmenu

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

    // The desktop's right-click menu (opened from the wallpaper layer).
    Variants {
        model: Features.on("desktopMenu") ? Quickshell.screens : []
        DesktopMenuOverlay {}
    }

    Variants {
        // One dock: on the main display, or the fallback while the main one
        // shows something fullscreen (Displays.qml).
        model: Features.on("dock") ? Quickshell.screens.filter(s => s.name === Displays.activeName) : []
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

    // Capture (screenshots, recording, OCR, color picker, camera).
    Variants {
        model: Features.on("capture") || Features.on("ocr") || Features.on("colorPicker") ? Quickshell.screens : []
        RegionOverlay {}
    }

    Variants {
        model: Features.on("capture") ? Quickshell.screens : []
        CaptureSelector {}
    }

    Variants {
        model: Features.on("capture") ? Quickshell.screens : []
        CaptureCountdown {}
    }

    Variants {
        model: Features.on("capture") ? Quickshell.screens : []
        CaptureThumbnail {}
    }

    Variants {
        model: Features.on("capture") ? Quickshell.screens : []
        CaptureTrim {}
    }

    Variants {
        model: Features.on("capture") ? Capture.pins : []
        PinnedCapture {}
    }

    LazyLoader {
        active: Features.on("camera") && Capture.cameraOn
        CameraMirror {}
    }

    SettingsApp {}

    // Hot-reload feedback: "Reloaded" / the QML error (live design loop).
    ReloadToast {}

    Lock {}

    LazyLoader {
        active: Features.on("systemMonitor")
        SystemMonitor {}
    }

    LazyLoader {
        active: Features.on("alerts")
        SystemAlerts {}
    }

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

    Variants {
        model: Features.on("mixer") ? Quickshell.screens : []
        Mixer {}
    }
}
