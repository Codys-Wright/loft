import QtQuick

// A slow "breathing" value for always-on status marks (an AI agent at work,
// a recording dot, an alert outline), stepped about 10 times a second
// instead of animated every frame. A Qt Quick animation redraws its whole
// window at the display's refresh rate for as long as it runs: one
// breathing icon on three islands at 240 / 180 / 180 Hz kept the shell's GUI
// thread rendering ~600 frames a second (Perf / `loft doctor perf`).
//
//   opacity: pulse.value
//   SlowPulse { id: pulse; running: …; low: 0.4; period: 1800 }
QtObject {
    id: root

    property bool running: false
    // The value swings between `low` and `high` over `period` ms (sine).
    property real low: 0.4
    property real high: 1
    property int period: 1800
    // Steps per second (redraws while running).
    property real rate: 10
    // `high` while stopped.
    property real value: high

    property real _t0: 0
    readonly property Timer _tick: Timer {
        interval: Math.round(1000 / Math.max(1, root.rate))
        repeat: true
        running: root.running
        onRunningChanged: {
            if (running)
                root._t0 = Date.now();
            else
                root.value = root.high;
        }
        onTriggered: {
            const phase = ((Date.now() - root._t0) % root.period) / root.period;
            // Starts at `high`, dips to `low` halfway.
            root.value = root.low + (root.high - root.low) * (0.5 + 0.5 * Math.cos(phase * 2 * Math.PI));
        }
    }
}
