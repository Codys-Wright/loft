import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.components
import qs.services

// The recording editor: trim (drag the ends of the top bar) and zoom
// segments, Screen Studio style (the lane under it). Auto Zoom proposes
// segments where the recording shows local activity — the pointer, clicks
// that change the UI, typing (`loft capture zoom auto`). A segment is a
// block on the lane: drag it to move, drag its ends to resize, select it to
// set its depth with the slider and its center by clicking the preview.
// Export writes "<name>-zoomed.mp4" with eased zooms (or, with no
// segments, Trim writes "<name>-trimmed.mp4"); the original stays as it is.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    readonly property var job: Capture.trimming
    readonly property real duration: job?.duration ?? 0
    readonly property real aspect: job && job.width > 0 && job.height > 0 ? job.width / job.height : 16 / 10
    property real start: 0
    property real end: 0
    property real playhead: 0
    property string previewFrame: ""
    // Zoom segments: [{start, end, zoom, x, y}] in seconds of the original;
    // x / y = the center (0–1 of the frame).
    property var segments: []
    property int selected: -1
    readonly property var current: selected >= 0 && selected < segments.length ? segments[selected] : null

    visible: job !== null && Capture.screenFocused?.name === modelData.name
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "loft:capture-trim"
    WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    implicitWidth: 760
    implicitHeight: 600
    color: "transparent"

    onJobChanged: {
        if (!job)
            return;
        start = 0;
        end = job.duration;
        playhead = 0;
        segments = [];
        selected = -1;
        previewFrame = "";
        seek(0);
    }

    function fmt(t) {
        const m = Math.floor(t / 60), s = t - m * 60;
        return `${m}:${s < 10 ? "0" : ""}${s.toFixed(1)}`;
    }

    // Show the frame at t seconds (debounced while dragging).
    function seek(t) {
        playhead = Math.max(0, Math.min(duration, t));
        frameTimer.restart();
    }
    Timer {
        id: frameTimer
        interval: 90
        onTriggered: {
            if (!root.job)
                return;
            const out = `${Capture.tmp}/edit-${Date.now()}.png`;
            const t = Math.min(root.playhead, Math.max(0, root.duration - 0.05));
            Capture.exec(["ffmpeg", "-v", "error", "-y", "-ss", t.toFixed(3), "-i", root.job.path, "-frames:v", "1", "-vf", "scale=960:-2", "-update", "1", out], code => {
                if (code === 0)
                    root.previewFrame = out;
            });
        }
    }

    // The zoom at time t: the same eased curve `loft capture zoom render`
    // draws (cli/loft/capture.py zoom_at).
    function zoomAt(t) {
        for (const s of segments) {
            if (s.start <= t && t <= s.end) {
                const r = Math.min(0.6, (s.end - s.start) / 3);
                const sm = p => {
                    p = Math.max(0, Math.min(1, p));
                    return p * p * (3 - 2 * p);
                };
                const env = sm((t - s.start) / r) * sm((s.end - t) / r);
                return {
                    zoom: 1 + (s.zoom - 1) * env,
                    x: s.x,
                    y: s.y,
                    seg: s
                };
            }
        }
        return {
            zoom: 1,
            x: 0.5,
            y: 0.5,
            seg: null
        };
    }

    function setSegment(i, patch) {
        const list = segments.slice();
        list[i] = Object.assign({}, list[i], patch);
        segments = list;
    }

    function addZoom() {
        const t = playhead;
        const hit = segments.findIndex(s => s.start <= t && t <= s.end);
        if (hit >= 0) {
            selected = hit;
            return;
        }
        const next = segments.filter(s => s.start > t).reduce((a, s) => Math.min(a, s.start), duration);
        const e = Math.min(next, t + 2.5);
        if (e - t < 0.5)
            return;
        const list = segments.concat([
            {
                start: t,
                end: e,
                zoom: 2,
                x: 0.5,
                y: 0.5
            }
        ]).sort((a, b) => a.start - b.start);
        segments = list;
        selected = list.findIndex(s => s.start === t);
    }

    function deleteSelected() {
        if (selected < 0)
            return;
        segments = segments.filter((_, i) => i !== selected);
        selected = -1;
    }

    function autoZoom() {
        Capture.autoZoom(job.path, segs => {
            if (!segs)
                return;
            root.segments = segs;
            root.selected = segs.length > 0 ? 0 : -1;
            if (segs.length > 0)
                root.seek((segs[0].start + segs[0].end) / 2);
            else
                Notifications.show({
                    appName: "Screen Recording",
                    appIcon: "zoom-in",
                    summary: "No zoom spots found",
                    body: "Add zooms by hand with Add Zoom",
                    image: "",
                    actions: []
                });
        });
    }

    function exportEdit() {
        // Only what survives the trim.
        const segs = segments.filter(s => s.end > start && s.start < end).map(s => Object.assign({}, s, {
                start: Math.max(s.start, start),
                end: Math.min(s.end, end)
            }));
        Capture.exportEdit(job.path, start, end, duration, segs);
    }

    component PillButton: Rectangle {
        id: btn
        property string text
        property string icon: ""
        property bool primary: false
        property bool active: true
        signal clicked
        implicitWidth: btnRow.implicitWidth + 28
        implicitHeight: 30
        radius: 15
        opacity: active ? 1 : 0.5
        color: primary ? (mouse.containsMouse ? Qt.lighter(Theme.accent, 1.1) : Theme.accent) : mouse.containsMouse ? Theme.withAlpha(Theme.text, 0.16) : Theme.withAlpha(Theme.text, 0.09)

        Row {
            id: btnRow
            anchors.centerIn: parent
            spacing: 6
            Icon {
                visible: btn.icon !== ""
                anchors.verticalCenter: parent.verticalCenter
                text: btn.icon
                size: 13
                color: btn.primary ? Theme.bg : Theme.text
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: btn.text
                color: btn.primary ? Theme.bg : Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 12
                font.weight: btn.primary ? Font.DemiBold : Font.Medium
            }
        }
        MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: if (btn.active)
                btn.clicked()
        }
    }

    BackgroundEffect.blurRegion: Theme.blur ? blur : null
    Region {
        id: blur
        item: panel
        radius: panel.radius
    }

    GlassSurface {
        id: panel
        anchors.fill: parent
        radius: 22
        strength: 1.8
        focus: root.visible
        Keys.onEscapePressed: Capture.trimming = null
        Keys.onDeletePressed: root.deleteSelected()

        ColumnLayout {
            anchors {
                fill: parent
                margins: 18
            }
            spacing: 12

            RowLayout {
                Layout.fillWidth: true
                Text {
                    Layout.fillWidth: true
                    text: "Edit Recording"
                    color: Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 16
                    font.weight: Font.DemiBold
                }
                Text {
                    text: `${root.fmt(root.playhead)}  ·  ${root.fmt(root.end - root.start)} of ${root.fmt(root.duration)}`
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 12
                    font.features: {
                        "tnum": 1
                    }
                }
            }

            // ── Preview: the frame at the playhead, with the zoomed view ──
            RoundedClip {
                id: preview
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: 12

                Rectangle {
                    anchors.fill: parent
                    color: Theme.overlay
                }
                Image {
                    id: frameImg
                    anchors.fill: parent
                    source: root.previewFrame ? "file://" + root.previewFrame : ""
                    fillMode: Image.PreserveAspectFit
                    cache: false
                    asynchronous: true
                    // The painted picture inside the item.
                    readonly property real pw: paintedWidth > 0 ? paintedWidth : Math.min(width, height * root.aspect)
                    readonly property real ph: paintedHeight > 0 ? paintedHeight : pw / root.aspect
                    readonly property real px: (width - pw) / 2
                    readonly property real py: (height - ph) / 2
                }

                // The part of the frame a zoom shows: the selected segment at
                // full depth, else the zoom at the playhead.
                Item {
                    id: zoomBox
                    readonly property var at: root.zoomAt(root.playhead)
                    readonly property var seg: root.current ?? at.seg
                    readonly property real level: root.current ? root.current.zoom : at.zoom
                    readonly property real cx: seg ? seg.x : 0.5
                    readonly property real cy: seg ? seg.y : 0.5
                    readonly property real vw: 1 / Math.max(1, level)
                    visible: seg !== null && root.previewFrame !== ""
                    x: frameImg.px + Math.max(0, Math.min(1 - vw, cx - vw / 2)) * frameImg.pw
                    y: frameImg.py + Math.max(0, Math.min(1 - vw, cy - vw / 2)) * frameImg.ph
                    width: vw * frameImg.pw
                    height: vw * frameImg.ph

                    Rectangle {
                        anchors.fill: parent
                        color: Theme.withAlpha(Theme.accent, 0.12)
                        border.width: 2
                        border.color: Theme.accent
                        radius: 4
                    }
                    Rectangle {
                        anchors {
                            left: parent.left
                            top: parent.top
                            margins: 6
                        }
                        width: zl.implicitWidth + 12
                        height: 20
                        radius: 10
                        color: Theme.accent
                        Text {
                            id: zl
                            anchors.centerIn: parent
                            text: `${zoomBox.level.toFixed(1)}×`
                            color: Theme.bg
                            font.family: Theme.fontUi
                            font.pixelSize: 11
                            font.weight: Font.DemiBold
                        }
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: root.current !== null
                    cursorShape: enabled ? Qt.CrossCursor : Qt.ArrowCursor
                    function place(mouse) {
                        root.setSegment(root.selected, {
                            x: Math.max(0, Math.min(1, (mouse.x - frameImg.px) / frameImg.pw)),
                            y: Math.max(0, Math.min(1, (mouse.y - frameImg.py) / frameImg.ph))
                        });
                    }
                    onPressed: mouse => place(mouse)
                    onPositionChanged: mouse => place(mouse)
                }

                Text {
                    visible: root.current !== null
                    anchors {
                        bottom: parent.bottom
                        horizontalCenter: parent.horizontalCenter
                        bottomMargin: 8
                    }
                    text: "Click to center the zoom"
                    color: "white"
                    style: Text.Outline
                    styleColor: Qt.rgba(0, 0, 0, 0.5)
                    font.family: Theme.fontUi
                    font.pixelSize: 11
                }
            }

            // ── Timeline: trim bar + zoom lane, one playhead ─────────────
            Item {
                id: timeline
                Layout.fillWidth: true
                Layout.preferredHeight: 76
                readonly property real span: Math.max(0.001, root.duration)
                function xOf(t) {
                    return t / span * width;
                }
                function at(x) {
                    return Math.max(0, Math.min(1, x / width)) * span;
                }

                // Trim: drag either handle.
                Item {
                    id: range
                    width: parent.width
                    height: 28

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width
                        height: 6
                        radius: 3
                        color: Theme.withAlpha(Theme.text, 0.15)
                    }
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        x: timeline.xOf(root.start)
                        width: timeline.xOf(root.end - root.start)
                        height: 6
                        radius: 3
                        color: Theme.accent
                    }
                    Repeater {
                        model: ["start", "end"]
                        delegate: Rectangle {
                            required property string modelData
                            anchors.verticalCenter: parent.verticalCenter
                            x: timeline.xOf(modelData === "start" ? root.start : root.end) - width / 2
                            width: 18
                            height: 18
                            radius: 9
                            color: "white"
                            border.width: 1
                            border.color: Theme.withAlpha("#000000", 0.15)
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -8
                        cursorShape: Qt.PointingHandCursor
                        property string handle: ""
                        onPressed: mouse => {
                            const t = timeline.at(mouse.x - 8);
                            handle = Math.abs(t - root.start) <= Math.abs(t - root.end) ? "start" : "end";
                            positionChanged(mouse);
                        }
                        onPositionChanged: mouse => {
                            if (!pressed)
                                return;
                            const t = timeline.at(mouse.x - 8);
                            if (handle === "start")
                                root.start = Math.min(t, root.end - 0.1);
                            else
                                root.end = Math.max(t, root.start + 0.1);
                            root.seek(handle === "start" ? root.start : Math.max(0, root.end - 0.05));
                        }
                    }
                }

                // Zoom lane.
                Rectangle {
                    id: lane
                    y: 38
                    width: parent.width
                    height: 34
                    radius: 8
                    color: Theme.withAlpha(Theme.text, 0.07)

                    // Outside the trim: dimmed.
                    Rectangle {
                        width: timeline.xOf(root.start)
                        height: parent.height
                        radius: 8
                        color: Theme.withAlpha(Theme.bg, 0.45)
                    }
                    Rectangle {
                        x: timeline.xOf(root.end)
                        width: parent.width - x
                        height: parent.height
                        radius: 8
                        color: Theme.withAlpha(Theme.bg, 0.45)
                    }

                    Text {
                        visible: root.segments.length === 0
                        anchors.centerIn: parent
                        text: Capture.zoomAnalyzing ? "Looking for the action…" : "Zoom — Auto Zoom, or Add Zoom at the playhead"
                        color: Theme.subtext
                        font.family: Theme.fontUi
                        font.pixelSize: 11
                    }

                    // Empty lane: move the playhead, deselect.
                    MouseArea {
                        anchors.fill: parent
                        onPressed: mouse => {
                            root.selected = -1;
                            root.seek(timeline.at(mouse.x));
                        }
                        onPositionChanged: mouse => {
                            if (pressed)
                                root.seek(timeline.at(mouse.x));
                        }
                    }

                    Repeater {
                        model: root.segments
                        delegate: Rectangle {
                            id: seg
                            required property var modelData
                            required property int index
                            readonly property bool isSel: root.selected === index
                            // While dragging, the block follows a draft that is
                            // committed on release (replacing `segments` would
                            // recreate this delegate mid-drag).
                            property bool dragging: false
                            property real draftStart: 0
                            property real draftEnd: 0
                            readonly property real s0: dragging ? draftStart : modelData.start
                            readonly property real e0: dragging ? draftEnd : modelData.end
                            x: timeline.xOf(s0)
                            y: 3
                            width: Math.max(10, timeline.xOf(e0 - s0))
                            height: lane.height - 6
                            radius: 6
                            color: isSel ? Theme.accent : Theme.withAlpha(Theme.accent, 0.55)
                            border.width: isSel ? 2 : 0
                            border.color: Qt.lighter(Theme.accent, 1.3)

                            Row {
                                anchors.centerIn: parent
                                spacing: 4
                                visible: seg.width > 54
                                Icon {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "󰛭"
                                    size: 12
                                    color: Theme.bg
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: `${seg.modelData.zoom.toFixed(1)}×`
                                    color: Theme.bg
                                    font.family: Theme.fontUi
                                    font.pixelSize: 11
                                    font.weight: Font.DemiBold
                                }
                            }
                            // Resize grips.
                            Repeater {
                                model: 2
                                delegate: Rectangle {
                                    required property int index
                                    visible: seg.isSel
                                    x: index === 0 ? 3 : seg.width - 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 3
                                    height: 12
                                    radius: 1.5
                                    color: Theme.bg
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: mode === "move" ? Qt.SizeAllCursor : Qt.SizeHorCursor
                                hoverEnabled: true
                                property string mode: "move"
                                property real pressT: 0
                                property var orig: null
                                function laneT(mouse) {
                                    return timeline.at(mapToItem(lane, mouse.x, 0).x);
                                }
                                onPositionChanged: mouse => {
                                    if (!pressed) {
                                        mode = mouse.x < 8 ? "start" : mouse.x > width - 8 ? "end" : "move";
                                        return;
                                    }
                                    const dt = laneT(mouse) - pressT;
                                    const i = seg.index;
                                    const prevEnd = i > 0 ? root.segments[i - 1].end : 0;
                                    const nextStart = i < root.segments.length - 1 ? root.segments[i + 1].start : root.duration;
                                    const o = orig;
                                    seg.dragging = true;
                                    if (mode === "start") {
                                        seg.draftStart = Math.max(prevEnd, Math.min(o.end - 0.5, o.start + dt));
                                        seg.draftEnd = o.end;
                                    } else if (mode === "end") {
                                        seg.draftStart = o.start;
                                        seg.draftEnd = Math.min(nextStart, Math.max(o.start + 0.5, o.end + dt));
                                    } else {
                                        const len = o.end - o.start;
                                        seg.draftStart = Math.max(prevEnd, Math.min(nextStart - len, o.start + dt));
                                        seg.draftEnd = seg.draftStart + len;
                                    }
                                }
                                onPressed: mouse => {
                                    mode = mouse.x < 8 ? "start" : mouse.x > width - 8 ? "end" : "move";
                                    root.selected = seg.index;
                                    pressT = laneT(mouse);
                                    orig = Object.assign({}, seg.modelData);
                                }
                                onReleased: {
                                    const a = seg.s0, b = seg.e0;
                                    root.seek(mode === "start" ? a + 0.05 : mode === "end" ? b - 0.05 : (a + b) / 2);
                                    if (seg.dragging) {
                                        // Last: this recreates the delegate.
                                        seg.dragging = false;
                                        root.setSegment(seg.index, {
                                            start: a,
                                            end: b
                                        });
                                    }
                                }
                            }
                        }
                    }
                }

                // Playhead.
                Rectangle {
                    x: timeline.xOf(root.playhead) - 1
                    y: 30
                    width: 2
                    height: parent.height - 30
                    radius: 1
                    color: Theme.text
                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: -4
                        width: 8
                        height: 8
                        radius: 4
                        color: Theme.text
                    }
                }
            }

            // ── The selected zoom ────────────────────────────────────────
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 30
                spacing: 10
                visible: root.current !== null

                Text {
                    text: "Zoom"
                    color: Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 12
                    font.weight: Font.Medium
                }
                Item {
                    id: depth
                    Layout.preferredWidth: 220
                    Layout.preferredHeight: 22
                    readonly property real lo: 1.25
                    readonly property real hi: 4
                    readonly property real frac: root.current ? (root.current.zoom - lo) / (hi - lo) : 0
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width
                        height: 4
                        radius: 2
                        color: Theme.withAlpha(Theme.text, 0.15)
                    }
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: depth.frac * parent.width
                        height: 4
                        radius: 2
                        color: Theme.accent
                    }
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        x: depth.frac * parent.width - width / 2
                        width: 16
                        height: 16
                        radius: 8
                        color: "white"
                        border.width: 1
                        border.color: Theme.withAlpha("#000000", 0.15)
                    }
                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -6
                        cursorShape: Qt.PointingHandCursor
                        function set(mouse) {
                            const f = Math.max(0, Math.min(1, (mouse.x - 6) / depth.width));
                            root.setSegment(root.selected, {
                                zoom: Math.round((depth.lo + f * (depth.hi - depth.lo)) * 20) / 20
                            });
                        }
                        onPressed: mouse => set(mouse)
                        onPositionChanged: mouse => {
                            if (pressed)
                                set(mouse);
                        }
                    }
                }
                Text {
                    text: root.current ? `${root.current.zoom.toFixed(2)}×  ·  ${root.fmt(root.current.start)}–${root.fmt(root.current.end)}` : ""
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 12
                    font.features: {
                        "tnum": 1
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
                PillButton {
                    text: "Delete"
                    icon: "󰆴"
                    onClicked: root.deleteSelected()
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                PillButton {
                    text: Capture.zoomAnalyzing ? "Finding…" : "Auto Zoom"
                    icon: "󰁨"
                    active: !Capture.zoomAnalyzing
                    onClicked: root.autoZoom()
                }
                PillButton {
                    text: "Add Zoom"
                    icon: "󰛭"
                    onClicked: root.addZoom()
                }
                Item {
                    Layout.fillWidth: true
                }
                PillButton {
                    text: "Cancel"
                    onClicked: Capture.trimming = null
                }
                PillButton {
                    text: root.segments.length > 0 ? "Export" : "Trim"
                    primary: true
                    onClicked: root.exportEdit()
                }
            }
        }
    }
}
