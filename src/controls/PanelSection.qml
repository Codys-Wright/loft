import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// A small section label ("Known Networks"). Collapsible ones show a
// chevron and toggle `expanded` (macOS "Other Networks ›").
Item {
    id: sec
    property string text
    property bool collapsible: false
    property bool expanded: true
    property string trailing

    readonly property bool navigable: collapsible
    readonly property bool lit: collapsible && Nav.item === sec
    function activate() {
        expanded = !expanded;
    }

    Layout.fillWidth: true
    implicitHeight: 24
    implicitWidth: label.implicitWidth + 40

    Rectangle {
        anchors.fill: parent
        radius: Theme.controlRadius
        color: sec.lit ? Theme.accent : "transparent"
    }

    Text {
        id: label
        anchors {
            left: parent.left
            leftMargin: 10
            verticalCenter: parent.verticalCenter
        }
        text: sec.text
        color: sec.lit ? Theme.bg : Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 11
        font.weight: Font.DemiBold
    }

    Text {
        anchors {
            right: chevron.visible ? chevron.left : parent.right
            rightMargin: 10
            verticalCenter: parent.verticalCenter
        }
        visible: sec.trailing !== ""
        text: sec.trailing
        color: sec.lit ? Theme.bg : Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 11
    }

    Icon {
        id: chevron
        visible: sec.collapsible
        anchors {
            right: parent.right
            rightMargin: 10
            verticalCenter: parent.verticalCenter
        }
        text: "󰅂"
        size: 12
        rotation: sec.expanded ? 90 : 0
        color: sec.lit ? Theme.bg : Theme.subtext
        Behavior on rotation {
            NumberAnimation {
                duration: 150
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        enabled: sec.collapsible
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: Nav.item = sec
        onClicked: sec.activate()
    }
}
