import QtQuick
import QtQuick.Layouts
import Quickshell.Services.SystemTray
import qs.components
import qs.services

// The » overflow: status items that didn't fit in the bar, and tray icons
// tucked away (Settings → Menu Bar). Clicking a control opens its panel
// here; tray items activate (right-click: their menu).
ColumnLayout {
    id: root

    property string screenName: ""
    property var window: null
    signal dismiss
    signal openSettings(string section)
    signal openControl(string id)

    spacing: 0

    readonly property var ids: Controls.overflowByScreen[screenName] ?? []
    readonly property var tucked: SystemTray.items.values.filter(i => Controls.isTrayTucked(i))

    Repeater {
        model: root.ids.filter(id => id !== "tray")
        delegate: PanelRow {
            required property string modelData
            readonly property var c: Controls.control(modelData)
            text: c?.label ?? modelData
            detail: Controls.status(modelData)
            glyph: Controls.iconOf(modelData)
            glyphActive: Controls.active(modelData) && c?.kind !== "panel"
            onClicked: root.openControl(modelData)
        }
    }

    PanelSeparator {
        visible: root.tucked.length > 0 && root.ids.filter(id => id !== "tray").length > 0
    }

    Repeater {
        model: root.tucked.concat(root.ids.includes("tray") ? SystemTray.items.values.filter(i => !Controls.isTrayTucked(i)) : [])
        delegate: PanelRow {
            id: trayRow
            required property var modelData
            text: modelData.tooltipTitle || modelData.title || modelData.id
            glyph: " " // a disc; the icon is drawn over it
            onClicked: {
                root.dismiss();
                modelData.activate();
            }
            onRightClicked: if (modelData.hasMenu && root.window)
                modelData.display(root.window, trayRow.mapToItem(null, 0, 0).x, trayRow.mapToItem(null, 0, trayRow.height).y)

            TemplateIcon {
                parent: trayRow
                x: 11
                y: 10
                size: 16
                source: trayRow.modelData.icon
                color: Theme.text
                template: !Controls.trayColor.includes(trayRow.modelData.id)
            }
        }
    }

    PanelRow {
        visible: root.ids.length === 0 && root.tucked.length === 0
        interactive: false
        dim: true
        text: "Everything fits"
    }

    PanelSeparator {}
    PanelRow {
        text: "Menu Bar Settings…"
        onClicked: root.openSettings("menubar")
    }
}
