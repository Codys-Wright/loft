pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// System load, temperatures, network traffic and processes, read from /proc
// and /sys.
//
// Cost is tiered by who is looking:
//   background   every 2 s: /proc/stat, /proc/meminfo, the CPU sensor, memory
//                pressure and (with the network module) /proc/net/dev — a few
//                small file reads, no processes. Feeds the island's alert
//                border, the bar readouts, the alerts and the history graphs.
//   detailed     the island's system page: also the GPU (nvidia-smi on NVIDIA,
//                sysfs gpu_busy_percent on AMD), every second.
//   monitorOpen  the System Monitor window: the above plus per-core load,
//                processes (one awk over /proc/<pid>/stat + status), every
//                hwmon sensor and fan, and disks.
Singleton {
    id: root

    property bool detailed: false // island system page (bound by Island)
    property bool monitorOpen: false // the System Monitor window
    property string monitorSection: "overview" // its page

    readonly property bool fast: detailed || monitorOpen
    readonly property var readouts: Features.on("barReadouts") ? Settings.system.readouts : []
    readonly property bool gpuWanted: fast || readouts.includes("gpu")
    readonly property bool networkWanted: Features.on("network") || readouts.includes("network")
    readonly property bool historyWanted: Features.on("systemMonitor")

    // Emitted after every sample (the alerts hook in here).
    signal sampled

    property real cpu: 0 // 0..1
    property var cores: [] // 0..1 per logical CPU (monitorOpen only)
    property real cpuTemp: 0 // °C
    property var loadAvg: [0, 0, 0]
    property real uptime: 0 // seconds
    property real memory: 0 // 0..1
    property real memoryUsedGiB: 0
    property real memoryTotalGiB: 0
    property real memoryCachedGiB: 0
    property real swapUsedGiB: 0
    property real swapTotalGiB: 0
    property real memoryPressure: 0 // PSI "some" avg10, %
    property real gpu: -1 // 0..1, -1 = unknown
    property real gpuTemp: -1
    property string gpuName: ""
    property real gpuMemUsedMiB: -1
    property real gpuMemTotalMiB: -1
    property real gpuFan: -1 // %, NVIDIA only
    property real gpuPower: -1 // W

    // Alert thresholds (Settings.island). Zen 4 runs to 95 °C by design.
    readonly property real maxTemp: Settings.island.maxTemp
    readonly property real maxLoad: Settings.island.maxLoad
    readonly property bool overheating: cpuTemp > maxTemp || gpuTemp > maxTemp
    readonly property bool overloaded: cpu > maxLoad || memory > maxLoad

    // ── Network ─────────────────────────────────────────────────────────
    // Rates (bytes/s) and session totals (bytes since the shell started)
    // summed over physical interfaces, so bridges/VPNs aren't counted twice.
    property real netRx: 0
    property real netTx: 0
    property real sessionRx: 0
    property real sessionTx: 0
    // [{ name, physical, wireless, rxRate, txRate, rxSession, txSession, rxTotal, txTotal }]
    property var interfaces: []
    property var physicalIfaces: null // names with a /sys/class/net/<if>/device
    property var wirelessIfaces: []
    property var lastNet: null

    // ── History (ring buffers, one sample every ~2 s) ───────────────────
    readonly property int historyLength: 150
    readonly property int historySeconds: 300
    property var history: ({
            cpu: [],
            gpu: [],
            memory: [],
            cpuTemp: [],
            gpuTemp: [],
            rx: [],
            tx: []
        })
    property real lastPush: 0

    function pushHistory() {
        const now = Date.now();
        if (now - lastPush < 1900)
            return;
        lastPush = now;
        const h = {};
        const add = (key, v) => {
            const a = history[key].length >= historyLength ? history[key].slice(1) : history[key].slice();
            a.push(v);
            h[key] = a;
        };
        add("cpu", cpu);
        add("gpu", gpuWanted && gpu >= 0 ? gpu : null);
        add("memory", memory);
        add("cpuTemp", cpuTemp > 0 ? cpuTemp : null);
        add("gpuTemp", gpuWanted && gpuTemp > 0 ? gpuTemp : null);
        add("rx", networkWanted ? netRx : null);
        add("tx", networkWanted ? netTx : null);
        history = h;
    }

    // ── Processes (monitorOpen only) ────────────────────────────────────
    // [{ pid, name, uid, cpu (% of one core), rssKiB, state }], top 30 by `processSort`.
    property var processes: []
    property string processSort: "cpu" // cpu | memory
    property int processCount: 0
    property int threadCount: 0
    property var lastProcs: null // { uptime, ticks: { pid: ticks } }
    property var allProcs: []
    property string killError: ""
    property int myUid: -1 // only your own processes can be quit

    Process {
        running: true
        command: ["id", "-u"]
        stdout: StdioCollector {
            onStreamFinished: root.myUid = Number(text.trim())
        }
    }

    onProcessSortChanged: sortProcesses()
    function sortProcesses() {
        const key = processSort === "memory" ? "rssKiB" : "cpu";
        processes = allProcs.slice().sort((a, b) => b[key] - a[key] || b.rssKiB - a.rssKiB).slice(0, 30);
    }

    // Quit (SIGTERM) or force quit (SIGKILL) a process.
    function kill(pid, force) {
        killError = "";
        killer.command = ["kill", force ? "-KILL" : "-TERM", String(pid)];
        killer.running = true;
    }

    // ── Sensors and disks (monitorOpen / on request) ────────────────────
    // [{ chipId (hwmon N), chip, label, kind: "temp" | "fan", value (°C | RPM) }]
    property var sensors: []
    property var sensorLabels: null // "<hwmon>/name" and "<hwmon>/<x>_label" → text
    // [{ source, fstype, size, used, avail, use (0..1), mount }] — one per device.
    property var disks: []
    property real disksAt: 0

    function refreshDisks() {
        if (!diskProbe.running)
            diskProbe.running = true;
    }

    // ── Formatting ──────────────────────────────────────────────────────
    function formatBytes(n) {
        const u = ["B", "KB", "MB", "GB", "TB", "PB"];
        let i = 0;
        n = Math.max(0, n);
        while (n >= 1000 && i < u.length - 1) {
            n /= 1000;
            i++;
        }
        return `${n >= 100 || i === 0 ? n.toFixed(0) : n.toFixed(1)} ${u[i]}`;
    }
    function formatRate(n) {
        return `${formatBytes(n)}/s`;
    }
    // Bar-sized: "1.2M", "340K".
    function formatRateShort(n) {
        const u = ["B", "K", "M", "G"];
        let i = 0;
        n = Math.max(0, n);
        while (n >= 1000 && i < u.length - 1) {
            n /= 1000;
            i++;
        }
        return `${n >= 10 || i === 0 ? n.toFixed(0) : n.toFixed(1)}${u[i]}`;
    }
    function formatKiB(k) {
        return formatBytes(k * 1024);
    }
    function formatDuration(s) {
        const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
        return d > 0 ? `${d}d ${h}h` : h > 0 ? `${h}h ${m}m` : `${m}m`;
    }

    // ── Sampling ────────────────────────────────────────────────────────
    property int tick: 0
    Timer {
        interval: root.fast ? 1000 : 2000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            // FileView loads asynchronously: what the previous tick read is
            // complete now, so record it before reading again.
            if (root.tick > 0) {
                if (root.historyWanted)
                    root.pushHistory();
                root.sampled();
            }
            root.tick++;
            stat.reload();
            meminfo.reload();
            pressure.reload();
            if (root.cpuTempPath !== "")
                cpuTempFile.reload();
            if (root.networkWanted)
                netdev.reload();
            // Bar-only GPU readouts poll at a third of the rate (nvidia-smi
            // is a process, not a file read).
            if (root.gpuWanted && (root.fast || root.tick % 3 === 0) && !gpuProbe.running)
                gpuProbe.running = true;
            if (root.monitorOpen) {
                loadavg.reload();
                if (root.tick % 2 === 0 && !procProbe.running)
                    procProbe.running = true;
                if (root.tick % 2 === 1 && root.sensorLabels !== null && !sensorProbe.running)
                    sensorProbe.running = true;
                if (Date.now() - root.disksAt > 30000)
                    root.refreshDisks();
            }
        }
    }

    onMonitorOpenChanged: {
        if (!monitorOpen)
            return;
        lastProcs = null;
        if (sensorLabels === null)
            sensorDiscover.running = true;
        if (!procProbe.running)
            procProbe.running = true;
        refreshDisks();
    }
    // Nobody polls the GPU any more: forget the last reading rather than
    // alert on a stale one.
    onGpuWantedChanged: if (!gpuWanted) {
        gpu = -1;
        gpuTemp = -1;
    }
    onNetworkWantedChanged: if (networkWanted && physicalIfaces === null)
        netDiscover.running = true
    Component.onCompleted: if (networkWanted)
        netDiscover.running = true

    // Find the CPU sensor: k10temp/zenpower (AMD) or coretemp (Intel).
    property string cpuTempPath: ""
    Process {
        running: true
        command: ["sh", "-c", "for h in /sys/class/hwmon/hwmon*; do case $(cat $h/name) in k10temp|zenpower|coretemp) echo $h/temp1_input; exit;; esac; done"]
        stdout: StdioCollector {
            onStreamFinished: root.cpuTempPath = text.trim()
        }
    }

    FileView {
        id: cpuTempFile
        path: root.cpuTempPath
        onLoaded: root.cpuTemp = Number(text()) / 1000
    }

    property var lastCpu: null
    property var lastCores: []
    FileView {
        id: stat
        path: "/proc/stat"
        onLoaded: {
            const lines = text().split("\n");
            const parse = line => {
                const f = line.trim().split(/\s+/).slice(1).map(Number);
                return {
                    idle: f[3] + (f[4] ?? 0),
                    total: f.reduce((a, b) => a + b, 0)
                };
            };
            const usage = (now, last) => {
                const dt = now.total - last.total;
                return dt > 0 ? 1 - (now.idle - last.idle) / dt : 0;
            };
            const all = parse(lines[0]);
            if (root.lastCpu)
                root.cpu = usage(all, root.lastCpu);
            root.lastCpu = all;

            if (!root.monitorOpen)
                return;
            const now = lines.filter(l => /^cpu\d/.test(l)).map(parse);
            if (root.lastCores.length === now.length)
                root.cores = now.map((c, i) => usage(c, root.lastCores[i]));
            root.lastCores = now;
        }
    }

    FileView {
        id: meminfo
        path: "/proc/meminfo"
        onLoaded: {
            const t = text();
            const kb = key => Number((t.match(new RegExp(`^${key}:\\s+(\\d+)`, "m")) ?? [0, 0])[1]);
            const total = kb("MemTotal");
            const avail = kb("MemAvailable");
            if (total > 0) {
                root.memory = (total - avail) / total;
                root.memoryUsedGiB = (total - avail) / 1048576;
                root.memoryTotalGiB = total / 1048576;
                root.memoryCachedGiB = (kb("Cached") + kb("Buffers")) / 1048576;
                root.swapTotalGiB = kb("SwapTotal") / 1048576;
                root.swapUsedGiB = (kb("SwapTotal") - kb("SwapFree")) / 1048576;
            }
        }
    }

    FileView {
        id: pressure
        path: "/proc/pressure/memory"
        printErrors: false
        onLoaded: {
            const m = text().match(/^some avg10=([\d.]+)/m);
            root.memoryPressure = m ? Number(m[1]) : 0;
        }
    }

    FileView {
        id: loadavg
        path: "/proc/loadavg"
        onLoaded: {
            root.loadAvg = text().trim().split(/\s+/).slice(0, 3).map(Number);
            uptimeFile.reload();
        }
    }

    FileView {
        id: uptimeFile
        path: "/proc/uptime"
        onLoaded: root.uptime = Number(text().split(/\s+/)[0])
    }

    // GPU: NVIDIA via nvidia-smi, else the first AMD/Intel sysfs busy counter.
    Process {
        id: gpuProbe
        command: ["sh", "-c", "if command -v nvidia-smi >/dev/null; then nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total,fan.speed,power.draw,name --format=csv,noheader,nounits | head -n1; else for f in /sys/class/drm/card*/device/gpu_busy_percent; do [ -r \"$f\" ] && echo \"$(cat $f), -1\" && exit; done; fi"]
        stdout: StdioCollector {
            onStreamFinished: {
                const f = text.trim().split(",").map(s => s.trim());
                const num = i => {
                    const v = Number(f[i]);
                    return f[i] === undefined || f[i] === "" || isNaN(v) ? -1 : v;
                };
                const use = num(0);
                root.gpu = use < 0 ? -1 : use / 100;
                root.gpuTemp = num(1);
                root.gpuMemUsedMiB = num(2);
                root.gpuMemTotalMiB = num(3);
                root.gpuFan = num(4);
                root.gpuPower = num(5);
                root.gpuName = f.slice(6).join(",");
            }
        }
    }

    // ── Network ─────────────────────────────────────────────────────────
    Process {
        id: netDiscover
        command: ["sh", "-c", "for i in /sys/class/net/*; do [ -e \"$i/device\" ] || continue; n=${i##*/}; if [ -d \"$i/wireless\" ]; then echo \"$n wifi\"; else echo \"$n wired\"; fi; done"]
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = text.trim().split("\n").filter(l => l);
                root.physicalIfaces = lines.map(l => l.split(" ")[0]);
                root.wirelessIfaces = lines.filter(l => l.endsWith(" wifi")).map(l => l.split(" ")[0]);
            }
        }
    }

    FileView {
        id: netdev
        path: "/proc/net/dev"
        onLoaded: {
            const now = Date.now();
            const cur = {};
            for (const line of text().split("\n").slice(2)) {
                const m = line.match(/^\s*([^:]+):\s*(.*)$/);
                if (!m)
                    continue;
                const f = m[2].trim().split(/\s+/).map(Number);
                cur[m[1]] = {
                    rx: f[0],
                    tx: f[8]
                };
            }
            const last = root.lastNet;
            const dt = last ? (now - last.at) / 1000 : 0;
            const prev = root.interfaces;
            const phys = root.physicalIfaces;
            // Before discovery finishes, guess: skip virtual devices.
            const isPhysical = name => phys !== null ? phys.includes(name) : !/^(veth|br-|docker|virbr|vnet|tap|tun|wg|tailscale|podman|cni|flannel|cali|kube)/.test(name);
            const list = [];
            let rx = 0, tx = 0, srx = 0, stx = 0;
            for (const name of Object.keys(cur)) {
                if (name === "lo")
                    continue;
                const c = cur[name];
                const p = last ? last.counters[name] : undefined;
                const old = prev.find(i => i.name === name);
                // Counters can reset (interface re-created): count nothing.
                const drx = p && c.rx >= p.rx ? c.rx - p.rx : 0;
                const dtx = p && c.tx >= p.tx ? c.tx - p.tx : 0;
                const iface = {
                    name: name,
                    physical: isPhysical(name),
                    wireless: root.wirelessIfaces.includes(name),
                    rxRate: dt > 0 ? drx / dt : 0,
                    txRate: dt > 0 ? dtx / dt : 0,
                    rxSession: (old ? old.rxSession : 0) + drx,
                    txSession: (old ? old.txSession : 0) + dtx,
                    rxTotal: c.rx,
                    txTotal: c.tx
                };
                list.push(iface);
                if (iface.physical) {
                    rx += iface.rxRate;
                    tx += iface.txRate;
                    srx += iface.rxSession;
                    stx += iface.txSession;
                }
            }
            list.sort((a, b) => (b.physical - a.physical) || (b.rxTotal + b.txTotal) - (a.rxTotal + a.txTotal));
            root.interfaces = list;
            root.netRx = rx;
            root.netTx = tx;
            root.sessionRx = srx;
            root.sessionTx = stx;
            root.lastNet = {
                at: now,
                counters: cur
            };
        }
    }

    // ── Processes ───────────────────────────────────────────────────────
    // One awk over every /proc/<pid>/stat (name, state, CPU ticks, RSS,
    // threads) and /proc/<pid>/status (owner). Processes that exit between
    // the glob and the read are skipped (gawk's BEGINFILE; gawk is in the
    // shell's runtime deps — other awks make a vanished file fatal).
    Process {
        id: procProbe
        command: ["sh", "-c", `exec awk '
            BEGINFILE { if (ERRNO != "") nextfile }
            FILENAME == "/proc/uptime" { print "U", $1; nextfile }
            FILENAME ~ /stat$/ {
                match($0, /\\(.*\\)/); comm = substr($0, RSTART + 1, RLENGTH - 2);
                split(substr($0, RSTART + RLENGTH + 1), f, " ");
                split(FILENAME, p, "/");
                print "S", p[3], f[1], f[12] + f[13], f[22] * 4, f[18], comm; nextfile
            }
            /^Uid:/ { split(FILENAME, p, "/"); print "O", p[3], $2; nextfile }
        ' /proc/uptime /proc/[0-9]*/stat /proc/[0-9]*/status 2>/dev/null`]
        stdout: StdioCollector {
            onStreamFinished: root.parseProcs(text)
        }
    }

    function parseProcs(out) {
        let up = 0;
        let threads = 0;
        const procs = {};
        const owners = {};
        for (const line of out.split("\n")) {
            if (line.startsWith("U ")) {
                up = Number(line.slice(2));
            } else if (line.startsWith("S ")) {
                // S pid state ticks rssKiB threads comm…
                const f = line.split(" ");
                procs[f[1]] = {
                    pid: Number(f[1]),
                    state: f[2],
                    ticks: Number(f[3]),
                    rssKiB: Number(f[4]),
                    name: f.slice(6).join(" ")
                };
                threads += Number(f[5]) || 0;
            } else if (line.startsWith("O ")) {
                const f = line.split(" ");
                owners[f[1]] = Number(f[2]);
            }
        }
        const last = lastProcs;
        const dt = last ? up - last.uptime : 0;
        const ticks = {};
        const list = [];
        for (const pid in procs) {
            const p = procs[pid];
            ticks[pid] = p.ticks;
            const prev = last ? last.ticks[pid] : undefined;
            // CLK_TCK is 100 on Linux; % of one core, like top.
            p.cpu = dt > 0 && prev !== undefined ? Math.max(0, (p.ticks - prev) / dt) : 0;
            p.uid = owners[pid] ?? -1;
            list.push(p);
        }
        lastProcs = {
            uptime: up,
            ticks: ticks
        };
        processCount = list.length;
        threadCount = threads;
        allProcs = list;
        sortProcesses();
    }

    Process {
        id: killer
        stderr: StdioCollector {
            onStreamFinished: if (text.trim() !== "")
                root.killError = text.trim()
        }
        onExited: if (!procProbe.running)
            procProbe.running = true
    }

    // ── Sensors ─────────────────────────────────────────────────────────
    // Names and labels once; the inputs are re-read while the monitor is open.
    Process {
        id: sensorDiscover
        command: ["sh", "-c", "grep -Hs . /sys/class/hwmon/hwmon*/name /sys/class/hwmon/hwmon*/device/model /sys/class/hwmon/hwmon*/temp*_label /sys/class/hwmon/hwmon*/fan*_label; true"]
        stdout: StdioCollector {
            onStreamFinished: {
                const labels = {};
                for (const line of text.split("\n")) {
                    const i = line.indexOf(":");
                    if (i > 0)
                        labels[line.slice(0, i)] = line.slice(i + 1).trim();
                }
                root.sensorLabels = labels;
                sensorProbe.running = true;
            }
        }
    }

    Process {
        id: sensorProbe
        command: ["sh", "-c", "grep -Hs . /sys/class/hwmon/hwmon*/temp*_input /sys/class/hwmon/hwmon*/fan*_input; true"]
        stdout: StdioCollector {
            onStreamFinished: {
                const labels = root.sensorLabels ?? {};
                const list = [];
                for (const line of text.split("\n")) {
                    const m = line.match(/^(\/sys\/class\/hwmon\/hwmon\d+)\/(temp|fan)(\d+)_input:(-?\d+)/);
                    if (!m)
                        continue;
                    const kind = m[2];
                    const raw = Number(m[4]);
                    // Unconnected headers read as nonsense (-62 °C, 127 °C).
                    if (kind === "temp" && (raw < -20000 || raw >= 127000))
                        continue;
                    list.push({
                        chipId: Number(m[1].match(/\d+$/)[0]),
                        // Drives say which drive (the controller's model).
                        chip: (labels[`${m[1]}/device/model`] ?? labels[`${m[1]}/name`] ?? m[1].split("/").pop()).trim(),
                        label: labels[`${m[1]}/${kind}${m[3]}_label`] ?? `${kind === "temp" ? "Temp" : "Fan"} ${m[3]}`,
                        kind: kind,
                        value: kind === "temp" ? raw / 1000 : raw
                    });
                }
                list.sort((a, b) => a.chip.localeCompare(b.chip) || a.chipId - b.chipId || b.kind.localeCompare(a.kind) || a.label.localeCompare(b.label, undefined, {
                        numeric: true
                    }));
                root.sensors = list;
            }
        }
    }

    // ── Disks ───────────────────────────────────────────────────────────
    // Local filesystems only (a stale network mount would hang df), one row
    // per device (btrfs subvolumes and the /nix/store bind mount share one).
    Process {
        id: diskProbe
        command: ["sh", "-c", "timeout 5 df -l -B1 --output=source,fstype,size,used,avail,target -x tmpfs -x devtmpfs -x efivarfs -x overlay -x squashfs -x ramfs 2>/dev/null; true"]
        stdout: StdioCollector {
            onStreamFinished: {
                const byDev = {};
                for (const line of text.split("\n").slice(1)) {
                    const f = line.trim().split(/\s+/);
                    if (f.length < 6)
                        continue;
                    const d = {
                        source: f[0],
                        fstype: f[1],
                        size: Number(f[2]),
                        used: Number(f[3]),
                        avail: Number(f[4]),
                        mount: f.slice(5).join(" ")
                    };
                    if (!(d.size > 0) || d.fstype === "fuse.portal")
                        continue;
                    // df's Use%: root-reserved blocks don't count as free.
                    d.use = d.used + d.avail > 0 ? d.used / (d.used + d.avail) : 0;
                    const prev = byDev[d.source];
                    if (!prev || d.mount.length < prev.mount.length)
                        byDev[d.source] = d;
                }
                root.disks = Object.values(byDev).sort((a, b) => a.mount.localeCompare(b.mount));
                root.disksAt = Date.now();
            }
        }
    }
}
