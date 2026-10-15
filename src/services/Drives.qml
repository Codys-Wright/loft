pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Drives: external drives you can eject (macOS: the ⏏ next to a USB stick).
// Only removable / hot-plugged / USB / FireWire / SD / optical disks with a
// mounted filesystem, and never a disk that carries a system mount (/, /nix,
// /boot, /home, …): fixed internal data drives mounted under /run/media are
// left alone even though they look like "volumes".
//
//   list = [{ id, disk, kind, name, size, model, mounts: [{ dev, mount }],
//             locks: [crypt parents to lock after unmounting] }]
//
// Eject = udisksctl unmount every mounted filesystem on the disk (lock an
// unlocked LUKS container), then power the disk off (optical: `eject`).
// LOFT_EJECT_DRYRUN=<file> (named loft-dev sessions) logs every command
// there instead of running it. The list is re-read on udisks changes
// (`udisksctl monitor`) and written to <state>/drives.json for Spotlight's
// "Eject <name>" commands (launcher/elephant-commands).
//
// IPC: drives list | refresh | eject ID | ejectAll
Singleton {
    id: root

    property var list: []
    readonly property int count: list.length
    // Disk ids being ejected right now.
    property var busy: []
    readonly property string dryRun: Quickshell.env("LOFT_EJECT_DRYRUN") || ""
    readonly property string stateDir: Quickshell.env("LOFT_STATE_DIR") || `${Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state"}/loft`

    readonly property var systemMounts: ["/", "/nix", "/nix/store", "/boot", "/boot/efi", "/efi", "/home", "/persist", "/usr", "/var", "/etc", "/.swapvol", "[SWAP]"]
    readonly property var externalTransports: ["usb", "ieee1394", "mmc", "sdio"]

    function refresh() {
        if (lsblk.running)
            again = true;
        else
            lsblk.running = true;
    }
    property bool again: false

    function find(id) {
        return list.find(d => d.id === id || d.disk === id || d.name === id) ?? null;
    }

    function isSystemMount(m) {
        return systemMounts.includes(m) || m.startsWith("/nix/") || m.startsWith("/var/") || m.startsWith("/boot/") || m.startsWith("/usr/");
    }

    // lsblk's tree → the ejectable drives.
    function parse(json) {
        const out = [];
        const mountsOf = n => (n.mountpoints ?? (n.mountpoint ? [n.mountpoint] : [])).filter(m => m);
        for (const d of json.blockdevices ?? []) {
            if (d.type !== "disk" && d.type !== "rom")
                continue;
            const external = d.rm === true || d.rm === "1" || d.hotplug === true || d.hotplug === "1" || externalTransports.includes(d.tran ?? "") || d.type === "rom";
            if (!external)
                continue;
            const mounts = [];
            const locks = [];
            let system = false;
            let label = "";
            const walk = (n, parent) => {
                const ms = mountsOf(n);
                if (ms.some(m => isSystemMount(m)))
                    system = true;
                if (ms.length > 0) {
                    mounts.push({ dev: n.path, mount: ms[0] });
                    if (!label && n.label)
                        label = n.label;
                    if (n.type === "crypt" && parent && !locks.includes(parent.path))
                        locks.push(parent.path);
                }
                for (const c of n.children ?? [])
                    walk(c, n);
            };
            walk(d, null);
            if (system || mounts.length === 0)
                continue;
            const model = [d.vendor, d.model].filter(s => s && s.trim()).map(s => s.trim()).join(" ");
            out.push({
                id: d.name,
                disk: d.path,
                kind: d.type === "rom" ? "rom" : "disk",
                name: label || model || d.name,
                size: d.size ?? "",
                model: model,
                tran: d.tran ?? "",
                mounts: mounts,
                locks: locks
            });
        }
        return out;
    }

    Process {
        id: lsblk
        command: ["lsblk", "-J", "-o", "NAME,PATH,TYPE,RM,HOTPLUG,TRAN,SIZE,FSTYPE,LABEL,MODEL,VENDOR,MOUNTPOINTS"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const l = root.parse(JSON.parse(text));
                    if (JSON.stringify(l) !== JSON.stringify(root.list))
                        root.list = l;
                } catch (e) {
                    console.warn(`Drives: lsblk: ${e}`);
                }
                root.writeSpotlight();
            }
        }
        onExited: if (root.again) {
            root.again = false;
            running = true;
        }
    }

    // Spotlight reads this for its Eject commands.
    function writeSpotlight() {
        spotlightFile.setText(JSON.stringify({ drives: list.map(d => ({ id: d.id, name: d.name, size: d.size, kind: d.kind })) }));
    }
    FileView {
        id: spotlightFile
        path: `${root.stateDir}/drives.json`
        printErrors: false
    }

    // udisks tells us about every change; a burst becomes one re-read.
    Process {
        id: monitor
        running: true
        command: ["udisksctl", "monitor"]
        stdout: SplitParser {
            onRead: _ => debounce.restart()
        }
        onExited: retry.start()
    }
    Timer {
        id: retry
        interval: 30000
        onTriggered: monitor.running = true
    }
    Timer {
        id: debounce
        interval: 600
        onTriggered: root.refresh()
    }
    Component.onCompleted: refresh()

    // ── Eject ────────────────────────────────────────────────────────────
    // $1 disk, $2 kind (disk|rom), then the filesystems to unmount, then
    // "--lock" and the LUKS containers to lock. Exit 2 = a filesystem is in
    // use (nothing powered off). A failed power-off (some card readers) still
    // leaves everything unmounted: safe to remove, exit 0 with a note.
    readonly property string script: `
run() { if [ -n "$LOFT_EJECT_DRYRUN" ]; then printf '%s\\n' "$*" >> "$LOFT_EJECT_DRYRUN"; else "$@"; fi; }
disk=$1; kind=$2; shift 2; lock=
for a in "$@"; do
  if [ "$a" = --lock ]; then lock=1; continue; fi
  if [ -n "$lock" ]; then run udisksctl lock -b "$a" --no-user-interaction || exit 3
  else run udisksctl unmount -b "$a" --no-user-interaction || exit 2; fi
done
if [ "$kind" = rom ]; then run eject "$disk" || echo "power-off failed" >&2
else run udisksctl power-off -b "$disk" --no-user-interaction || echo "power-off failed" >&2; fi
exit 0`

    function eject(id) {
        const d = find(id);
        if (!d || busy.includes(d.id))
            return false;
        busy = busy.concat([d.id]);
        const args = [d.disk, d.kind].concat(d.mounts.map(m => m.dev));
        if (d.locks.length > 0)
            args.push("--lock", ...d.locks);
        const p = ejectProc.createObject(root, { drive: d, command: ["sh", "-c", script, "eject"].concat(args) });
        p.running = true;
        return true;
    }

    function ejectAll() {
        for (const d of list.slice())
            eject(d.id);
    }

    signal ejected(var drive, bool ok, string message)

    Component {
        id: ejectProc
        Process {
            id: proc
            property var drive
            stderr: StdioCollector {
                id: err
            }
            onExited: code => {
                const d = proc.drive;
                root.busy = root.busy.filter(x => x !== d.id);
                const msg = code === 0 ? `“${d.name}” can be removed${root.dryRun ? " (dry run)" : ""}` : code === 2 ? `“${d.name}” is in use and wasn't ejected` : `Couldn't eject “${d.name}”`;
                if (code !== 0)
                    console.warn(`Drives: eject ${d.disk}: ${code} ${err.text.trim()}`);
                Hud.say(code === 0 ? "\u{F01EA}" : "\u{F0026}", msg);
                root.ejected(d, code === 0, msg);
                // Dry run: nothing really changed, so pretend it did.
                if (code === 0 && root.dryRun) {
                    root.list = root.list.filter(x => x.id !== d.id);
                    root.writeSpotlight();
                } else
                    root.refresh();
                proc.destroy();
            }
        }
    }

    IpcHandler {
        target: "drives"

        function list(): string {
            return JSON.stringify(root.list);
        }
        function refresh(): void {
            root.refresh();
        }
        function eject(id: string): bool {
            return root.eject(id);
        }
        function ejectAll(): void {
            root.ejectAll();
        }
    }
}
