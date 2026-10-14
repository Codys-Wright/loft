import QtQuick
import qs.services

// A slider. moved(v) fires while dragging, committed(v) once on release —
// use committed for settings that are expensive to apply (niri config).
// While dragging it shows its own value, so the owner may keep `value`
// bound to the stored setting.
Item {
    id: sl
    property real from: 0
    property real to: 1
    property real value: 0
    property real step: 0
    property string suffix: ""
    property int decimals: 0
    // Optional custom label for a value.
    property var format: null
    signal moved(real v)
    signal committed(real v)
    implicitWidth: 240
    implicitHeight: 26
    opacity: enabled ? 1 : 0.4

    property bool dragging: false
    property real dragValue: 0
    readonly property real shown: dragging ? dragValue : value
    readonly property real t: (shown - from) / (to - from)

    Rectangle {
        id: track
        anchors.verticalCenter: parent.verticalCenter
        // Room for the value; a long one ("750 items") takes more.
        width: parent.width - Math.max(56, valueLabel.implicitWidth + 14)
        height: 6
        radius: 3
        color: Theme.withAlpha(Theme.text, 0.15)

        Rectangle {
            width: parent.width * Math.max(0, Math.min(1, sl.t))
            height: parent.height
            radius: 3
            color: Theme.accent
        }

        Rectangle {
            x: parent.width * Math.max(0, Math.min(1, sl.t)) - width / 2
            anchors.verticalCenter: parent.verticalCenter
            width: 18
            height: 18
            radius: 9
            color: "white"
            border.width: 1
            border.color: Theme.withAlpha("#000000", 0.15)
        }

        MouseArea {
            anchors.fill: parent
            anchors.margins: -8
            cursorShape: Qt.PointingHandCursor
            function set(x) {
                let v = sl.from + Math.max(0, Math.min(1, x / track.width)) * (sl.to - sl.from);
                if (sl.step > 0)
                    v = Math.round(v / sl.step) * sl.step;
                sl.dragValue = v;
                sl.moved(v);
            }
            onPressed: mouse => {
                sl.dragging = true;
                set(mouse.x - 8);
            }
            onPositionChanged: mouse => pressed && set(mouse.x - 8)
            onReleased: {
                sl.dragging = false;
                sl.committed(sl.dragValue);
            }
        }
    }

    Text {
        id: valueLabel
        anchors {
            right: parent.right
            verticalCenter: parent.verticalCenter
        }
        text: sl.format ? sl.format(sl.shown) : sl.shown.toFixed(sl.decimals) + sl.suffix
        color: Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 12
        font.features: {
            "tnum": 1
        }
    }
}
