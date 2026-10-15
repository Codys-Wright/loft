pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The island's IPC (`qs ipc call island <cmd>`), registered once: there is
// one island per screen, and a handler per island made Quickshell warn and
// drop all but one ("another handler is registered for target island").
// Each command goes to the island on the focused output (Island.qml).
Singleton {
    id: root

    // cmd: toggle | flash | a page name (media, system, …)
    signal command(string cmd)

    IpcHandler {
        target: "island"

        function toggle(): void {
            root.command("toggle");
        }
        function media(): void {
            root.command("media");
        }
        function system(): void {
            root.command("system");
        }
        function usage(): void {
            root.command("usage");
        }
        function notifications(): void {
            root.command("notifications");
        }
        function live(): void {
            root.command("live");
        }
        function calendar(): void {
            root.command("calendar");
        }
        function timers(): void {
            root.command("timers");
        }
        function controls(): void {
            root.command("controls");
        }
        function ai(): void {
            root.command("ai");
        }
        function scratchpad(): void {
            root.command("scratchpad");
        }
        // Exercise the shutter flash without taking a screenshot.
        function flash(): void {
            root.command("flash");
        }
    }
}
