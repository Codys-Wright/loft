import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import qs.components
import qs.services

// One glass dropdown of the cascade: rows with a check/radio column, the
// label, the shortcut right-aligned (or a chevron for submenus).
//
// Optional per item (all off unless set, so plain menus look as before):
// `icon` (a Nerd Font glyph; Golden Gate puts icons only on a few common
// actions), `swatch` ([colors…]: a tiny palette chip), `thumb` (an image
// url: a small rounded thumbnail), `header: true` (a non-selectable group
// heading). `maxHeight` > 0 makes a taller list scroll (wheel, keyboard,
// or hovering the arrows at either end).
GlassSurface {
    id: panel

    property var items: []
    // The rows actually drawn. Menus that rebuild their items on every
    // hover (the app menu's appItems, the system menu) hand over fresh but
    // identical objects each time; replacing the Repeater's model would
    // destroy the row under the pointer between press and release (the new
    // rows sit at y 0 until the layout's next polish), so a mouse click
    // never arrived. Rows are swapped only when something visible changed.
    property var rowItems: []
    property string rowSig: ""
    onItemsChanged: {
        const sig = signature(items);
        if (sig === rowSig)
            return;
        rowSig = sig;
        rowItems = items;
    }
    Component.onCompleted: {
        rowSig = signature(items);
        rowItems = items;
    }
    function signature(list) {
        return JSON.stringify((list ?? []).map(i => [MenuState.keyOf(i), i.label ?? "", i.enabled !== false, i.checked === true, i.toggle ?? "", i.submenu === true, i.separator === true, i.header === true, i.icon ?? "", i.swatch ?? null, i.thumb ?? "", i.shortcut ?? null]));
    }
    property int level: 0
    // Key of the highlighted row (MenuState.path[level]).
    property var highlighted

    signal hovered(var item)
    signal clicked(var item)

    readonly property int pad: 6
    readonly property bool anyToggle: rowItems.some(i => i.toggle)
    // The leading picture column (icons, swatches, thumbnails), if any.
    readonly property int leadWidth: rowItems.some(i => i.thumb) ? 44 : rowItems.some(i => i.swatch) ? 30 : rowItems.some(i => i.icon) ? 16 : 0
    readonly property int leadX: anyToggle ? 22 : 10
    readonly property int labelX: leadX + (leadWidth > 0 ? leadWidth + 8 : 0)
    // 0 = as tall as the rows; otherwise the list scrolls inside this.
    property real maxHeight: 0
    readonly property bool scrolls: maxHeight > 0 && column.implicitHeight + 2 * pad > maxHeight

    width: Math.max(200, column.implicitWidth + 2 * pad)
    height: scrolls ? maxHeight : column.implicitHeight + 2 * pad
    radius: 12
    strength: 1.9

    function rowY(key) {
        for (let i = 0; i < rows.count; i++) {
            const r = rows.itemAt(i);
            if (r && MenuState.keyOf(r.modelData) === key)
                return r.y + pad - flick.contentY;
        }
        return pad;
    }

    // Keep the highlighted row in view (keyboard navigation in a long list).
    // Positions come from the rows' heights, so it also works right after
    // the items changed, before the column has laid them out.
    onHighlightedChanged: {
        if (!scrolls)
            return;
        let y = 0;
        for (let i = 0; i < rows.count; i++) {
            const r = rows.itemAt(i);
            if (!r)
                return;
            if (MenuState.keyOf(r.modelData) === highlighted) {
                const h = r.implicitHeight;
                const view = height - 2 * pad;
                if (y < flick.contentY + 18)
                    flick.contentY = Math.max(0, y - 18);
                else if (y + h > flick.contentY + view - 18)
                    flick.contentY = Math.min(column.implicitHeight - view, y + h - view + 18);
                return;
            }
            y += r.implicitHeight;
        }
    }

    // Swallow clicks between rows.
    MouseArea {
        anchors.fill: parent
    }

    Flickable {
        id: flick
        anchors.fill: parent
        anchors.margins: panel.pad
        contentHeight: column.implicitHeight
        interactive: panel.scrolls
        clip: panel.scrolls
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: column
            width: flick.width
            spacing: 0

            Repeater {
                id: rows
                model: panel.rowItems

                delegate: Item {
                    id: row
                    required property var modelData
                    readonly property bool sep: modelData.separator === true
                    readonly property bool on: modelData.enabled !== false
                    readonly property bool lit: !sep && on && MenuState.keyOf(modelData) === panel.highlighted
                    readonly property string shortcut: AppMenu.formatShortcut(modelData.shortcut)
                    readonly property bool header: modelData.header === true

                    Layout.fillWidth: true
                    implicitHeight: sep ? 9 : header ? 24 : modelData.thumb ? 34 : 26
                    implicitWidth: sep ? 0 : (header ? 10 : panel.labelX) + label.implicitWidth + (shortcut !== "" ? 32 + keys.implicitWidth : 0) + (modelData.submenu ? 28 : 0) + 10

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

                    // Leading picture: icon, palette swatch or thumbnail.
                    Item {
                        visible: !row.sep && !row.header && panel.leadWidth > 0
                        x: panel.leadX
                        width: panel.leadWidth
                        height: parent.height

                        Icon {
                            visible: (row.modelData.icon ?? "") !== ""
                            anchors.centerIn: parent
                            text: row.modelData.icon ?? ""
                            size: 14
                            color: row.lit ? Theme.bg : Theme.text
                            opacity: row.on ? 1 : 0.4
                        }

                        Rectangle {
                            id: chip
                            readonly property var colors: row.modelData.swatch ?? []
                            visible: colors.length > 0
                            anchors.centerIn: parent
                            width: 28
                            height: 16
                            radius: 5
                            color: colors[0] ?? "transparent"
                            border.width: 1
                            border.color: Theme.withAlpha(row.lit ? Theme.bg : Theme.text, 0.25)

                            Row {
                                anchors {
                                    right: parent.right
                                    rightMargin: 3
                                    verticalCenter: parent.verticalCenter
                                }
                                spacing: 2
                                Repeater {
                                    model: chip.colors.slice(1, 3)
                                    delegate: Rectangle {
                                        required property var modelData
                                        width: 8
                                        height: 8
                                        radius: 4
                                        color: modelData
                                    }
                                }
                            }
                        }

                        Rectangle {
                            visible: (row.modelData.thumb ?? "") !== ""
                            anchors.centerIn: parent
                            width: 44
                            height: 26
                            radius: 5
                            color: Theme.withAlpha(Theme.text, 0.1)
                            border.width: 1
                            border.color: Theme.withAlpha(row.lit ? Theme.bg : Theme.text, 0.25)

                            Image {
                                anchors.fill: parent
                                anchors.margins: 1
                                source: row.modelData.thumb ?? ""
                                sourceSize: Qt.size(96, 56)
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                layer.enabled: true
                                layer.effect: MultiEffect {
                                    maskEnabled: true
                                    maskSource: thumbMask
                                    maskThresholdMin: 0.5
                                    maskSpreadAtMin: 1
                                }
                            }
                            Rectangle {
                                id: thumbMask
                                anchors.fill: parent
                                anchors.margins: 1
                                radius: 4
                                visible: false
                                layer.enabled: true
                            }
                        }
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
                        x: row.header ? 10 : panel.labelX
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.verticalCenterOffset: row.header ? 2 : 0
                        text: row.modelData.label ?? ""
                        color: row.lit ? Theme.bg : row.header ? Theme.subtext : Theme.text
                        opacity: row.on || row.header ? 1 : 0.4
                        font.family: Theme.fontUi
                        font.pixelSize: row.header ? 11 : 13
                        font.weight: row.header ? Font.DemiBold : Font.Normal
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

    // Scroll arrows (macOS): shown while there is more above / below;
    // hovering one scrolls.
    component ScrollArrow: Rectangle {
        id: arrow
        property int direction: 1
        readonly property bool more: panel.scrolls && (direction < 0 ? flick.contentY > 0.5 : flick.contentY < flick.contentHeight - flick.height - 0.5)
        visible: more
        anchors {
            left: parent.left
            right: parent.right
            margins: 1
        }
        height: 18
        radius: panel.radius
        color: Theme.fillFor(1.9)

        Icon {
            anchors.centerIn: parent
            text: arrow.direction < 0 ? "󰅃" : "󰅀"
            size: 12
            color: Theme.subtext
        }

        MouseArea {
            id: arrowHover
            anchors.fill: parent
            hoverEnabled: true
        }

        Timer {
            interval: 16
            repeat: true
            running: arrow.more && arrowHover.containsMouse
            onTriggered: flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, flick.contentY + 6 * arrow.direction))
        }
    }

    ScrollArrow {
        direction: -1
        anchors.top: parent.top
    }

    ScrollArrow {
        direction: 1
        anchors.bottom: parent.bottom
    }
}
