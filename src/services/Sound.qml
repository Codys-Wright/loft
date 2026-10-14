pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire

// Sound: the PipeWire graph as the shell sees it — outputs, inputs, app
// streams grouped per app — plus the actions on it (Features: "mixer",
// "audioOutputs", "micTools"). Surfaces (src/audio/, the bar, the Control
// Center, the OSD) only read these properties and call these functions.
//
// Volumes are Quickshell's linear 0..1 scale (1 = 100 %); app streams may go
// to Settings.sound.boost ? 1.5 : 1. Moving a stream to another output sets
// its `target.object` in PipeWire's default metadata (pw-metadata) — the
// session manager relinks it; deleting the key makes it follow the default.
Singleton {
    id: root

    // ── Graph ───────────────────────────────────────────────────────────
    readonly property var nodes: Pipewire.nodes.values ?? []
    readonly property var sinks: nodes.filter(n => n.audio && n.isSink && !n.isStream).sort(root.byLabel)
    readonly property var sources: nodes.filter(n => n.audio && !n.isSink && !n.isStream).sort(root.byLabel)
    readonly property var streams: nodes.filter(n => n.audio && n.isStream)
    // App playback / capture streams (filters, loopbacks and level meters
    // are plumbing, not apps).
    readonly property var playback: streams.filter(n => n.isSink && root.isAppStream(n))
    readonly property var capture: streams.filter(n => !n.isSink && root.isAppStream(n) && n.properties["stream.capture.sink"] !== "true")

    readonly property PwNode defaultSink: Pipewire.defaultAudioSink
    readonly property PwNode defaultSource: Pipewire.defaultAudioSource

    // Bind everything we show or change, so volumes and properties are live.
    PwObjectTracker {
        objects: [...root.streams, ...root.sinks, ...root.sources]
    }

    function byLabel(a, b) {
        return root.label(a).localeCompare(root.label(b));
    }

    function label(n) {
        return n ? (n.description || n.nickname || n.name || "") : "";
    }

    function isAppStream(n) {
        if (!n.ready)
            return false;
        const p = n.properties;
        if (p["node.link-group"] || p["stream.monitor"] === "true" || p["node.virtual"] === "true")
            return false;
        return p["media.category"] !== "Monitor" && p["application.name"] !== "Quickshell Peak Detect";
    }

    // ── Apps ────────────────────────────────────────────────────────────
    function appName(n) {
        const p = n?.properties ?? {};
        return p["application.name"] || p["application.process.binary"] || root.label(n) || "Unknown";
    }

    function appIcon(n) {
        const p = n?.properties ?? {};
        const named = p["application.icon_name"];
        if (named) {
            const path = Quickshell.iconPath(named, true);
            if (path)
                return path;
        }
        return Apps.icon(p["pipewire.access.portal.app_id"] || p["application.id"] || p["application.process.binary"] || (p["application.name"] ?? "").toLowerCase());
    }

    // One row per app (Firefox's tabs are one Firefox): favorites first, in
    // their saved order (also when not playing), then the rest as they came.
    readonly property var apps: {
        const groups = {};
        const order = [];
        for (const n of playback) {
            const key = appName(n);
            if (!groups[key]) {
                groups[key] = {
                    key: key,
                    name: key,
                    icon: appIcon(n),
                    streams: []
                };
                order.push(key);
            }
            groups[key].streams.push(n);
        }
        const pinned = Array.from(Settings.sound.pinned);
        const out = pinned.map(k => groups[k] ?? {
                key: k,
                name: k,
                icon: Apps.icon(k.toLowerCase()),
                streams: []
            });
        for (const k of order)
            if (!pinned.includes(k))
                out.push(groups[k]);
        return out;
    }

    readonly property real maxAppVolume: Settings.sound.boost ? 1.5 : 1

    function appVolume(app) {
        const s = app.streams.find(s => s.ready);
        return s ? s.audio.volume : 0;
    }

    function setAppVolume(app, v) {
        for (const s of app.streams)
            if (s.ready)
                s.audio.volume = Math.max(0, Math.min(root.maxAppVolume, v));
    }

    function appMuted(app) {
        return app.streams.length > 0 && app.streams.every(s => s.ready && s.audio.muted);
    }

    function setAppMuted(app, muted) {
        for (const s of app.streams)
            if (s.ready)
                s.audio.muted = muted;
    }

    function isPinned(key) {
        return Array.from(Settings.sound.pinned).includes(key);
    }

    function togglePin(key) {
        const l = Array.from(Settings.sound.pinned);
        const i = l.indexOf(key);
        if (i >= 0)
            l.splice(i, 1);
        else
            l.push(key);
        Settings.sound.pinned = l;
    }

    function movePin(key, step) {
        const l = Array.from(Settings.sound.pinned);
        const i = l.indexOf(key);
        const j = i + step;
        if (i < 0 || j < 0 || j >= l.length)
            return;
        l.splice(i, 1);
        l.splice(j, 0, key);
        Settings.sound.pinned = l;
    }

    // ── Per-app output ──────────────────────────────────────────────────
    // The sink a stream is linked to right now.
    function streamOutput(n) {
        const g = Pipewire.linkGroups.values.find(g => g.source === n && g.target && !g.target.isStream);
        return g ? g.target : null;
    }

    function appOutput(app) {
        for (const s of app.streams) {
            const o = streamOutput(s);
            if (o)
                return o;
        }
        return null;
    }

    // Streams the user sent somewhere explicitly (stream id → sink name);
    // the rest follow the default output.
    property var targets: ({})

    function appTarget(app) {
        for (const s of app.streams)
            if (targets[s.id])
                return targets[s.id];
        return "";
    }

    // sink = null: follow the default output again.
    function moveApp(app, sink) {
        const t = Object.assign({}, targets);
        for (const s of app.streams) {
            if (sink) {
                Quickshell.execDetached(["pw-metadata", "-n", "default", String(s.id), "target.object", sink.name]);
                t[s.id] = sink.name;
            } else {
                Quickshell.execDetached(["pw-metadata", "-n", "default", "-d", String(s.id), "target.object"]);
                delete t[s.id];
            }
        }
        targets = t;
    }

    // ── Outputs ─────────────────────────────────────────────────────────
    function setDefaultSink(n) {
        if (n)
            Pipewire.preferredDefaultAudioSink = n;
    }

    function cycleOutput(step) {
        const l = sinks;
        if (l.length === 0)
            return;
        const i = l.findIndex(n => n.id === defaultSink?.id);
        setDefaultSink(l[(i + step + l.length) % l.length]);
    }

    // Headphones, headsets, Bluetooth — outputs whose loss would otherwise
    // blast the room at headphone volume.
    function isPersonal(n) {
        if (!n)
            return false;
        const p = n.properties;
        const ff = p["device.form-factor"] ?? "";
        return ["headphone", "headset", "hands-free", "handset", "earbuds"].includes(ff) || p["device.bus"] === "bluetooth" || p["device.api"] === "bluez5" || (n.name ?? "").startsWith("bluez_output") || /headphone|headset|buds|airpods/i.test(label(n));
    }

    function outputIcon(n) {
        if (!n)
            return "󰕾";
        const p = n.properties;
        const ff = p["device.form-factor"] ?? "";
        if (p["device.bus"] === "bluetooth" || p["device.api"] === "bluez5" || (n.name ?? "").startsWith("bluez_output"))
            return "󰂰";
        if (isPersonal(n))
            return "󰋋";
        if (ff === "monitor" || ff === "tv" || /hdmi|displayport/i.test(label(n) + n.name))
            return "󰍹";
        return "󰓃";
    }

    function inputIcon(n) {
        const ff = n?.properties["device.form-factor"] ?? "";
        return ff === "webcam" || /webcam|camera|insta360/i.test(label(n)) ? "󰄀" : "󰍬";
    }

    // Announcements for the HUD (Hud.qml → the island or Osd.qml): icon + text.
    signal announced(string icon, string text)

    // Don't announce the state the shell starts into.
    property bool armed: false
    Timer {
        running: Pipewire.ready
        interval: 1500
        onTriggered: root.armed = true
    }

    // Track the default output (with what we knew about it) so that when it
    // changes because the old one disappeared, we can tell.
    readonly property var defaultInfo: defaultSink ? {
        id: defaultSink.id,
        label: label(defaultSink),
        personal: isPersonal(defaultSink)
    } : null
    property var lastDefault: null
    property var previousDefault: null
    onDefaultInfoChanged: {
        if (!defaultInfo)
            return; // the old one went away; wait for its replacement
        if (lastDefault && lastDefault.id !== defaultInfo.id) {
            previousDefault = lastDefault;
            switched.restart();
            if (armed && Features.on("audioOutputs"))
                announced(outputIcon(defaultSink), `Output: ${defaultInfo.label}`);
        }
        lastDefault = defaultInfo;
    }

    // Let the graph settle (node removal and the new default arrive in
    // either order) before deciding whether the old output vanished.
    Timer {
        id: switched
        interval: 400
        onTriggered: {
            const prev = root.previousDefault;
            const now = root.defaultSink;
            if (!prev || !now || !root.armed || !Features.on("audioOutputs"))
                return;
            const gone = !root.nodes.some(n => n.id === prev.id);
            if (gone && prev.personal && Settings.sound.safeOnUnplug && now.ready && now.audio.volume > Settings.sound.safeVolume) {
                now.audio.volume = Settings.sound.safeVolume;
                root.announced("󰋋", `${prev.label} disconnected · volume lowered to ${Math.round(Settings.sound.safeVolume * 100)}%`);
            }
        }
    }

    // ── Inputs ──────────────────────────────────────────────────────────
    function setDefaultSource(n) {
        if (n)
            Pipewire.preferredDefaultAudioSource = n;
    }

    readonly property var mics: sources.filter(n => n.ready)
    readonly property bool micsMuted: !!mics && mics.length > 0 && mics.every(n => n.audio?.muted ?? false)
    readonly property var recordingApps: Array.from(new Set(capture.map(n => appName(n))))
    readonly property bool recording: (capture?.length ?? 0) > 0

    function setMicsMuted(muted) {
        for (const n of mics)
            n.audio.muted = muted;
        announced(muted ? "󰍭" : "󰍬", muted ? "Microphones muted" : "Microphones on");
    }

    // ── Mixer panel ─────────────────────────────────────────────────────
    property bool mixerOpen: false
    // Output name the mixer opens on; empty = the focused one.
    property string mixerScreen: ""

    function openMixer(screenName) {
        mixerScreen = screenName || (Niri.focusedWorkspace?.output ?? "");
        mixerOpen = true;
    }

    function toggleMixer(screenName) {
        const s = screenName || (Niri.focusedWorkspace?.output ?? "");
        if (mixerOpen && s === mixerScreen)
            mixerOpen = false;
        else
            openMixer(s);
    }

    // ── IPC (bindable from niri: niri/shell-binds.kdl.in) ───────────────
    IpcHandler {
        target: "mixer"
        enabled: Features.on("mixer")

        function toggle(): void {
            root.toggleMixer("");
        }
        function open(): void {
            root.openMixer("");
        }
        function close(): void {
            root.mixerOpen = false;
        }
        // Settings → Sound.
        function settings(): void {
            Panels.settingsSection = "sound";
            Panels.settingsOpen = true;
        }
    }

    IpcHandler {
        target: "audio"
        enabled: Features.on("audioOutputs")

        function nextOutput(): void {
            root.cycleOutput(1);
        }
        function prevOutput(): void {
            root.cycleOutput(-1);
        }
    }

    IpcHandler {
        target: "mic"
        enabled: Features.on("micTools")

        function toggleMute(): void {
            root.setMicsMuted(!root.micsMuted);
        }
        function mute(): void {
            root.setMicsMuted(true);
        }
        function unmute(): void {
            root.setMicsMuted(false);
        }
    }
}
