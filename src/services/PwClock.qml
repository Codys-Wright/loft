pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The PipeWire graph clock (Sound ⌥-click): sample rate and quantum from
// the "settings" metadata, with quick switching through clock.force-rate /
// clock.force-quantum (0 = Auto: the graph picks). Read while a Sound panel
// shows its details (`watching`), never otherwise.
//
// Forcing the clock changes it for every app on the graph — studio work,
// network audio (Dante/AES67) and DAW sessions follow it.
Singleton {
    id: root

    // Panels showing the clock keep this > 0.
    property int watching: 0

    property int rate: 0 // clock.rate (the default)
    property int quantum: 0 // clock.quantum (the default)
    property int forceRate: 0
    property int forceQuantum: 0
    property var allowedRates: []
    property bool ready: false

    readonly property int effectiveRate: forceRate || rate
    readonly property int effectiveQuantum: forceQuantum || quantum
    readonly property real latencyMs: effectiveRate > 0 ? effectiveQuantum / effectiveRate * 1000 : 0

    readonly property var rates: {
        const l = allowedRates.length > 0 ? allowedRates : [44100, 48000, 88200, 96000];
        return l.filter(r => r >= 44100 && r <= 192000);
    }
    readonly property var quanta: [64, 128, 256, 512, 1024]

    function rateLabel(r) {
        return r % 1000 === 0 ? `${r / 1000} kHz` : `${(r / 1000).toFixed(1)} kHz`;
    }

    function refresh() {
        if (!probe.running)
            probe.running = true;
    }

    // 0 = Auto.
    function setRate(r) {
        Quickshell.execDetached(["pw-metadata", "-n", "settings", "0", "clock.force-rate", String(r)]);
        forceRate = r;
        settle.restart();
    }

    function setQuantum(q) {
        Quickshell.execDetached(["pw-metadata", "-n", "settings", "0", "clock.force-quantum", String(q)]);
        forceQuantum = q;
        settle.restart();
    }

    Timer {
        id: settle
        interval: 300
        onTriggered: root.refresh()
    }

    Timer {
        running: root.watching > 0
        repeat: true
        triggeredOnStart: true
        interval: 2000
        onTriggered: root.refresh()
    }

    Process {
        id: probe
        command: ["pw-metadata", "-n", "settings", "0"]
        stdout: StdioCollector {
            onStreamFinished: {
                const get = key => {
                    const m = text.match(new RegExp(`key:'${key.replace(".", "\\.")}' value:'([^']*)'`));
                    return m ? m[1] : "";
                };
                root.rate = parseInt(get("clock.rate")) || 0;
                root.quantum = parseInt(get("clock.quantum")) || 0;
                root.forceRate = parseInt(get("clock.force-rate")) || 0;
                root.forceQuantum = parseInt(get("clock.force-quantum")) || 0;
                const allowed = get("clock.allowed-rates").replace(/[\[\],]/g, " ").trim();
                root.allowedRates = allowed ? allowed.split(/\s+/).map(x => parseInt(x)).filter(x => x > 0) : [];
                root.ready = root.rate > 0;
            }
        }
    }

    // Bindable quick switches: `qs ipc call pwclock rate 96000`, `… auto`.
    IpcHandler {
        target: "pwclock"

        function rate(r: int): void {
            root.setRate(r);
        }
        function quantum(q: int): void {
            root.setQuantum(q);
        }
        function auto(): void {
            root.setRate(0);
            root.setQuantum(0);
        }
        function status(): string {
            return `rate ${root.effectiveRate} (force ${root.forceRate}) quantum ${root.effectiveQuantum} (force ${root.forceQuantum})`;
        }
    }
}
