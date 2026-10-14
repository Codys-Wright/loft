import QtQuick
import QtQuick.Layouts
import qs.services

// Focus: Do Not Disturb and focus timers (FocusTimer, shown in the island).
ColumnLayout {
    id: root

    property bool details: false
    property bool shown: true
    property bool inMenu: true
    signal dismiss
    signal openSettings(string section)

    spacing: 0

    PanelHeader {
        title: "Focus"
    }

    PanelRow {
        text: "Do Not Disturb"
        detail: Panels.doNotDisturb ? "Notifications are kept quiet" : ""
        glyph: "󰂛"
        glyphActive: Panels.doNotDisturb
        onClicked: Panels.doNotDisturb = !Panels.doNotDisturb
    }

    PanelRow {
        visible: FocusTimer.active
        text: FocusTimer.paused ? "Focus timer paused" : "Focus timer"
        detail: `${FocusTimer.format(FocusTimer.remaining)} left`
        glyph: "󰔟"
        glyphActive: true
        trailing: "Stop"
        onClicked: FocusTimer.stop()
    }

    Repeater {
        model: FocusTimer.active ? [] : [Settings.island.focusMinutes, 50].filter((m, i, a) => a.indexOf(m) === i)
        delegate: PanelRow {
            required property int modelData
            text: `Focus for ${modelData} minutes`
            glyph: "󰔟"
            onClicked: {
                FocusTimer.startFor(modelData);
                Panels.doNotDisturb = true;
            }
        }
    }

    PanelSeparator {}
    PanelRow {
        text: "Focus Settings…"
        onClicked: root.openSettings("island")
    }
}
