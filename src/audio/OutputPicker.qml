import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// The outputs list as a glass tile (Control Center, under the volume
// slider): pick the default output.
GlassSurface {
    id: root

    implicitHeight: list.implicitHeight + 16
    radius: 18
    showHighlight: false

    DeviceList {
        id: list
        anchors {
            left: parent.left
            right: parent.right
            top: parent.top
            margins: 8
        }
        nodes: Sound.sinks
        currentId: Sound.defaultSink?.id ?? -1
        onPicked: node => Sound.setDefaultSink(node)
    }
}
