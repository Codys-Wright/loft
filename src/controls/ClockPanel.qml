import QtQuick
import QtQuick.Layouts
import qs.services

// The date in the bar → calendar + recent notifications (Notification
// Center, in short).
ColumnLayout {
    id: root

    property bool details: false
    property bool shown: true
    property bool inMenu: true
    signal dismiss
    signal openSettings(string section)

    spacing: 4

    Calendar {
        Layout.fillWidth: true
        color: "transparent"
        showBorder: false
    }

    PanelSeparator {}
    PanelSection {
        text: "Notifications"
        trailing: Notifications.history.length > 0 ? String(Notifications.history.length) : ""
    }
    Repeater {
        model: Notifications.history.slice(-5).reverse()
        delegate: PanelRow {
            required property var modelData
            text: modelData.summary || Notifications.appLabel(modelData)
            detail: modelData.body ?? ""
            onClicked: Notifications.activate(modelData)
        }
    }
    PanelRow {
        visible: Notifications.history.length === 0
        enabled: false
        dim: true
        text: "No notifications"
    }
    PanelRow {
        visible: Notifications.history.length > 0
        text: "Clear All"
        onClicked: Notifications.clearHistory()
    }

    PanelSeparator {}
    PanelRow {
        text: "Date & Time Settings…"
        onClicked: root.openSettings("menubar")
    }
}
