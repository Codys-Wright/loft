import QtQuick
import qs.services

// The Liquid Glass material: a tinted, semi-transparent fill (the compositor
// blurs behind it — the owning window adds the surface to its blurRegion),
// a hairline border and a specular highlight along the top edge.
// Ported from javiiervm/dotfiles' GlassSurface; all values come from Theme.
Rectangle {
    id: root

    // Strength relative to the theme's glass opacity (1 = as the theme says);
    // hover/active states nudge it up.
    property real strength: 1.0
    property bool showBorder: true
    property bool showHighlight: true

    radius: Theme.radius
    color: Theme.withAlpha(Theme.glassFill, Math.min(1, Theme.glassOpacity * strength))
    border.width: showBorder ? 1 : 0
    border.color: Theme.glassBorder

    Behavior on color {
        ColorAnimation {
            duration: 180
        }
    }

    Rectangle {
        visible: root.showHighlight
        anchors {
            left: parent.left
            right: parent.right
            top: parent.top
            leftMargin: root.radius / 2
            rightMargin: root.radius / 2
            topMargin: 1
        }
        height: 1
        color: Theme.withAlpha(Theme.glassBorder, Theme.glassBorder.a * 0.8)
    }
}
