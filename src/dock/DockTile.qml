import QtQuick
import qs.services

// One slot of the dock (an app, a folder stack, the Trash): sized by the
// dock's fisheye (`magnify`, 1 = resting), its face pinned to the screen
// edge and growing away from it. Left click → clicked(); right click,
// Ctrl+click or a long press → menuRequested(alt) — like macOS.
Item {
    id: root

    property string edge: "bottom"
    property real iconSize: 48
    property real magnify: 1
    property string label: ""
    property bool running: false
    property bool showIndicator: true
    // Pixels the face is lifted away from the edge (launch bounce).
    property real lift: 0
    // Highlight (a file dragged over it).
    property bool lit: false

    readonly property bool vertical: edge !== "bottom"
    readonly property real size: iconSize * magnify
    readonly property bool hovered: mouse.containsMouse
    readonly property alias face: face
    default property alias content: face.data

    signal clicked(var mouse)
    signal menuRequested(bool alt)

    implicitWidth: vertical ? iconSize : size
    implicitHeight: vertical ? size : iconSize

    // The icon, square, grown away from the edge.
    Item {
        id: face
        width: root.size
        height: root.size
        x: root.edge === "bottom" ? (root.width - width) / 2 : root.edge === "left" ? root.lift : root.width - width - root.lift
        y: root.edge === "bottom" ? root.height - height - root.lift : (root.height - height) / 2

        Rectangle {
            anchors.fill: parent
            anchors.margins: -3
            visible: root.lit
            radius: width * 0.24
            color: Theme.withAlpha(Theme.accent, 0.25)
            border.width: 2
            border.color: Theme.accent
        }
    }

    // Running indicator, between the icon and the screen edge.
    Rectangle {
        visible: root.running && root.showIndicator
        width: 4
        height: 4
        radius: 2
        color: Theme.text
        opacity: 0.85
        x: root.edge === "bottom" ? (root.width - width) / 2 : root.edge === "left" ? -6 : root.width + 2
        y: root.edge === "bottom" ? root.height + 3 : (root.height - height) / 2
    }

    MouseArea {
        id: mouse
        // The magnified face is the target, not just the resting slot.
        x: Math.min(0, face.x)
        y: Math.min(0, face.y)
        width: Math.max(root.width, face.x + face.width) - x
        height: Math.max(root.height, face.y + face.height) - y
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        pressAndHoldInterval: 550
        property bool held: false

        onPressed: m => held = false
        onPressAndHold: m => {
            if (m.button !== Qt.LeftButton)
                return;
            held = true;
            root.menuRequested((m.modifiers & Qt.AltModifier) !== 0);
        }
        onClicked: m => {
            if (held)
                return;
            if (m.button === Qt.RightButton || (m.modifiers & Qt.ControlModifier))
                root.menuRequested((m.modifiers & Qt.AltModifier) !== 0);
            else
                root.clicked(m);
        }
    }
}
