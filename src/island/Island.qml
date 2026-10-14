import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Mpris
import qs.capture
import qs.components
import qs.services

// Dynamic Island at the top center (design ported from javiiervm/dotfiles'
// DynamicIsland). Settings → Dynamic Island → Style: attached (default)
// hangs from the top edge like the MacBook notch — flush, square top with
// concave shoulders (NotchShape), rounded bottom — and grows down and
// sideways from it; floating is a pill with a gap above it. Fill: a solid
// near-black (default; content is always light on it, Theme.island*) or
// the Liquid Glass material.
//
// Collapsed, in priority order: a notification banner (5 s; hovering holds
// it so its buttons can be clicked), a live activity (screen recording,
// focus timer, timers, downloads — scroll to cycle when several run), the
// next calendar event when it's close, now playing (art + equalizer), the
// time — with a mark while AI agents run. The border pulses on system alerts
// (overheating / overload) and turns white for unread notifications.
//
// Hover expands it into a carousel of pages (IslandPages: order and which
// are shown live in Settings → Dynamic Island) — live activity, camera,
// notifications, calendar, media, timers, controls, system, screen time, AI
// agents; scroll to switch.
// IPC: island toggle|media|system|usage|notifications|live|calendar|timers|
// controls|ai|flash.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "loft:island"
    // Sit inside the bar's strip rather than below its exclusive zone.
    exclusionMode: ExclusionMode.Ignore
    anchors.top: true
    margins.top: attached ? 0 : 3
    implicitWidth: 560
    implicitHeight: 260
    color: "transparent"

    // ── State ───────────────────────────────────────────────────────────
    readonly property var players: Mpris.players.values
    readonly property var player: players.find(p => p.isPlaying) ?? players[0] ?? null
    readonly property bool playing: player?.isPlaying ?? false

    readonly property var liveActivities: [Recorder.active ? "recording" : "", FocusTimer.active ? "focus" : "", Timers.active ? "timer" : "", Downloads.active.length > 0 ? "download" : ""].filter(s => s)
    property int liveIndex: 0
    readonly property string live: liveActivities.length ? liveActivities[liveIndex % liveActivities.length] : ""

    // Pages that exist right now, in the user's order.
    function pageAvailable(id) {
        switch (id) {
        case "live":
            return live !== "";
        case "camera":
            return Capture.cameraOn;
        case "notifications":
            return Notifications.history.length > 0;
        case "calendar":
            return Agenda.enabled;
        case "ai":
            return AiUsage.enabled && AiUsage.available;
        }
        return true;
    }
    readonly property var pages: {
        const out = IslandPages.order.filter(p => p.shown && pageAvailable(p.id)).map(p => p.id);
        return out.length ? out : ["system"];
    }
    // The next event, while it's close (Settings: eventSoonMinutes).
    readonly property var soonEvent: Agenda.soon
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
    readonly property var banner: Notifications.current
    // A banner under the pointer stays a banner (its buttons stay clickable);
    // the island expands once it's gone.
    readonly property bool expanded: pinned || (hover.hovered && banner === null)
    readonly property bool bannering: banner !== null && !expanded

    // Unread = notifications arrived since the notifications page was last seen.
    property int seenCount: 0
    readonly property bool unread: Notifications.history.length > seenCount

    readonly property color alertColor: SystemStats.overheating ? Theme.urgent : SystemStats.overloaded ? Theme.warn : "transparent"
    readonly property bool alerting: alertColor.a > 0

    readonly property bool showEvent: live === "" && soonEvent !== null
    readonly property bool agentMark: Settings.island.aiIndicator && AiUsage.enabled && AiUsage.sessions.length > 0
    readonly property real targetWidth: expanded ? 480 : bannering ? 460 : live !== "" ? 250 : showEvent ? 300 : playing ? 300 : agentMark ? 190 : 150
    readonly property real targetHeight: expanded ? 210 : bannering ? 84 : attached ? barHeight : 24

    // ── Look (Settings → Dynamic Island) ────────────────────────────────
    readonly property bool attached: Settings.island.style !== "floating"
    readonly property bool black: Theme.islandBlack
    // Collapsed and attached, it fills the menu bar's strip (Bar.qml).
    readonly property int barHeight: 30

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
            page = [live !== "" ? "live" : "", unread ? "notifications" : "", soonEvent ? "calendar" : "", player ? "media" : "", "system"].find(p => p && pages.includes(p)) ?? pages[0];
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
        target: AiUsage
        property: "watching"
        value: root.expanded && root.page === "ai"
        when: root.expanded
        restoreMode: Binding.RestoreValue
    }

    Binding {
        target: SystemStats
        property: "detailed"
        value: root.expanded && root.page === "system"
    }

    // ── Window shape ────────────────────────────────────────────────────
    // Input and blur cover the body only: an attached island's square top
    // and rounded bottom, never its shoulders, so the transparent corners
    // beside them leave the bar's clicks alone.
    mask: Region {
        item: pill
        topLeftRadius: root.attached ? 0 : pill.radius
        topRightRadius: root.attached ? 0 : pill.radius
        bottomLeftRadius: pill.radius
        bottomRightRadius: pill.radius
    }
    // Black needs no blur: the region empties rather than going null, which
    // would leave the compositor blurring the last glass shape.
    BackgroundEffect.blurRegion: Theme.blur ? blur : null
    Region {
        id: blur
        item: root.black ? null : pill
        topLeftRadius: root.attached ? 0 : pill.radius
        topRightRadius: root.attached ? 0 : pill.radius
        bottomLeftRadius: pill.radius
        bottomRightRadius: pill.radius
    }

    Item {
        id: pill
        anchors {
            top: parent.top
            horizontalCenter: parent.horizontalCenter
        }
        width: root.targetWidth
        height: root.targetHeight

        // Attached: the bottom corners and the concave top shoulders, one
        // shape morphing with the size. Floating: every corner.
        property real radius: root.attached ? (root.expanded ? 30 : root.bannering ? 26 : 12) : root.expanded ? 30 : root.bannering ? 26 : height / 2
        property real shoulder: root.attached ? (root.expanded ? 14 : root.bannering ? 12 : 7) : 0

        // The outline: alerts pulse, unread notifications turn it white;
        // otherwise a glass hairline, or none on black (like the notch).
        property real edgeWidth: root.alerting || (root.unread && !root.expanded) ? 2 : root.black ? 0 : 1
        property color edgeColor: root.alerting ? root.alertColor : root.unread && !root.expanded ? Theme.islandText : root.black ? "transparent" : Theme.glassBorder

        // Alerts breathe instead of sitting there.
        SequentialAnimation on edgeColor {
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
        Behavior on shoulder {
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

        // ── Fill ────────────────────────────────────────────────────────
        NotchShape {
            visible: root.attached
            anchors.fill: parent
            radius: pill.radius
            shoulder: pill.shoulder
            color: root.black ? Theme.islandFill : Theme.fillFor(1.6)
            borderWidth: pill.edgeWidth
            borderColor: pill.edgeColor
        }

        GlassSurface {
            visible: !root.attached && !root.black
            anchors.fill: parent
            radius: pill.radius
            showHighlight: false
            textShadow: false
            strength: 1.6
            border.width: pill.edgeWidth
            border.color: pill.edgeColor
        }

        Rectangle {
            visible: !root.attached && root.black
            anchors.fill: parent
            radius: pill.radius
            color: Theme.islandFill
            border.width: pill.edgeWidth
            border.color: pill.edgeColor
        }

        // ── Content ─────────────────────────────────────────────────────
        Item {
            id: body
            anchors.fill: parent
            clip: true

            // On clear glass, a soft shadow under the content (as
            // GlassSurface gives its own children).
            layer.enabled: !root.black && Theme.textShadowStrength > 0.02
            layer.effect: MultiEffect {
                shadowEnabled: true
                shadowColor: Theme.textShadow
                shadowBlur: 0.35
                shadowVerticalOffset: 1
                shadowHorizontalOffset: 0
            }

            // ── Collapsed ───────────────────────────────────────────────
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

                // The next event, minutes before it starts.
                RowLayout {
                    anchors {
                        fill: parent
                        leftMargin: 12
                        rightMargin: 14
                    }
                    visible: root.showEvent
                    spacing: 8

                    Icon {
                        text: root.soonEvent?.joinUrl ? "󰕧" : "󰃭"
                        size: 13
                        color: Theme.accent
                    }

                    Text {
                        Layout.fillWidth: true
                        text: root.soonEvent?.title ?? ""
                        color: Theme.islandText
                        font.family: Theme.fontUi
                        font.pixelSize: 12
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                    }

                    Text {
                        text: root.soonEvent ? Agenda.when(root.soonEvent) : ""
                        color: Theme.accent
                        font.family: Theme.fontUi
                        font.pixelSize: 12
                        font.weight: Font.DemiBold
                        font.features: { "tnum": 1 }
                    }
                }

                RowLayout {
                    anchors {
                        fill: parent
                        leftMargin: 8
                        rightMargin: 14
                    }
                    visible: root.live === "" && !root.showEvent
                    spacing: 10

                    Rectangle {
                        visible: root.playing
                        Layout.preferredWidth: 18
                        Layout.preferredHeight: 18
                        radius: 5
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
                        color: Theme.islandText
                        font.family: Theme.fontUi
                        font.pixelSize: 12
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                    }

                    Equalizer {
                        visible: root.playing
                        running: root.playing && !root.expanded
                        Layout.preferredWidth: 16
                        Layout.preferredHeight: 12
                    }

                    // AI agents running: a sparkle and how many (breathes while one works).
                    Row {
                        visible: root.agentMark
                        spacing: 3
                        Icon {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "󰫢"
                            size: 12
                            color: AiUsage.busy > 0 ? Theme.accent2 : Theme.islandSubtext

                            SequentialAnimation on opacity {
                                running: root.agentMark && AiUsage.busy > 0 && !root.expanded
                                loops: Animation.Infinite
                                NumberAnimation {
                                    to: 0.4
                                    duration: 900
                                    easing.type: Easing.InOutSine
                                }
                                NumberAnimation {
                                    to: 1
                                    duration: 900
                                    easing.type: Easing.InOutSine
                                }
                            }
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: AiUsage.sessions.length
                            color: Theme.islandSubtext
                            font.family: Theme.fontUi
                            font.pixelSize: 11
                            font.weight: Font.DemiBold
                        }
                    }
                }
            }

            // ── Notification banner ─────────────────────────────────────
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
                running: root.bannering && !hover.hovered
                interval: 5000
                onTriggered: Notifications.next()
            }

            // ── Expanded: page carousel ─────────────────────────────────
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
                                case "camera":
                                    return cameraPage;
                                case "notifications":
                                    return notificationsPage;
                                case "media":
                                    return mediaPage;
                                case "system":
                                    return systemPage;
                                case "calendar":
                                    return calendarPage;
                                case "timers":
                                    return timersPage;
                                case "controls":
                                    return controlsPage;
                                case "ai":
                                    return aiPage;
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
                            color: Theme.islandText
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
                topLeftRadius: root.attached ? 0 : pill.radius
                topRightRadius: root.attached ? 0 : pill.radius
                bottomLeftRadius: pill.radius
                bottomRightRadius: pill.radius
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
        id: cameraPage
        CameraPage {}
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
    Component {
        id: calendarPage
        CalendarPage {}
    }
    Component {
        id: timersPage
        TimersPage {}
    }
    Component {
        id: controlsPage
        ControlsPage {}
    }
    Component {
        id: aiPage
        AiPage {}
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

        function calendar(): void {
            root.showPage("calendar");
        }

        function timers(): void {
            root.showPage("timers");
        }

        function controls(): void {
            root.showPage("controls");
        }

        function ai(): void {
            root.showPage("ai");
        }

        // Exercise the shutter flash without taking a screenshot.
        function flash(): void {
            shutter.restart();
        }
    }
}
