import QtQuick
import QtQuick.Layouts
import qs.services

// Keyboard layouts (niri's xkb layouts): pick one.
ColumnLayout {
    id: root

    property bool details: false
    property bool shown: true
    property bool inMenu: true
    signal dismiss
    signal openSettings(string section)

    spacing: 0

    readonly property var names: Compositor.keyboardLayouts.names ?? []

    Repeater {
        model: root.names
        delegate: PanelRow {
            required property var modelData
            required property int index
            text: modelData
            checked: index === Compositor.keyboardLayouts.current_idx
            onClicked: {
                Compositor.switchKeyboardLayout(index);
                root.dismiss();
            }
        }
    }

    PanelSeparator {}
    PanelRow {
        text: "Keyboard Settings…"
        onClicked: root.openSettings("input")
    }
}
