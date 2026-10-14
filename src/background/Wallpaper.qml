import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.services

// Background layer. niri's xray blur samples it, so it is what the glass
// surfaces show through. Source: Vibes.wallpaperFor (this screen's active
// workspace's image: per-workspace and per-display choices, wallpaper sets,
// auto picks, rotation, the theme's default), else the theme's gradient.
// Image changes — a new choice, or switching to a workspace with its own
// image — crossfade (WallpaperView). Each image is cropped around its
// interest (Vibes.focusFor, from the plan's framing) rather than its center:
// on the portrait display a landscape image keeps its subject.
//
// The desktop's mouse handling lives in DesktopMouse, shared with the
// per-workspace surfaces (WorkspaceWallpaper.qml).
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    WlrLayershell.layer: WlrLayer.Background
    WlrLayershell.namespace: "loft:wallpaper"
    exclusionMode: ExclusionMode.Ignore
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    color: Theme.bg

    // With per-workspace surfaces (WorkspaceWallpapers: a patched niri
    // slides each workspace's own surface with it), this one steps aside
    // once the screen's active workspace has its surface up, and lets go of
    // its image. Until then, and on a stock niri, it shows the active
    // workspace's image and swaps it on activation.
    readonly property bool stepAside: WorkspaceWallpapers.active && WorkspaceWallpapers.isCovered(modelData.name)
    visible: !stepAside

    WallpaperView {
        anchors.fill: parent
        path: root.stepAside ? "" : Vibes.wallpaperFor(root.modelData.name)
        screenName: root.modelData.name
        playVideo: !root.stepAside
        onDecodedBytesChanged: WorkspaceWallpapers.report("base|" + root.modelData.name, decodedBytes)
    }

    DesktopMouse {
        anchors.fill: parent
        screenName: root.modelData.name
    }
}
