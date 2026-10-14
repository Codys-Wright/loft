import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.services

// Snapshots for the dock preview (see services/Previews.qml for why): one
// still of each display an app's window is showing on (wlr-screencopy,
// through ScreencopyView), cropped to the window and kept as an image
// (Previews.setThumb). The dock starts this when the pointer reaches an
// icon, before the popover appears, so the popover isn't in the picture.
// Lives in the dock's window, far outside its visible area: drawn, so the
// crops can be grabbed, but never on screen.
Item {
    id: root

    x: -100000
    width: 1
    height: 1

    // [{ id, output, rect: { x, y, width, height }, size: [w, h] }]
    property var jobs: []
    property int remaining: 0
    // The longer side of a stored thumbnail, in px.
    readonly property int maxSide: 440

    function capture(appId) {
        if (!Previews.enabled || !Previews.thumbnails || jobs.length > 0)
            return;
        const js = [];
        for (const w of DockData.windowsOf(appId)) {
            const r = Previews.screenRect(w);
            if (!r)
                continue;
            const k = Math.min(1, maxSide / Math.max(r.width, r.height));
            js.push({ id: w.id, output: r.output, rect: r, size: [Math.max(1, Math.round(r.width * k)), Math.max(1, Math.round(r.height * k))] });
        }
        if (js.length === 0)
            return;
        remaining = js.length;
        jobs = js;
        safety.restart();
    }

    function done() {
        remaining -= 1;
        if (remaining <= 0)
            finish();
    }

    function finish() {
        safety.stop();
        jobs = [];
        remaining = 0;
    }

    // A display that never delivers a frame doesn't block the next capture.
    Timer {
        id: safety
        interval: 3000
        onTriggered: root.finish()
    }

    Repeater {
        model: [...new Set(root.jobs.map(j => j.output))]

        delegate: Item {
            id: out
            required property string modelData
            readonly property var scr: Quickshell.screens.find(s => s.name === modelData) ?? null
            readonly property var mine: root.jobs.filter(j => j.output === modelData)
            width: scr?.width ?? 1
            height: scr?.height ?? 1

            // The display's still: the real capture, or (test sessions) the
            // stand-in PNG of the whole session, shifted to this display.
            Loader {
                id: source
                active: Previews.canCapture || Previews.stillPath !== ""
                sourceComponent: Previews.canCapture ? live : still
                onLoaded: if (!Previews.canCapture)
                    crops.model = Qt.binding(() => item.status === Image.Ready ? out.mine : [])
            }
            Component {
                id: live
                ScreencopyView {
                    width: out.width
                    height: out.height
                    captureSource: out.scr
                    onHasContentChanged: if (hasContent)
                        crops.model = out.mine
                    onStopped: {
                        for (const _ of out.mine)
                            root.done();
                    }
                }
            }
            Component {
                id: still
                Image {
                    source: "file://" + Previews.stillPath
                    cache: false
                    x: -(out.scr?.x ?? 0)
                    y: -(out.scr?.y ?? 0)
                }
            }

            Repeater {
                id: crops
                model: []

                delegate: ShaderEffectSource {
                    id: crop
                    required property var modelData
                    readonly property var r: modelData.rect
                    y: out.height + 10
                    width: modelData.size[0]
                    height: modelData.size[1]
                    sourceItem: source.item
                    // In the item's own coordinates (the still is shifted).
                    sourceRect: Qt.rect(r.x - (source.item?.x ?? 0), r.y - (source.item?.y ?? 0), r.width, r.height)
                    live: false
                    hideSource: false
                    smooth: true

                    Component.onCompleted: Qt.callLater(() => {
                        const ok = crop.grabToImage(res => {
                            Previews.setThumb(crop.modelData.id, res);
                            root.done();
                        }, Qt.size(crop.width, crop.height));
                        if (!ok)
                            root.done();
                    })
                }
            }
        }
    }
}
