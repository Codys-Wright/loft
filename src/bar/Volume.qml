import QtQuick
import Quickshell.Services.Pipewire
import qs.components
import qs.services

// Default output volume: scroll to change, click to mute, right-click for
// the mixer (Feature "mixer").
Item {
    id: root

    readonly property PwNode sink: Pipewire.defaultAudioSink
    readonly property bool ready: sink?.ready ?? false
    readonly property real volume: ready ? sink.audio.volume : 0
    readonly property bool muted: ready ? sink.audio.muted : true
    // The bar's output, for the mixer to open on.
    property string screenName: ""

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
            if (Sound.isPersonal(root.sink))
                return "󰋋";
            return root.volume >= 0.66 ? "󰕾" : root.volume >= 0.33 ? "󰖀" : "󰕿";
        }
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: event => {
            if (event.button === Qt.RightButton) {
                if (Features.on("mixer"))
                    Sound.toggleMixer(root.screenName);
            } else if (root.ready) {
                root.sink.audio.muted = !root.sink.audio.muted;
            }
        }
        onWheel: wheel => {
            if (!root.ready)
                return;
            const step = wheel.angleDelta.y > 0 ? 0.05 : -0.05;
            root.sink.audio.volume = Math.max(0, Math.min(1, root.sink.audio.volume + step));
        }
    }
}
