import QtQuick
import qs.components
import qs.services

// Workspace indicator for one output: a dot per niri workspace (ghost when
// empty, filled when it has windows) and a sliding "pacman" pill on the
// active one. Design from javiiervm/dotfiles; data from niri.
Item {
    id: root

    required property string output

    // Bar colors for this output (light/dark from the wallpaper, Theme).
    readonly property color fg: Theme.barTextFor(output)

    readonly property var workspaces: Niri.workspacesOn(output)
    readonly property int activeIndex: Math.max(0, workspaces.findIndex(w => w.is_active))

    readonly property int cell: 24
    readonly property int gap: 10

    implicitWidth: workspaces.length * cell + Math.max(0, workspaces.length - 1) * gap
    implicitHeight: cell

    Row {
        spacing: root.gap

        Repeater {
            model: root.workspaces

            delegate: Rectangle {
                id: dot

                required property var modelData
                required property int index

                readonly property bool occupied: Niri.windowsOn(modelData.id).length > 0

                width: root.cell
                height: root.cell
                radius: root.cell / 2
                color: mouse.containsMouse ? Theme.withAlpha(root.fg, 0.14) : "transparent"

                // Fade the glyph the pacman is about to "eat".
                opacity: {
                    const d = Math.abs(pacman.x + pacman.width / 2 - (x + width / 2));
                    return d < 22 ? Math.pow(d / 22, 0.55) : 1;
                }

                Behavior on color {
                    ColorAnimation {
                        duration: 200
                    }
                }

                Icon {
                    anchors.centerIn: parent
                    text: dot.modelData.is_urgent ? "󰀦" : dot.occupied ? "󰧞" : "󰊠"
                    color: dot.modelData.is_urgent ? Theme.urgent : Theme.barSubtextFor(root.output)
                    size: 16
                }

                MouseArea {
                    id: mouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Niri.focusWorkspace(dot.modelData.id)
                }
            }
        }
    }

    Rectangle {
        id: pacman
        visible: root.workspaces.length > 0
        width: root.cell + 8
        height: root.cell
        radius: root.cell / 2
        x: root.activeIndex * (root.cell + root.gap) - 4
        color: root.fg

        Behavior on x {
            NumberAnimation {
                duration: 250
                easing.type: Easing.OutQuint
            }
        }

        Icon {
            anchors.centerIn: parent
            text: "󰮯"
            color: Theme.barOnTextFor(root.output)
            size: 16
        }
    }
}
