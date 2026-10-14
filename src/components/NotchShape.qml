import QtQuick
import QtQuick.Shapes

// A notch: a shape hanging from the top edge of the screen, flush with it,
// rounded only at the bottom, with concave "shoulders" (inverse fillets)
// where it meets the edge, so it flows into the edge instead of meeting it
// at a hard 90° (the MacBook notch; the Dynamic Island's attached style).
//
// The item's own width × height is the body: anchor it, mask it and lay out
// content in it as usual. The shoulders reach `shoulder` px past its left and
// right edges, outside the item, so they never take input in a mask built
// from the body. The outline is stroked along the sides and the bottom only,
// never along the edge it hangs from. Animate radius / shoulder / size and
// the one shape morphs.
Item {
    id: root

    property color color: "#000000"
    // Bottom corners.
    property real radius: 12
    // Concave top corners; 0 = a plain square top.
    property real shoulder: 6
    property color borderColor: "transparent"
    property real borderWidth: 0

    // Clamped so the corners never cross on a small or animating body.
    readonly property real s: Math.max(0, Math.min(shoulder, height / 2))
    readonly property real r: Math.max(0, Math.min(radius, width / 2, height - s))

    Shape {
        id: shape
        x: -root.s
        width: root.width + 2 * root.s
        height: root.height
        preferredRendererType: Shape.CurveRenderer

        readonly property real w: root.width
        readonly property real h: root.height
        readonly property real s: root.s
        readonly property real r: root.r

        // Fill: the whole outline, top edge included.
        ShapePath {
            fillColor: root.color
            strokeColor: "transparent"
            strokeWidth: 0
            startX: 0
            startY: 0

            PathLine {
                x: shape.w + 2 * shape.s
                y: 0
            }
            PathArc {
                x: shape.w + shape.s
                y: shape.s
                radiusX: shape.s
                radiusY: shape.s
                direction: PathArc.Counterclockwise
            }
            PathLine {
                x: shape.w + shape.s
                y: shape.h - shape.r
            }
            PathArc {
                x: shape.w + shape.s - shape.r
                y: shape.h
                radiusX: shape.r
                radiusY: shape.r
            }
            PathLine {
                x: shape.s + shape.r
                y: shape.h
            }
            PathArc {
                x: shape.s
                y: shape.h - shape.r
                radiusX: shape.r
                radiusY: shape.r
            }
            PathLine {
                x: shape.s
                y: shape.s
            }
            PathArc {
                x: 0
                y: 0
                radiusX: shape.s
                radiusY: shape.s
                direction: PathArc.Counterclockwise
            }
        }

        // Outline: inset by half the stroke so it sits inside the body like
        // a Rectangle's border; open along the top edge.
        ShapePath {
            id: outline
            readonly property real d: root.borderWidth / 2

            fillColor: "transparent"
            strokeColor: root.borderWidth > 0 ? root.borderColor : "transparent"
            strokeWidth: root.borderWidth
            capStyle: ShapePath.FlatCap
            startX: 0
            startY: -d

            PathArc {
                x: shape.s + outline.d
                y: shape.s
                radiusX: shape.s + outline.d
                radiusY: shape.s + outline.d
            }
            PathLine {
                x: shape.s + outline.d
                y: shape.h - Math.max(shape.r, outline.d)
            }
            PathArc {
                x: shape.s + Math.max(shape.r, outline.d)
                y: shape.h - outline.d
                radiusX: Math.max(0, shape.r - outline.d)
                radiusY: Math.max(0, shape.r - outline.d)
                direction: PathArc.Counterclockwise
            }
            PathLine {
                x: shape.w + shape.s - Math.max(shape.r, outline.d)
                y: shape.h - outline.d
            }
            PathArc {
                x: shape.w + shape.s - outline.d
                y: shape.h - Math.max(shape.r, outline.d)
                radiusX: Math.max(0, shape.r - outline.d)
                radiusY: Math.max(0, shape.r - outline.d)
                direction: PathArc.Counterclockwise
            }
            PathLine {
                x: shape.w + shape.s - outline.d
                y: shape.s
            }
            PathArc {
                x: shape.w + 2 * shape.s
                y: -outline.d
                radiusX: shape.s + outline.d
                radiusY: shape.s + outline.d
            }
        }
    }
}
