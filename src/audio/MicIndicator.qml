import QtQuick
import qs.components
import qs.services

// Bar mic indicator (Feature "micTools"): shown while an app records (amber,
// like macOS's privacy dot) or the microphones are muted (struck through).
// Click: mute / unmute all microphones; right-click: the mixer.
Item {
    id: root

    property string screenName: ""
    // Show even while idle (menu bar: "only when active" off).
    property bool always: false

    visible: Features.on("micTools") && Settings.sound.micIndicator && (always || Sound.recording || Sound.micsMuted)
    implicitWidth: 20
    implicitHeight: 24

    Icon {
        anchors.centerIn: parent
        size: 16
        text: Sound.micsMuted ? "󰍭" : "󰍬"
        color: Sound.micsMuted ? Theme.barSubtextFor(screenName) : Sound.recording ? Theme.warn : Theme.barTextFor(screenName)
    }

    // Recording dot.
    Rectangle {
        visible: Sound.recording && !Sound.micsMuted
        anchors {
            right: parent.right
            top: parent.top
            topMargin: 2
            rightMargin: -1
        }
        width: 6
        height: 6
        radius: 3
        color: Theme.warn
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        anchors.margins: -4
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: event => {
            if (event.button === Qt.RightButton && Features.on("mixer"))
                Sound.toggleMixer(root.screenName);
            else if (event.button === Qt.LeftButton)
                Sound.setMicsMuted(!Sound.micsMuted);
        }
    }
}
