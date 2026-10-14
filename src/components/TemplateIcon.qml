import QtQuick
import QtQuick.Effects
import Quickshell.Widgets

// An app icon drawn the way macOS draws menu bar icons: as a "template" —
// only its shape (alpha) counts, filled with one color (the bar's text
// color), so colored tray icons sit in the bar like the rest. `template:
// false` shows the original colors.
Item {
    id: root

    property string source
    property real size: 16
    property color color: "white"
    property bool template: true

    implicitWidth: size
    implicitHeight: size

    IconImage {
        id: image
        anchors.fill: parent
        implicitSize: root.size
        source: root.source
        visible: !root.template
        layer.enabled: root.template
    }

    Rectangle {
        id: fill
        anchors.fill: parent
        visible: false
        color: root.color
        layer.enabled: root.template
    }

    MultiEffect {
        visible: root.template
        anchors.fill: parent
        source: fill
        maskEnabled: true
        maskSource: image
        maskThresholdMin: 0.0
        maskSpreadAtMin: 1.0
    }
}
