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

    // cmd: toggle | close | dismiss | next | prev | flash | a page name (media, system, …)
    signal command(string cmd)

    // A system alert swiped away (Island.qml): "warn" (overload) or "urgent"
    // (overheating), shared by every screen's island. It stays quiet until
    // the alert clears or gets worse (overload → overheating).
    property string alertSilenced: ""
    readonly property string alertLevel: SystemStats.overheating ? "urgent" : SystemStats.overloaded ? "warn" : ""
    readonly property bool alertQuiet: alertSilenced !== "" && (alertSilenced === "urgent" || alertLevel !== "urgent")
    onAlertLevelChanged: if (alertLevel === "" || (alertLevel === "urgent" && alertSilenced === "warn"))
        alertSilenced = ""

    IpcHandler {
        target: "island"

        function toggle(): void {
            root.command("toggle");
        }
        function close(): void {
            root.command("close");
        }
        // What swiping up does: close it, the banner, then a system alert.
        function dismiss(): void {
            root.command("dismiss");
        }
        // The next / previous page (opens the island first when it's closed).
        function next(): void {
            root.command("next");
        }
        function prev(): void {
            root.command("prev");
        }
        // Open on a page by id (IslandPages: live, media, controls, …).
        function page(id: string): void {
            root.command(id);
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
