pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.UPower

// The idle timeline (Settings → Lock & Sleep): after so many seconds with
// no input, dim the screens → start the screen saver → lock → turn the
// displays off → sleep. Each step is its own Wayland idle notification
// (IdleMonitor, ext-idle-notify through niri) with the time for the current
// power source (LockSleepConfig.idle, on AC / on battery), so any input
// resets all of them, and idle inhibitors — Keep Awake, a playing video —
// hold all of them.
//
// Locking before the system sleeps and on logind's Lock signal stays with
// swayidle (programs.loft); the timeouts moved here so they apply live.
// Also here: the power key and the lid, the critical battery action and
// what this machine can do (logind's Can*, its lid / power-button handling).
//
// Under KWin, idle is Plasma's (kscreenlocker in KWin, PowerDevil): the
// lock, displays-off and sleep steps don't run here; the shell writes their
// times (and the lock's grace, lock before sleep) into kscreenlockerrc /
// powerdevilrc at start and on every change (`loft idle apply`,
// cli/loft/kdeidle.py), and both reload live. Loft's unit gives KDE's own
// values back when it stops (`loft idle revert`, docs/KWIN.md §4.20). The
// dim and the screen saver run here under both.
Singleton {
    id: root

    readonly property var cfg: LockSleepConfig
    readonly property bool kde: Compositor.backend === "kwin"
    // Steps Plasma does itself under KWin.
    readonly property var plasmaSteps: ["lock", "displayOff", "sleep"]
    // Test sessions never suspend, hibernate or power off the real machine.
    readonly property bool devMode: Quickshell.env("LOFT_DEV") === "1"

    // ── Power source ─────────────────────────────────────────────────────
    readonly property var batteryDevice: UPower.displayDevice
    readonly property bool hasBattery: batteryDevice !== null && batteryDevice.ready && batteryDevice.isLaptopBattery
    readonly property bool onBattery: hasBattery && UPower.onBattery
    readonly property string power: onBattery ? "battery" : "ac"
    readonly property real batteryPct: hasBattery ? (batteryDevice.percentage > 1 ? batteryDevice.percentage : batteryDevice.percentage * 100) : 100

    // Seconds for a step on the current power source (0 = never).
    function after(step) {
        return cfg.seconds(step, power);
    }

    // ── The steps ────────────────────────────────────────────────────────
    // An IdleMonitor enabled while its timeout is still the default 0
    // reports idle at once (VideoWallpapers.qml): arm them a moment late.
    property bool armed: false
    Timer {
        interval: 1500
        running: true
        onTriggered: root.armed = true
    }

    // A running IdleMonitor keeps the timeout it started with, so a new
    // time re-arms it (off for a moment, then on again).
    component Step: IdleMonitor {
        id: monitor
        required property string step
        readonly property real secs: root.after(step)
        property bool rearming: false
        enabled: root.armed && secs > 0 && !rearming && !(root.kde && root.plasmaSteps.includes(step))
        respectInhibitors: true
        timeout: Math.max(1, secs)
        readonly property bool reached: enabled && isIdle
        onSecsChanged: {
            rearming = true;
            rearm.restart();
        }
        property Timer rearm: Timer {
            interval: 50
            onTriggered: monitor.rearming = false
        }
    }

    Step {
        id: dimStep
        step: "dim"
    }
    Step {
        id: saverStep
        step: "screenSaver"
    }
    Step {
        id: lockStep
        step: "lock"
        onReachedChanged: if (reached)
            root.lockNow()
    }
    Step {
        id: displayStep
        step: "displayOff"
        onReachedChanged: if (reached)
            root.displaysOff()
    }
    Step {
        id: sleepStep
        step: "sleep"
        onReachedChanged: if (reached)
            root.sleepNow("idle")
    }

    readonly property bool dimmed: dimStep.reached
    // The screen saver shows while its step is reached or a preview runs;
    // any input ends both (ScreenSaver.qml ends the preview).
    property bool previewing: false
    readonly property bool saverOn: (saverStep.reached || previewing) && !LockState.locked

    function previewSaver() {
        previewing = true;
    }
    function endPreview() {
        previewing = false;
    }

    // ── Actions ──────────────────────────────────────────────────────────
    // The last thing the timeline did, for Settings ("Locked after 5 min").
    property string lastAction: ""

    function lockNow() {
        lastAction = "lock";
        LockState.requestLock();
    }

    function displaysOff() {
        lastAction = "displayOff";
        run(["niri", "msg", "action", "power-off-monitors"]);
    }

    readonly property var verbs: ({
            "suspend": "suspend",
            "hibernate": "hibernate",
            "hybrid-sleep": "hybrid-sleep",
            "suspend-then-hibernate": "suspend-then-hibernate",
            "poweroff": "poweroff"
        })

    // `mode`: a systemctl verb, or "" for the chosen sleep mode.
    function sleepNow(why, mode) {
        const verb = verbs[mode || cfg.sleepMode] ?? "suspend";
        lastAction = verb;
        if (devMode) {
            console.log(`Idle: would run systemctl ${verb} (${why}); skipped in a dev session`);
            return;
        }
        run(["systemctl", verb]);
    }

    function run(cmd) {
        Quickshell.execDetached(cmd);
    }

    // ── Critical battery ─────────────────────────────────────────────────
    // Once per discharge: plugging in (or charging above it) re-arms it.
    property bool criticalDone: false
    readonly property bool critical: onBattery && cfg.battery.criticalPercent > 0 && batteryPct <= cfg.battery.criticalPercent
    onCriticalChanged: {
        if (!critical) {
            if (!onBattery || batteryPct > cfg.battery.criticalPercent + 2)
                criticalDone = false;
            return;
        }
        if (criticalDone)
            return;
        criticalDone = true;
        const action = cfg.battery.criticalAction;
        if (action === "none")
            return;
        Notifications.show({
            appName: "Battery",
            appIcon: "battery-empty",
            summary: "Battery critically low",
            body: `${Math.round(batteryPct)}% left — ${action === "poweroff" ? "shutting down" : action === "hibernate" ? "hibernating" : "going to sleep"} now.`,
            urgency: 2,
            image: "",
            actions: []
        });
        criticalAct.action = action;
        criticalAct.restart();
    }
    Timer {
        id: criticalAct
        property string action: ""
        // A moment to read the banner (and to plug in).
        interval: 5000
        onTriggered: {
            if (root.critical)
                root.act(action, "critical battery");
        }
    }

    // ── Power key and lid ────────────────────────────────────────────────
    // niri suspends on the power key itself unless that's turned off
    // (input.disable-power-key-handling); then the XF86PowerOff bind
    // (niri/shell-binds.kdl.in) calls powerKey() here. Plain "sleep" with
    // the suspend mode stays niri's; "system" hands the key to logind.
    readonly property string powerAction: cfg.powerButton
    readonly property bool niriPowerKey: powerAction === "sleep" && cfg.sleepMode === "suspend"
    readonly property bool hasLid: logind.HasLid === "yes"
    readonly property var lidContexts: ["battery", "ac", "docked"]
    // The lid is ours once any situation has an action other than logind's.
    readonly property bool lidTakeover: hasLid && lidContexts.some(k => (cfg.lid[k] ?? "system") !== "system")

    // systemd-logind must not act on what the shell handles: hold its
    // handle-power-key / handle-lid-switch inhibitors meanwhile. They die
    // with the shell, so without it logind's own settings apply again.
    // Never in a dev session: those would reach the real machine.
    readonly property string inhibitWhat: devMode || kde ? "" : [powerAction !== "system" ? "handle-power-key" : "", lidTakeover ? "handle-lid-switch" : ""].filter(x => x !== "").join(":")
    property string inhibitError: ""
    onInhibitWhatChanged: {
        inhibitor.running = false;
        if (inhibitWhat !== "")
            restartInhibit.restart();
    }
    Timer {
        id: restartInhibit
        interval: 50
        onTriggered: inhibitor.running = root.inhibitWhat !== ""
    }
    Component.onCompleted: {
        restartInhibit.restart();
        schedule();
    }
    Process {
        id: inhibitor
        command: ["systemd-inhibit", `--what=${root.inhibitWhat}`, "--who=Loft", "--why=Settings → Lock & Sleep handles the power button / lid", "--mode=block", "sleep", "infinity"]
        onStarted: root.inhibitError = ""
        stderr: SplitParser {
            onRead: line => {
                root.inhibitError = line;
                console.warn(`Idle: systemd-inhibit: ${line}`);
            }
        }
    }

    // Keep niri's setting in step with the choice. The override lives in
    // overrides/niri.json, so this only writes when the choice changes.
    readonly property string niriKey: "input.disable-power-key-handling"
    readonly property bool wantNiriOff: !niriPowerKey
    onWantNiriOffChanged: syncNiri()
    function syncNiri() {
        if (kde)
            return;
        const k = NiriSettings.keys[niriKey];
        if (!k) {
            // Not read yet: read, then come back (onKeysChanged).
            if (!NiriSettings.busy)
                NiriSettings.refresh();
            return;
        }
        if (NiriSettings.busy)
            return;
        if (wantNiriOff && k.value !== true)
            NiriSettings.set(niriKey, true);
        else if (!wantNiriOff && k.source === "override")
            NiriSettings.unset(niriKey);
    }
    Connections {
        target: NiriSettings
        function onKeysChanged() {
            root.syncNiri();
        }
    }
    // niri's own setting, for Settings: is its power-key handling off?
    readonly property bool niriPowerKeyOff: NiriSettings.keys[niriKey]?.value === true

    // The wake: the key that woke the machine can arrive after resuming;
    // a power key within a few seconds of a wake is ignored. A gap in this
    // tick means the machine slept.
    property real lastTick: Date.now()
    property real resumedAt: 0
    Timer {
        interval: 2000
        running: true
        repeat: true
        onTriggered: {
            const now = Date.now();
            if (now - root.lastTick > 8000)
                root.resumedAt = now;
            root.lastTick = now;
        }
    }

    // Show the Shut Down / Restart / Sleep dialog (menubar/MenuState.qml).
    signal powerDialogRequested

    property real lastPowerKey: 0
    function powerKey() {
        const now = Date.now();
        if (now - lastPowerKey < 1500 || now - resumedAt < 4000)
            return;
        lastPowerKey = now;
        if (powerAction !== "system")
            act(powerAction, "power key");
    }

    // The situation the lid's setting is for right now.
    function lidContext() {
        return KeepAwake.externalScreens.length > 0 ? "docked" : onBattery ? "battery" : "ac";
    }
    // logind's own setting for a situation, as one of our actions.
    function logindLid(context) {
        const v = logind[{
            battery: "HandleLidSwitch",
            ac: "HandleLidSwitchExternalPower",
            docked: "HandleLidSwitchDocked"
        }[context]] ?? "suspend";
        return v === "ignore" ? "nothing" : v;
    }
    function lidAction(context) {
        const a = cfg.lid[context] ?? "system";
        return a === "system" ? logindLid(context) : a;
    }

    property bool lidClosed: false
    property bool lidTurnedDisplaysOff: false
    function lid(closed) {
        lidClosed = closed;
        if (kde)
            return;
        if (!closed) {
            if (lidTurnedDisplaysOff)
                run(["niri", "msg", "action", "power-on-monitors"]);
            lidTurnedDisplaysOff = false;
            return;
        }
        // Not taken over: logind does what it's set to.
        if (!lidTakeover)
            return;
        // Keep Awake → "Stay awake with the lid closed".
        if (KeepAwake.active && EverydayConfig.keepAwake.lidClosed)
            return;
        const a = lidAction(lidContext());
        lidTurnedDisplaysOff = a === "displayOff";
        act(a, "lid");
    }

    // One action by name (the power key, the lid, the critical battery).
    function act(action, why) {
        switch (action) {
        case "sleep":
            sleepNow(why);
            break;
        case "suspend":
        case "hibernate":
        case "hybrid-sleep":
        case "suspend-then-hibernate":
        case "poweroff":
            sleepNow(why, action);
            break;
        case "lock":
            lockNow();
            break;
        case "displayOff":
            displaysOff();
            break;
        case "ask":
            lastAction = "ask";
            powerDialogRequested();
            break;
        default:
            // nothing / ignore
            break;
        }
    }

    // ── What this machine can do ─────────────────────────────────────────
    // logind's Can* answers ("yes", "no", "challenge", "na") and its
    // handling of the lid and power keys (set in NixOS, logind.conf).
    property var can: ({})
    property var logind: ({})
    function canDo(mode) {
        const key = {
            "suspend": "CanSuspend",
            "hibernate": "CanHibernate",
            "hybrid-sleep": "CanHybridSleep",
            "suspend-then-hibernate": "CanSuspendThenHibernate",
            "poweroff": "CanPowerOff"
        }[mode];
        const v = can[key];
        // Unknown until the probe answers: don't hide anything.
        return v === undefined || v === "yes" || v === "challenge";
    }
    function refresh() {
        probe.running = true;
    }

    Process {
        id: probe
        running: true
        // One "Name value" line each; busctl prints `s "yes"`.
        command: ["sh", "-c", `
            m=org.freedesktop.login1.Manager
            for c in CanSuspend CanHibernate CanHybridSleep CanSuspendThenHibernate CanPowerOff; do
                printf '%s %s\\n' "$c" "$(busctl call org.freedesktop.login1 /org/freedesktop/login1 $m $c 2>/dev/null)"
            done
            for p in HandlePowerKey HandleLidSwitch HandleLidSwitchExternalPower HandleLidSwitchDocked IdleAction; do
                printf '%s %s\\n' "$p" "$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 $m $p 2>/dev/null)"
            done
            [ -d /proc/acpi/button/lid ] && ls /proc/acpi/button/lid | grep -q . && echo 'HasLid s "yes"'
        `]
        stdout: StdioCollector {
            onStreamFinished: {
                const can = {}, logind = {};
                for (const line of text.split("\n")) {
                    const m = line.match(/^(\w+) s "([^"]*)"/);
                    if (!m)
                        continue;
                    if (m[1].startsWith("Can"))
                        can[m[1]] = m[2];
                    else
                        logind[m[1]] = m[2];
                }
                root.can = can;
                root.logind = logind;
            }
        }
    }

    // ── KWin: Plasma's locker and PowerDevil ─────────────────────────────
    // `loft idle status --json`: { settings, kde, matches, applied }
    property var kdeStatus: null
    property string error: ""
    readonly property var kdeValues: kdeStatus?.kde ?? null
    readonly property bool matches: kdeStatus?.matches ?? false

    // What the shell passes (the shape of Settings.idle): the times for the
    // current power source, the lock's grace and lock before sleep.
    readonly property string given: JSON.stringify({
        lockAfter: after("lock"),
        screenOffAfter: after("displayOff"),
        suspendAfter: after("sleep"),
        lockGrace: Settings.idle.lockGrace,
        lockOnResume: Settings.idle.lockOnResume
    })
    onGivenChanged: schedule()
    onKdeChanged: schedule()

    // Settings.idle mirrors the times, so `loft idle` without --settings
    // (the unit, the CLI) sees the same values.
    function mirror() {
        const i = Settings.idle;
        if (i.lockAfter !== after("lock"))
            i.lockAfter = after("lock");
        if (i.screenOffAfter !== after("displayOff"))
            i.screenOffAfter = after("displayOff");
        if (i.suspendAfter !== after("sleep"))
            i.suspendAfter = after("sleep");
    }

    function schedule() {
        if (kde)
            debounce.restart();
    }

    function refreshKde() {
        if (statusProc.running)
            return;
        statusProc.command = ["loft", "idle", "status", "--json", "--settings", given];
        statusProc.running = true;
    }

    // The lock's grace and lock before sleep (Settings.idle; KWin only).
    function set(key, value) {
        Settings.idle[key] = value;
    }

    // "5 min", "30 s", "1 h 30 min", "Never".
    function format(seconds) {
        if (!(seconds > 0))
            return "Never";
        if (seconds < 60)
            return `${seconds} s`;
        const m = Math.round(seconds / 60);
        if (m < 60)
            return `${m} min`;
        return m % 60 ? `${Math.floor(m / 60)} h ${m % 60} min` : `${m / 60} h`;
    }

    Timer {
        id: debounce
        interval: 400
        onTriggered: {
            if (applyProc.running) {
                restart();
                return;
            }
            // Here, not in onGivenChanged: given reads Settings.idle.
            root.mirror();
            root.error = "";
            applyProc.command = ["loft", "idle", "apply", "--settings", root.given];
            applyProc.running = true;
        }
    }

    Process {
        id: applyProc
        stdout: SplitParser {
            onRead: line => {
                if (/not running|not told/.test(line))
                    console.warn(`Idle: ${line}`);
            }
        }
        stderr: StdioCollector {
            id: applyErr
        }
        onExited: code => {
            if (code !== 0) {
                root.error = applyErr.text.trim().split("\n").pop() || `loft idle apply failed (${code})`;
                console.warn(`Idle: ${root.error}`);
            }
            root.refreshKde();
        }
    }

    Process {
        id: statusProc
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.kdeStatus = JSON.parse(text);
                } catch (e) {
                    root.kdeStatus = null;
                }
            }
        }
    }

    // qs ipc call idle status | saver | lock | displays-off
    IpcHandler {
        target: "idle"

        function status(): string {
            return JSON.stringify({
                power: root.power,
                dimmed: root.dimmed,
                saver: root.saverOn,
                lock: lockStep.reached,
                displayOff: displayStep.reached,
                sleep: sleepStep.reached,
                lastAction: root.lastAction,
                powerButton: root.powerAction,
                niriPowerKey: root.niriPowerKey,
                inhibit: root.inhibitWhat,
                lidTakeover: root.lidTakeover,
                after: LockSleepConfig.steps.reduce((o, s) => {
                    o[s] = root.after(s);
                    return o;
                }, {})
            });
        }
        function saver(): void {
            root.previewSaver();
        }
        function displaysOff(): void {
            root.displaysOff();
        }
        // The system menu and Spotlight: sleep the chosen way / hibernate.
        function sleep(): void {
            root.sleepNow("menu");
        }
        function hibernate(): void {
            root.sleepNow("menu", "hibernate");
        }
        // niri binds (niri/shell-binds.kdl.in).
        function powerKey(): void {
            root.powerKey();
        }
        function lidClosed(): void {
            root.lid(true);
        }
        function lidOpened(): void {
            root.lid(false);
        }
    }
}
