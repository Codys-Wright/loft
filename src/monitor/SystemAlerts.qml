import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications
import Quickshell.Services.UPower
import qs.services

// Alerts: notifications (island banners) when the system needs attention —
// sustained CPU load, high temperatures, memory pressure, low disk space,
// low battery. Every condition has to hold for a while before it fires,
// fires once, and re-arms only after it has clearly cleared (hysteresis);
// the same alert never repeats within 10 minutes. Thresholds live in
// Settings → System. Loaded only while the alerts module is on.
Scope {
    id: root

    readonly property var cfg: Settings.system
    readonly property int cooldownMs: 10 * 60 * 1000

    // key → { since (ms, 0 = condition not holding), fired, last (ms) }
    property var state: ({})

    // `over`: the condition holds; `under`: it has cleared (re-arm). Between
    // the two the alert neither fires nor re-arms.
    function track(key, over, under, seconds, notify) {
        const s = state[key] ?? (state[key] = {
                since: 0,
                fired: false,
                last: 0
            });
        const now = Date.now();
        if (over) {
            if (!s.since)
                s.since = now;
            if (!s.fired && now - s.since >= seconds * 1000 && now - s.last >= cooldownMs) {
                s.fired = true;
                s.last = now;
                notify();
            }
        } else {
            s.since = 0;
            if (under)
                s.fired = false;
        }
    }

    function notify(summary, body, icon, critical) {
        Notifications.show({
            appName: "System",
            appIcon: icon,
            summary: summary,
            body: body,
            image: "",
            urgency: critical ? NotificationUrgency.Critical : NotificationUrgency.Normal,
            actions: []
        });
    }

    function topProcessHint() {
        return SystemStats.monitorOpen && SystemStats.processes.length ? ` Busiest: ${SystemStats.processes[0].name}.` : "";
    }

    Connections {
        target: SystemStats

        function onSampled() {
            const c = root.cfg;
            if (c.alertCpu) {
                const t = c.cpuThreshold;
                root.track("cpu", SystemStats.cpu >= t, SystemStats.cpu < t - 0.15, c.cpuSeconds, () => root.notify("Sustained CPU load", `CPU has been above ${Math.round(t * 100)}% for over ${c.cpuSeconds} s.${root.topProcessHint()}`, "utilities-system-monitor", false));
            }

            if (c.alertTemp) {
                const max = SystemStats.maxTemp;
                const hot = Math.max(SystemStats.cpuTemp, SystemStats.gpuTemp);
                const which = SystemStats.gpuTemp > SystemStats.cpuTemp ? "GPU" : "CPU";
                root.track("temp", hot >= max, hot < max - 5, 20, () => root.notify(`${which} is running hot`, `${Math.round(hot)} °C — above the ${Math.round(max)} °C alert for 20 s.`, "dialog-warning", hot >= max + 5));
            }

            if (c.alertMemory) {
                const p = SystemStats.memoryPressure;
                const used = SystemStats.memory;
                root.track("memory", p >= c.memoryPressure || used >= 0.95, p < c.memoryPressure / 2 && used < 0.9, 15, () => root.notify("Memory pressure", `${Math.round(used * 100)}% of ${SystemStats.memoryTotalGiB.toFixed(0)} GiB in use; tasks are stalling on memory ${p.toFixed(0)}% of the time.`, "dialog-warning", used >= 0.98));
            }
        }

        // Low disk: re-alert only when the set of full filesystems grows.
        function onDisksChanged() {
            if (!root.cfg.alertDisk)
                return;
            const t = root.cfg.diskThreshold;
            const full = SystemStats.disks.filter(d => d.use >= t);
            // Keep the ones still within 2% of the threshold (hysteresis).
            const keep = root.alertedDisks.filter(m => SystemStats.disks.some(d => d.mount === m && d.use >= t - 0.02));
            const fresh = full.filter(d => !keep.includes(d.mount));
            root.alertedDisks = keep.concat(fresh.map(d => d.mount));
            if (fresh.length === 0)
                return;
            const d = fresh[0];
            root.notify(fresh.length > 1 ? `${fresh.length} disks are almost full` : `${d.mount} is almost full`, fresh.map(x => `${x.mount}: ${SystemStats.formatBytes(x.avail)} free (${Math.round(x.use * 100)}% used)`).join("\n"), "drive-harddisk", d.use >= 0.98);
        }
    }

    property var alertedDisks: []

    // Disk space changes slowly: check every 5 minutes (the monitor
    // refreshes more often while open).
    Timer {
        running: root.cfg.alertDisk
        interval: 5 * 60 * 1000
        repeat: true
        triggeredOnStart: true
        onTriggered: SystemStats.refreshDisks()
    }

    // ── Battery ─────────────────────────────────────────────────────────
    readonly property var battery: UPower.displayDevice
    readonly property bool hasBattery: battery !== null && battery.ready && battery.isLaptopBattery
    // UPower reports 0..100; Quickshell exposes 0..1.
    readonly property real batteryPct: hasBattery ? (battery.percentage > 1 ? battery.percentage : battery.percentage * 100) : 100
    readonly property bool discharging: hasBattery && UPower.onBattery

    onBatteryPctChanged: checkBattery()
    onDischargingChanged: checkBattery()

    function checkBattery() {
        if (!cfg.alertBattery || !hasBattery)
            return;
        const pct = batteryPct;
        const low = cfg.batteryThreshold;
        const remaining = battery.timeToEmpty > 0 ? ` About ${SystemStats.formatDuration(battery.timeToEmpty)} left.` : "";
        track("battery", discharging && pct <= low, !discharging || pct > low + 5, 0, () => notify("Low battery", `${Math.round(pct)}% remaining.${remaining} Plug in soon.`, "battery-caution", false));
        track("batteryCritical", discharging && pct <= 5, !discharging || pct > 10, 0, () => notify("Battery critically low", `${Math.round(pct)}% remaining.${remaining} Plug in now.`, "battery-empty", true));
    }

    IpcHandler {
        target: "alerts"

        // Preview the alert banner without waiting for a real condition.
        function test(): void {
            root.notify("Sustained CPU load", `CPU has been above ${Math.round(root.cfg.cpuThreshold * 100)}% for over ${root.cfg.cpuSeconds} s.`, "utilities-system-monitor", false);
        }
    }
}
