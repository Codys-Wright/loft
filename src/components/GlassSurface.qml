import QtQuick
import QtQuick.Effects
import qs.services

// The Liquid Glass material (docs/DESIGN-GOLDEN-GATE.md): a tinted,
// semi-transparent fill the compositor blurs behind (the owning window adds
// the surface to its blurRegion), a hairline, a darkened inner rim and a
// bright top specular for depth. Every value comes from Theme: the Liquid
// Glass slider (Theme.glass) sets fill, tint and text shadow together, and
// Reduce transparency (Theme.reduceTransparency) turns it into a flat opaque
// fill — no surface picks its own opacity.
//
// The window's blur: `BackgroundEffect.blurRegion: blur` always, and the
// Region's `item` turns null when the glass is gone (blur off, panel hidden,
// mid-animation). Never set blurRegion itself to null: that left the
// compositor blurring the last shape, a faint patch with no glass over it.
// A Region follows its item's x/y/size only, not opacity, scale or a moving
// parent, so drop the item while the surface fades, scales or slides.
Rectangle {
    id: root

    // Strength relative to the slider (1 = a plain surface; windows and
    // panels use more, cards inside them less); hover/active states nudge it.
    property real strength: 1.0
    property bool showBorder: true
    property bool showHighlight: true
    // The darkened inner rim. Off for flush strips (the menu bar).
    property bool showEdge: showBorder
    // false: an inactive window's glass, slightly dimmed (Golden Gate makes
    // the active window more distinct).
    property bool active: true
    // A soft shadow under the content (text, icons) once the glass is
    // clearer than the theme's default. A surface inside another one leaves
    // it to the outermost.
    property bool textShadow: true
    // Clear glass: a light frost over the blurred backdrop instead of the
    // theme's tint (the dock; Theme.clearFillFor), with a stronger specular.
    property bool clear: false

    default property alias content: body.data
    readonly property bool isGlassSurface: true
    property bool nested: false

    radius: Theme.radius
    color: clear ? Theme.clearFillFor(strength) : Theme.fillFor(strength)
    border.width: showBorder ? 1 : 0
    border.color: Theme.glassBorder

    Behavior on color {
        ColorAnimation {
            duration: 180
        }
    }

    Component.onCompleted: {
        for (let p = parent; p; p = p.parent) {
            if (p.isGlassSurface === true) {
                nested = true;
                break;
            }
        }
    }

    readonly property bool glassy: !Theme.reduceTransparency

    // Depth: a darker rim just inside the hairline.
    Rectangle {
        visible: root.glassy && root.showEdge && Theme.edgeDarken > 0
        anchors.fill: parent
        anchors.margins: root.border.width
        radius: Math.max(0, root.radius - root.border.width)
        color: "transparent"
        border.width: 1
        border.color: Theme.edgeColor
    }

    // Specular: a soft sheen down from the top edge …
    Rectangle {
        visible: root.glassy && root.showHighlight && Theme.specular > 0
        anchors {
            left: parent.left
            right: parent.right
            top: parent.top
            margins: root.border.width
        }
        height: Math.min(root.height / 2, Math.max(root.radius * 1.6, 18))
        radius: Math.max(0, root.radius - root.border.width)
        gradient: Gradient {
            GradientStop {
                position: 0
                color: root.clear ? Theme.withAlpha("#ffffff", Math.min(1, Theme.sheenColor.a * 1.8)) : Theme.sheenColor
            }
            GradientStop {
                position: 1
                color: "transparent"
            }
        }
    }

    // … and a bright line along it, fading out toward the corners.
    Rectangle {
        visible: root.glassy && root.showHighlight && Theme.specular > 0
        anchors {
            left: parent.left
            right: parent.right
            top: parent.top
            leftMargin: root.radius * 0.5
            rightMargin: root.radius * 0.5
            topMargin: root.border.width
        }
        height: 1
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop {
                position: 0
                color: "transparent"
            }
            GradientStop {
                position: 0.2
                color: Theme.specularColor
            }
            GradientStop {
                position: 0.8
                color: Theme.specularColor
            }
            GradientStop {
                position: 1
                color: "transparent"
            }
        }
    }

    // Inactive: dim the glass (not the content).
    Rectangle {
        anchors.fill: parent
        radius: root.radius
        color: Theme.withAlpha(Theme.dark ? "#000000" : "#ffffff", Theme.inactiveDim)
        opacity: root.active ? 0 : 1
        visible: opacity > 0
        Behavior on opacity {
            NumberAnimation {
                duration: 180
            }
        }
    }

    // The surface's own children.
    Item {
        id: body
        anchors.fill: parent
        // Children that ask their parent for these keep working.
        readonly property real radius: root.radius
        readonly property color color: root.color

        layer.enabled: root.textShadow && !root.nested && Theme.textShadowStrength > 0.02
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Theme.textShadow
            shadowBlur: 0.35
            shadowVerticalOffset: 1
            shadowHorizontalOffset: 0
        }
    }
}
