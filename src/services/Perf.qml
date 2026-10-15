pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

// A lightweight watchdog for the shell itself: is the GUI thread keeping up?
//
//   - event-loop lag: a 100 ms timer notes how late it fires; lateness is
//     time the GUI thread was busy (QML, rendering, a video frame upload…).
//     Kept for the last 30 s: p50 / p99 / max, stalls over 50 ms.
//   - CPU % and RSS from /proc/self/stat and /proc/self/statm every 5 s.
//   - what usually costs: video wallpapers loaded / playing and how they
//     decode (VideoWallpapers), wallpaper surfaces, child processes,
//     reloads.
//
// `qs ipc call perf status` returns it as JSON; `loft doctor perf` prints
// it with the child processes and the journal's copy-back warnings.
// Sustained trouble (lag p99 > 50 ms or CPU > 60% for 30 s) logs one line
// naming the likely culprit (at most every 10 minutes) and, with
// Settings → System → "Desktop shell running slow" (off by default), shows
// a notification once per session.
Singleton {
    id: root

    readonly property int tickMs: 100
    readonly property int windowS: 30
    readonly property int sampleMs: 5000

    // ── Event-loop lag ───────────────────────────────────────────────────
    property var lags: []          // ms late, one per tick, last windowS
    property real lastTick: 0
    Timer {
        interval: root.tickMs
        running: true
        repeat: true
        onTriggered: {
            const now = Date.now();
            if (root.lastTick > 0) {
                const late = Math.max(0, now - root.lastTick - root.tickMs);
                const l = root.lags;
                l.push(late);
                if (l.length > root.windowS * 1000 / root.tickMs)
                    l.shift();
            }
            root.lastTick = now;
        }
    }
    function pct(sorted, p) {
        return sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * p))] : 0;
    }
    function lagStats() {
        const s = lags.slice().sort((a, b) => a - b);
        return {
            p50: pct(s, 0.5),
            p99: pct(s, 0.99),
            max: s.length ? s[s.length - 1] : 0,
            stalls: lags.filter(v => v > 50).length
        };
    }

    // ── CPU / memory ─────────────────────────────────────────────────────
    readonly property int pid: Quickshell.processId
    property real cpu: 0          // % of one core, last sample
    property var cpuHistory: []   // last windowS / 5 s samples
    property real rssMB: 0
    property real lastCpuTicks: -1
    property real lastCpuAt: 0
    property int childCount: 0
    readonly property real cpuAvg: cpuHistory.length ? Math.round(cpuHistory.reduce((a, b) => a + b, 0) / cpuHistory.length) : 0

    FileView {
        id: statFile
        path: `/proc/${root.pid}/stat`
        blockLoading: true
        printErrors: false
    }
    FileView {
        id: statmFile
        path: `/proc/${root.pid}/statm`
        blockLoading: true
        printErrors: false
    }
    FileView {
        id: childrenFile
        path: `/proc/${root.pid}/task/${root.pid}/children`
        blockLoading: true
        printErrors: false
    }

    function sample() {
        statFile.reload();
        statmFile.reload();
        childrenFile.reload();
        const st = statFile.text();
        const f = st.slice(st.lastIndexOf(")") + 2).split(" ");
        // fields after "(comm) ": state=0 … utime=11 stime=12 (USER_HZ = 100)
        const ticks = parseInt(f[11]) + parseInt(f[12]);
        const now = Date.now();
        if (!isNaN(ticks)) {
            if (lastCpuTicks >= 0 && now > lastCpuAt) {
                cpu = Math.round((ticks - lastCpuTicks) / 100 / ((now - lastCpuAt) / 1000) * 1000) / 10;
                const h = cpuHistory.slice();
                h.push(cpu);
                if (h.length > windowS * 1000 / sampleMs)
                    h.shift();
                cpuHistory = h;
            }
            lastCpuTicks = ticks;
            lastCpuAt = now;
        }
        const pages = parseInt(statmFile.text().split(" ")[1]);
        if (!isNaN(pages))
            rssMB = Math.round(pages * 4096 / 1048576);
        childCount = childrenFile.text().trim().split(/\s+/).filter(s => s !== "").length;
        check();
    }
    Timer {
        interval: root.sampleMs
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.sample()
    }

    // ── Reloads (a generation counter that survives them) ────────────────
    PersistentProperties {
        id: persist
        reloadableId: "perf"
        property int generations: 0
        property real startedAt: 0
        property bool hinted: false
        property real loggedAt: 0
    }
    Connections {
        target: persist
        // After the reload stage (restored values are in): count this generation.
        function onLoaded() {
            persist.generations += 1;
            if (!persist.startedAt)
                persist.startedAt = Date.now();
        }
    }
    readonly property int reloads: Math.max(0, persist.generations - 1)

    // ── Leftover helpers ─────────────────────────────────────────────────
    // When Quickshell crashes it re-executes itself in the same process
    // ("Quickshell has been restarted"): the crashed image's helpers
    // (nmcli monitor, udisksctl monitor, inotifywait, `loft … --watch`) stay
    // its children, running next to the new ones, and turn into zombies
    // when they exit. Once the shell is up, end every child that is older
    // than this image (Quickshell.launchTime). (programs.loft's systemd unit
    // turns the in-place restart off instead, QS_DISABLE_CRASH_HANDLER, and
    // restarts the unit with a clean cgroup.)
    property int leftoversKilled: 0
    Process {
        id: leftovers
        command: ["sh", "-c", `
pid=$1; t0=$2
btime=$(awk '/^btime/ {print $2}' /proc/stat); hz=$(getconf CLK_TCK)
n=0
for k in $(cat /proc/$pid/task/$pid/children 2>/dev/null); do
  [ "$k" = "$$" ] && continue
  st=$(sed 's/.*) //' /proc/$k/stat 2>/dev/null | cut -d' ' -f20)
  [ -n "$st" ] || continue
  if [ $((btime + st / hz)) -lt $((t0 - 2)) ]; then kill -TERM "$k" 2>/dev/null && n=$((n + 1)); fi
done
echo $n`, "sh", String(root.pid), String(Math.floor(Quickshell.launchTime.getTime() / 1000))]
        stdout: StdioCollector {
            onStreamFinished: {
                const n = parseInt(text);
                if (n > 0) {
                    root.leftoversKilled = n;
                    console.warn(`loft perf: ended ${n} helper process(es) left over from before a crash restart`);
                }
            }
        }
    }
    Timer {
        interval: 4000
        running: true
        onTriggered: leftovers.running = true
    }

    // ── Trouble ──────────────────────────────────────────────────────────
    property int troubleSamples: 0
    property string culprit: ""
    readonly property bool troubled: troubleSamples >= windowS * 1000 / sampleMs

    function likelyCulprit(l) {
        const v = VideoWallpapers;
        if (v.playingCount > 0 && v.decodePath.indexOf("zero-copy") < 0)
            return `${v.playingCount} video wallpaper(s) playing, decoded as "${v.decodePath}" (frames may be copied through the CPU; try Settings → Wallpaper → Video wallpapers: Still frame)`;
        if (v.playingCount > 0)
            return `${v.playingCount} video wallpaper(s) playing`;
        if (l.p99 > 50)
            return "the GUI thread stalls (QML or rendering); `loft doctor perf` for details";
        return "high CPU without video wallpapers; `loft doctor perf` for details";
    }

    function check() {
        const l = lagStats();
        const bad = l.p99 > 50 || cpu > 60;
        troubleSamples = bad ? troubleSamples + 1 : 0;
        if (!troubled) {
            culprit = "";
            return;
        }
        culprit = likelyCulprit(l);
        const now = Date.now();
        if (now - persist.loggedAt > 10 * 60 * 1000) {
            persist.loggedAt = now;
            console.warn(`loft perf: shell slow for ${windowS}s+ (cpu ${cpu}%, lag p99 ${l.p99} ms, rss ${rssMB} MB); likely: ${culprit}`);
        }
        if (Settings.system.perfHint && !persist.hinted) {
            persist.hinted = true;
            hintProc.command = ["notify-send", "-a", "Loft", "-i", "dialog-warning", "The desktop shell is running slow", culprit + ".\nRun `loft doctor perf` for details."];
            hintProc.running = true;
        }
    }
    Process {
        id: hintProc
    }

    function status() {
        const v = VideoWallpapers;
        return {
            pid: pid,
            uptime: Math.round((Date.now() - persist.startedAt) / 1000),
            reloads: reloads,
            cpu: cpu,
            cpuAvg: cpuAvg,
            window: windowS,
            rssMB: rssMB,
            lag: lagStats(),
            videos: {
                loaded: v.loadedCount,
                playing: v.playingCount,
                decode: v.decodePath,
                held: v.globalReason,
                covered: v.covered,
                copies: Object.keys(v.variants).filter(k => v.variants[k] !== "").length,
                players: v.playerList
            },
            surfaces: WorkspaceWallpapers.keys.length,
            children: childCount,
            leftoversKilled: leftoversKilled,
            troubled: troubled,
            hints: culprit ? [culprit] : []
        };
    }

    IpcHandler {
        target: "perf"

        // {pid, uptime, reloads, cpu, cpuAvg, rssMB, lag{p50,p99,max,stalls}, videos{…}, surfaces, children, troubled, hints}
        function status(): string {
            return JSON.stringify(root.status());
        }
    }
}
