import QtQuick
import qs.services

// A glass volume track: drag or scroll. `to` may exceed 1 (boost); the part
// above 100 % is tinted and 100 % is marked. moved(v) fires while dragging.
Item {
    id: root

    property real value: 0
    property real to: 1
    property bool dimmed: false
    readonly property bool dragging: drag.pressed

    signal moved(real value)

    implicitHeight: 22
    implicitWidth: 200

    readonly property real t: Math.max(0, Math.min(1, value / to))
    readonly property real unity: 1 / to

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: Theme.withAlpha(Theme.text, 0.12)
    }

    Rectangle {
        id: fill
        width: Math.max(height, parent.width * root.t)
        height: parent.height
        radius: height / 2
        color: root.dimmed ? Theme.withAlpha(Theme.text, 0.35) : root.value > 1.001 ? Theme.warn : Theme.text

        Behavior on width {
            enabled: !drag.pressed
            NumberAnimation {
                duration: 120
            }
        }
    }

    // 100 % mark when boosting is possible.
    Rectangle {
        visible: root.to > 1
        x: parent.width * root.unity - width / 2
        anchors.verticalCenter: parent.verticalCenter
        width: 2
        height: parent.height - 8
        radius: 1
        color: root.value >= 1 ? Theme.withAlpha(Theme.bg, 0.6) : Theme.withAlpha(Theme.text, 0.35)
    }

    MouseArea {
        id: drag
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        function update(x) {
            let v = Math.max(0, Math.min(1, x / width)) * root.to;
            // A little detent at 100 % so boost is deliberate.
            if (root.to > 1 && Math.abs(v - 1) < 0.03)
                v = 1;
            root.moved(v);
        }
        onPressed: mouse => update(mouse.x)
        onPositionChanged: mouse => pressed && update(mouse.x)
        onWheel: wheel => root.moved(Math.max(0, Math.min(root.to, root.value + (wheel.angleDelta.y > 0 ? 0.05 : -0.05))))
    }
}
