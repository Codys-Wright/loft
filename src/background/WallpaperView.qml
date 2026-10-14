import QtQuick
import QtMultimedia
import qs.services

// What a wallpaper surface draws: `path`'s image cropped around its interest
// (Vibes.focusFor: the user's per-role override for `screenName`, else the
// plan's framing) rather than its center, else the theme's gradient. Image
// changes crossfade (~400 ms); the outgoing image stays until the incoming
// one has decoded, so there is no flash.
//
// A live wallpaper (Vibes.videoFor: a same-stem video next to the still)
// plays muted and looping over its still, with the still's crop: the video
// must have the still's aspect. It plays only while `playVideo` (the surface
// is what the screen shows); otherwise it holds its frame, and the still
// shows until the first frame is up.
//
// `decodeScale` < 1 decodes the image smaller (sourceSize × scale) and draws
// it scaled back up: the overview shows workspaces at its zoom, so a
// workspace seen only there needs no full-size copy (WorkspaceWallpapers).
// Such a surface never loads its video.
Item {
    id: root

    // Absolute path, "~/…" or "" (the gradient).
    property string path: ""
    // The screen this is drawn on: picks its role's focus override.
    property string screenName: ""
    property real decodeScale: 1
    property bool playVideo: true
    readonly property string source: Vibes.url(path)
    readonly property bool videoAllowed: decodeScale >= 1
    // The current image has decoded (or there is none: the gradient).
    readonly property bool ready: source === "" || (flip ? a : b).status === Image.Ready
    // Bytes of decoded image data held (both layers), for the stats.
    readonly property real decodedBytes: a.bytes + b.bytes

    // Gradient fallback (no image), with soft color fields for the blur.
    Item {
        anchors.fill: parent
        visible: root.source === ""

        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                orientation: Gradient.Vertical
                GradientStop { position: 0.0; color: Theme.wallpaperGradient[0] ?? Theme.bg }
                GradientStop { position: 0.55; color: Theme.wallpaperGradient[1] ?? Theme.surface }
                GradientStop { position: 1.0; color: Theme.wallpaperGradient[2] ?? Theme.overlay }
            }
        }

        Repeater {
            model: [
                { x: 0.18, y: 0.30, size: 0.45, color: Theme.accent },
                { x: 0.62, y: 0.95, size: 0.55, color: Theme.accent2 }
            ]
            delegate: Rectangle {
                required property var modelData
                readonly property real d: Math.min(root.width, root.height) * modelData.size
                width: d
                height: d
                radius: d / 2
                x: root.width * modelData.x - d / 2
                y: root.height * modelData.y - d / 2
                color: Theme.withAlpha(modelData.color, 0.35)
            }
        }
    }

    function videoUrl(p) {
        return videoAllowed ? Vibes.url(Vibes.videoFor(p)) : "";
    }

    // How a layer is fitted: its crop focus, and for fit "native" the image's
    // size (drawn 1:1, scaled up only to cover the screen). Unknown size:
    // cover, until the plan brings it.
    function fitLayer(layer) {
        layer.crop = Vibes.focusFor(path, screenName);
        const size = Vibes.sizeFor(path);
        layer.natural = Vibes.fitFor(path) === "native" && size ? size : null;
    }

    // Two images: `flip` says which one is current (true = a). The outgoing
    // one stays until the incoming one has loaded, then they crossfade.
    property bool flip: true
    onSourceChanged: {
        if ((flip ? a : b).source.toString() === source)
            return;
        flip = !flip;
        const layer = flip ? a : b;
        layer.crop = Vibes.focusFor(path, screenName);
        layer.video = videoUrl(path);
        layer.source = source;
    }
    Component.onCompleted: {
        a.crop = Vibes.focusFor(path, screenName);
        a.video = videoUrl(path);
        a.source = source;
    }

    // Once the incoming image shows, the outgoing one lets go of its pixels
    // (and its video).
    Timer {
        id: release
        interval: 450
        onTriggered: {
            const old = root.flip ? b : a;
            if (old.status === Image.Ready && old.opacity === 0) {
                old.source = "";
                old.video = "";
            }
        }
    }
    onReadyChanged: if (ready)
        release.restart()

    // A plan arriving later (framing, a paired video), a focus override or a
    // new decode scale re-fits what is showing.
    function refit() {
        const cur = flip ? a : b;
        cur.crop = Vibes.focusFor(path, screenName);
        const v = videoUrl(path);
        if (cur.video !== v)
            cur.video = v;
    }
    onVideoAllowedChanged: refit()
    Connections {
        target: Vibes
        function onPlanChanged() {
            root.refit();
        }
    }
    Connections {
        target: Settings
        function onWallpaperFramingChanged() {
            root.refit();
        }
    }

    component Layer: Item {
        id: layer
        property alias source: img.source
        // The live wallpaper's video URL; "" = a still.
        property string video: ""
        // The layer showing (not the outgoing one): only it plays.
        property bool current: false
        readonly property alias status: img.status
        readonly property real bytes: img.status === Image.Ready ? img.implicitWidth * img.implicitHeight * 4 : 0
        // The image point (0..1) to keep near the screen's center.
        property var crop: [0.5, 0.5]

        anchors.fill: parent
        clip: true
        visible: opacity > 0
        Behavior on opacity {
            NumberAnimation {
                duration: 400
                easing.type: Easing.InOutQuad
            }
        }

        // Decoded to cover the screen × decodeScale (PreserveAspectCrop
        // scales to cover sourceSize, keeping the aspect) and drawn at screen
        // size, shifted so the focus sits as close to the center as the
        // image's edges allow.
        Image {
            id: img
            readonly property real s: Math.max(0.05, root.decodeScale)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            retainWhileLoading: true
            sourceSize: Qt.size(Math.ceil(root.width * s), Math.ceil(root.height * s))
            width: Math.max(implicitWidth / s, root.width)
            height: Math.max(implicitHeight / s, root.height)
            smooth: true
            x: Math.min(0, Math.max(root.width - width, root.width / 2 - layer.crop[0] * width))
            y: Math.min(0, Math.max(root.height - height, root.height / 2 - layer.crop[1] * height))
        }

        // The video in the still's rectangle (same aspect, so the same crop).
        // No audio output: muted.
        MediaPlayer {
            id: player
            source: layer.video
            loops: MediaPlayer.Infinite
            videoOutput: out
            readonly property bool wanted: layer.video !== "" && layer.current && root.playVideo
            onWantedChanged: wanted ? play() : pause()
            onMediaStatusChanged: if (mediaStatus === MediaPlayer.LoadedMedia && wanted)
                play()
        }
        VideoOutput {
            id: out
            x: img.x
            y: img.y
            width: img.width
            height: img.height
            fillMode: VideoOutput.Stretch
            // Up once playback has started; the still is beneath until then.
            opacity: layer.video !== "" && player.hasVideo && player.playbackState !== MediaPlayer.StoppedState ? 1 : 0
            Behavior on opacity {
                NumberAnimation {
                    duration: 300
                }
            }
        }
    }

    Layer {
        id: a
        current: root.flip
        opacity: root.source !== "" && a.status === Image.Ready && (root.flip || b.status !== Image.Ready) ? 1 : 0
    }

    Layer {
        id: b
        current: !root.flip
        opacity: root.source !== "" && b.status === Image.Ready && (!root.flip || a.status !== Image.Ready) ? 1 : 0
    }
}
