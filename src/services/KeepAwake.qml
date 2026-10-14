pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower

// Keep Awake (formerly Caffeine): keep the session from idling — no screen
// blanking, no idle lock, optionally no suspend — by hand for a while, or
// while a rule holds:
//
//   by hand    Panels.caffeine (indefinitely) or until `until` (ms epoch)
//   rules      EverydayConfig.keepAwake: while an app has a window, while on
//              AC power (UPower), while an external display is connected
//
// While awake: the bar's Wayland IdleInhibitor (niri honours it for its
// idle notifier → swayidle and friends) plus a systemd-logind inhibitor
// (`systemd-inhibit`, from the system's systemd like nmcli/busctl):
// idle (+ sleep with blockSleep, + handle-lid-switch with lidClosed). The
// inhibitor process dies with the shell, so nothing outlives it.
Singleton {
    id: root

    readonly property var cfg: EverydayConfig.keepAwake
    readonly property bool featureOn: Features.on("keepAwake")

    // ── By hand ──────────────────────────────────────────────────────────
    // ms since the epoch; 0 = no timer. Kept across reloads.
    property alias until: persist.until
    property real now: Date.now()

    PersistentProperties {
        id: persist
        reloadableId: "keepAwake"
        property real until: 0
    }

    readonly property bool timed: until > now
    readonly property bool manual: Panels.caffeine || timed
    readonly property real remaining: timed ? until - now : 0

    function keepFor(minutes) {
        if (minutes <= 0) {
            until = 0;
            Panels.caffeine = true;
        } else {
            Panels.caffeine = false;
            until = Date.now() + minutes * 60000;
            now = Date.now();
        }
    }

    // Until a clock time today (or tomorrow if it has passed): "18:00".
    function keepUntilClock(hh, mm) {
        const d = new Date();
        d.setHours(hh, mm, 0, 0);
        if (d.getTime() <= Date.now())
            d.setDate(d.getDate() + 1);
        Panels.caffeine = false;
        until = d.getTime();
        now = Date.now();
    }

    function stop() {
        Panels.caffeine = false;
        until = 0;
    }

    // The control's click: off → the default duration; on (by hand) → off.
    function toggle() {
        if (manual)
            stop();
        else
            keepFor(cfg.defaultMinutes);
    }

    // ── Rules ────────────────────────────────────────────────────────────
    readonly property var appRule: {
        const apps = Array.from(cfg.apps ?? []);
        if (apps.length === 0)
            return "";
        const w = Niri.windows.find(x => apps.includes(x.app_id));
        return w ? w.app_id : "";
    }
    readonly property bool hasBattery: UPower.displayDevice?.isLaptopBattery ?? false
    readonly property bool onAC: !UPower.onBattery
    readonly property bool acRule: cfg.onAC && onAC
    // Internal panels: eDP / LVDS / DSI connectors. Everything else is external.
    readonly property var externalScreens: Quickshell.screens.filter(s => !/^(eDP|LVDS|DSI)/i.test(s.name))
    readonly property bool displayRule: cfg.externalDisplay && externalScreens.length > 0

    // Why it's awake ("" = it isn't): the first that applies.
    readonly property string reason: {
        if (!featureOn)
            return "";
        if (Panels.caffeine)
            return "manual";
        if (timed)
            return "timer";
        if (appRule !== "")
            return "app";
        if (acRule)
            return "power";
        if (displayRule)
            return "display";
        return "";
    }
    readonly property bool active: reason !== ""

    // One line for the Control Center tile / menu.
    function format(ms) {
        const m = Math.ceil(ms / 60000);
        if (m < 60)
            return `${m} min`;
        const h = Math.floor(m / 60);
        return m % 60 ? `${h} h ${m % 60} min` : `${h} h`;
    }

    readonly property string status: {
        switch (reason) {
        case "manual":
            return "On";
        case "timer":
            return `${format(remaining)} left`;
        case "app":
            return `While ${Apps.name(appRule)} is open`;
        case "power":
            return "While on power";
        case "display":
            return "While a display is connected";
        }
        return "Off";
    }

    // qs ipc call keepawake on | off | toggle | minutes N | status
    IpcHandler {
        target: "keepawake"

        function on(): void {
            root.keepFor(0);
        }
        function off(): void {
            root.stop();
        }
        function toggle(): void {
            root.toggle();
        }
        function minutes(n: int): void {
            root.keepFor(n);
        }
        function status(): string {
            return root.active ? `${root.reason}: ${root.status}` : "off";
        }
    }

    // Tick while a timer runs; the minute display needs no finer clock.
    Timer {
        running: root.until > 0
        interval: 5000
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            root.now = Date.now();
            if (root.until > 0 && root.until <= root.now)
                root.until = 0;
        }
    }

    // ── logind inhibitor ─────────────────────────────────────────────────
    // Its last error ("Failed to inhibit: Access denied" outside an active
    // logind session / without polkit rights); the idle inhibitor still works.
    property string inhibitError: ""
    readonly property string what: ["idle"].concat(cfg.blockSleep ? ["sleep"] : []).concat(cfg.lidClosed && hasBattery ? ["handle-lid-switch"] : []).join(":")
    readonly property string inhibitKey: active ? what : ""
    onInhibitKeyChanged: {
        inhibitor.running = false;
        if (inhibitKey !== "")
            restartInhibit.restart();
    }

    Timer {
        id: restartInhibit
        interval: 50
        onTriggered: inhibitor.running = root.inhibitKey !== ""
    }

    Process {
        id: inhibitor
        command: ["systemd-inhibit", `--what=${root.what}`, "--who=Loft", `--why=Keep Awake (${root.reason})`, "--mode=block", "sleep", "infinity"]
        onStarted: root.inhibitError = ""
        stderr: SplitParser {
            onRead: line => {
                root.inhibitError = line;
                console.warn(`KeepAwake: systemd-inhibit: ${line}`);
            }
        }
    }
}
