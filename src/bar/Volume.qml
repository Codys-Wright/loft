import QtQuick
import Quickshell.Services.Pipewire
import qs.components
import qs.services

// Default output volume: scroll to change, click to mute.
Item {
    id: root

    readonly property PwNode sink: Pipewire.defaultAudioSink
    readonly property bool ready: sink?.ready ?? false
    readonly property real volume: ready ? sink.audio.volume : 0
    readonly property bool muted: ready ? sink.audio.muted : true

    implicitWidth: 22
    implicitHeight: 24

    // Bind the node so its audio properties are live.
    PwObjectTracker {
        objects: root.sink ? [root.sink] : []
    }

    Icon {
        anchors.centerIn: parent
        size: 16
        color: root.muted ? Theme.subtext : Theme.text
        text: {
            if (root.muted || root.volume <= 0)
                return "󰝟";
            const desc = (root.sink?.description ?? "").toLowerCase();
            if (desc.includes("headphone") || desc.includes("bluez") || desc.includes("buds"))
                return "󰋋";
            return root.volume >= 0.66 ? "󰕾" : root.volume >= 0.33 ? "󰖀" : "󰕿";
        }
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: if (root.ready)
            root.sink.audio.muted = !root.sink.audio.muted
        onWheel: wheel => {
            if (!root.ready)
                return;
            const step = wheel.angleDelta.y > 0 ? 0.05 : -0.05;
            root.sink.audio.volume = Math.max(0, Math.min(1, root.sink.audio.volume + step));
        }
    }
}
