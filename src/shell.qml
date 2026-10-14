//@ pragma UseQApplication
import QtQuick
import Quickshell
import qs.background
import qs.bar
import qs.dock

// Entry point: instantiate per-screen surfaces only. Logic lives in services/.
ShellRoot {
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
}
