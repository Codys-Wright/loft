import QtQuick
import QtQuick.Layouts
import qs.services
import qs.settings

// A panel's title line: bold name, optional subtitle, optional switch on
// the right (Wi-Fi, Bluetooth), like macOS's status menus.
Item {
    id: header
    property string title
    property string subtitle
    property bool hasSwitch: false
    property bool checked: false
    property string trailing
    signal toggled(bool on)

    readonly property bool navigable: hasSwitch && enabled
    readonly property bool lit: navigable && Nav.item === header
    readonly property string text: title
    function activate() {
        toggled(!checked);
    }

    Layout.fillWidth: true
    implicitHeight: col.implicitHeight + 10
    implicitWidth: col.implicitWidth + (hasSwitch ? 64 : 20)

    Rectangle {
        anchors.fill: parent
        radius: 7
        color: header.lit ? Theme.withAlpha(Theme.accent, 0.25) : "transparent"
    }

    ColumnLayout {
        id: col
        anchors {
            left: parent.left
            right: sw.visible ? sw.left : trail.left
            leftMargin: 10
            rightMargin: 10
            verticalCenter: parent.verticalCenter
        }
        spacing: 1
        Text {
            Layout.fillWidth: true
            text: header.title
            color: Theme.text
            font.family: Theme.fontUi
            font.pixelSize: 13
            font.weight: Font.Bold
            elide: Text.ElideRight
        }
        Text {
            Layout.fillWidth: true
            visible: header.subtitle !== ""
            text: header.subtitle
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
            elide: Text.ElideRight
        }
    }

    Text {
        id: trail
        anchors {
            right: parent.right
            rightMargin: 10
            verticalCenter: parent.verticalCenter
        }
        visible: !header.hasSwitch && header.trailing !== ""
        text: header.trailing
        color: Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 13
        font.weight: Font.DemiBold
    }

    SettingsSwitch {
        id: sw
        visible: header.hasSwitch
        anchors {
            right: parent.right
            rightMargin: 8
            verticalCenter: parent.verticalCenter
        }
        checked: header.checked
        onToggled: on => header.toggled(on)
    }
}
