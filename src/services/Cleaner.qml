pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Cleaner (Utilities → Cleaner): reclaimable space from `loft clean scan`
// (cli/loft/cleaner.py) — user caches, Trash, Loft's cache, messaging
// download folders with a retention rule, Nix generations — and the slow,
// read-only Nix store scan (`loft clean store`: a --print-dead dry run,
// cached). Clearing deletes only cache contents you picked (after a
// confirm); expired messaging downloads go to the Trash. Garbage collection
// is never run here: the page shows the commands (sudo for the system).
Singleton {
    id: root

    readonly property bool active: Utilities.open && Utilities.section === "cleaner"

    property var scan: null
    property bool scanning: false
    property bool storeScanning: false
    property string storeStage: ""
    property var selected: ({}) // id → true
    property string notice: ""
    property var lastClear: null
    // { ids, bytes, label } waiting for the confirm sheet.
    property var confirming: null
    property bool clearing: false

    readonly property var caches: scan?.caches ?? []
    readonly property var selectedIds: Object.keys(selected).filter(k => selected[k])
    readonly property real selectedBytes: caches.filter(c => selected[c.id]).reduce((a, c) => a + c.bytes, 0)

    onActiveChanged: if (active && scan === null)
        rescan()

    function rescan() {
        if (scanning)
            return;
        scanning = true;
        scanner.running = true;
    }

    Process {
        id: scanner
        command: ["loft", "clean", "scan"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.scan = JSON.parse(text);
                    // Drop selections whose rows went away.
                    const ids = new Set(root.caches.map(c => c.id));
                    const s = {};
                    for (const k of Object.keys(root.selected))
                        if (ids.has(k) && root.selected[k])
                            s[k] = true;
                    root.selected = s;
                } catch (e) {
                    root.notice = "Couldn't scan.";
                }
                root.scanning = false;
            }
        }
    }

    function toggle(id) {
        const s = Object.assign({}, selected);
        s[id] = !s[id];
        selected = s;
    }

    function selectGroup(group, on) {
        const s = Object.assign({}, selected);
        for (const c of caches)
            if (c.group === group && c.group !== "Keep")
                s[c.id] = on;
        selected = s;
    }

    // toTrash: the items move to the Trash (messaging downloads) instead of being deleted.
    function askClear(ids, label, bytes, toTrash) {
        confirming = {
            ids: ids,
            label: label,
            bytes: bytes,
            toTrash: toTrash === true
        };
    }

    function clear() {
        if (!confirming)
            return;
        clearing = true;
        clearer.command = ["loft", "clean", "clear"].concat(confirming.ids).concat(["--yes"]);
        clearer.running = true;
    }

    Process {
        id: clearer
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const r = JSON.parse(text);
                    root.lastClear = r;
                    const errs = r.results.filter(x => x.error);
                    const failed = r.results.reduce((a, x) => a + (x.failed ?? 0), 0);
                    root.notice = `Freed ${root.formatBytes(r.bytes)}` + (failed ? ` · ${failed} item${failed === 1 ? "" : "s"} in use, skipped` : "") + (errs.length ? ` · ${errs.map(e => e.error).join(", ")}` : "");
                } catch (e) {
                    root.notice = "Clearing failed.";
                }
                root.clearing = false;
                root.confirming = null;
                root.selected = ({});
                root.rescan();
            }
        }
    }

    // ── Nix store (slow) ────────────────────────────────────────────────
    function scanStore() {
        if (storeScanning)
            return;
        storeScanning = true;
        storeStage = "starting";
        storeProc.running = true;
    }

    Process {
        id: storeProc
        command: ["loft", "clean", "store"]
        stdout: SplitParser {
            onRead: line => {
                try {
                    const m = JSON.parse(line);
                    if (m.stage)
                        root.storeStage = m.stage + (m.dead ? ` (${m.dead} paths)` : "");
                } catch (e) {}
            }
        }
        onExited: {
            root.storeScanning = false;
            root.storeStage = "";
            root.rescan();
        }
    }

    // ── Retention + schedule ────────────────────────────────────────────
    function setRetention(path, days) {
        run(["loft", "clean", "retention", "set", path, String(days)]);
    }

    function removeRetention(path) {
        run(["loft", "clean", "retention", "remove", path]);
    }

    // { every, olderThanDays, categories, trashDays, retention } or null (off).
    function setSchedule(s) {
        if (s === null) {
            run(["loft", "clean", "schedule", "off"]);
            return;
        }
        const argv = ["loft", "clean", "schedule", "set", "--every", s.every, "--older-than", String(s.olderThanDays), "--categories", (s.categories ?? []).join(",")];
        if (s.trashDays)
            argv.push("--trash-days", String(s.trashDays));
        if (s.retention)
            argv.push("--retention");
        run(argv);
    }

    function run(argv) {
        cmd.command = argv;
        cmd.running = true;
    }

    Process {
        id: cmd
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const r = JSON.parse(text);
                    if (r.systemctl)
                        root.notice = r.systemctl.join(" · ");
                } catch (e) {}
                root.rescan();
            }
        }
    }

    function copy(text) {
        Quickshell.execDetached(["sh", "-c", 'printf %s "$1" | wl-copy >/dev/null 2>&1', "sh", text]);
        notice = "Copied — paste it in a terminal.";
    }

    function formatBytes(b) {
        if (b === undefined || b === null)
            return "—";
        const u = ["B", "KB", "MB", "GB", "TB"];
        let i = 0;
        let v = b;
        while (v >= 1000 && i < u.length - 1) {
            v /= 1000;
            i++;
        }
        return `${v >= 100 || i === 0 ? Math.round(v) : v.toFixed(1)} ${u[i]}`;
    }
}
