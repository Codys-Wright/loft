import QtQuick
import QtQuick.Layouts
import qs.services

// Keep Awake: by hand for a while, and what the rules say (KeepAwake).
ColumnLayout {
    id: root

    property bool details: false
    property bool shown: true
    property bool inMenu: true
    signal dismiss
    signal openSettings(string section)

    spacing: 0

    PanelHeader {
        title: "Keep Awake"
        subtitle: KeepAwake.active ? KeepAwake.status : "Screen sleeps as usual"
        hasSwitch: true
        checked: KeepAwake.manual
        onToggled: on => on ? KeepAwake.keepFor(EverydayConfig.keepAwake.defaultMinutes) : KeepAwake.stop()
    }

    PanelRow {
        visible: KeepAwake.timed
        text: "Timer"
        detail: `${KeepAwake.format(KeepAwake.remaining)} left`
        glyph: "󰔟"
        glyphActive: true
        trailing: "Stop"
        onClicked: KeepAwake.stop()
    }

    Repeater {
        model: [{ label: "For 15 minutes", minutes: 15 }, { label: "For 1 hour", minutes: 60 }, { label: "For 2 hours", minutes: 120 }, { label: "For 5 hours", minutes: 300 }, { label: "Until tomorrow morning", clock: [7, 0] }, { label: "Indefinitely", minutes: 0 }]
        delegate: PanelRow {
            required property var modelData
            text: modelData.label
            checked: modelData.minutes === 0 && Panels.caffeine
            onClicked: modelData.clock ? KeepAwake.keepUntilClock(modelData.clock[0], modelData.clock[1]) : KeepAwake.keepFor(modelData.minutes)
        }
    }

    // What the rules say right now (Settings → Everyday).
    PanelSeparator {
        visible: rules.text !== ""
    }
    PanelRow {
        id: rules
        visible: text !== ""
        interactive: false
        dim: true
        text: {
            const r = [];
            const c = EverydayConfig.keepAwake;
            if ((c.apps ?? []).length > 0)
                r.push(KeepAwake.appRule !== "" ? `${Apps.name(KeepAwake.appRule)} is open` : "while chosen apps are open");
            if (c.onAC)
                r.push(KeepAwake.acRule ? "on power" : "while on power");
            if (c.externalDisplay)
                r.push(KeepAwake.displayRule ? "a display is connected" : "while a display is connected");
            return r.length ? `Also awake ${r.join(", ")}` : "";
        }
    }

    PanelSeparator {}
    PanelRow {
        text: "Keep Awake Settings…"
        onClicked: root.openSettings("everyday")
    }
}
