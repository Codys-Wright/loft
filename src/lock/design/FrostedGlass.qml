import QtQuick
import QtQuick.Effects
import qs.services
import qs.components

// GlassSurface over an in-scene blur of `backdrop`. On the desktop the
// compositor blurs what is behind a glass surface; a lock or login screen is
// one opaque surface, so the frost has to be rendered here: a blurred copy
// of the backdrop region under this item, clipped to the rounded shape,
// with the theme's glass tint/border/highlight on top.
Item {
    id: root

    required property Item backdrop
    property real radius: Theme.radius
    property real strength: 1.0
    property bool showHighlight: true

    // Re-evaluated when this item or its ancestors move (layout, resize).
    // Transient transforms (the shake) don't re-sample — the frost of a
    // smooth wallpaper can't visibly lag in 400 ms.
    readonly property rect region: {
        void [x, y, width, height, parent?.x, parent?.y, parent?.width, parent?.height, backdrop?.width, backdrop?.height];
        return backdrop ? mapToItem(backdrop, 0, 0, width, height) : Qt.rect(0, 0, 0, 0);
    }

    ShaderEffectSource {
        id: snapshot
        visible: false
        sourceItem: Theme.blur ? root.backdrop : null
        sourceRect: root.region
    }

    Rectangle {
        id: shape
        anchors.fill: parent
        visible: false
        radius: root.radius
        layer.enabled: true
    }

    MultiEffect {
        anchors.fill: parent
        visible: Theme.blur
        source: snapshot
        blurEnabled: true
        blur: 1.0
        blurMax: 64
        saturation: 0.15
        maskEnabled: true
        maskSource: shape
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
    }

    GlassSurface {
        anchors.fill: parent
        radius: root.radius
        strength: root.strength
        showHighlight: root.showHighlight
    }
}
