import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.components
import qs.services

// A pop-up menu button. options: [{ value, label }]; emits activated(value).
Rectangle {
    id: sel
    property var options: []
    property var current
    property string placeholder: "—"
    signal activated(var value)

    readonly property var currentOption: options.find(o => o.value === current) ?? null

    implicitWidth: Math.max(140, label.implicitWidth + 40)
    implicitHeight: 28
    radius: 8
    color: hover.containsMouse || menu.visible ? Theme.withAlpha(Theme.text, 0.14) : Theme.withAlpha(Theme.text, 0.08)
    border.width: 1
    border.color: Theme.withAlpha(Theme.text, 0.08)
    opacity: enabled ? 1 : 0.4

    Text {
        id: label
        anchors {
            left: parent.left
            leftMargin: 10
            verticalCenter: parent.verticalCenter
        }
        text: sel.currentOption?.label ?? sel.placeholder
        color: Theme.text
        font.family: Theme.fontUi
        font.pixelSize: 12
        font.features: {
            "tnum": 1
        }
    }

    Icon {
        anchors {
            right: parent.right
            rightMargin: 8
            verticalCenter: parent.verticalCenter
        }
        text: "󰅀"
        size: 11
        color: Theme.subtext
    }

    MouseArea {
        id: hover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: menu.visible ? menu.close() : menu.open()
    }

    Popup {
        id: menu
        y: sel.height + 4
        width: Math.max(sel.width, list.implicitWidth + 12)
        height: Math.min(list.implicitHeight + 12, 280)
        padding: 6
        modal: false
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        background: Rectangle {
            radius: 10
            color: Theme.withAlpha(Theme.surface, 0.97)
            border.width: 1
            border.color: Theme.glassBorder
        }

        contentItem: Flickable {
            clip: true
            contentHeight: list.implicitHeight
            boundsBehavior: Flickable.StopAtBounds

            ColumnLayout {
                id: list
                width: parent.width
                spacing: 1

                Repeater {
                    model: sel.options
                    delegate: Rectangle {
                        id: item
                        required property var modelData
                        readonly property bool selected: modelData.value === sel.current
                        Layout.fillWidth: true
                        implicitWidth: itemText.implicitWidth + 36
                        implicitHeight: 26
                        radius: 6
                        color: itemHover.containsMouse ? Theme.accent : "transparent"

                        Icon {
                            anchors {
                                left: parent.left
                                leftMargin: 6
                                verticalCenter: parent.verticalCenter
                            }
                            visible: item.selected
                            text: "󰄬"
                            size: 11
                            color: itemHover.containsMouse ? Theme.bg : Theme.accent
                        }

                        Text {
                            id: itemText
                            anchors {
                                left: parent.left
                                leftMargin: 24
                                verticalCenter: parent.verticalCenter
                            }
                            text: item.modelData.label
                            color: itemHover.containsMouse ? Theme.bg : Theme.text
                            font.family: Theme.fontUi
                            font.pixelSize: 12
                            font.features: {
                                "tnum": 1
                            }
                        }

                        MouseArea {
                            id: itemHover
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                menu.close();
                                sel.activated(item.modelData.value);
                            }
                        }
                    }
                }
            }
        }
    }
}
