import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Mpris
import qs.components
import qs.services

// Dynamic Island: a glass pill at the top center (design ported from
// javiiervm/dotfiles' DynamicIsland).
//
// Collapsed, in priority order: a notification banner (5 s), a live
// activity (screen recording, focus timer — scroll to cycle when both run),
// now playing (art + equalizer), the time. The border pulses on system
// alerts (overheating / overload) and turns white for unread notifications.
//
// Hover expands it into a carousel of pages — live activity, notifications
// (when there are any), media, system, screen time; scroll to switch.
// IPC: island toggle|media|system|usage|notifications|live|flash.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "studio:island"
    // Sit inside the bar's strip rather than below its exclusive zone.
    exclusionMode: ExclusionMode.Ignore
    anchors.top: true
    margins.top: 5
    implicitWidth: 560
    implicitHeight: 260
    color: "transparent"

    // ── State ───────────────────────────────────────────────────────────
    readonly property var players: Mpris.players.values
    readonly property var player: players.find(p => p.isPlaying) ?? players[0] ?? null
    readonly property bool playing: player?.isPlaying ?? false

    readonly property var liveActivities: [Recorder.active ? "recording" : "", FocusTimer.active ? "focus" : ""].filter(s => s)
    property int liveIndex: 0
    readonly property string live: liveActivities.length ? liveActivities[liveIndex % liveActivities.length] : ""

    readonly property var pages: [live !== "" ? "live" : "", Notifications.history.length > 0 ? "notifications" : "", "media", "system", "usage"].filter(s => s)
    property alias page: persist.page
    readonly property int pageIndex: Math.max(0, pages.indexOf(page))

    property alias pinned: persist.pinned

    // Survive hot reloads (one per screen).
    PersistentProperties {
        id: persist
        reloadableId: `island-${root.modelData.name}`
        property string page: "media"
        property bool pinned: false
    }
    readonly property bool expanded: hover.hovered || pinned
    readonly property var banner: Notifications.current
    readonly property bool bannering: banner !== null && !expanded

    // Unread = notifications arrived since the notifications page was last seen.
    property int seenCount: 0
    readonly property bool unread: Notifications.history.length > seenCount

    readonly property color alertColor: SystemStats.overheating ? Theme.urgent : SystemStats.overloaded ? Theme.warn : "transparent"
    readonly property bool alerting: alertColor.a > 0

    readonly property real targetWidth: expanded ? 480 : bannering ? 440 : live !== "" ? 240 : playing ? 300 : 150
    readonly property real targetHeight: expanded ? 210 : bannering ? 84 : 34

    function showPage(name) {
        pinned = true;
        page = pages.includes(name) ? name : pages[0];
    }

    function step(delta) {
        page = pages[(pageIndex + delta + pages.length) % pages.length];
    }

    onExpandedChanged: {
        // Open on the most relevant page.
        if (expanded && !pinned)
            page = live !== "" ? "live" : unread ? "notifications" : player ? "media" : "system";
    }
    onPageChanged: if (page === "notifications")
        seenCount = Notifications.history.length
    onPagesChanged: if (!pages.includes(page))
        page = pages[0]

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    Binding {
        target: SystemStats
        property: "detailed"
        value: root.expanded && root.page === "system"
    }

    // ── Window shape ────────────────────────────────────────────────────
    mask: Region {
        item: pill
        radius: pill.radius
    }
    BackgroundEffect.blurRegion: Theme.blur ? blur : null
    Region {
        id: blur
        item: pill
        radius: pill.radius
    }

    GlassSurface {
        id: pill
        anchors {
            top: parent.top
            horizontalCenter: parent.horizontalCenter
        }
        width: root.targetWidth
        height: root.targetHeight
        radius: root.expanded ? 30 : root.bannering ? 26 : height / 2
        showHighlight: false
        strength: 1.6
        clip: true

        border.width: root.alerting || (root.unread && !root.expanded) ? 2 : 1
        border.color: root.alerting ? root.alertColor : root.unread && !root.expanded ? Theme.text : Theme.glassBorder

        // Alerts breathe instead of sitting there.
        SequentialAnimation on border.color {
            running: root.alerting && !root.expanded
            loops: Animation.Infinite
            ColorAnimation {
                to: Theme.withAlpha(root.alertColor, 0.25)
                duration: 900
                easing.type: Easing.InOutSine
            }
            ColorAnimation {
                to: root.alertColor
                duration: 900
                easing.type: Easing.InOutSine
            }
        }

        Behavior on width {
            NumberAnimation {
                duration: 320
                easing.type: Easing.OutQuint
            }
        }
        Behavior on height {
            NumberAnimation {
                duration: 320
                easing.type: Easing.OutQuint
            }
        }
        Behavior on radius {
            NumberAnimation {
                duration: 320
                easing.type: Easing.OutQuint
            }
        }

        HoverHandler {
            id: hover
        }

        WheelHandler {
            onWheel: event => {
                const d = event.angleDelta.y < 0 ? 1 : -1;
                if (root.expanded)
                    root.step(d);
                else if (root.liveActivities.length > 1)
                    root.liveIndex = (root.liveIndex + 1) % root.liveActivities.length;
            }
        }

        // ── Collapsed ───────────────────────────────────────────────────
        Item {
            anchors.fill: parent
            visible: opacity > 0
            opacity: root.expanded || root.bannering ? 0 : 1

            Behavior on opacity {
                NumberAnimation {
                    duration: 150
                }
            }

            LiveCompact {
                anchors.fill: parent
                visible: root.live !== ""
                activity: root.live
            }

            RowLayout {
                anchors {
                    fill: parent
                    leftMargin: 8
                    rightMargin: 14
                }
                visible: root.live === ""
                spacing: 10

                Rectangle {
                    visible: root.playing
                    Layout.preferredWidth: 22
                    Layout.preferredHeight: 22
                    radius: 6
                    clip: true
                    color: Theme.overlay

                    Image {
                        anchors.fill: parent
                        source: root.player?.trackArtUrl ?? ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                    }
                }

                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: root.playing ? Text.AlignLeft : Text.AlignHCenter
                    text: root.playing ? (root.player.trackTitle || root.player.identity) : Qt.formatDateTime(clock.date, "h:mm AP")
                    color: Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 13
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                }

                Equalizer {
                    visible: root.playing
                    running: root.playing && !root.expanded
                    Layout.preferredWidth: 18
                    Layout.preferredHeight: 14
                }
            }
        }

        // ── Notification banner ─────────────────────────────────────────
        Banner {
            anchors {
                fill: parent
                margins: 12
            }
            notification: root.banner
            visible: opacity > 0
            opacity: root.bannering ? 1 : 0

            Behavior on opacity {
                NumberAnimation {
                    duration: 180
                }
            }
        }

        Timer {
            running: root.bannering
            interval: 5000
            onTriggered: Notifications.next()
        }

        // ── Expanded: page carousel ─────────────────────────────────────
        Item {
            id: viewport
            anchors.fill: parent
            visible: opacity > 0
            opacity: root.expanded ? 1 : 0
            clip: true

            Behavior on opacity {
                NumberAnimation {
                    duration: 220
                }
            }

            Repeater {
                model: root.pages

                delegate: Item {
                    id: slot
                    required property string modelData
                    required property int index

                    width: viewport.width
                    height: viewport.height
                    x: (index - root.pageIndex) * width
                    visible: Math.abs(index - root.pageIndex) <= 1

                    Behavior on x {
                        NumberAnimation {
                            duration: 300
                            easing.type: Easing.OutQuint
                        }
                    }

                    Loader {
                        anchors.fill: parent
                        sourceComponent: {
                            switch (slot.modelData) {
                            case "live":
                                return livePage;
                            case "notifications":
                                return notificationsPage;
                            case "media":
                                return mediaPage;
                            case "system":
                                return systemPage;
                            default:
                                return usagePage;
                            }
                        }
                    }
                }
            }

            // Page dots.
            Row {
                anchors {
                    bottom: parent.bottom
                    horizontalCenter: parent.horizontalCenter
                    bottomMargin: 8
                }
                spacing: 6

                Repeater {
                    model: root.pages.length
                    delegate: Rectangle {
                        required property int index
                        width: index === root.pageIndex ? 14 : 6
                        height: 6
                        radius: 3
                        color: Theme.text
                        opacity: index === root.pageIndex ? 0.9 : 0.3

                        Behavior on width {
                            NumberAnimation {
                                duration: 200
                            }
                        }
                    }
                }
            }
        }

        // Camera-shutter flash when a screenshot is taken.
        Rectangle {
            id: flash
            anchors.fill: parent
            radius: pill.radius
            color: "white"
            opacity: 0

            SequentialAnimation {
                id: shutter
                NumberAnimation {
                    target: flash
                    property: "opacity"
                    to: 0.9
                    duration: 40
                    easing.type: Easing.OutExpo
                }
                NumberAnimation {
                    target: flash
                    property: "opacity"
                    to: 0
                    duration: 320
                    easing.type: Easing.InExpo
                }
            }
        }
    }

    Connections {
        target: Niri
        function onScreenshotTaken() {
            shutter.restart();
        }
    }

    Component {
        id: livePage
        LivePage {
            activity: root.live
        }
    }
    Component {
        id: notificationsPage
        NotificationsPage {}
    }
    Component {
        id: mediaPage
        MediaPage {
            player: root.player
        }
    }
    Component {
        id: systemPage
        SystemPage {}
    }
    Component {
        id: usagePage
        UsagePage {}
    }

    IpcHandler {
        target: "island"

        function toggle(): void {
            root.pinned = !root.pinned;
        }

        function media(): void {
            root.showPage("media");
        }

        function system(): void {
            root.showPage("system");
        }

        function usage(): void {
            root.showPage("usage");
        }

        function notifications(): void {
            root.showPage("notifications");
        }

        function live(): void {
            root.showPage("live");
        }

        // Exercise the shutter flash without taking a screenshot.
        function flash(): void {
            shutter.restart();
        }
    }
}
