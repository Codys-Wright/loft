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
import "paging.js" as Paging

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
// notification banner (3 s; hovering holds
// it so its buttons can be clicked), a live activity (screen recording,
// focus timer, timers, downloads — scroll to cycle when several run), the
// next calendar event when it's close, now playing (art + equalizer), the
// time — with a mark while AI agents run. A space switch shows the space's
// icon and name for a moment (Spaces.activated). The border pulses on system alerts
// (overheating / overload) and turns white for unread notifications.
//
// Swipe up — drag it upwards (or scroll up over a banner) — to send away
// what's there, all at once: an open island closes, a banner goes, and a
// system alert's outline goes quiet (IslandIpc: until it clears or gets
// worse, on every screen). A call stays until it is answered or declined.
//
// Hover expands it into a carousel of pages (IslandPages: order and which
// are shown live in Settings → Dynamic Island) — live activity, camera,
// notifications, calendar, media, timers, controls, system, screen time, AI
// agents; scroll to switch.
// IPC: island toggle|close|next|prev|page <id>|media|system|usage|
// notifications|live|calendar|timers|controls|ai|scratchpad|flash.
//
// Paging, expanded: the wheel or a horizontal touchpad swipe (one page per
// gesture), the ‹ › that appear at its edges, the page dots (click; hover
// names the page), ← / → once it has the keyboard (click it; Esc closes),
// and Mod+Alt+← / → (shell-binds). A page picked by hand is where it opens
// next time, for `chosenMs`, unless a live activity has started since.
//
// Full screen (FullscreenChrome; Settings → Dynamic Island → Hide in full
// screen): while this display shows a fullscreen window the island slides up
// out of sight and takes no input, and comes back down with the menu bar when
// the pointer reaches the top edge. An incoming call, a notification banner
// or a page opened on purpose (IPC, Mod+Alt+←/→) still drop down; volume /
// brightness show in the bottom pill (Osd.qml) instead.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    // Away in full screen (once it has slid off): unmapped, so the
    // fullscreen app keeps every pixel's input (not an empty mask: see
    // `mask`). Mapping again also puts it back above the bar, which moves to
    // Overlay in full screen.
    visible: !concealed || (pill.opacity > 0 && slide.y > -(pill.height + 6))
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "loft:island"
    // Sit inside the bar's strip rather than below its exclusive zone.
    exclusionMode: ExclusionMode.Ignore
    // Expanded, the keyboard on click: ← / → page, Esc closes, and the
    // Scratchpad's text field.
    WlrLayershell.keyboardFocus: expanded ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
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
    // Esc closed it under the pointer: stays closed until the pointer leaves.
    property bool dismissed: false
    readonly property bool expanded: !ringing && (pinned || typing || (hover.hovered && banner === null && !dismissed))
    // A call (a "call" live activity) keeps the island to itself.
    readonly property bool calling: liveActivities.includes("call")
    // What just changed (Hud.qml), on the focused output's island: over
    // everything collapsed, but not over an expanded island, a call, or a
    // banner the pointer is on.
    readonly property bool hudShowing: Hud.inIsland && Hud.onScreen(modelData.name) && !expanded && !calling && !(banner !== null && hover.hovered) && !awayInFullscreen
    readonly property bool bannering: banner !== null && !expanded && !hudShowing && !ringing

    // Full screen: away (no input) unless something asks to be seen. The
    // bar's reveal brings it back (FullscreenChrome.islandConcealedOn).
    readonly property bool awayInFullscreen: FullscreenChrome.islandConcealedOn(modelData.name)
    readonly property bool concealed: awayInFullscreen && !ringing && !pinned && !typing && !(banner !== null)
    // Hovered or open: keeps a revealed bar down while the pointer is here.
    readonly property bool busy: !concealed && (hover.hovered || expanded)
    onBusyChanged: FullscreenChrome.setIslandBusy(modelData.name, busy)
    Component.onDestruction: FullscreenChrome.setIslandBusy(modelData.name, false)

    // Unread = notifications arrived since the notifications page was last seen.
    property int seenCount: 0
    readonly property bool unread: Notifications.history.length > seenCount

    readonly property color alertColor: IslandIpc.alertLevel === "urgent" ? Theme.urgent : IslandIpc.alertLevel === "warn" ? Theme.warn : "transparent"
    // Swiped away: quiet until it clears or gets worse (IslandIpc).
    readonly property bool alerting: alertColor.a > 0 && !IslandIpc.alertQuiet

    readonly property bool showEvent: live === "" && soonEvent !== null
    readonly property bool agentMark: Settings.island.aiIndicator && AiUsage.enabled && AiUsage.sessions.length > 0
    // A space switch (Spaces.activated): its icon and name for 1.2 s
    // (SPACES §6.3), over everything collapsed but a notification.
    property var spaceFlash: null
    readonly property bool spaceShowing: spaceFlash !== null && !expanded && !bannering && !hudShowing && !ringing
    readonly property bool hudMessage: Hud.kind === "message"
    readonly property real hudWidth: hudMessage ? Math.min(460, Math.max(200, hudMessageRow.implicitWidth + 44)) : 300
    // Each content layer is laid out at its own size, never the animating
    // pill's (IslandLayer): the pill clips it while the shape morphs.
    readonly property real spaceWidth: Math.max(190, spaceRow.implicitWidth + 40)
    readonly property real compactWidth: live !== "" ? 250 : showEvent ? 300 : playing ? 300 : agentMark ? 190 : 150
    readonly property real compactHeight: attached ? barHeight : 24
    readonly property real expandedWidth: 480
    readonly property real expandedHeight: 210
    readonly property real bannerWidth: 460
    readonly property real bannerHeight: 84
    readonly property real targetWidth: ringing ? bannerWidth : expanded ? expandedWidth : hudShowing ? hudWidth : bannering ? bannerWidth : spaceShowing ? spaceWidth : compactWidth
    readonly property real targetHeight: ringing || (bannering && !expanded) ? bannerHeight : expanded ? expandedHeight : compactHeight

    // ── Look (Settings → Dynamic Island) ────────────────────────────────
    readonly property bool attached: Settings.island.style !== "floating"
    readonly property bool black: Theme.islandBlack
    // Collapsed and attached, it fills the menu bar's strip (Bar.qml).
    readonly property int barHeight: 30

    function showPage(name) {
        pinned = true;
        choose(pages.includes(name) ? name : pages[0]);
    }

    function step(delta) {
        choose(pages[(pageIndex + delta + pages.length) % pages.length]);
    }

    // A page picked by hand (wheel, swipe, ‹ ›, dots, keys, IPC): the island
    // opens on it again for `chosenMs` instead of jumping back to the most
    // relevant page — unless a live activity has started since.
    readonly property int chosenMs: 5 * 60 * 1000
    property string chosenPage: ""
    property real chosenAt: 0
    property var chosenLive: []
    function choose(p) {
        page = p;
        chosenPage = p;
        chosenAt = Date.now();
        chosenLive = liveActivities.slice();
    }
    function remembered() {
        if (chosenPage === "" || !pages.includes(chosenPage) || Date.now() - chosenAt > chosenMs)
            return "";
        return liveActivities.some(a => !chosenLive.includes(a)) ? "" : chosenPage;
    }

    // Swipe up: send away all of it at once — the pointer that swipes has
    // to hover the island first, which opens it, so "one thing per swipe"
    // only ever closed it. Returns whether there was anything.
    function swipeAway() {
        if (ringing)
            return false;
        let any = false;
        if (alerting) {
            IslandIpc.alertSilenced = IslandIpc.alertLevel;
            any = true;
        }
        if (banner !== null && !expanded) {
            Notifications.next();
            any = true;
        }
        if (expanded) {
            dismiss();
            any = true;
        }
        return any;
    }

    // Close, even under the pointer (Esc): until the pointer leaves.
    function dismiss() {
        pinned = false;
        if (hover.hovered)
            dismissed = true;
    }

    // ── Paging gestures (paging.js) ─────────────────────────────────────
    property var _wheel: Paging.fresh()
    function wheelStep(event) {
        const r = Paging.step(_wheel, {
            ax: event.angleDelta.x,
            ay: event.angleDelta.y,
            px: event.pixelDelta.x,
            py: event.pixelDelta.y
        }, Date.now());
        _wheel = r.st;
        wheelIdle.restart();
        return r.d;
    }
    Timer {
        id: wheelIdle
        interval: 200
        onTriggered: root._wheel = Paging.idle()
    }

    // The wheel / swipe handler (two on the pill: vertical and horizontal).
    component PageWheel: WheelHandler {
        acceptedDevices: PointerDevice.AllDevices
        onWheel: event => {
            const d = root.wheelStep(event);
            if (d === 0)
                return;
            if (root.expanded)
                root.step(d);
            else if (d < 0 && orientation === Qt.Vertical && root.swipeAway())
                return;
            else if (root.liveActivities.length > 1)
                root.liveIndex = (root.liveIndex + 1) % root.liveActivities.length;
        }
    }

    onExpandedChanged: {
        if (expanded)
            keys.forceActiveFocus();
        // Open on the most relevant page.
        if (expanded && !pinned)
            page = remembered() || ([live !== "" ? "live" : "", unread ? "notifications" : "", soonEvent ? "calendar" : "", player ? "media" : "", "system"].find(p => p && pages.includes(p)) ?? pages[0]);
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
    // The pill's resting place (hitBox), not the pill: a Region maps its
    // item with transforms, so the pill mid-slide (Translate, below) would
    // give an empty mask, which Quickshell makes WindowTransparentForInput
    // for good (QtWayland never drops it when the mask fills again).
    mask: Region {
        item: hitBox
        topLeftRadius: root.attached ? 0 : pill.radius
        topRightRadius: root.attached ? 0 : pill.radius
        bottomLeftRadius: pill.radius
        bottomRightRadius: pill.radius
    }
    // Black needs no blur: the region empties (see GlassSurface).
    BackgroundEffect.blurRegion: blur
    Region {
        id: blur
        item: Theme.blur && !root.black && !root.concealed ? hitBox : null
        topLeftRadius: root.attached ? 0 : pill.radius
        topRightRadius: root.attached ? 0 : pill.radius
        bottomLeftRadius: pill.radius
        bottomRightRadius: pill.radius
    }

    Item {
        id: hitBox
        anchors {
            top: parent.top
            horizontalCenter: parent.horizontalCenter
        }
        width: pill.width
        height: pill.height
    }

    Item {
        id: pill
        anchors {
            top: parent.top
            horizontalCenter: parent.horizontalCenter
        }
        width: root.targetWidth
        height: root.targetHeight

        // Full screen: slid up past the top edge (Reduce Motion: faded).
        transform: Translate {
            id: slide
            y: root.concealed && !Motion.reduce ? -(pill.height + 6) : 0
            Behavior on y {
                enabled: !Motion.reduce
                NumberAnimation {
                    duration: Motion.ms(240)
                    easing.type: Easing.OutCubic
                }
            }
        }
        opacity: root.concealed && Motion.reduce ? 0 : 1
        Behavior on opacity {
            enabled: Motion.reduce
            NumberAnimation {
                duration: Motion.ms(160)
            }
        }

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

        // The shape morph: a springy settle (a slight overshoot) growing
        // into the expanded island or a banner, a quick ease back down.
        // Reduce Motion: it jumps; only the content cross-fades.
        readonly property bool springy: root.expanded || root.bannering || root.ringing
        readonly property int morphMs: Motion.ms(springy ? 460 : 340)
        readonly property int morphEasing: springy ? Easing.OutBack : Easing.OutQuint

        Behavior on width {
            enabled: !Motion.reduce
            NumberAnimation {
                duration: pill.morphMs
                easing.type: pill.morphEasing
                easing.overshoot: 0.9
            }
        }
        Behavior on height {
            enabled: !Motion.reduce
            NumberAnimation {
                duration: pill.morphMs
                easing.type: pill.morphEasing
                easing.overshoot: 0.9
            }
        }
        Behavior on radius {
            enabled: !Motion.reduce
            NumberAnimation {
                duration: pill.morphMs
                easing.type: Easing.OutQuint
            }
        }
        Behavior on shoulder {
            enabled: !Motion.reduce
            NumberAnimation {
                duration: pill.morphMs
                easing.type: Easing.OutQuint
            }
        }

        // A fresh HoverHandler each time the window maps: an unmapped
        // window gets no leave event, so one kept across going away in full
        // screen with the pointer on it would stay hovered for good (and
        // hold every later banner on screen).
        QtObject {
            id: hover
            readonly property bool hovered: hoverLoader.item?.hovered ?? false
            onHoveredChanged: if (!hovered)
                root.dismissed = false
        }
        Loader {
            id: hoverLoader
            anchors.fill: parent
            active: root.visible
            sourceComponent: Item {
                readonly property alias hovered: handler.hovered
                HoverHandler {
                    id: handler
                }
            }
        }

        // Expanded: a wheel notch or a swipe (either axis) pages; collapsed,
        // it cycles live activities. Two handlers, as a WheelHandler takes
        // one orientation (vertical by default). All devices: QtWayland
        // delivers even a mouse wheel's events from a "touchpad" device
        // (type TouchPad, with pixel deltas), and WheelHandler takes only
        // PointerDevice.Mouse by default — so wheel paging never fired at
        // all. Children that scroll (a long notification list) take the
        // vertical wheel first; a horizontal swipe still pages over them.
        PageWheel {
            orientation: Qt.Vertical
        }
        PageWheel {
            orientation: Qt.Horizontal
        }

        // Swipe up: press and drag upwards 14 px — a fixed distance, not the
        // pill's: hovering has already opened it to full height, and the
        // screen edge is right above. Takes over only once the drag starts,
        // so clicks on the pages' buttons still work.
        DragHandler {
            target: null
            xAxis.enabled: false
            dragThreshold: 6
            property real dy: 0
            onActiveTranslationChanged: dy = activeTranslation.y
            onActiveChanged: {
                if (!active && dy < -14)
                    root.swipeAway();
                dy = 0;
            }
        }

        // Keys while expanded (focus on click): ← / → page, Esc closes.
        Item {
            id: keys
            focus: root.expanded
            Keys.onLeftPressed: root.step(-1)
            Keys.onRightPressed: root.step(1)
            Keys.onEscapePressed: root.dismiss()
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

        // The body's outline as a mask (the bottom corners; square top when
        // attached), so content that reaches the corners — the media art,
        // a page mid-slide — is cut to the shape, not to its bounding box.
        Item {
            id: shapeMask
            anchors.fill: parent
            visible: false
            layer.enabled: body.clipToShape
            Rectangle {
                anchors.fill: parent
                radius: pill.radius
            }
            Rectangle {
                visible: root.attached
                width: parent.width
                height: Math.min(parent.height, pill.radius + 1)
            }
        }

        // ── Content ─────────────────────────────────────────────────────
        // Layers (IslandLayer) cross over in step with the morph: the one
        // leaving fades at once, the one arriving waits for the shape.
        Item {
            id: body
            anchors.fill: parent
            clip: true

            // On clear glass, a soft shadow under the content (as
            // GlassSurface gives its own children).
            readonly property bool shadowed: !root.black && Theme.textShadowStrength > 0.02
            // Only while big content is up: the compact layers stay inside
            // the corners, and an idle collapsed island stays one plain item.
            readonly property bool clipToShape: expandedLayer.visible || bannerLayer.visible || callLayer.visible
            layer.enabled: shadowed || clipToShape
            layer.effect: MultiEffect {
                shadowEnabled: body.shadowed
                shadowColor: Theme.textShadow
                shadowBlur: 0.35
                shadowVerticalOffset: 1
                shadowHorizontalOffset: 0
                maskEnabled: body.clipToShape
                maskSource: shapeMask
                maskThresholdMin: 0.5
                maskSpreadAtMin: 1
            }

            // ── Collapsed ───────────────────────────────────────────────
            IslandLayer {
                id: compactLayer
                anchors {
                    top: parent.top
                    horizontalCenter: parent.horizontalCenter
                }
                // Stretches with the pill between compact sizes (time ↔
                // now playing), never into the expanded island.
                width: Math.min(pill.width, root.compactWidth)
                height: root.compactHeight
                shown: !(root.expanded || root.bannering || root.spaceShowing || root.hudShowing || root.ringing)
                inDelay: 140
                inDuration: 160

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
            IslandLayer {
                anchors {
                    top: parent.top
                    horizontalCenter: parent.horizontalCenter
                }
                width: Math.min(pill.width, root.spaceWidth)
                height: root.compactHeight
                shown: root.spaceShowing
                inDelay: 60
                inDuration: 150

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
            IslandLayer {
                anchors {
                    top: parent.top
                    horizontalCenter: parent.horizontalCenter
                }
                width: Math.min(pill.width, root.hudWidth)
                height: root.compactHeight
                shown: root.hudShowing
                inDelay: 60
                inDuration: 150

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
            IslandLayer {
                id: callLayer
                anchors {
                    top: parent.top
                    horizontalCenter: parent.horizontalCenter
                }
                width: root.bannerWidth
                height: root.bannerHeight
                shown: root.ringing
                inDelay: 150
                fromScale: 0.96

                CallBanner {
                    anchors {
                        fill: parent
                        margins: 12
                    }
                    call: root.ringingCall
                }
            }

            IslandLayer {
                id: bannerLayer
                anchors {
                    top: parent.top
                    horizontalCenter: parent.horizontalCenter
                }
                width: root.bannerWidth
                height: root.bannerHeight
                shown: root.bannering
                inDelay: 150
                fromScale: 0.96

                Banner {
                    anchors {
                        fill: parent
                        margins: 12
                    }
                    notification: root.banner
                }
            }

            // Each banner shows for 3 s (hovering holds it, so its buttons
            // can be clicked). Repeating, and restarted per banner: a one-shot
            // Timer stops itself after firing while `bannering` stays true for
            // the next banner in the queue, so the binding never ran again and
            // every banner after the first stayed up until the pointer passed.
            Timer {
                id: bannerTimer
                running: root.bannering && !hover.hovered
                repeat: true
                interval: 3000
                onTriggered: Notifications.next()
            }
            Connections {
                target: root
                function onBannerChanged() {
                    if (bannerTimer.running)
                        bannerTimer.restart();
                }
            }

            // ── Expanded: page carousel ─────────────────────────────────
            // At its final size from the first frame (nothing reflows while
            // the shape opens); it comes in once the shape is mostly open
            // and leaves at once when it closes.
            IslandLayer {
                id: expandedLayer
                anchors {
                    top: parent.top
                    horizontalCenter: parent.horizontalCenter
                }
                width: root.expandedWidth
                height: root.expandedHeight
                shown: root.expanded
                inDelay: 120
                inDuration: 220
                outDuration: 80
                fromScale: 0.96

                // The pages side by side on one track; paging slides the
                // track, so the way between two pages is always continuous
                // (a jump of several passes them by) and clipped. Snaps
                // while the layer is coming in: opening on the most
                // relevant page never slides.
                Item {
                    id: viewport
                    anchors.fill: parent
                    clip: true

                    Item {
                        id: track
                        height: parent.height
                        x: -root.pageIndex * viewport.width

                        Behavior on x {
                            enabled: expandedLayer.settled && !Motion.reduce
                            NumberAnimation {
                                duration: Motion.ms(380)
                                easing.type: Easing.OutCubic
                            }
                        }

                        Repeater {
                            model: root.pages

                            delegate: Item {
                                id: slot
                                required property string modelData
                                required property int index

                                x: index * viewport.width
                                width: viewport.width
                                height: viewport.height
                                // On screen (or sliding through it) only.
                                visible: x + track.x > -width && x + track.x < width

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
                    }
                }

                // ‹ › at the edges, shown while the pointer is on that edge.
                Repeater {
                    model: root.pages.length > 1 ? [-1, 1] : []

                    delegate: MouseArea {
                        id: edge
                        required property int modelData
                        anchors {
                            top: parent.top
                            bottom: parent.bottom
                            topMargin: 24
                            bottomMargin: 24
                            left: modelData < 0 ? parent.left : undefined
                            right: modelData > 0 ? parent.right : undefined
                        }
                        width: 28
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.step(modelData)

                        Icon {
                            anchors {
                                verticalCenter: parent.verticalCenter
                                horizontalCenter: parent.horizontalCenter
                                horizontalCenterOffset: edge.modelData < 0 ? -3 : 3
                            }
                            text: edge.modelData < 0 ? "󰅁" : "󰅂"
                            size: 20
                            color: Theme.islandText
                            opacity: edge.containsMouse ? (edge.pressed ? 0.6 : 0.95) : 0

                            Behavior on opacity {
                                NumberAnimation {
                                    duration: Motion.ms(120)
                                }
                            }
                        }
                    }
                }

                // Page dots: click one to go there; hovering names it.
                Row {
                    id: dots
                    anchors {
                        bottom: parent.bottom
                        horizontalCenter: parent.horizontalCenter
                        bottomMargin: 2
                    }
                    property int hovered: -1

                    Repeater {
                        model: root.pages.length
                        delegate: MouseArea {
                            id: dot
                            required property int index
                            readonly property bool current: index === root.pageIndex
                            // A dot is 6 px; its target is 18 × 18.
                            width: (current ? 14 : 6) + 12
                            height: 18
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.choose(root.pages[index])
                            onContainsMouseChanged: {
                                if (containsMouse)
                                    dots.hovered = index;
                                else if (dots.hovered === index)
                                    dots.hovered = -1;
                            }

                            Behavior on width {
                                NumberAnimation {
                                    duration: Motion.ms(200)
                                }
                            }

                            Rectangle {
                                anchors.centerIn: parent
                                width: parent.width - 12
                                height: 6
                                radius: 3
                                color: Theme.islandText
                                opacity: dot.current ? 0.9 : dot.containsMouse ? 0.6 : 0.3
                            }
                        }
                    }
                }

                // The hovered dot's page name, beside the dots (the row
                // under the pages is theirs; never over a page's content).
                Text {
                    anchors {
                        verticalCenter: dots.verticalCenter
                        left: dots.right
                        leftMargin: 4
                    }
                    text: dots.hovered >= 0 ? (IslandPages.info(root.pages[dots.hovered])?.label ?? "") : ""
                    color: Theme.islandSubtext
                    font.family: Theme.fontUi
                    font.pixelSize: 10
                    font.weight: Font.DemiBold
                    opacity: dots.hovered >= 0 ? 1 : 0

                    Behavior on opacity {
                        NumberAnimation {
                            duration: Motion.ms(120)
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
            // The island clips it to its outline (body's shape mask).
            cornerRadius: 0
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
            else if (cmd === "close")
                root.dismiss();
            else if (cmd === "dismiss")
                root.swipeAway();
            else if (cmd === "next" || cmd === "prev") {
                if (root.expanded)
                    root.step(cmd === "next" ? 1 : -1);
                else
                    root.showPage(root.page);
            } else if (cmd === "flash")
                shutter.restart();
            else
                root.showPage(cmd);
        }
    }
}
