import QtQuick
import Quickshell
import qs.services

// One dock icon: magnifies on hover, shows a dot when the app has windows.
// Click focuses the app (cycling its windows) or launches it.
Item {
    id: root

    required property string appId
    property real iconSize: Settings.dock.iconSize
    property real magnification: Settings.dock.magnification

    readonly property var appWindows: Niri.windows.filter(w => w.app_id === appId)
    readonly property bool running: appWindows.length > 0
    readonly property bool hovered: mouse.containsMouse
    readonly property string label: Apps.name(appId)

    signal hoverChanged(bool hovered)

    implicitWidth: iconSize * (hovered ? magnification : 1)
    implicitHeight: iconSize

    Behavior on implicitWidth {
        NumberAnimation {
            duration: 140
            easing.type: Easing.OutCubic
        }
    }

    Image {
        id: icon
        anchors {
            horizontalCenter: parent.horizontalCenter
            bottom: parent.bottom
        }
        width: root.implicitWidth
        height: width
        source: Apps.icon(root.appId)
        sourceSize: Qt.size(128, 128)
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true
    }

    Rectangle {
        visible: root.running
        anchors {
            horizontalCenter: parent.horizontalCenter
            top: parent.bottom
            topMargin: 4
        }
        width: 4
        height: 4
        radius: 2
        color: Theme.text
        opacity: 0.85
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onContainsMouseChanged: root.hoverChanged(containsMouse)
        onClicked: {
            if (!root.running) {
                Apps.launch(root.appId);
                return;
            }
            // Focus the app; if it already has focus, cycle to its next window.
            const ws = root.appWindows;
            const i = ws.findIndex(w => w.is_focused);
            Niri.focusWindow(ws[(i + 1) % ws.length].id);
        }
    }
}
