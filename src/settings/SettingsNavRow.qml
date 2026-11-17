import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services
import "settingsnav.js" as Nav

// A drill-in row on an overview (System Settings' "› " rows): badge, label
// and a one-line summary on the left; the current state (`value`) and a
// chevron on the right. With `feature` set the row carries the module's
// on/off switch (Features), and an off module's row is dimmed but stays —
// so a switched-off page is still one click away from being turned on.
Item {
    id: row

    // A page id (settingsnav.js): fills icon, badge, label, summary and
    // feature, and a click opens it.
    property string page: ""
    readonly property var info: page !== "" ? Nav.page(page) : null
    property string icon: info?.icon ?? ""
    property string badge: info?.badge ?? "gray"
    property string label: info?.label ?? ""
    property string summary: info?.summary ?? ""
    // The current state, right-aligned ("Bottom · 48 px", "3 spaces").
    property string value
    // A Features module id: show its switch.
    property string feature: info?.feature ?? ""
    readonly property bool featureOn: feature === "" || Features.on(feature)
    // false: a row that can't be opened here (shows `summary` only).
    property bool available: true

    signal clicked

    Layout.fillWidth: true
    implicitHeight: Math.max(40, labels.implicitHeight + 8)

    Rectangle {
        anchors.fill: parent
        anchors.margins: -6
        radius: Theme.controlRadius
        color: mouse.containsMouse && row.available ? Theme.withAlpha(Theme.text, 0.06) : "transparent"
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        enabled: row.available
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            if (row.page !== "")
                Panels.settingsSection = row.page;
            row.clicked();
        }
    }

    RowLayout {
        anchors.fill: parent
        spacing: 10

        IconBadge {
            icon: row.icon
            badge: row.badge
            size: 26
            opacity: row.featureOn && row.available ? 1 : 0.45
        }

        ColumnLayout {
            id: labels
            Layout.fillWidth: true
            spacing: 1
            Text {
                Layout.fillWidth: true
                text: row.label
                color: row.featureOn && row.available ? Theme.text : Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 13
                elide: Text.ElideRight
            }
            Text {
                Layout.fillWidth: true
                visible: text !== ""
                text: row.summary
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 11
                elide: Text.ElideRight
            }
        }

        Text {
            Layout.maximumWidth: 220
            visible: text !== ""
            text: row.featureOn ? row.value : "Off"
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 12
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignRight
        }

        SettingsSwitch {
            visible: row.feature !== ""
            checked: row.featureOn
            onToggled: on => Features.set(row.feature, on)
        }

        Icon {
            visible: row.available
            text: "󰅂"
            size: 14
            color: Theme.withAlpha(Theme.text, 0.45)
        }
    }
}
