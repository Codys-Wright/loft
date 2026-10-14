import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// One glass dropdown of the cascade: rows with a check/radio column, the
// label, the shortcut right-aligned (or a chevron for submenus).
GlassSurface {
    id: panel

    property var items: []
    property int level: 0
    // Key of the highlighted row (MenuState.path[level]).
    property var highlighted

    signal hovered(var item)
    signal clicked(var item)

    readonly property int pad: 6
    readonly property bool anyToggle: items.some(i => i.toggle)

    width: Math.max(200, column.implicitWidth + 2 * pad)
    height: column.implicitHeight + 2 * pad
    radius: 12
    strength: 1.9

    function rowY(key) {
        for (let i = 0; i < rows.count; i++) {
            const r = rows.itemAt(i);
            if (r && MenuState.keyOf(r.modelData) === key)
                return r.y + pad;
        }
        return pad;
    }

    // Swallow clicks between rows.
    MouseArea {
        anchors.fill: parent
    }

    ColumnLayout {
        id: column
        anchors {
            left: parent.left
            right: parent.right
            top: parent.top
            margins: panel.pad
        }
        spacing: 0

        Repeater {
            id: rows
            model: panel.items

            delegate: Item {
                id: row
                required property var modelData
                readonly property bool sep: modelData.separator === true
                readonly property bool on: modelData.enabled !== false
                readonly property bool lit: !sep && on && MenuState.keyOf(modelData) === panel.highlighted
                readonly property string shortcut: AppMenu.formatShortcut(modelData.shortcut)

                Layout.fillWidth: true
                implicitHeight: sep ? 9 : 26
                implicitWidth: sep ? 0 : (panel.anyToggle ? 22 : 10) + label.implicitWidth + (shortcut !== "" ? 32 + keys.implicitWidth : 0) + (modelData.submenu ? 28 : 0) + 10

                Rectangle {
                    visible: row.sep
                    anchors {
                        left: parent.left
                        right: parent.right
                        verticalCenter: parent.verticalCenter
                        leftMargin: 8
                        rightMargin: 8
                    }
                    height: 1
                    color: Theme.withAlpha(Theme.text, 0.14)
                }

                Rectangle {
                    visible: !row.sep
                    anchors.fill: parent
                    radius: 6
                    color: row.lit ? Theme.accent : "transparent"
                }

                Text {
                    // ✓ for checks, • for radios.
                    visible: !row.sep && row.modelData.checked === true
                    x: 7
                    anchors.verticalCenter: parent.verticalCenter
                    text: row.modelData.toggle === "radio" ? "•" : "✓"
                    color: row.lit ? Theme.bg : Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: row.modelData.toggle === "radio" ? 18 : 13
                    font.weight: Font.DemiBold
                }

                Text {
                    id: label
                    visible: !row.sep
                    x: panel.anyToggle ? 22 : 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: row.modelData.label ?? ""
                    color: row.lit ? Theme.bg : Theme.text
                    opacity: row.on ? 1 : 0.4
                    font.family: Theme.fontUi
                    font.pixelSize: 13
                }

                Text {
                    id: keys
                    visible: !row.sep && row.shortcut !== ""
                    anchors {
                        right: parent.right
                        rightMargin: 10
                        verticalCenter: parent.verticalCenter
                    }
                    text: row.shortcut
                    color: row.lit ? Theme.bg : Theme.subtext
                    opacity: row.on ? 0.85 : 0.35
                    font.family: Theme.fontUi
                    font.pixelSize: 12
                }

                Icon {
                    visible: !row.sep && row.modelData.submenu === true
                    anchors {
                        right: parent.right
                        rightMargin: 8
                        verticalCenter: parent.verticalCenter
                    }
                    text: "󰅂"
                    size: 12
                    color: row.lit ? Theme.bg : Theme.subtext
                    opacity: row.on ? 1 : 0.35
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: !row.sep
                    hoverEnabled: true
                    onEntered: if (row.on)
                        panel.hovered(row.modelData)
                    onClicked: if (row.on)
                        panel.clicked(row.modelData)
                }
            }
        }
    }
}
