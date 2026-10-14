import QtQuick
import QtQuick.Layouts
import qs.components
import qs.settings
import qs.services

// Edit Controls → the gallery: every control, grouped like Features, with
// "+" to add it to the Control Center (in its first size) and "Show in
// Menu Bar" for the ones that can live in the bar.
GlassSurface {
    id: root

    // ids currently in the (draft) layout.
    property var present: []
    signal add(string id)

    radius: Theme.panelRadius + 8
    strength: 1.7

    readonly property var groups: {
        const out = [];
        for (const g of Features.groups.concat(["System"])) {
            const items = Controls.controls.filter(c => c.group === g && Controls.available(c.id) && ((c.sizes ?? []).length > 0 || c.bar) && !out.some(o => o.items.includes(c)));
            if (items.length > 0)
                out.push({ name: g, items: items });
        }
        return out;
    }

    MouseArea {
        anchors.fill: parent
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 14
        spacing: 8

        Text {
            text: "Add Controls"
            color: Theme.text
            font.family: Theme.fontUi
            font.pixelSize: 17
            font.weight: Font.DemiBold
        }
        Text {
            Layout.fillWidth: true
            text: "Click + to add a control. Drag modules to reorder, − removes, ⤢ resizes. Controls can also live in the menu bar."
            wrapMode: Text.WordWrap
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
        }

        Flickable {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentHeight: list.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            ColumnLayout {
                id: list
                width: parent.width
                spacing: 4

                Repeater {
                    model: root.groups
                    delegate: ColumnLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 2

                        Text {
                            Layout.topMargin: 8
                            text: modelData.name
                            color: Theme.subtext
                            font.family: Theme.fontUi
                            font.pixelSize: 11
                            font.weight: Font.DemiBold
                        }

                        Repeater {
                            model: modelData.items
                            delegate: Rectangle {
                                id: item
                                required property var modelData
                                readonly property bool inCc: root.present.includes(modelData.id)
                                readonly property bool canCc: (modelData.sizes ?? []).length > 0
                                Layout.fillWidth: true
                                implicitHeight: 44
                                radius: 10
                                color: hover.containsMouse ? Theme.withAlpha(Theme.text, 0.06) : "transparent"

                                MouseArea {
                                    id: hover
                                    anchors.fill: parent
                                    hoverEnabled: true
                                }

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 6
                                    anchors.rightMargin: 6
                                    spacing: 10

                                    Rectangle {
                                        Layout.preferredWidth: 30
                                        Layout.preferredHeight: 30
                                        radius: 15
                                        color: Theme.withAlpha(Theme.text, 0.14)
                                        Icon {
                                            anchors.centerIn: parent
                                            text: item.modelData.icon
                                            size: 14
                                        }
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 0
                                        Text {
                                            Layout.fillWidth: true
                                            text: item.modelData.label
                                            color: Theme.text
                                            font.family: Theme.fontUi
                                            font.pixelSize: 13
                                            elide: Text.ElideRight
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: [item.canCc ? (item.modelData.sizes ?? []).join(" · ") : "Menu bar only", item.modelData.bar ? (Controls.onBar(item.modelData.id) ? "in the menu bar" : "") : ""].filter(x => x).join(" — ")
                                            color: Theme.subtext
                                            font.family: Theme.fontUi
                                            font.pixelSize: 10
                                            elide: Text.ElideRight
                                        }
                                    }
                                    // Show in Menu Bar.
                                    Rectangle {
                                        visible: item.modelData.bar
                                        Layout.preferredWidth: 28
                                        Layout.preferredHeight: 22
                                        radius: 6
                                        color: Controls.onBar(item.modelData.id) ? Theme.accent : Theme.withAlpha(Theme.text, 0.12)
                                        Icon {
                                            anchors.centerIn: parent
                                            text: "󰍜"
                                            size: 12
                                            color: Controls.onBar(item.modelData.id) ? Theme.bg : Theme.text
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: Controls.setOnBar(item.modelData.id, !Controls.onBar(item.modelData.id))
                                        }
                                    }
                                    Rectangle {
                                        visible: item.canCc
                                        Layout.preferredWidth: 22
                                        Layout.preferredHeight: 22
                                        radius: 11
                                        color: item.inCc ? Theme.withAlpha(Theme.text, 0.10) : Theme.accent
                                        Text {
                                            anchors.centerIn: parent
                                            text: item.inCc ? "✓" : "+"
                                            color: item.inCc ? Theme.subtext : Theme.bg
                                            font.pixelSize: 14
                                            font.weight: Font.Bold
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            enabled: !item.inCc
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.add(item.modelData.id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
