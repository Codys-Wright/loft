pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Shell-wide motion: Reduce Motion (Settings.reduceMotion — morphs become
// quick cross-fades) and a test-only slow-motion factor to record transitions
// frame by frame. `ms(320)` is how long a 320 ms animation runs right now.
//
//   LOFT_ANIM_SCALE=10 in the shell's environment, or at runtime
//   `quickshell ipc … call motion scale 10` (1 = normal speed).
Singleton {
    id: root

    readonly property bool reduce: Settings.reduceMotion === true
    property real scale: Math.max(0.05, Number(Quickshell.env("LOFT_ANIM_SCALE")) || 1)

    function ms(base) {
        return Math.round(base * scale);
    }

    IpcHandler {
        target: "motion"

        // Slow every Motion-timed animation down by `factor` (testing).
        function scale(factor: real): void {
            root.scale = Math.max(0.05, factor || 1);
        }
        function reduce(on: bool): void {
            Settings.reduceMotion = on;
        }
        function status(): string {
            return JSON.stringify({ scale: root.scale, reduce: root.reduce });
        }
    }
}
