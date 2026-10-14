import QtQuick
import QtQuick.Layouts
import qs.components

// A grouped block of settings rows on glass.
GlassSurface {
    default property alias content: col.data
    property alias spacing: col.spacing
    Layout.fillWidth: true
    implicitHeight: col.implicitHeight + 28
    radius: 18
    showHighlight: false
    strength: 0.9

    ColumnLayout {
        id: col
        anchors {
            left: parent.left
            right: parent.right
            top: parent.top
            margins: 14
        }
        spacing: 14
    }
}
