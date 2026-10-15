import QtQuick
import qs.services

// One of the island's content layers (collapsed, banner, HUD, expanded …),
// choreographed with the shape's morph: a layer that goes away fades out at
// once, a layer that comes in waits `inDelay` (until the shape is mostly
// there) and then fades and grows in from `fromScale`. Transitions, not
// Behaviors, so the delay only ever applies to the incoming direction.
//
// Lay the layer out at its own final size (not the animating pill's), so
// nothing reflows while the shape morphs: the pill clips it.
Item {
    id: root

    property bool shown: false
    property int inDelay: 0
    property int inDuration: 200
    property int outDuration: 90
    property real fromScale: 1

    // Fully in (no transition running): safe to animate things inside.
    readonly property bool settled: shown && opacity >= 1

    visible: opacity > 0
    opacity: 0
    scale: fromScale
    transformOrigin: Item.Top

    states: State {
        name: "on"
        when: root.shown
        PropertyChanges {
            root.opacity: 1
            root.scale: 1
        }
    }

    transitions: [
        Transition {
            to: "on"
            SequentialAnimation {
                PauseAnimation {
                    // Reduce Motion: the shape jumps; the content cross-fades,
                    // the outgoing layer first so the two never overlap.
                    duration: Motion.ms(Motion.reduce ? 90 : root.inDelay)
                }
                ParallelAnimation {
                    NumberAnimation {
                        property: "opacity"
                        duration: Motion.ms(Motion.reduce ? 150 : root.inDuration)
                        easing.type: Easing.OutCubic
                    }
                    NumberAnimation {
                        property: "scale"
                        duration: Motion.reduce ? 0 : Motion.ms(root.inDuration + 60)
                        easing.type: Easing.OutCubic
                    }
                }
            }
        },
        Transition {
            from: "on"
            NumberAnimation {
                properties: "opacity,scale"
                duration: Motion.ms(Motion.reduce ? 90 : root.outDuration)
                easing.type: Easing.OutCubic
            }
        }
    ]
}
