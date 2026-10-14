import QtQuick
import qs.services

// Close / hide / full screen, Golden Gate style: Aqua-like Liquid Glass
// buttons (a colored bead with a specular highlight and a darker rim), the
// glyphs appear while the pointer is over the group, grey in an inactive
// window. The owner decides what each does (WindowChrome wires them).
Row {
    id: root

    // false: the window is in the background — grey beads until hovered.
    property bool active: true
    property bool canHide: true
    property bool canFullscreen: true
    property real size: 13

    signal close
    signal hide
    signal fullscreen

    spacing: 8

    // Hovering anywhere over the group shows all three glyphs, as on macOS.
    readonly property bool hovered: groupHover.hovered

    HoverHandler {
        id: groupHover
    }

    component Bead: Item {
        id: bead
        property color tint
        property string glyph
        property bool available: true
        signal clicked

        width: root.size
        height: root.size

        readonly property bool lit: available && (root.active || root.hovered)
        readonly property color base: lit ? tint : Theme.trafficInactive

        // The bead: base color, darker toward the bottom (glass depth).
        Rectangle {
            anchors.fill: parent
            radius: width / 2
            gradient: Gradient {
                GradientStop {
                    position: 0
                    color: bead.lit ? Qt.lighter(bead.base, 1.12) : bead.base
                }
                GradientStop {
                    position: 1
                    color: bead.lit ? Qt.darker(bead.base, 1.12) : bead.base
                }
            }
            border.width: 1
            border.color: bead.lit ? Theme.withAlpha(Qt.darker(bead.tint, 1.6), 0.55) : Theme.withAlpha("#000000", 0.12)
            Behavior on border.color {
                ColorAnimation {
                    duration: 120
                }
            }
        }

        // Specular highlight: a soft bright lens along the top.
        Rectangle {
            visible: bead.lit
            anchors.horizontalCenter: parent.horizontalCenter
            y: parent.height * 0.1
            width: parent.width * 0.6
            height: parent.height * 0.36
            radius: height / 2
            gradient: Gradient {
                GradientStop {
                    position: 0
                    color: Theme.withAlpha("#ffffff", 0.7)
                }
                GradientStop {
                    position: 1
                    color: Theme.withAlpha("#ffffff", 0.0)
                }
            }
        }

        Text {
            anchors.centerIn: parent
            anchors.verticalCenterOffset: 0.5
            visible: root.hovered && bead.available
            text: bead.glyph
            color: Theme.withAlpha("#000000", 0.6)
            font.family: Theme.fontIcons
            font.pixelSize: Math.round(root.size * 0.72)
        }

        MouseArea {
            anchors.fill: parent
            anchors.margins: -2
            enabled: bead.available
            onClicked: bead.clicked()
        }
    }

    Bead {
        tint: Theme.trafficClose
        glyph: "󰅖"
        onClicked: root.close()
    }

    Bead {
        tint: Theme.trafficHide
        glyph: "󰍴"
        available: root.canHide
        onClicked: root.hide()
    }

    Bead {
        tint: Theme.trafficZoom
        glyph: "󰁌"
        available: root.canFullscreen
        onClicked: root.fullscreen()
    }
}
