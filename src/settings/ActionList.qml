import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// An arrangeable list of actions (Settings → Quick Panel / Radial Menu):
// drag a row by its handle (or use the arrows) to reorder, − removes,
// clicking a row selects it.
//   items: [{ icon, label, sub, appId, badge }]
ColumnLayout {
    id: list

    property var items: []
    property int selected: -1
    // Row under the pointer (-1 none), for live previews.
    property int hovered: -1
    property real rowHeight: 40

    signal moved(int from, int to)
    signal removed(int index)
    signal clicked(int index)

    spacing: 0

    // Drag state: the row being dragged and where it would land.
    property int dragFrom: -1
    property int dragTo: -1

    Repeater {
        model: list.items

        delegate: Item {
            id: row
            required property var modelData
            required property int index
            readonly property bool dragging: list.dragFrom === index

            Layout.fillWidth: true
            implicitHeight: list.rowHeight
            z: dragging ? 2 : 0

            // Drop marker above the landing row.
            Rectangle {
                visible: list.dragFrom >= 0 && list.dragTo === row.index && list.dragTo !== list.dragFrom
                anchors {
                    left: parent.left
                    right: parent.right
                    top: list.dragTo < list.dragFrom ? parent.top : undefined
                    bottom: list.dragTo > list.dragFrom ? parent.bottom : undefined
                }
                height: 2
                radius: 1
                color: Theme.accent
            }

            Rectangle {
                id: body
                width: parent.width
                height: parent.height
                y: row.dragging ? handle.dy : 0
                radius: 8
                color: row.dragging ? Theme.withAlpha(Theme.text, 0.1) : row.index === list.selected ? Theme.withAlpha(Theme.accent, 0.18) : hover.containsMouse ? Theme.withAlpha(Theme.text, 0.05) : "transparent"
                border.width: row.dragging ? 1 : 0
                border.color: Theme.glassBorder

                MouseArea {
                    id: hover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onContainsMouseChanged: {
                        if (containsMouse)
                            list.hovered = row.index;
                        else if (list.hovered === row.index)
                            list.hovered = -1;
                    }
                    onClicked: list.clicked(row.index)
                }

                RowLayout {
                    anchors {
                        fill: parent
                        leftMargin: 4
                        rightMargin: 6
                    }
                    spacing: 8

                    // Drag handle
                    Item {
                        Layout.preferredWidth: 22
                        Layout.fillHeight: true
                        Icon {
                            anchors.centerIn: parent
                            text: "󰇝"
                            size: 14
                            color: Theme.withAlpha(Theme.subtext, handle.containsMouse || row.dragging ? 1 : 0.55)
                        }
                        MouseArea {
                            id: handle
                            property real startY: 0
                            property real dy: 0
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                            preventStealing: true
                            onPressed: mouse => {
                                startY = mapToItem(list, 0, mouse.y).y;
                                dy = 0;
                                list.dragFrom = row.index;
                                list.dragTo = row.index;
                            }
                            onPositionChanged: mouse => {
                                if (!pressed)
                                    return;
                                dy = mapToItem(list, 0, mouse.y).y - startY;
                                list.dragTo = Math.max(0, Math.min(list.items.length - 1, row.index + Math.round(dy / list.rowHeight)));
                            }
                            onReleased: {
                                const from = list.dragFrom, to = list.dragTo;
                                list.dragFrom = -1;
                                list.dragTo = -1;
                                dy = 0;
                                if (from >= 0 && to >= 0 && from !== to)
                                    list.moved(from, to);
                            }
                            onCanceled: {
                                list.dragFrom = -1;
                                list.dragTo = -1;
                                dy = 0;
                            }
                        }
                    }

                    Item {
                        Layout.preferredWidth: 24
                        Layout.preferredHeight: 24
                        Rectangle {
                            anchors.fill: parent
                            radius: 7
                            visible: !row.modelData.appId
                            color: Theme.badgeColor(row.modelData.badge ?? "gray")
                            Icon {
                                anchors.centerIn: parent
                                text: row.modelData.icon ?? ""
                                size: 13
                                color: "white"
                            }
                        }
                        AppIcon {
                            anchors.fill: parent
                            visible: !!row.modelData.appId
                            appId: row.modelData.appId ?? ""
                            pixelSize: 48
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        Text {
                            Layout.fillWidth: true
                            text: row.modelData.label ?? ""
                            color: Theme.text
                            font.family: Theme.fontUi
                            font.pixelSize: 13
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: text !== ""
                            text: row.modelData.sub ?? ""
                            color: row.modelData.warn ? Theme.warn : Theme.subtext
                            font.family: Theme.fontUi
                            font.pixelSize: 11
                            elide: Text.ElideRight
                        }
                    }

                    SmallButton {
                        glyph: "󰁝"
                        enabled: row.index > 0
                        onClicked: list.moved(row.index, row.index - 1)
                    }
                    SmallButton {
                        glyph: "󰁅"
                        enabled: row.index < list.items.length - 1
                        onClicked: list.moved(row.index, row.index + 1)
                    }
                    SmallButton {
                        glyph: "󰍴"
                        onClicked: list.removed(row.index)
                    }
                }
            }
        }
    }

    component SmallButton: Rectangle {
        id: btn
        property string glyph
        signal clicked

        implicitWidth: 26
        implicitHeight: 24
        radius: 7
        color: hit.containsMouse && enabled ? Theme.withAlpha(Theme.text, 0.16) : Theme.withAlpha(Theme.text, 0.07)
        opacity: enabled ? 1 : 0.3

        Icon {
            anchors.centerIn: parent
            text: btn.glyph
            size: 13
        }
        MouseArea {
            id: hit
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: btn.clicked()
        }
    }
}
