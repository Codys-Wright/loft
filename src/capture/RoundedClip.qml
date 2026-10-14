import QtQuick
import QtQuick.Effects

// Clips its children to a rounded rectangle (or a circle: radius = size/2),
// antialiased — plain `clip` only cuts square corners.
Item {
    id: root

    property real radius: 0
    default property alias content: inner.data

    Item {
        id: inner
        anchors.fill: parent
        layer.enabled: true
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: mask
            maskThresholdMin: 0.5
            maskSpreadAtMin: 1.0
        }
    }

    Rectangle {
        id: mask
        anchors.fill: parent
        radius: root.radius
        visible: false
        layer.enabled: true
        layer.smooth: true
    }
}
