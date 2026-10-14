import QtQuick
import QtQuick.Layouts
import qs.components
import qs.controls
import qs.services

// Island page: quick toggles from the Controls model — Do Not Disturb, Keep
// Awake, microphones, screen recording, the focus timer (those whose module
// is on). Clicking does what the Control Center tile does (ControlActions).
Item {
    id: root

    readonly property var items: [
        { id: "focus", label: "Do Not Disturb", icon: "󰂛" },
        { id: "caffeine", label: "Keep Awake", icon: "󰅶" },
        { id: "micMute", label: "Microphones", icon: "" },
        { id: "record", label: "Record", icon: "󰻃" },
        { id: "focusTimer", label: "Focus Timer", icon: "󰔟" }
    ].filter(c => Controls.available(c.id))

    function on(id) {
        switch (id) {
        case "focus":
            return Panels.doNotDisturb;
        case "micMute":
            return Sound.micsMuted;
        }
        return Controls.active(id);
    }

    function status(id) {
        switch (id) {
        case "focus":
            return Panels.doNotDisturb ? "On" : "Off";
        case "micMute":
            return Sound.micsMuted ? "Muted" : Sound.recording ? "In use" : "On";
        }
        return Controls.status(id);
    }

    RowLayout {
        anchors {
            fill: parent
            leftMargin: 14
            rightMargin: 14
            bottomMargin: 14
        }
        spacing: 0

        Repeater {
            model: root.items

            delegate: ColumnLayout {
                id: tile
                required property var modelData
                readonly property bool active: root.on(modelData.id)
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: 6

                IslandButton {
                    Layout.alignment: Qt.AlignHCenter
                    size: 54
                    on: tile.active
                    tint: tile.modelData.id === "record" ? Theme.urgent : tile.modelData.id === "micMute" ? Theme.warn : Theme.accent
                    icon: tile.modelData.id === "micMute" ? Controls.iconOf("micMute") : tile.modelData.id === "focus" ? "󰂛" : tile.modelData.icon
                    onClicked: ControlActions.trigger(tile.modelData.id)
                }

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: tile.modelData.label
                    color: Theme.islandText
                    font.family: Theme.fontUi
                    font.pixelSize: 11
                    font.weight: Font.DemiBold
                }

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: root.status(tile.modelData.id)
                    color: Theme.islandSubtext
                    font.family: Theme.fontUi
                    font.pixelSize: 10
                    font.features: { "tnum": 1 }
                }
            }
        }
    }
}
