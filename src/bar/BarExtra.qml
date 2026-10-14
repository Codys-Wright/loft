import QtQuick
import qs.components
import qs.controls
import qs.menubar
import qs.services

// One status item in the bar: a monochrome glyph (or short text) with the
// menu-title highlight while its panel is open. Panels open on click and
// switch on hover while any bar menu is open; ⌥-click opens with details.
// Toggles and actions just act. `content` replaces the glyph (badges…).
Item {
    id: root

    required property string controlId
    property string screenName: ""
    property string glyph: Controls.iconOf(controlId)
    property string label: ""
    property color fg: Theme.barTextFor(screenName)
    property bool dimmed: false
    default property alias content: extraContent.data

    readonly property var control: Controls.control(controlId)
    readonly property bool isPanel: control?.kind === "panel"
    readonly property bool lit: MenuState.open && MenuState.mode === "extra" && MenuState.extra === controlId && MenuState.screen === screenName

    // Mouse hooks for items with more buttons (Sound: middle-click mute…).
    signal middleClicked
    signal rightClicked
    signal wheeled(var wheel)

    implicitWidth: Math.max(22, (label !== "" ? text.implicitWidth : icon.implicitWidth) + 12)
    implicitHeight: 22

    function open(withDetails) {
        if (controlId === "controlcenter") {
            MenuState.close();
            Panels.toggleControlCenter(screenName);
        } else if (isPanel) {
            MenuState.toggleExtra(screenName, controlId, root, withDetails);
        } else {
            MenuState.close();
            ControlActions.trigger(controlId);
        }
    }

    Rectangle {
        anchors.fill: parent
        radius: 6
        color: root.lit ? Theme.withAlpha(root.fg, 0.18) : mouse.containsMouse ? Theme.withAlpha(root.fg, 0.08) : "transparent"
        Behavior on color {
            ColorAnimation {
                duration: 120
            }
        }
    }

    Icon {
        id: icon
        visible: root.label === ""
        anchors.centerIn: parent
        text: root.glyph
        size: 15
        color: root.fg
        opacity: root.dimmed ? 0.5 : 1
    }

    Text {
        id: text
        visible: root.label !== ""
        anchors.centerIn: parent
        text: root.label
        color: root.fg
        opacity: root.dimmed ? 0.5 : 1
        font.family: Theme.fontUi
        font.pixelSize: 12
        font.weight: Font.DemiBold
    }

    Item {
        id: extraContent
        anchors.fill: parent
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: event => {
            if (event.button === Qt.MiddleButton)
                root.middleClicked();
            else if (event.button === Qt.RightButton)
                root.rightClicked();
            else
                root.open((event.modifiers & Qt.AltModifier) !== 0);
        }
        onWheel: wheel => root.wheeled(wheel)
        onContainsMouseChanged: if (containsMouse && root.isPanel)
            MenuState.hoverExtra(root.screenName, root.controlId, root)
    }
}
