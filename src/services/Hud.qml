pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire

// The on-screen HUD: what just changed — output volume / mute, display
// brightness, or a Sound announcement (output switched, microphones muted,
// a space without the island). One state, two places to show it: the
// Dynamic Island (Island.qml: the collapsed pill widens for a moment) or,
// with the island off or Settings → Dynamic Island → "Show changes in the
// Dynamic Island" off, the pill above the dock (Osd.qml). Shown on the
// focused output only. The `osd` feature turns all of it off.
//
// IPC `osd volume 0.62 | mute | unmute | brightness 0.4 | message ICON TEXT`
// feeds the same paths as the real signals (testing without audio or DDC).
Singleton {
    id: root

    readonly property bool enabled: Features.on("osd")
    // Where it shows: the island, else the bottom pill.
    readonly property bool inIsland: Features.on("island") && Settings.island.hud !== false

    // "volume" | "brightness" | "message"
    property string kind: ""
    property real value: 0
    property bool muted: false
    property string icon: ""
    property string text: ""
    // The focused output when it changed; "" = unknown (every screen shows it).
    property string output: ""
    property bool shown: false

    function onScreen(name) {
        return shown && (output === "" || output === name);
    }

    readonly property string levelIcon: kind === "brightness" ? (value >= 0.66 ? "󰃠" : value >= 0.33 ? "󰃟" : "󰃞") : muted || value <= 0 ? "󰝟" : value >= 0.66 ? "󰕾" : value >= 0.33 ? "󰖀" : "󰕿"

    // ── Inputs ──────────────────────────────────────────────────────────
    function showVolume(v, m) {
        value = v;
        muted = m;
        // The new output's volume right after "Output: …" keeps the
        // announcement up.
        if (!(kind === "message" && messageHold.running))
            kind = "volume";
        present();
    }

    function showBrightness(v) {
        // The bottom pill has never shown brightness; only the island does.
        if (!inIsland)
            return;
        kind = "brightness";
        value = v;
        muted = false;
        present();
    }

    function say(icon, text) {
        root.icon = icon;
        root.text = text;
        kind = "message";
        messageHold.restart();
        present();
    }

    function present() {
        if (!enabled)
            return;
        output = Niri.focusedWorkspace?.output ?? "";
        shown = true;
        hide.interval = kind === "message" ? 2200 : inIsland ? 1500 : 1400;
        hide.restart();
    }

    Timer {
        id: messageHold
        interval: 2200
    }

    Timer {
        id: hide
        onTriggered: root.shown = false
    }

    // ── Signals ─────────────────────────────────────────────────────────
    readonly property PwNode sink: Pipewire.defaultAudioSink
    readonly property bool ready: sink?.ready ?? false
    readonly property real sinkVolume: ready ? sink.audio.volume : 0
    readonly property bool sinkMuted: ready ? sink.audio.muted : false

    PwObjectTracker {
        objects: root.sink ? [root.sink] : []
    }

    // Ignore the initial values reported when the sink first binds.
    property bool armed: false
    Timer {
        running: root.ready
        interval: 500
        onTriggered: root.armed = true
    }

    onSinkVolumeChanged: if (armed)
        showVolume(sinkVolume, sinkMuted)
    onSinkMutedChanged: if (armed)
        showVolume(sinkVolume, sinkMuted)

    Connections {
        target: Sound
        function onAnnounced(icon, text) {
            root.say(icon, text);
        }
    }

    Connections {
        target: Brightness
        function onAdjusted(v) {
            root.showBrightness(v);
        }
    }

    IpcHandler {
        target: "osd"

        function volume(v: real): void {
            root.showVolume(Math.max(0, Math.min(1.5, v)), false);
        }
        function mute(): void {
            root.showVolume(root.value > 0 ? root.value : 0.62, true);
        }
        function unmute(): void {
            root.showVolume(root.value > 0 ? root.value : 0.62, false);
        }
        function brightness(v: real): void {
            Brightness.adjusted(Math.max(0, Math.min(1, v)));
        }
        function message(icon: string, text: string): void {
            Sound.announced(icon, text);
        }
    }
}
