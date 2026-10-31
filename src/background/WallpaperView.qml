import QtQuick
import QtMultimedia
import Quickshell
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
// is what the screen shows) and VideoWallpapers lets it (it can be seen:
// not locked, idle, covered by an opaque window, …). Otherwise it is "ready
// in the background": the file is open (demuxed, no decoder: ~1 MB of VRAM)
// and the still shows; play() puts the first frame up in 0.1–0.3 s and it
// fades in over the still (a frame of the same video: ~0.4 % RMSE apart),
// so there is no flash. A video that played and then stops being wanted pauses on its
// frame (a quick switch back resumes in ~30 ms) and, after `releaseMs`,
// lets go of its decoder: a paused decoder keeps its whole frame pool in
// VRAM (measured on an RTX 4080: 276 MB for a 2560x1440 copy, 534 MB for
// 5120x1440, 1.7 GB for a 5K 10-bit original), and too many of those made
// nvidia-vaapi-driver segfault (nvGetImage) under VRAM pressure.
// Once the still is laid out, the layer plays a display-sized copy of just
// the part it shows (VideoWallpapers.variant), when there is one.
//
// `decodeScale` < 1 decodes the image smaller (sourceSize × scale) and draws
// it scaled back up: the overview shows workspaces at its zoom, so a
// workspace seen only there needs no full-size copy (WorkspaceWallpapers).
// Such a surface never loads its video, and neither does any in a
// performance mode (PerformanceMode: no decoder, not even the file open).
Item {
    // How long a video that stopped being wanted keeps its decoder (paused).
    property int releaseMs: 10000
    id: root

    // Absolute path, "~/…" or "" (the gradient).
    property string path: ""
    // The screen this is drawn on: picks its role's focus override.
    property string screenName: ""
    property real decodeScale: 1
    property bool playVideo: true
    readonly property string source: Vibes.url(path)
    readonly property bool videoAllowed: decodeScale >= 1 && !PerformanceMode.on
    // The current image has decoded (or there is none: the gradient).
    readonly property bool ready: source === "" || (flip ? a : b).status === Image.Ready
    // Bytes of decoded image data held (both layers), for the stats.
    readonly property real decodedBytes: a.bytes + b.bytes
    // The screen's device pixels per logical pixel (display-sized copies).
    readonly property real dpr: Quickshell.screens.find(s => s.name === screenName)?.devicePixelRatio ?? 1
    // Why the video holds even though playVideo ("" = it may play).
    readonly property string holdReason: VideoWallpapers.holdReason(screenName)

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
        fitLayer(layer);
        layer.video = videoUrl(path);
        layer.source = source;
    }
    Component.onCompleted: {
        fitLayer(a);
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
        fitLayer(cur);
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
        // fit "native": the image's [w, h], drawn 1:1 (scaled up only to
        // cover the screen); null = scaled to cover.
        property var natural: null
        readonly property real nativeScale: natural ? Math.max(1, root.width / natural[0], root.height / natural[1]) : 0

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
        // scales to cover sourceSize, keeping the aspect), or for fit
        // "native" at its own size (× decodeScale), and drawn at that size,
        // shifted so the focus sits as close to the center as the image's
        // edges allow.
        Image {
            id: img
            readonly property real s: Math.max(0.05, root.decodeScale)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            retainWhileLoading: true
            sourceSize: layer.natural ? Qt.size(Math.ceil(layer.natural[0] * layer.nativeScale * s), Math.ceil(layer.natural[1] * layer.nativeScale * s)) : Qt.size(Math.ceil(root.width * s), Math.ceil(root.height * s))
            width: layer.natural ? layer.natural[0] * layer.nativeScale : Math.max(implicitWidth / s, root.width)
            height: layer.natural ? layer.natural[1] * layer.nativeScale : Math.max(implicitHeight / s, root.height)
            smooth: true
            x: Math.min(0, Math.max(root.width - width, root.width / 2 - layer.crop[0] * width))
            y: Math.min(0, Math.max(root.height - height, root.height / 2 - layer.crop[1] * height))
        }

        // The display-sized copy of what this layer shows: the visible part
        // of the image's rectangle (fractions of the frame) at the screen's
        // pixel size. "" until it exists (or with smallerCopies off): the
        // original plays, drawn in the image's rectangle.
        readonly property var visibleCrop: img.width > 0 && img.height > 0 ? [Math.max(0, -img.x / img.width), Math.max(0, -img.y / img.height), Math.min(1, root.width / img.width), Math.min(1, root.height / img.height)] : null
        readonly property bool laidOut: layer.video !== "" && img.status === Image.Ready && root.width > 0 && visibleCrop !== null
        readonly property string variant: laidOut ? VideoWallpapers.variant(layer.video, visibleCrop, root.width * root.dpr, root.height * root.dpr) : ""
        function requestCopy() {
            if (laidOut)
                Qt.callLater(() => {
                    if (layer.laidOut)
                        VideoWallpapers.request(layer.video, layer.visibleCrop, root.width * root.dpr, root.height * root.dpr);
                });
        }
        onLaidOutChanged: requestCopy()
        onVisibleCropChanged: requestCopy()
        Connections {
            target: VideoWallpapers
            function onVideoScaleChanged() {
                layer.requestCopy();
            }
        }
        readonly property string playSource: layer.video === "" ? "" : variant !== "" ? variant : layer.video

        // The video over the still (same aspect, so the same crop). No
        // audio output: muted.
        // Reopened (set to "" and back) to drop a held decoder: the file stays
        // open, no decoder until play().
        property bool reopening: false
        MediaPlayer {
            id: player
            source: layer.reopening ? "" : layer.playSource
            loops: MediaPlayer.Infinite
            videoOutput: out
            readonly property bool wanted: layer.video !== "" && layer.current && root.playVideo && root.holdReason === ""
            onWantedChanged: wanted ? play() : pause()
            onMediaStatusChanged: if (mediaStatus === MediaPlayer.LoadedMedia && wanted)
                play()
        }
        Timer {
            interval: root.releaseMs
            running: !player.wanted && player.playbackState === MediaPlayer.PausedState
            onTriggered: {
                layer.reopening = true;
                Qt.callLater(() => layer.reopening = false);
            }
        }
        VideoOutput {
            id: out
            // A copy shows exactly the screen; the original, the image's rectangle.
            x: layer.variant !== "" ? 0 : img.x
            y: layer.variant !== "" ? 0 : img.y
            width: layer.variant !== "" ? root.width : img.width
            height: layer.variant !== "" ? root.height : img.height
            fillMode: VideoOutput.Stretch
            // Up once playback has started; the still is beneath until then.
            opacity: layer.video !== "" && player.hasVideo && player.playbackState !== MediaPlayer.StoppedState ? 1 : 0
            Behavior on opacity {
                NumberAnimation {
                    duration: 300
                }
            }
        }

        // Report to VideoWallpapers (perf status, doctor).
        property int statsId: 0
        readonly property var info: layer.video === "" ? null : {
            screen: root.screenName,
            path: layer.video.split("/").pop(),
            copy: layer.variant !== "",
            playing: player.playbackState === MediaPlayer.PlayingState,
            held: layer.current && root.playVideo ? root.holdReason : "",
            size: player.metaData.value(MediaMetaData.Resolution) ? `${player.metaData.value(MediaMetaData.Resolution).width}x${player.metaData.value(MediaMetaData.Resolution).height}` : ""
        }
        onInfoChanged: if (statsId)
            VideoWallpapers.report(statsId, info)
        Component.onCompleted: {
            statsId = VideoWallpapers.newId();
            VideoWallpapers.report(statsId, info);
        }
        Component.onDestruction: VideoWallpapers.report(statsId, null)
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
