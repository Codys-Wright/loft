import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// A settings row for one niri setting (NiriSettings.keys[key]): the hint
// says where the value comes from, and an overridden value gets a reset
// button that drops the override (back to the config / niri default).
SettingsRow {
    id: row
    property string key
    property string extraHint: ""
    readonly property var info: NiriSettings.keys[key] ?? null
    readonly property bool overridden: info?.source === "override"

    label: info?.label ?? key
    hintColor: overridden ? Theme.accent : Theme.subtext
    hint: {
        if (!info)
            return extraHint;
        let src = "";
        if (info.source === "override")
            src = "Changed here";
        else if (info.source === "config")
            src = `From ${(info.file ?? "").replace(/^.*\//, "")}:${info.line}`;
        else
            src = "niri default";
        return extraHint ? `${extraHint} · ${src}` : src;
    }

    Icon {
        visible: row.overridden
        text: "󰑓"
        size: 13
        color: resetHover.containsMouse ? Theme.accent : Theme.subtext
        Layout.rightMargin: 4

        MouseArea {
            id: resetHover
            anchors.fill: parent
            anchors.margins: -5
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: NiriSettings.unset(row.key)
        }
    }
}
