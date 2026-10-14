import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.services

// One workspace's wallpaper surface, bound to that workspace by niri's
// `place-within-workspace` layer rule (niri/workspace-wallpapers.kdl): niri
// draws it behind its workspace only, so it slides with the workspace during
// a switch and shows behind it in the overview. WorkspaceWallpapers decides
// which exist (the ones that can be on screen) and at what decode size;
// `modelData` is its key, "<screen>|<ref>".
PanelWindow {
    id: root

    required property string modelData
    readonly property string screenName: modelData.slice(0, modelData.indexOf("|"))
    readonly property string ref: modelData.slice(modelData.indexOf("|") + 1)
    readonly property var entry: WorkspaceWallpapers.entry(modelData)
    // The workspace now (by name, or index on the output), for its image.
    readonly property var ws: WorkspaceWallpapers.workspaceFor(screenName, ref)

    screen: Quickshell.screens.find(s => s.name === screenName) ?? null

    WlrLayershell.layer: WlrLayer.Background
    WlrLayershell.namespace: "loft:wallpaper@" + ref
    exclusionMode: ExclusionMode.Ignore
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    color: Theme.bg

    WallpaperView {
        id: view
        anchors.fill: parent
        // A workspace that is gone (kept for the grace period) keeps its image.
        readonly property string wanted: root.ws ? Vibes.wallpaperAt(root.screenName, root.ws) : ""
        onWantedChanged: if (root.ws)
            path = wanted
        Component.onCompleted: path = wanted
        decodeScale: root.entry?.scale ?? 1
        onReadyChanged: WorkspaceWallpapers.setReady(root.modelData, ready)
        onDecodedBytesChanged: WorkspaceWallpapers.report(root.modelData, decodedBytes)
    }
    Component.onCompleted: if (view.ready)
        WorkspaceWallpapers.setReady(modelData, true)
    Component.onDestruction: {
        WorkspaceWallpapers.setReady(modelData, false);
        WorkspaceWallpapers.report(modelData, null);
    }

    DesktopMouse {
        anchors.fill: parent
        screenName: root.screenName
    }
}
