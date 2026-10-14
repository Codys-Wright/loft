import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Settings → Displays: arrange outputs by dragging them, and set each one's
// resolution, refresh rate, scale, rotation, VRR and whether it's used.
//
// Edits are staged, then applied together. Arrangement and VRR apply
// directly; resolution, scale, rotation and turning a display off are first
// applied live only, with 15 s to keep them before they revert (like macOS),
// so a mode the monitor can't show undoes itself. Kept changes are recorded
// by the output's Make/Model/Serial identity, never its connector.
ColumnLayout {
    id: page
    spacing: 12

    // Connector of the selected output.
    property string selected: ""
    // connector → { position: {x, y}, mode, scale, transform, vrr, off }
    property var pending: ({})
    // While a change awaits confirmation: { changes, previous } by identity.
    property var confirm: null
    property int countdown: 0

    readonly property var outs: NiriSettings.outputs
    readonly property var sel: outs.find(o => o.name === selected) ?? null
    readonly property bool hasPending: Object.keys(pending).length > 0

    onOutsChanged: if (!sel && outs.length > 0)
        selected = (outs.find(o => o.enabled) ?? outs[0]).name

    // ── Model ───────────────────────────────────────────────────────────
    function stage(name, patch) {
        const p = Object.assign({}, pending);
        p[name] = Object.assign({}, p[name] ?? {}, patch);
        pending = p;
    }

    function parseMode(m) {
        const r = /^(\d+)x(\d+)(?:@([\d.]+))?$/.exec(m ?? "");
        return r ? { w: +r[1], h: +r[2], refresh: r[3] ? +r[3] : 0 } : null;
    }

    // An output with its staged changes applied: geometry in logical px.
    function eff(o) {
        const p = pending[o.name] ?? {};
        const mode = parseMode(p.mode ?? o.mode) ?? { w: 1920, h: 1080, refresh: 60 };
        const scale = p.scale ?? o.scale ?? 1;
        const transform = p.transform ?? o.transform;
        const rotated = ["90", "270", "flipped-90", "flipped-270"].includes(transform);
        const w = Math.round((rotated ? mode.h : mode.w) / scale);
        const h = Math.round((rotated ? mode.w : mode.h) / scale);
        const pos = p.position ?? (o.logical ? { x: o.logical.x, y: o.logical.y } : { x: 0, y: 0 });
        return {
            name: o.name,
            x: pos.x,
            y: pos.y,
            w: w,
            h: h,
            mode: p.mode ?? o.mode,
            modeSize: mode,
            scale: scale,
            transform: transform,
            enabled: p.off !== undefined ? !p.off : o.enabled,
            vrr: p.vrr ?? o.vrr_enabled
        };
    }

    readonly property var rects: outs.map(o => eff(o)).filter(e => e.enabled)

    function overlaps(a, b) {
        return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
    }

    // Snap a dragged rect's edges to the others' edges within `t` logical px.
    function snap(r, others, t) {
        let bestX = null, bestY = null;
        for (const o of others) {
            for (const c of [o.x, o.x + o.w, o.x - r.w, o.x + o.w - r.w])
                if (Math.abs(c - r.x) < t && (bestX === null || Math.abs(c - r.x) < Math.abs(bestX - r.x)))
                    bestX = c;
            for (const c of [o.y, o.y + o.h, o.y - r.h, o.y + o.h - r.h])
                if (Math.abs(c - r.y) < t && (bestY === null || Math.abs(c - r.y) < Math.abs(bestY - r.y)))
                    bestY = c;
        }
        return Object.assign({}, r, { x: bestX ?? r.x, y: bestY ?? r.y });
    }

    // Push a rect out of any overlap, along the shortest way out.
    function separate(r, others) {
        let out = Object.assign({}, r);
        for (let i = 0; i < 16; i++) {
            const o = others.find(o => overlaps(out, o));
            if (!o)
                break;
            const moves = [
                { x: o.x - out.w, y: out.y },
                { x: o.x + o.w, y: out.y },
                { x: out.x, y: o.y - out.h },
                { x: out.x, y: o.y + o.h }
            ];
            moves.sort((a, b) => Math.hypot(a.x - out.x, a.y - out.y) - Math.hypot(b.x - out.x, b.y - out.y));
            out = Object.assign(out, moves[0]);
        }
        return out;
    }

    // ── Apply / confirm ─────────────────────────────────────────────────
    function applyPending() {
        const changes = {};
        const previous = {};
        let needsConfirm = false;
        for (const name in pending) {
            const o = outs.find(o => o.name === name);
            if (!o)
                continue;
            const p = pending[name];
            const c = {};
            const prev = {};
            if (p.off !== undefined) {
                c.off = p.off;
                prev.off = !o.enabled;
                needsConfirm = true;
            }
            if (p.mode !== undefined) {
                c.mode = p.mode;
                prev.mode = o.mode;
                needsConfirm = true;
            }
            if (p.scale !== undefined) {
                c.scale = p.scale;
                prev.scale = o.scale;
                needsConfirm = true;
            }
            if (p.transform !== undefined) {
                c.transform = p.transform;
                prev.transform = o.transform;
                needsConfirm = true;
            }
            if (p.position !== undefined) {
                c.position = p.position;
                if (o.logical)
                    prev.position = { x: o.logical.x, y: o.logical.y };
            }
            if (p.vrr !== undefined) {
                c.vrr = p.vrr;
                prev.vrr = o.vrr_enabled;
            }
            // Turning it back off needs nothing else restored.
            if (prev.off === true)
                previous[o.identity] = { off: true };
            else
                previous[o.identity] = prev;
            changes[o.identity] = c;
        }
        pending = {};
        if (!needsConfirm) {
            NiriSettings.setOutputs(changes, true, true);
            return;
        }
        // If niri refuses the change there's nothing to confirm.
        NiriSettings.setOutputs(changes, true, false, r => {
            if (!r.ok) {
                confirmTimer.stop();
                page.confirm = null;
            }
        });
        confirm = { changes: changes, previous: previous };
        countdown = 15;
        confirmTimer.restart();
    }

    function keep() {
        confirmTimer.stop();
        if (confirm)
            NiriSettings.setOutputs(confirm.changes, false, true);
        confirm = null;
    }

    function revert() {
        confirmTimer.stop();
        if (confirm)
            NiriSettings.setOutputs(confirm.previous, true, false);
        confirm = null;
    }

    Timer {
        id: confirmTimer
        interval: 1000
        repeat: true
        onTriggered: {
            page.countdown -= 1;
            if (page.countdown <= 0)
                page.revert();
        }
    }

    // ── Arrangement ─────────────────────────────────────────────────────
    SettingsCard {
        PageHeader {
            title: "Arrangement"
            SettingsButton {
                text: "Identify"
                icon: "󰍹"
                onClicked: NiriSettings.identify()
            }
        }

        Text {
            Layout.fillWidth: true
            text: page.outs.length === 0 ? "No outputs reported by niri (is $NIRI_SOCKET set?)" : "Drag displays to arrange them. Edges snap together."
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }

        Rectangle {
            id: canvas
            Layout.fillWidth: true
            // Fit the arrangement's aspect ratio, within limits.
            Layout.preferredHeight: Math.max(150, Math.min(280, (width - 48) * aspect + 48))
            radius: 12
            color: Theme.withAlpha(Theme.bg, 0.35)
            border.width: 1
            border.color: Theme.withAlpha(Theme.text, 0.06)
            clip: true

            // Logical → canvas mapping, frozen while dragging so the view
            // doesn't rescale under the pointer.
            property bool dragging: false
            property var frozen: null
            readonly property var live: {
                const rs = page.rects;
                if (rs.length === 0)
                    return { bx: 0, by: 0, k: 1, ox: 0, oy: 0 };
                const bx = Math.min(...rs.map(r => r.x));
                const by = Math.min(...rs.map(r => r.y));
                const bw = Math.max(...rs.map(r => r.x + r.w)) - bx;
                const bh = Math.max(...rs.map(r => r.y + r.h)) - by;
                const k = Math.min((width - 48) / bw, (height - 48) / bh);
                return { bx: bx, by: by, k: k, ox: (width - bw * k) / 2, oy: (height - bh * k) / 2 };
            }
            readonly property var map: dragging && frozen ? frozen : live
            readonly property real aspect: {
                const rs = page.rects;
                if (rs.length === 0)
                    return 0.5;
                const bw = Math.max(...rs.map(r => r.x + r.w)) - Math.min(...rs.map(r => r.x));
                const bh = Math.max(...rs.map(r => r.y + r.h)) - Math.min(...rs.map(r => r.y));
                return bh / bw;
            }

            Repeater {
                model: page.rects

                delegate: Rectangle {
                    id: tile
                    required property var modelData
                    readonly property bool isSelected: modelData.name === page.selected
                    readonly property var m: canvas.map
                    property real dragX: 0
                    property real dragY: 0
                    property bool held: false

                    x: m.ox + (modelData.x - m.bx) * m.k + (held ? dragX : 0)
                    y: m.oy + (modelData.y - m.by) * m.k + (held ? dragY : 0)
                    width: Math.max(8, modelData.w * m.k - 3)
                    height: Math.max(8, modelData.h * m.k - 3)
                    z: held ? 2 : isSelected ? 1 : 0
                    radius: 8
                    color: isSelected ? Theme.withAlpha(Theme.accent, 0.35) : Theme.withAlpha(Theme.surface, 0.85)
                    border.width: isSelected ? 2 : 1
                    border.color: isSelected ? Theme.accent : Theme.glassBorder

                    Behavior on x {
                        enabled: !tile.held
                        NumberAnimation {
                            duration: 160
                            easing.type: Easing.OutCubic
                        }
                    }
                    Behavior on y {
                        enabled: !tile.held
                        NumberAnimation {
                            duration: 160
                            easing.type: Easing.OutCubic
                        }
                    }

                    // A bar-like strip on top, like a tiny desktop.
                    Rectangle {
                        anchors {
                            left: parent.left
                            right: parent.right
                            top: parent.top
                            margins: 3
                        }
                        height: Math.min(6, parent.height / 8)
                        radius: 2
                        color: Theme.withAlpha(Theme.text, 0.18)
                    }

                    Column {
                        anchors.centerIn: parent
                        spacing: 1
                        width: parent.width - 8

                        Text {
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                            text: tile.modelData.name
                            color: Theme.text
                            font.family: Theme.fontUi
                            font.pixelSize: 12
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                        }
                        Text {
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                            visible: tile.height > 40
                            text: `${tile.modelData.modeSize.w}×${tile.modelData.modeSize.h}`
                            color: Theme.subtext
                            font.family: Theme.fontUi
                            font.pixelSize: 10
                            elide: Text.ElideRight
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: tile.held ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                        property point start
                        onPressed: mouse => {
                            page.selected = tile.modelData.name;
                            canvas.frozen = canvas.live;
                            canvas.dragging = true;
                            start = mapToItem(canvas, mouse.x, mouse.y);
                            tile.dragX = 0;
                            tile.dragY = 0;
                            tile.held = true;
                        }
                        onPositionChanged: mouse => {
                            if (!tile.held)
                                return;
                            const p = mapToItem(canvas, mouse.x, mouse.y);
                            const k = tile.m.k;
                            const others = page.rects.filter(r => r.name !== tile.modelData.name);
                            // Snap in logical space, show it in canvas space.
                            const raw = Object.assign({}, tile.modelData, {
                                x: tile.modelData.x + (p.x - start.x) / k,
                                y: tile.modelData.y + (p.y - start.y) / k
                            });
                            const s = page.snap(raw, others, 14 / k);
                            tile.dragX = (s.x - tile.modelData.x) * k;
                            tile.dragY = (s.y - tile.modelData.y) * k;
                        }
                        onReleased: {
                            if (!tile.held)
                                return;
                            const k = tile.m.k;
                            const moved = Math.abs(tile.dragX) + Math.abs(tile.dragY) > 2;
                            // Staging re-creates the tiles (new model), so
                            // end the drag first.
                            tile.held = false;
                            canvas.dragging = false;
                            if (moved) {
                                const others = page.rects.filter(r => r.name !== tile.modelData.name);
                                let r = Object.assign({}, tile.modelData, {
                                    x: Math.round(tile.modelData.x + tile.dragX / k),
                                    y: Math.round(tile.modelData.y + tile.dragY / k)
                                });
                                r = page.separate(page.snap(r, others, 14 / k), others);
                                page.stage(tile.modelData.name, {
                                    position: { x: Math.round(r.x), y: Math.round(r.y) }
                                });
                            }
                        }
                    }
                }
            }
        }

        // Outputs that are off don't take part in the arrangement.
        Flow {
            Layout.fillWidth: true
            spacing: 8
            visible: page.outs.some(o => !page.eff(o).enabled)

            Repeater {
                model: page.outs.filter(o => !page.eff(o).enabled)
                delegate: SettingsButton {
                    required property var modelData
                    text: `${modelData.name} (off)`
                    icon: "󰶐"
                    onClicked: page.selected = modelData.name
                }
            }
        }
    }

    // ── Pending / confirm bar ───────────────────────────────────────────
    GlassSurface {
        Layout.fillWidth: true
        visible: page.hasPending || page.confirm !== null
        implicitHeight: 48
        radius: 14
        showHighlight: false
        strength: 1.2
        border.color: page.confirm ? Theme.warn : Theme.accent

        RowLayout {
            anchors {
                fill: parent
                leftMargin: 14
                rightMargin: 10
            }
            spacing: 8

            Icon {
                text: page.confirm ? "󰔟" : "󰏫"
                size: 15
                color: page.confirm ? Theme.warn : Theme.accent
            }
            Text {
                Layout.fillWidth: true
                text: page.confirm ? `Keep these display settings? Reverting in ${page.countdown} s` : "Display changes not applied yet"
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 13
                elide: Text.ElideRight
            }
            SettingsButton {
                text: "Revert"
                onClicked: page.confirm ? page.revert() : (page.pending = {})
            }
            SettingsButton {
                primary: true
                text: page.confirm ? "Keep" : "Apply"
                onClicked: page.confirm ? page.keep() : page.applyPending()
            }
        }
    }

    // ── Selected output ─────────────────────────────────────────────────
    SettingsCard {
        id: details
        visible: page.sel !== null
        readonly property var o: page.sel
        readonly property var e: o ? page.eff(o) : null
        readonly property string identity: o?.identity ?? ""
        readonly property bool hasOverride: NiriSettings.outputOverrides[identity] !== undefined

        PageHeader {
            title: details.o ? (details.o.description || details.o.name) : ""
            Rectangle {
                implicitWidth: connLabel.implicitWidth + 14
                implicitHeight: 20
                radius: 10
                color: Theme.withAlpha(Theme.text, 0.1)
                Text {
                    id: connLabel
                    anchors.centerIn: parent
                    text: details.o?.name ?? ""
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 11
                }
            }
            SettingsButton {
                visible: details.hasOverride
                text: "Reset"
                onClicked: NiriSettings.resetOutput(details.identity)
            }
        }

        Text {
            Layout.fillWidth: true
            text: {
                const o = details.o;
                if (!o)
                    return "";
                const size = o.physical_size ? ` · ${Math.round(Math.hypot(o.physical_size[0], o.physical_size[1]) / 25.4)}″` : "";
                const src = details.hasOverride ? " · changed here" : "";
                return `${o.identity}${size}${src}`;
            }
            color: details.hasOverride ? Theme.accent : Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
            elide: Text.ElideMiddle
        }

        SettingsRow {
            label: "Use this display"
            hint: details.e && !details.e.enabled ? "Off" : ""
            SettingsSwitch {
                checked: details.e?.enabled ?? false
                // Never turn off the last display that's on.
                enabled: !(checked && page.rects.length <= 1)
                onToggled: on => page.stage(details.o.name, { off: !on })
            }
        }

        SettingsRow {
            label: "Resolution"
            hint: {
                const s = details.e?.modeSize;
                const pref = (details.o?.modes ?? []).find(m => m.preferred);
                return pref && s && pref.width === s.w && pref.height === s.h ? "Native (preferred)" : "";
            }
            enabled: details.e?.enabled ?? false
            SettingsSelect {
                options: {
                    const seen = new Set();
                    const out = [];
                    for (const m of details.o?.modes ?? []) {
                        const k = `${m.width}x${m.height}`;
                        if (seen.has(k))
                            continue;
                        seen.add(k);
                        out.push({ value: k, label: `${m.width} × ${m.height}${m.preferred ? "  (native)" : ""}`, area: m.width * m.height });
                    }
                    return out.sort((a, b) => b.area - a.area);
                }
                current: details.e ? `${details.e.modeSize.w}x${details.e.modeSize.h}` : ""
                onActivated: v => {
                    // Keep the refresh rate if the new size has it, else the highest.
                    const cands = details.o.modes.filter(m => `${m.width}x${m.height}` === v);
                    const want = details.e.modeSize.refresh;
                    cands.sort((a, b) => Math.abs(a.refresh - want) - Math.abs(b.refresh - want) || b.refresh - a.refresh);
                    page.stage(details.o.name, { mode: cands[0].mode });
                }
            }
        }

        SettingsRow {
            label: "Refresh rate"
            enabled: details.e?.enabled ?? false
            SettingsSelect {
                options: (details.o?.modes ?? []).filter(m => details.e && m.width === details.e.modeSize.w && m.height === details.e.modeSize.h).sort((a, b) => b.refresh_mhz - a.refresh_mhz).map(m => ({
                            value: m.mode,
                            label: `${m.refresh.toFixed(2)} Hz`
                        }))
                current: details.e?.mode ?? ""
                onActivated: v => page.stage(details.o.name, { mode: v })
            }
        }

        SettingsRow {
            label: "Scale"
            hint: details.e ? `Looks like ${details.e.w} × ${details.e.h}` : ""
            enabled: details.e?.enabled ?? false
            SettingsSegmented {
                readonly property var presets: [1, 1.25, 1.5, 1.75, 2, 3]
                options: {
                    const s = details.e?.scale ?? 1;
                    const list = presets.includes(s) ? presets : presets.concat([s]).sort((a, b) => a - b);
                    return list.map(v => ({ value: v, label: `${v}×` }));
                }
                current: details.e?.scale ?? 1
                onActivated: v => page.stage(details.o.name, { scale: v })
            }
        }

        SettingsRow {
            label: "Rotation"
            enabled: details.e?.enabled ?? false
            SettingsSegmented {
                options: [
                    { value: "normal", label: "Standard" },
                    { value: "90", label: "90°" },
                    { value: "180", label: "180°" },
                    { value: "270", label: "270°" }
                ]
                current: details.e?.transform ?? "normal"
                onActivated: v => page.stage(details.o.name, { transform: v })
            }
        }

        SettingsRow {
            label: "Variable refresh rate"
            hint: details.o?.vrr_supported ? "Adaptive sync (FreeSync / G-Sync compatible)" : "Not supported by this display"
            enabled: (details.o?.vrr_supported ?? false) && (details.e?.enabled ?? false)
            SettingsSwitch {
                checked: details.e?.vrr ?? false
                onToggled: on => page.stage(details.o.name, { vrr: on })
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        visible: Object.keys(NiriSettings.outputOverrides).length > 0

        Text {
            Layout.fillWidth: true
            text: `Display changes are saved for ${Object.keys(NiriSettings.outputOverrides).length} display(s), by make, model and serial.`
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }
        SettingsButton {
            text: "Reset all displays"
            onClicked: NiriSettings.apply({ reset_outputs: Object.keys(NiriSettings.outputOverrides) })
        }
    }

    Text {
        Layout.fillWidth: true
        visible: NiriSettings.error !== ""
        text: NiriSettings.error
        color: Theme.urgent
        font.family: Theme.fontUi
        font.pixelSize: 11
        wrapMode: Text.Wrap
    }
}
