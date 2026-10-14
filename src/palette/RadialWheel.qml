import QtQuick
import QtQuick.Shapes
import qs.components
import qs.services

// Draws a radial menu (Radial.qml has the logic): a glass disc of slices
// around a hub that names the selection, the selected wedge lit, and — for
// a submenu — its items as glass bubbles on an outer arc. Also the preview
// in Settings → Radial Menu. The item is square; its center is the wheel's.
Item {
    id: wheel

    property var slices: []
    property int selMain: -1
    property int selChild: -1
    property int ring: -1
    property real radius: 136
    property real hub: radius * 0.34
    property real ringRadius: radius + 46
    property string caption: ""
    // The disc, for the window's blur region.
    readonly property alias disc: disc

    readonly property int n: slices.length
    readonly property real step: n > 0 ? 360 / n : 360
    readonly property real c: width / 2
    readonly property var ringItems: ring >= 0 && ring < n ? Radial.kids(slices[ring]) : []

    width: (ringRadius + 34) * 2
    height: width

    function rad(deg) {
        return (deg - 90) * Math.PI / 180;
    }

    GlassSurface {
        id: disc
        x: wheel.c - wheel.radius
        y: wheel.c - wheel.radius
        width: wheel.radius * 2
        height: width
        radius: wheel.radius
        strength: 1.6
        // GlassSurface's sheen is a rounded rect, wider than a circle's
        // top; a round one instead.
        showHighlight: false

        Rectangle {
            visible: !Theme.reduceTransparency && Theme.specular > 0
            anchors.fill: parent
            anchors.margins: 1
            radius: width / 2
            gradient: Gradient {
                GradientStop {
                    position: 0
                    color: Theme.sheenColor
                }
                GradientStop {
                    position: 0.45
                    color: "transparent"
                }
            }
        }
    }

    // The lit wedge.
    Shape {
        id: wedge
        anchors.fill: parent
        visible: wheel.selMain >= 0 && wheel.n > 0
        opacity: wheel.selChild >= 0 ? 0.55 : 1
        preferredRendererType: Shape.CurveRenderer
        property real a0: wheel.rad(wheel.selMain * wheel.step - wheel.step / 2 + (wheel.n > 1 ? 1.2 : 0))
        property real a1: wheel.rad(wheel.selMain * wheel.step + wheel.step / 2 - (wheel.n > 1 ? 1.2 : 0))
        readonly property real ro: wheel.radius - 5
        readonly property real ri: wheel.hub + 5
        Behavior on a0 {
            enabled: wheel.n > 1
            NumberAnimation {
                duration: 90
            }
        }
        Behavior on a1 {
            enabled: wheel.n > 1
            NumberAnimation {
                duration: 90
            }
        }

        ShapePath {
            fillColor: Theme.withAlpha(Theme.accent, 0.34)
            strokeColor: Theme.withAlpha(Theme.accent, 0.6)
            strokeWidth: 1
            startX: wheel.c + wedge.ri * Math.cos(wedge.a0)
            startY: wheel.c + wedge.ri * Math.sin(wedge.a0)
            PathLine {
                x: wheel.c + wedge.ro * Math.cos(wedge.a0)
                y: wheel.c + wedge.ro * Math.sin(wedge.a0)
            }
            PathArc {
                x: wheel.c + wedge.ro * Math.cos(wedge.a1)
                y: wheel.c + wedge.ro * Math.sin(wedge.a1)
                radiusX: wedge.ro
                radiusY: wedge.ro
                useLargeArc: wheel.step > 180
            }
            PathLine {
                x: wheel.c + wedge.ri * Math.cos(wedge.a1)
                y: wheel.c + wedge.ri * Math.sin(wedge.a1)
            }
            PathArc {
                x: wheel.c + wedge.ri * Math.cos(wedge.a0)
                y: wheel.c + wedge.ri * Math.sin(wedge.a0)
                radiusX: wedge.ri
                radiusY: wedge.ri
                direction: PathArc.Counterclockwise
                useLargeArc: wheel.step > 180
            }
        }
    }

    // Dividers between slices (drawn as one path).
    Shape {
        anchors.fill: parent
        visible: wheel.n > 1
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeColor: Theme.withAlpha(Theme.text, 0.09)
            strokeWidth: 1
            fillColor: "transparent"
            PathMultiline {
                paths: {
                    const out = [];
                    for (let i = 0; i < wheel.n; i++) {
                        const a = wheel.rad((i + 0.5) * wheel.step);
                        out.push([Qt.point(wheel.c + (wheel.hub + 8) * Math.cos(a), wheel.c + (wheel.hub + 8) * Math.sin(a)), Qt.point(wheel.c + (wheel.radius - 10) * Math.cos(a), wheel.c + (wheel.radius - 10) * Math.sin(a))]);
                    }
                    return out;
                }
            }
        }
    }

    // Slice icons.
    Repeater {
        model: wheel.slices
        delegate: Item {
            id: sl
            required property var modelData
            required property int index
            readonly property real a: wheel.rad(index * wheel.step)
            readonly property real r: (wheel.hub + wheel.radius) / 2
            readonly property bool selected: index === wheel.selMain
            readonly property bool on: !modelData.children && Actions.active(modelData.action ?? "")
            x: wheel.c + r * Math.cos(a) - width / 2
            y: wheel.c + r * Math.sin(a) - height / 2
            width: 40
            height: 40
            scale: selected ? 1.12 : 1
            Behavior on scale {
                NumberAnimation {
                    duration: 120
                    easing.type: Easing.OutQuart
                }
            }

            Rectangle {
                anchors.centerIn: parent
                width: 36
                height: 36
                radius: 18
                visible: sl.on
                color: Theme.accent
            }
            Icon {
                anchors.centerIn: parent
                text: Radial.sliceIcon(sl.modelData)
                size: 20
                color: sl.on ? Theme.bg : sl.selected ? Theme.text : Theme.withAlpha(Theme.text, 0.85)
            }
            // A submenu: a chevron pointing out, toward its ring.
            Icon {
                visible: !!sl.modelData.children
                x: parent.width / 2 - width / 2 + 25 * Math.cos(sl.a)
                y: parent.height / 2 - height / 2 + 25 * Math.sin(sl.a)
                text: "󰅂"
                size: 11
                rotation: sl.index * wheel.step - 90
                color: sl.selected ? Theme.text : Theme.subtext
            }
        }
    }

    // Hub: the selection's name.
    Rectangle {
        x: wheel.c - wheel.hub
        y: wheel.c - wheel.hub
        width: wheel.hub * 2
        height: width
        radius: wheel.hub
        color: Theme.withAlpha(Theme.text, wheel.selMain < 0 ? 0.1 : 0.05)
        border.width: 1
        border.color: Theme.withAlpha(Theme.text, 0.08)

        Text {
            anchors.centerIn: parent
            width: parent.width - 10
            text: wheel.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            maximumLineCount: 3
            elide: Text.ElideRight
            color: Theme.text
            font.family: Theme.fontUi
            font.pixelSize: wheel.radius < 120 ? 10 : 11
            font.weight: Font.DemiBold
        }
    }

    // Submenu ring: glass bubbles on an arc around the parent's direction.
    Repeater {
        model: wheel.ringItems
        delegate: Item {
            id: bub
            required property var modelData
            required property int index
            readonly property real a: wheel.rad(Radial.childAngle(wheel.ring, index, wheel.n, wheel.ringItems.length))
            readonly property bool selected: wheel.selChild === index
            readonly property bool on: Actions.active(modelData.action ?? "")
            x: wheel.c + wheel.ringRadius * Math.cos(a) - width / 2
            y: wheel.c + wheel.ringRadius * Math.sin(a) - height / 2
            width: 50
            height: 50
            opacity: 0
            scale: 0.6
            Component.onCompleted: {
                opacity = 1;
                scale = Qt.binding(() => bub.selected ? 1.14 : 1);
            }
            Behavior on opacity {
                NumberAnimation {
                    duration: 160
                }
            }
            Behavior on scale {
                NumberAnimation {
                    duration: 160
                    easing.type: Easing.OutBack
                }
            }

            GlassSurface {
                anchors.fill: parent
                radius: width / 2
                strength: 2.2
                color: bub.selected ? Theme.mix(Theme.fillFor(2.2), Theme.accent, 0.45) : bub.on ? Theme.mix(Theme.fillFor(2.2), Theme.accent, 0.25) : Theme.fillFor(2.2)
            }
            Icon {
                anchors.centerIn: parent
                text: Radial.sliceIcon(bub.modelData)
                size: 19
            }
        }
    }
}
