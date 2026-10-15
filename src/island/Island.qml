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
// Collapsed, in priority order: what just changed (Hud: volume, mute,
// brightness, sound announcements — the pill widens to an icon, a level bar
// and the value, or an icon and a line, for 1.5 / 2.2 s; Settings → Dynamic
// Island → Show changes in the Dynamic Island, else Osd.qml shows it), a
// notification banner (5 s; hovering holds
// it so its buttons can be clicked), a live activity (screen recording,
// focus timer, timers, downloads — scroll to cycle when several run), the
// next calendar event when it's close, now playing (art + equalizer), the
// time — with a mark while AI agents run. A space switch shows the space's
// icon and name for a moment (Spaces.activated). The border pulses on system alerts
// (overheating / overload) and turns white for unread notifications.
//
// Hover expands it into a carousel of pages (IslandPages: order and which
// are shown live in Settings → Dynamic Island) — live activity, camera,
// notifications, calendar, media, timers, controls, system, screen time, AI
// agents; scroll to switch.
// IPC: island toggle|media|system|usage|notifications|live|calendar|timers|
// controls|ai|scratchpad|flash.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "loft:island"
    // Sit inside the bar's strip rather than below its exclusive zone.
    exclusionMode: ExclusionMode.Ignore
    // The keyboard only for a page with a text field (Scratchpad), on click.
    WlrLayershell.keyboardFocus: expanded && page === "scratchpad" ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    anchors.top: true
    margins.top: attached ? 0 : 3
    implicitWidth: 560
    implicitHeight: 260
    color: "transparent"

    // ── State ───────────────────────────────────────────────────────────
    readonly property var players: Mpris.players.values
    readonly property var player: players.find(p => p.isPlaying) ?? players[0] ?? null
    readonly property bool playing: player?.isPlaying ?? false

    readonly property var liveActivities: [Phone.activeCall !== null || Phone.ringingCall !== null ? "call" : "", Recorder.active ? "recording" : "", FocusTimer.active ? "focus" : "", Timers.active ? "timer" : "", Downloads.active.length > 0 ? "download" : ""].filter(s => s)
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
        case "scratchpad":
            return Scratchpad.enabled;
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
    // An incoming iPhone call (Phone.qml): Answer / Decline over everything.
    readonly property var ringingCall: Phone.ringingCall
    readonly property bool ringing: ringingCall !== null
    // Typing into a page (the Scratchpad's quick add) keeps it open.
    property bool typing: false
    readonly property bool expanded: !ringing && (pinned || typing || (hover.hovered && banner === null))
    // A call (a "call" live activity) keeps the island to itself.
    readonly property bool calling: liveActivities.includes("call")
    // What just changed (Hud.qml), on the focused output's island: over
    // everything collapsed, but not over an expanded island, a call, or a
    // banner the pointer is on.
    readonly property bool hudShowing: Hud.inIsland && Hud.onScreen(modelData.name) && !expanded && !calling && !(banner !== null && hover.hovered)
    readonly property bool bannering: banner !== null && !expanded && !hudShowing && !ringing

    // Unread = notifications arrived since the notifications page was last seen.
    property int seenCount: 0
    readonly property bool unread: Notifications.history.length > seenCount

    readonly property color alertColor: SystemStats.overheating ? Theme.urgent : SystemStats.overloaded ? Theme.warn : "transparent"
    readonly property bool alerting: alertColor.a > 0

    readonly property bool showEvent: live === "" && soonEvent !== null
    readonly property bool agentMark: Settings.island.aiIndicator && AiUsage.enabled && AiUsage.sessions.length > 0
    // A space switch (Spaces.activated): its icon and name for 1.2 s
    // (SPACES §6.3), over everything collapsed but a notification.
    property var spaceFlash: null
    readonly property bool spaceShowing: spaceFlash !== null && !expanded && !bannering && !hudShowing && !ringing
    readonly property bool hudMessage: Hud.kind === "message"
    readonly property real hudWidth: hudMessage ? Math.min(460, Math.max(200, hudMessageRow.implicitWidth + 44)) : 300
    readonly property real targetWidth: ringing ? 460 : expanded ? 480 : hudShowing ? hudWidth : bannering ? 460 : spaceShowing ? Math.max(190, spaceRow.implicitWidth + 40) : live !== "" ? 250 : showEvent ? 300 : playing ? 300 : agentMark ? 190 : 150
    readonly property real targetHeight: ringing ? 84 : expanded ? 210 : bannering ? 84 : attached ? barHeight : 24

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
    // Black needs no blur: the region empties (see GlassSurface).
    BackgroundEffect.blurRegion: blur
    Region {
        id: blur
        item: Theme.blur && !root.black ? pill : null
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
        property real radius: root.attached ? (root.expanded ? 30 : root.bannering || root.ringing ? 26 : 12) : root.expanded ? 30 : root.bannering || root.ringing ? 26 : height / 2
        property real shoulder: root.attached ? (root.expanded ? 14 : root.bannering || root.ringing ? 12 : 7) : 0

        // The outline: alerts pulse, unread notifications turn it white;
        // otherwise a glass hairline, or none on black (like the notch).
        property real edgeWidth: root.alerting || (root.unread && !root.expanded) ? 2 : root.black ? 0 : 1
        property color edgeColor: root.alerting ? Theme.withAlpha(root.alertColor, alertPulse.value) : root.unread && !root.expanded ? Theme.islandText : root.black ? "transparent" : Theme.glassBorder

        // Alerts breathe instead of sitting there (stepped: SlowPulse).
        SlowPulse {
            id: alertPulse
            running: root.alerting && !root.expanded
            low: 0.25
        }

        Behavior on width {
            NumberAnimation {
                duration: Motion.ms(320)
                easing.type: Easing.OutQuint
            }
        }
        Behavior on height {
            NumberAnimation {
                duration: Motion.ms(320)
                easing.type: Easing.OutQuint
            }
        }
        Behavior on radius {
            NumberAnimation {
                duration: Motion.ms(320)
                easing.type: Easing.OutQuint
            }
        }
        Behavior on shoulder {
            NumberAnimation {
                duration: Motion.ms(320)
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
                opacity: root.expanded || root.bannering || root.spaceShowing || root.hudShowing || root.ringing ? 0 : 1

                Behavior on opacity {
                    NumberAnimation {
                        duration: Motion.ms(150)
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

                            // Breathes while one works (stepped: SlowPulse).
                            opacity: agentPulse.value
                            SlowPulse {
                                id: agentPulse
                                running: root.agentMark && AiUsage.busy > 0 && !root.expanded
                                low: 0.4
                                period: 1800
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

            // ── Space switch ────────────────────────────────────────────
            Item {
                anchors.fill: parent
                visible: opacity > 0
                opacity: root.spaceShowing ? 1 : 0

                Behavior on opacity {
                    NumberAnimation {
                        duration: Motion.ms(150)
                    }
                }

                Row {
                    id: spaceRow
                    anchors.centerIn: parent
                    spacing: 8

                    Icon {
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.spaceFlash?.icon || "󰕰"
                        size: 14
                        color: Theme.accent
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.spaceFlash?.name ?? ""
                        color: Theme.islandText
                        font.family: Theme.fontUi
                        font.pixelSize: 13
                        font.weight: Font.DemiBold
                    }
                }
            }

            Timer {
                id: spaceTimer
                interval: 1200
                onTriggered: root.spaceFlash = null
            }

            // ── HUD: what just changed (Hud.qml) ────────────────────────
            Item {
                anchors.fill: parent
                visible: opacity > 0
                opacity: root.hudShowing ? 1 : 0

                Behavior on opacity {
                    NumberAnimation {
                        duration: Motion.ms(150)
                    }
                }

                // Volume / brightness: icon, level bar, value.
                RowLayout {
                    anchors {
                        fill: parent
                        leftMargin: 14
                        rightMargin: 14
                    }
                    visible: !root.hudMessage
                    spacing: 10

                    Icon {
                        Layout.preferredWidth: 16
                        text: Hud.levelIcon
                        size: 14
                        color: Hud.muted ? Theme.islandSubtext : Theme.islandText
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 4
                        radius: 2
                        color: Theme.withAlpha(Theme.islandText, 0.18)

                        Rectangle {
                            width: parent.width * Math.max(0, Math.min(1, Hud.value))
                            height: parent.height
                            radius: 2
                            color: Hud.muted ? Theme.withAlpha(Theme.islandText, 0.35) : Theme.accent

                            Behavior on width {
                                NumberAnimation {
                                    duration: Motion.ms(100)
                                }
                            }
                        }
                    }

                    Text {
                        Layout.preferredWidth: 44
                        horizontalAlignment: Text.AlignRight
                        text: Hud.muted ? "Muted" : `${Math.round(Hud.value * 100)}%`
                        color: Hud.muted ? Theme.islandSubtext : Theme.islandText
                        font.family: Theme.fontUi
                        font.pixelSize: 12
                        font.weight: Font.DemiBold
                        font.features: { "tnum": 1 }
                    }
                }

                // Announcements: icon + a line.
                Row {
                    id: hudMessageRow
                    anchors.centerIn: parent
                    visible: root.hudMessage
                    spacing: 8

                    Icon {
                        anchors.verticalCenter: parent.verticalCenter
                        text: Hud.icon
                        size: 14
                        color: Theme.accent
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(implicitWidth, 380)
                        text: Hud.text
                        elide: Text.ElideRight
                        color: Theme.islandText
                        font.family: Theme.fontUi
                        font.pixelSize: 12
                        font.weight: Font.DemiBold
                    }
                }
            }

            // ── Notification banner ─────────────────────────────────────
            // ── Incoming call ──────────────────────────────────────────
            CallBanner {
                anchors {
                    fill: parent
                    margins: 12
                }
                call: root.ringingCall
                visible: opacity > 0
                opacity: root.ringing ? 1 : 0

                Behavior on opacity {
                    NumberAnimation {
                        duration: Motion.ms(180)
                    }
                }
            }

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
                        duration: Motion.ms(180)
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
                        duration: Motion.ms(220)
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
                                duration: Motion.ms(300)
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
                                case "scratchpad":
                                    return scratchpadPage;
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
                                    duration: Motion.ms(200)
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
                        duration: Motion.ms(40)
                        easing.type: Easing.OutExpo
                    }
                    NumberAnimation {
                        target: flash
                        property: "opacity"
                        to: 0
                        duration: Motion.ms(320)
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

    Connections {
        target: Spaces
        function onActivated(space) {
            if (!space)
                return;
            root.spaceFlash = { icon: space.icon, name: space.name };
            spaceTimer.restart();
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
            // The art backdrop follows the island's outline.
            cornerRadius: pill.radius
            squareTop: root.attached
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
    Component {
        id: scratchpadPage
        ScratchpadPage {
            onTypingChanged: root.typing = typing
            Component.onDestruction: root.typing = false
        }
    }

    // IPC (IslandIpc, one handler for all screens): the island on the
    // focused output answers (the first screen's when niri isn't known).
    readonly property bool ipcHere: (Niri.focusedWorkspace?.output ?? Quickshell.screens[0]?.name ?? modelData.name) === modelData.name
    Connections {
        target: IslandIpc
        function onCommand(cmd) {
            if (!root.ipcHere)
                return;
            if (cmd === "toggle")
                root.pinned = !root.pinned;
            else if (cmd === "flash")
                shutter.restart();
            else
                root.showPage(cmd);
        }
    }
}
