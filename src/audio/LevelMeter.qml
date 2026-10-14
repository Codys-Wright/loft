import QtQuick
import Quickshell.Services.Pipewire
import qs.services

// A thin live level bar for a node (a microphone, or an app's stream).
// Metering opens a small capture stream, so only run it while visible.
Item {
    id: root

    property PwNode node: null
    property bool active: visible
    readonly property real level: meter.enabled ? Math.min(1, Math.sqrt(meter.peak)) : 0

    implicitHeight: 4
    implicitWidth: 120

    PwNodePeakMonitor {
        id: meter
        // The monitor starts enabled; give it a node only while active so
        // no stream opens before `enabled` is bound.
        node: root.active ? root.node : null
        enabled: root.active && root.node !== null
    }

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: Theme.withAlpha(Theme.text, 0.10)
    }

    Rectangle {
        width: parent.width * root.level
        height: parent.height
        radius: height / 2
        color: root.level > 0.9 ? Theme.urgent : root.level > 0.7 ? Theme.warn : Theme.ok

        Behavior on width {
            NumberAnimation {
                duration: 60
            }
        }
    }
}
