import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.components
import qs.services

// Settings → Lock & Sleep: when and how the computer dims, starts the
// screen saver, locks, turns the displays off and sleeps (services/Idle.qml,
// LockSleepConfig), how it sleeps (suspend, hibernate, …), the battery's
// critical action, Keep Awake, and what happens during sleep. How the lock
// screen and the screen saver look lives under Appearance; the cards link
// there and back.
ColumnLayout {
    id: page
    spacing: 12

    readonly property var cfg: LockSleepConfig
    readonly property var everyday: EverydayConfig

    component Note: Text {
        Layout.fillWidth: true
        wrapMode: Text.Wrap
        color: Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 12
    }

    // ── Time helpers
    function fmt(secs) {
        if (!secs || secs <= 0)
            return "Never";
        if (secs < 60)
            return `${secs} s`;
        if (secs < 3600)
            return `${Math.round(secs / 60)} min`;
        const h = secs / 3600;
        return Number.isInteger(h) ? `${h} h` : `${Math.floor(h)} h ${Math.round((secs % 3600) / 60)} min`;
    }

    readonly property var choices: ({
            dim: [30, 60, 120, 180, 300, 600, 900, 1800],
            screenSaver: [60, 120, 300, 600, 900, 1200, 1800, 2700, 3600],
            lock: [60, 120, 300, 600, 900, 1200, 1800, 3600, 7200],
            displayOff: [60, 120, 300, 600, 900, 1200, 1800, 3600, 7200],
            sleep: [600, 900, 1200, 1800, 2700, 3600, 7200, 10800]
        })

    function optionsFor(step, current) {
        const l = page.choices[step].slice();
        if (current > 0 && !l.includes(current))
            l.push(current);
        l.sort((a, b) => a - b);
        return [{ value: 0, label: "Never" }].concat(l.map(s => ({ value: s, label: page.fmt(s) })));
    }

    readonly property var names: ({
            dim: "Dim",
            screenSaver: "Screen saver",
            lock: "Lock",
            displayOff: "Display off",
            sleep: "Sleep"
        })

    // "Dim 2 min → Screen saver 5 min → Lock 6 min → …" for a power source.
    function timeline(power) {
        const on = page.cfg.steps.map(s => ({ step: s, secs: page.cfg.seconds(s, power) })).filter(x => x.secs > 0);
        on.sort((a, b) => a.secs - b.secs);
        return on.length === 0 ? "Nothing happens while idle" : on.map(x => `${page.names[x.step]} ${page.fmt(x.secs)}`).join("  →  ");
    }

    // A step that a lock or sleep before it makes pointless.
    function warning(step, power) {
        const secs = page.cfg.seconds(step, power);
        if (secs <= 0)
            return "";
        const lock = page.cfg.seconds("lock", power), off = page.cfg.seconds("displayOff", power), sleep = page.cfg.seconds("sleep", power);
        if ((step === "dim" || step === "screenSaver") && lock > 0 && lock <= secs)
            return "Comes after the lock, so it won't be seen";
        if ((step === "dim" || step === "screenSaver") && off > 0 && off <= secs)
            return "Comes after the displays turn off";
        if (step !== "sleep" && sleep > 0 && sleep <= secs)
            return "Comes after sleep";
        return "";
    }

    // One row per step: label, then a select per power source.
    component StepRow: SettingsRow {
        id: sr
        required property string step
        property string what
        readonly property string warn: page.warning(step, "ac") || (Idle.hasBattery ? page.warning(step, "battery") : "")
        label: page.names[step]
        hint: warn || what
        hintColor: warn ? Theme.warn : Theme.subtext

        SettingsSelect {
            implicitWidth: 120
            options: page.optionsFor(sr.step, page.cfg.seconds(sr.step, "ac"))
            current: page.cfg.seconds(sr.step, "ac")
            onActivated: v => page.cfg.setSeconds(sr.step, "ac", v)
        }
        SettingsSelect {
            visible: Idle.hasBattery
            implicitWidth: 120
            options: page.optionsFor(sr.step, page.cfg.seconds(sr.step, "battery"))
            current: page.cfg.seconds(sr.step, "battery")
            onActivated: v => page.cfg.setSeconds(sr.step, "battery", v)
        }
    }

    // ── When idle
    SettingsCard {
        objectName: "idle"

        PageHeader {
            title: "When idle"
            SettingsButton {
                text: "Screen saver look…"
                onClicked: Panels.openSettings("screensaver")
            }
            SettingsButton {
                text: "Preview"
                onClicked: Idle.previewSaver()
            }
        }
        Note {
            text: (Idle.hasBattery ? `On power: ${page.timeline("ac")}\nOn battery: ${page.timeline("battery")}` : page.timeline("ac")) + (KeepAwake.active ? `\nPaused now: Keep Awake (${KeepAwake.status.toLowerCase()}).` : "")
        }
        // Under KWin, Plasma's locker and PowerDevil do the lock, displays
        // off and sleep with these times (Idle.qml, cli/loft/kdeidle.py).
        Note {
            visible: Idle.kde
            text: {
                const k = Idle.kdeValues;
                if (!k)
                    return "Plasma's locker and PowerDevil follow these while Loft runs.";
                return `Plasma's locker and PowerDevil follow these while Loft runs (KDE's own values come back without Loft). KDE now: lock ${Idle.format(k.lockAfter).toLowerCase()}, displays off ${Idle.format(k.screenOffAfter).toLowerCase()}, sleep ${Idle.format(k.suspendAfter).toLowerCase()}` + (Idle.matches ? "." : " (applying…)");
            }
        }
        Note {
            visible: Idle.error !== ""
            color: Theme.warn
            text: Idle.error
        }

        RowLayout {
            visible: Idle.hasBattery
            Layout.fillWidth: true
            Item {
                Layout.fillWidth: true
            }
            Repeater {
                model: ["On power", "On battery"]
                delegate: Text {
                    required property string modelData
                    Layout.preferredWidth: 120
                    horizontalAlignment: Text.AlignHCenter
                    text: modelData + (Idle.power === (modelData === "On power" ? "ac" : "battery") ? " ·  now" : "")
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 11
                }
            }
        }

        StepRow {
            step: "dim"
            what: "Darken the screens a little first: a warning that moving the mouse cancels"
        }
        StepRow {
            step: "screenSaver"
            what: "Any key, click or mouse move ends it"
        }
        StepRow {
            step: "lock"
            what: "Ask for the password. Always locks before sleep too"
        }
        StepRow {
            step: "displayOff"
            what: "Power the monitors off; any input turns them back on"
        }
        StepRow {
            step: "sleep"
            what: "Using the sleep mode below"
        }
        Note {
            text: "Times count from the last key press or mouse move. A playing video, a call or Keep Awake holds every step (idle inhibitors)."
        }
    }

    // ── Lock
    SettingsCard {
        objectName: "lock"

        PageHeader {
            title: "Lock"
            SettingsButton {
                text: "Lock screen look…"
                onClicked: Panels.openSettings("lockscreen")
            }
            SettingsButton {
                text: "Lock now"
                icon: "󰌾"
                primary: true
                onClicked: LockState.requestLock()
            }
        }
        SettingsRow {
            label: "Lock after idle"
            hint: page.cfg.seconds("lock", Idle.power) > 0 ? `After ${page.fmt(page.cfg.seconds("lock", Idle.power))} (set under When idle)` : "Never on idle (set under When idle)"
        }
        SettingsRow {
            label: "Lock before sleep"
            hint: Idle.kde ? "Plasma's locker locks as the system suspends or hibernates" : "Always: the screen is locked before the system suspends or hibernates"
            SettingsSwitch {
                visible: Idle.kde
                checked: Settings.idle.lockOnResume
                onToggled: on => Idle.set("lockOnResume", on)
            }
        }
        SettingsRow {
            visible: Idle.kde
            label: "Unlock without password for"
            hint: "Right after an idle lock, a key or a move unlocks"
            SettingsSelect {
                options: [0, 5, 10, 30, 60].map(x => ({ value: x, label: x === 0 ? "No grace" : `${x} s` }))
                // -1 = not set here: what `loft idle` resolved (Nix / Loft's 5 s).
                current: Settings.idle.lockGrace >= 0 ? Settings.idle.lockGrace : (Idle.kdeStatus?.settings?.lockGrace ?? 5)
                onActivated: v => Idle.set("lockGrace", v)
            }
        }
        SettingsRow {
            label: "Keyboard shortcut"
            hint: "Mod+Ctrl+Q, or Lock Screen in Spotlight and the Control Center"
        }
        SettingsRow {
            visible: Features.on("phone")
            label: "Lock when the phone leaves"
            hint: "Settings → Phone"
            SettingsButton {
                text: "Phone…"
                onClicked: Panels.openSettings("phone")
            }
        }
    }

    // ── Sleep
    SettingsCard {
        id: sleepCard
        objectName: "sleep"
        onVisibleChanged: if (visible) {
            Idle.refresh();
            SystemInfo.refresh();
            btCard.refresh();
        }

        readonly property var modes: [
            { value: "suspend", label: "Suspend", hint: "Fast to wake; memory stays powered" },
            { value: "hibernate", label: "Hibernate", hint: "Saves memory to disk and powers off: no power used, slower to wake" },
            { value: "hybrid-sleep", label: "Hybrid sleep", hint: "Suspends, with memory also saved to disk in case the power goes" },
            { value: "suspend-then-hibernate", label: "Suspend, then hibernate", hint: "Suspends, then hibernates after a while (HibernateDelaySec in systemd's sleep.conf)" }
        ]
        readonly property var available: modes.filter(m => Idle.canDo(m.value) || m.value === page.cfg.sleepMode)
        readonly property var current: modes.find(m => m.value === page.cfg.sleepMode) ?? modes[0]

        PageHeader {
            title: "Sleep"
        }
        SettingsRow {
            label: "Sleep mode"
            hint: sleepCard.current.hint + (Idle.canDo(page.cfg.sleepMode) ? "" : " — this computer says it can't") + ". Used by idle sleep, Sleep in the menu and Spotlight, the power button and the lid"
            hintColor: Idle.canDo(page.cfg.sleepMode) ? Theme.subtext : Theme.warn
            SettingsSelect {
                options: sleepCard.available.map(m => ({ value: m.value, label: m.label }))
                current: page.cfg.sleepMode
                onActivated: v => page.cfg.sleepMode = v
            }
        }
        SettingsRow {
            visible: Idle.canDo("hibernate")
            label: "Hibernate in the menu"
            hint: "The system menu gets Hibernate under Sleep"
            SettingsSwitch {
                checked: page.cfg.showHibernate
                onToggled: on => page.cfg.showHibernate = on
            }
        }
        Note {
            visible: sleepCard.available.length < sleepCard.modes.length
            text: "Missing modes aren't available on this computer: hibernating needs swap at least as large as the memory in use, and no kernel lockdown (Secure Boot usually turns it on)."
        }
        Note {
            visible: SystemInfo.nvidia
            color: Theme.warn
            text: "NVIDIA graphics: suspend may not come back cleanly; hibernate is often safer."
        }

        // During sleep (the loft-sleep user service does the work).
        Item {
            id: btCard
            visible: false
            // `loft-sleep status`: { enabled, remembered, adapters: [{ path, powered }] }
            property var status: null
            property bool serviceActive: false
            readonly property var adapters: status?.adapters ?? []

            function refresh() {
                sleepStatus.running = true;
                sleepUnit.running = true;
            }
            Component.onCompleted: refresh()

            Process {
                id: sleepStatus
                command: ["loft-sleep", "status"]
                stdout: StdioCollector {
                    onStreamFinished: {
                        try {
                            btCard.status = JSON.parse(text);
                        } catch (e) {
                            btCard.status = null;
                        }
                    }
                }
            }
            Process {
                id: sleepUnit
                command: ["systemctl", "--user", "is-active", "--quiet", "loft-sleep.service"]
                onExited: code => btCard.serviceActive = code === 0
            }
        }
        SettingsRow {
            label: "Turn Bluetooth off during sleep"
            hint: (btCard.serviceActive ? "" : "The loft-sleep service isn't running (programs.loft.sleepWatcher) · ") + (btCard.adapters.length === 0 ? "No Bluetooth adapter found" : btCard.adapters.map(a => `${a.path.replace(/^.*\//, "")}: ${a.powered ? "on" : "off"}`).join(" · ") + " — back on after the wake if it was on")
            hintColor: btCard.serviceActive ? Theme.subtext : Theme.warn
            SettingsSwitch {
                checked: page.everyday.sleep.bluetoothOff
                onToggled: on => page.everyday.sleep.bluetoothOff = on
            }
        }
    }

    // ── Power button and lid
    SettingsCard {
        id: buttonsCard
        objectName: "buttons"

        readonly property var actionNames: ({
                "ignore": "Nothing",
                "nothing": "Nothing",
                "poweroff": "Shut down",
                "reboot": "Restart",
                "halt": "Halt",
                "kexec": "Restart (kexec)",
                "suspend": "Suspend",
                "hibernate": "Hibernate",
                "hybrid-sleep": "Hybrid sleep",
                "suspend-then-hibernate": "Suspend, then hibernate",
                "lock": "Lock",
                "sleep": "Sleep",
                "displayOff": "Turn the display off",
                "ask": "Ask (Shut Down dialog)",
                "factory-reset": "Factory reset"
            })
        function name(v) {
            return v ? (actionNames[v] ?? v) : "…";
        }

        readonly property var powerOptions: [
            { value: "sleep", label: "Sleep" },
            { value: "hibernate", label: "Hibernate" },
            { value: "lock", label: "Lock" },
            { value: "displayOff", label: "Turn display off" },
            { value: "ask", label: "Ask" },
            { value: "poweroff", label: "Shut down" },
            { value: "nothing", label: "Nothing" },
            { value: "system", label: "System default" }
        ].filter(o => o.value !== "hibernate" || Idle.canDo("hibernate"))

        function lidOptions(context) {
            const sys = name(Idle.logindLid(context));
            return [
                { value: "system", label: `System (${sys})` },
                { value: "sleep", label: "Sleep" },
                { value: "hibernate", label: "Hibernate" },
                { value: "lock", label: "Lock" },
                { value: "displayOff", label: "Turn display off" },
                { value: "nothing", label: "Nothing" }
            ].filter(o => o.value !== "hibernate" || Idle.canDo("hibernate"));
        }

        PageHeader {
            title: "Power button & lid"
        }
        Note {
            visible: Idle.kde
            text: "In a Plasma session, PowerDevil handles the power button and the lid (System Settings → Power Management)."
        }
        SettingsRow {
            visible: !Idle.kde
            label: "Pressing the power button"
            hint: page.cfg.powerButton === "system" ? `systemd-logind decides: ${buttonsCard.name(Idle.logind.HandlePowerKey)} (services.logind.settings.Login.HandlePowerKey in NixOS)` : Idle.niriPowerKey ? "Suspends (niri's own power-key handling)" : page.cfg.powerButton === "sleep" ? `Sleeps the chosen way (${sleepCard.current.label.toLowerCase()})` : "Works on the lock screen too"
            SettingsSelect {
                options: buttonsCard.powerOptions
                current: page.cfg.powerButton
                onActivated: v => page.cfg.powerButton = v
            }
        }

        SettingsRow {
            visible: Idle.hasLid && !Idle.kde
            label: "Closing the lid on battery"
            SettingsSelect {
                implicitWidth: 180
                options: buttonsCard.lidOptions("battery")
                current: page.cfg.lid.battery
                onActivated: v => page.cfg.lid.battery = v
            }
        }
        SettingsRow {
            visible: Idle.hasLid && !Idle.kde
            label: "Closing the lid on power"
            SettingsSelect {
                implicitWidth: 180
                options: buttonsCard.lidOptions("ac")
                current: page.cfg.lid.ac
                onActivated: v => page.cfg.lid.ac = v
            }
        }
        SettingsRow {
            visible: Idle.hasLid && !Idle.kde
            label: "Closing the lid with a display connected"
            hint: "An external display counts as docked"
            SettingsSelect {
                implicitWidth: 180
                options: buttonsCard.lidOptions("docked")
                current: page.cfg.lid.docked
                onActivated: v => page.cfg.lid.docked = v
            }
        }
        Note {
            visible: !Idle.kde
            text: (Idle.inhibitError ? `systemd-logind refused the inhibitor (${Idle.inhibitError}), so it may act on the key or lid as well. ` : "") + (Idle.hasLid ? "\"System\" leaves the lid to systemd-logind. Any other choice is done by Loft while it runs (logind is told to stand back); if the shell isn't running, logind's own settings apply." : "No lid on this computer.") + (Idle.devMode ? " Dev session: nothing is inhibited, and sleep / shut down are only logged." : "")
        }
    }

    // ── Battery
    SettingsCard {
        objectName: "battery"
        visible: Idle.hasBattery

        PageHeader {
            title: "Battery"
        }
        SettingsRow {
            label: "Low battery warning"
            hint: Settings.system.alertBattery ? `A notification at ${Settings.system.batteryThreshold}% (also in System → Alerts)` : "Off"
            SettingsSelect {
                options: [{ value: 0, label: "Off" }, { value: 10, label: "10%" }, { value: 15, label: "15%" }, { value: 20, label: "20%" }, { value: 25, label: "25%" }]
                current: Settings.system.alertBattery ? Settings.system.batteryThreshold : 0
                onActivated: v => {
                    Settings.system.alertBattery = v > 0;
                    if (v > 0)
                        Settings.system.batteryThreshold = v;
                }
            }
        }
        SettingsRow {
            label: "When the battery is critical"
            hint: page.cfg.battery.criticalPercent > 0 ? `At ${page.cfg.battery.criticalPercent}% on battery, after a 5 s warning` : "Nothing (the system may still act on its own)"
            SettingsSelect {
                options: [{ value: "hibernate", label: "Hibernate" }, { value: "sleep", label: "Sleep" }, { value: "poweroff", label: "Shut down" }, { value: "none", label: "Do nothing" }]
                current: page.cfg.battery.criticalAction
                onActivated: v => page.cfg.battery.criticalAction = v
            }
            SettingsSelect {
                implicitWidth: 80
                enabled: page.cfg.battery.criticalAction !== "none"
                options: [{ value: 3, label: "3%" }, { value: 5, label: "5%" }, { value: 7, label: "7%" }, { value: 10, label: "10%" }]
                current: page.cfg.battery.criticalPercent
                onActivated: v => page.cfg.battery.criticalPercent = v
            }
        }
    }

    // ── Keep Awake (moved from Everyday)
    SettingsCard {
        objectName: "keepawake"
        visible: Features.on("keepAwake")

        PageHeader {
            title: "Keep Awake"
        }
        Note {
            text: KeepAwake.kde ? (KWin.keepAwake.error ? `${KWin.keepAwake.error}. ` : "") + `Now: ${KeepAwake.status}. While awake, PowerDevil neither dims nor turns the displays off, Plasma's locker doesn't lock on idle and the system doesn't sleep on idle (a PowerDevil inhibition, listed in Plasma's battery applet as Loft's). Closing the lid does what PowerDevil's lid setting says.` : (KeepAwake.inhibitError ? `systemd-logind refused the inhibitor (${KeepAwake.inhibitError}); idle is still inhibited through Wayland. ` : "") + `Now: ${KeepAwake.status}. While awake nothing above happens on idle (an idle inhibitor) and, with the option below, the system doesn't suspend (a systemd-logind inhibitor).`
        }
        SettingsRow {
            label: "The toggle keeps awake"
            hint: "Control Center / menu bar click; the menu has more durations"
            SettingsSegmented {
                options: [{ value: 0, label: "Until off" }, { value: 15, label: "15 min" }, { value: 60, label: "1 h" }, { value: 120, label: "2 h" }]
                current: page.everyday.keepAwake.defaultMinutes
                onActivated: v => page.everyday.keepAwake.defaultMinutes = v
            }
        }
        SettingsRow {
            // Under KWin, PowerDevil's inhibition always holds off idle sleep.
            visible: !KeepAwake.kde
            label: "Also block suspend"
            hint: "systemd-inhibit --what=idle:sleep while awake"
            SettingsSwitch {
                checked: page.everyday.keepAwake.blockSleep
                onToggled: on => page.everyday.keepAwake.blockSleep = on
            }
        }
        SettingsRow {
            visible: KeepAwake.hasBattery && !KeepAwake.kde
            label: "Stay awake with the lid closed"
            hint: "While awake, closing the lid doesn't suspend (logind handle-lid-switch inhibitor)"
            SettingsSwitch {
                checked: page.everyday.keepAwake.lidClosed
                onToggled: on => page.everyday.keepAwake.lidClosed = on
            }
        }
        SettingsRow {
            label: "While on power"
            hint: KeepAwake.hasBattery ? (KeepAwake.onAC ? "On power now" : "On battery now") : "No battery: always on power"
            SettingsSwitch {
                checked: page.everyday.keepAwake.onAC
                onToggled: on => page.everyday.keepAwake.onAC = on
            }
        }
        SettingsRow {
            label: "While an external display is connected"
            hint: KeepAwake.externalScreens.length > 0 ? `Connected: ${KeepAwake.externalScreens.map(s => s.name).join(", ")}` : "None connected (eDP / LVDS / DSI panels are internal)"
            SettingsSwitch {
                checked: page.everyday.keepAwake.externalDisplay
                onToggled: on => page.everyday.keepAwake.externalDisplay = on
            }
        }
        SettingsRow {
            label: "While these apps have a window open"
        }
        AppIdList {
            apps: Array.from(page.everyday.keepAwake.apps)
            emptyText: "No apps — e.g. a video player or a presentation app"
            onChanged: l => page.everyday.keepAwake.apps = l
        }
    }
}
