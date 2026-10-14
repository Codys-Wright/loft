import QtQuick
import QtQuick.Effects
import Quickshell.Widgets

// An app icon drawn the way macOS draws menu bar icons: as a "template" in
// the bar's text color, so colored tray icons sit in the bar like the rest.
//
// Two ways, picked per icon by looking at its pixels once:
//   "mask" — a symbolic / mostly transparent icon: only its shape (alpha)
//            counts, filled with `color`.
//   "luma" — an opaque icon (a round badge, a full square — Nextcloud,
//            many Electron apps): filling its alpha would leave a solid
//            blob, so it keeps its detail as grayscale, its luminance
//            squeezed into the bar color's light (or dark) range.
// `template: false` shows the original colors.
Item {
    id: root

    property string source
    property real size: 16
    property color color: "white"
    property bool template: true
    // "mask" | "luma" — from the analysis below (mask until it's known).
    property string mode: "mask"
    // Share of the box covered by (near) opaque pixels.
    property real coverage: 0

    readonly property bool lightInk: (0.299 * color.r + 0.587 * color.g + 0.114 * color.b) > 0.5

    implicitWidth: size
    implicitHeight: size

    IconImage {
        id: image
        anchors.fill: parent
        implicitSize: root.size
        source: root.source
        visible: !root.template
    }

    // Symbolic: every opaque pixel pushed to white, then tinted.
    MultiEffect {
        visible: root.template && root.mode === "mask"
        anchors.fill: parent
        source: image
        brightness: 1.0
        colorization: 1.0
        colorizationColor: root.color
    }

    // Opaque: grayscale, contrast reduced, then shifted toward the ink —
    // luminance L lands in about [0.3, 1] for light ink, [0, 0.7] for dark,
    // so the badge reads in the bar's tone and its inner detail survives.
    MultiEffect {
        visible: root.template && root.mode === "luma"
        anchors.fill: parent
        source: image
        saturation: -1.0
        contrast: -0.3
        brightness: root.lightInk ? 0.15 : -0.15
    }

    // ── Analysis: read the icon's alpha once per source ──────────────────
    readonly property int probeSize: 24
    function analyze() {
        mode = "mask";
        coverage = 0;
        if (source === "")
            return;
        // Already in the canvas cache (another icon, a reload): no
        // imageLoaded signal comes, so paint right away.
        if (probe.isImageLoaded(source)) {
            probe.loaded = source;
            probe.requestPaint();
        } else
            probe.loadImage(source);
    }
    onSourceChanged: analyze()
    Component.onCompleted: analyze()

    Canvas {
        id: probe
        width: root.probeSize
        height: root.probeSize
        visible: false
        property string loaded: ""

        onImageLoaded: {
            loaded = root.source;
            requestPaint();
        }
        onPaint: {
            if (loaded === "" || !isImageLoaded(loaded))
                return;
            const n = root.probeSize;
            const ctx = getContext("2d");
            ctx.clearRect(0, 0, n, n);
            ctx.drawImage(loaded, 0, 0, n, n);
            if (loaded !== root.source)
                return;
            const d = ctx.getImageData(0, 0, n, n).data;
            let opaque = 0;
            for (let i = 3; i < d.length; i += 4)
                if (d[i] > 200)
                    opaque++;
            root.coverage = opaque / (n * n);
            // A badge or a full square covers most of its box; symbolic
            // glyphs leave most of it transparent.
            root.mode = root.coverage > 0.5 ? "luma" : "mask";
        }
    }
}
