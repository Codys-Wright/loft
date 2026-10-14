pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Display brightness for the Control Center's Display module: laptop
// panels through /sys/class/backlight (set with brightnessctl), external
// monitors through DDC/CI (ddcutil, VCP 0x10). Both are optional: whatever
// can't be read is skipped, and with nothing readable the slider hides.
// ddcutil is slow (I²C), so displays are probed when a panel asks
// (`refresh()`), at most once a minute, and writes are debounced.
//
// LOFT_FAKE_BRIGHTNESS=1 (dev/testing) replaces all of it with two
// in-memory displays, so nothing touches real monitors.
Singleton {
    id: root

    readonly property bool fake: Quickshell.env("LOFT_FAKE_BRIGHTNESS") === "1"

    // [{ key, name, kind: "backlight" | "ddc" | "fake", value (0..1), max, bus }]
    property var displays: []
    readonly property bool available: displays.length > 0
    // The main slider: the average; moving it sets every display.
    readonly property real value: available ? displays.reduce((a, d) => a + d.value, 0) / displays.length : 0
    property bool probing: false
    property real probedAt: 0

    // Loft changed a display's brightness (the HUD shows it: Hud.qml).
    signal adjusted(real value)

    function refresh() {
        if (fake) {
            if (displays.length === 0)
                displays = [
                    { key: "fake-1", name: "Studio Display", kind: "fake", value: 0.7, max: 100 },
                    { key: "fake-2", name: "LG UltraFine", kind: "fake", value: 0.45, max: 100 }
                ];
            return;
        }
        if (probing || Date.now() - probedAt < 60000)
            return;
        probing = true;
        probe.running = true;
    }

    function set(key, v) {
        apply(key, v);
        adjusted(Math.max(0.01, Math.min(1, v)));
    }

    function apply(key, v) {
        v = Math.max(0.01, Math.min(1, v));
        displays = displays.map(d => d.key === key ? Object.assign({}, d, { value: v }) : d);
        if (!fake) {
            pending[key] = v;
            writer.restart();
        }
    }

    function setAll(v) {
        for (const d of displays)
            apply(d.key, v);
        adjusted(Math.max(0.01, Math.min(1, v)));
    }

    property var pending: ({})
    Timer {
        id: writer
        interval: 250
        onTriggered: {
            for (const key in root.pending) {
                const d = root.displays.find(x => x.key === key);
                if (!d)
                    continue;
                const pct = Math.round(root.pending[key] * 100);
                if (d.kind === "backlight")
                    Quickshell.execDetached(["brightnessctl", "-q", "-d", d.key, "set", `${pct}%`]);
                else if (d.kind === "ddc")
                    Quickshell.execDetached(["ddcutil", "--noverify", "--bus", String(d.bus), "setvcp", "10", String(Math.round(pct * d.max / 100))]);
            }
            root.pending = {};
        }
    }

    // One pass: backlights, then each DDC display's VCP 0x10.
    // Output lines: "B <name> <cur> <max>" | "D <bus> <cur> <max> <model>".
    Process {
        id: probe
        command: ["sh", "-c", `
for d in /sys/class/backlight/*; do
  [ -r "$d/brightness" ] && echo "B $(basename "$d") $(cat "$d/brightness") $(cat "$d/max_brightness")"
done
command -v ddcutil >/dev/null || exit 0
ddcutil detect --terse 2>/dev/null | awk '/I2C bus:/ {sub(/.*i2c-/, ""); bus=$0} /Monitor:/ {sub(/.*Monitor: */, ""); print bus "|" $0}' |
while IFS='|' read -r bus mon; do
  v=$(ddcutil --bus "$bus" getvcp 10 --terse 2>/dev/null) || continue
  set -- $v
  echo "D $bus $4 $5 $(echo "$mon" | cut -d: -f2)"
done`]
        stdout: StdioCollector {
            onStreamFinished: {
                const out = [];
                for (const line of text.split("\n")) {
                    const f = line.trim().split(" ");
                    if (f[0] === "B" && f.length >= 4)
                        out.push({ key: f[1], name: "Built-in Display", kind: "backlight", value: parseInt(f[2]) / Math.max(1, parseInt(f[3])), max: parseInt(f[3]) });
                    else if (f[0] === "D" && f.length >= 4)
                        out.push({ key: `ddc-${f[1]}`, bus: parseInt(f[1]), name: f.slice(4).join(" ") || `Display ${f[1]}`, kind: "ddc", value: parseInt(f[2]) / Math.max(1, parseInt(f[3])), max: parseInt(f[3]) });
                }
                root.displays = out;
            }
        }
        onExited: {
            root.probing = false;
            root.probedAt = Date.now();
        }
    }
}
