import QtQuick
import Quickshell
import qs.components
import qs.services

// An app in the dock: its icon (never a missing-image pattern), a dot while
// it has windows, a bounce while it launches. Click focuses it (again:
// the next of its windows) or launches it; files dropped on it open with it.
DockTile {
    id: root

    required property string appId
    // pinned | running | recent
    property string section: "pinned"
    property bool bounceOnLaunch: true

    readonly property var appWindows: DockData.windowsOf(appId)
    label: Apps.name(appId)
    running: appWindows.length > 0
    lit: drop.containsDrag

    AppIcon {
        anchors.fill: parent
        appId: root.appId
    }

    onClicked: {
        if (!root.running) {
            Apps.launch(root.appId);
            if (root.bounceOnLaunch)
                bounce.start();
            return;
        }
        // A hidden app comes back whole (macOS), focused on its first window.
        if (DockMenu.unhideApp(root.appId)) {
            DockMenu.focus(root.appWindows[0]);
            return;
        }
        // Focus the app; if it already has focus, cycle to its next window.
        const ws = root.appWindows;
        const i = ws.findIndex(w => w.is_focused);
        DockMenu.focus(ws[(i + 1) % ws.length]);
    }

    // Bounce until the first window shows up (or ~6 s).
    onRunningChanged: if (running)
        bounce.stop()
    SequentialAnimation {
        id: bounce
        loops: 6
        alwaysRunToEnd: true
        NumberAnimation {
            target: root
            property: "lift"
            to: root.iconSize * 0.45
            duration: 300
            easing.type: Easing.OutQuad
        }
        NumberAnimation {
            target: root
            property: "lift"
            to: 0
            duration: 300
            easing.type: Easing.InQuad
        }
    }

    // Drop files on the icon: open them with this app.
    DropArea {
        id: drop
        anchors.fill: parent
        onEntered: d => {
            if (!d.hasUrls)
                d.accepted = false;
        }
        onDropped: d => {
            for (const u of d.urls ?? [])
                DockData.openWith(root.appId, decodeURIComponent(String(u).replace(/^file:\/\//, "")));
            d.accept(Qt.CopyAction);
        }
    }
}
