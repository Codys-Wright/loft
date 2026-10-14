pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "urlclean.js" as UrlClean

// Clipboard history, backed by cliphist.
//
// While the `clipboard` module is on, the shell runs the recorder itself:
//   wl-paste --watch sh -c '… cliphist store …'
// (restarted if it dies). The watcher also reports every clipboard change to
// us, which drives auto-clear, Clean URL and live refresh of the panel.
// cliphist's db is the usual one (~/.cache/cliphist/db, or CLIPHIST_DB_PATH),
// so an existing cliphist setup shares the same history.
//
// Pins are copies of the content (text, or the image file) in
// <state>/clipboard/pins.json + pins/, so they survive `cliphist wipe`.
//
// Pasting = put the entry on the clipboard, then send Ctrl+V (Ctrl+Shift+V in
// terminals) with wtype. wtype types into whatever has keyboard focus — the
// app that was focused before the panel opened.
//
// IPC: clipboard toggle | open | close | pastePlain | clear | cleanUrl | wipe | settings
Singleton {
    id: root

    readonly property bool enabled: Features.on("clipboard")
    property bool panelOpen: false

    // Newest first: { id, text (one-line preview), image, format, size, width, height }
    property var entries: []
    property bool loading: false
    // id → decoded image file, filled by decodeImage().
    property var images: ({})
    // Full text of one entry, for the preview pane: { id, text }.
    property var detail: null
    // Last clipboard change (Date.now()), for whoever wants to react.
    property double lastChange: 0
    // Feedback line for the panel ("Copied", "Cleaned 3 parameters", …).
    property string toast: ""

    readonly property string cacheDir: `${Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"}/loft-clipboard/${Quickshell.env("WAYLAND_DISPLAY") || "wayland"}`
    readonly property string dataDir: `${Settings.stateDir}/clipboard`

    // Pinned items: { id, kind: "text" | "image", text, path, mime, added }.
    readonly property var pins: pinStore.value ?? []

    // ── jobs ───────────────────────────────────────────────────────────
    // run(argv, cb(stdout, exitCode)). Anything that runs wl-copy must send
    // its output to /dev/null: wl-copy forks a server that would hold our
    // stdout pipe open until the clipboard changes again.
    function run(command, cb) {
        const job = jobComponent.createObject(root, {
            command: command,
            callback: cb ?? null
        });
        job.running = true;
    }

    function sh(script, args, cb) {
        run(["sh", "-c", script, "sh"].concat(args ?? []), cb);
    }

    Component {
        id: jobComponent

        Process {
            id: job
            property var callback: null
            property bool exitDone: false
            property bool streamDone: false
            property int code: -1

            function finish() {
                if (!exitDone || !streamDone)
                    return;
                if (callback)
                    callback(out.text, code);
                destroy();
            }

            stdout: StdioCollector {
                id: out
                onStreamFinished: {
                    job.streamDone = true;
                    job.finish();
                }
            }
            onExited: exitCode => {
                code = exitCode;
                exitDone = true;
                finish();
            }
        }
    }

    // ── recorder / change watcher ──────────────────────────────────────
    // Prints CLIPBOARD_STATE (data | sensitive | clear | nil) per change.
    // A `clear` must not reach cliphist: it would delete the newest entry,
    // and auto-clear promises to keep the history.
    readonly property string watchScript: `
state="\${CLIPBOARD_STATE:-data}"
if [ "$state" = data ] && [ "$1" = 1 ]; then
  cliphist -max-items "$2" store
else
  cat >/dev/null
fi
echo "$state"`

    // The watcher must not outlive the shell. Reloads SIGKILL it (it's our
    // direct child: the sh execs into wl-paste); if the shell itself dies,
    // a helper sees our stdin pipe close and kills it, so a crashed or
    // restarted shell never leaves recorders behind.
    readonly property string superviseScript: `
p=$$
{ cat >/dev/null; kill $p; } <&0 >/dev/null 2>&1 &
exec wl-paste --watch sh -c "$1" sh "$2" "$3" </dev/null`

    function startWatcher() {
        watcher.command = ["sh", "-c", superviseScript, "sh", watchScript, ClipboardConfig.history.record ? "1" : "0", String(ClipboardConfig.history.maxItems)];
        watcher.running = true;
    }

    function restartWatcher() {
        if (watcher.running)
            watcher.signal(15); // onExited restarts it with the new command
        else if (enabled)
            startWatcher();
    }

    onEnabledChanged: {
        if (enabled)
            startWatcher();
        else if (watcher.running)
            watcher.signal(15);
    }
    Component.onCompleted: {
        Quickshell.execDetached(["mkdir", "-p", cacheDir, `${dataDir}/pins`]);
        if (enabled)
            startWatcher();
    }

    Connections {
        target: ClipboardConfig.history
        function onRecordChanged() {
            root.restartWatcher();
        }
        function onMaxItemsChanged() {
            root.restartWatcher();
        }
    }

    Process {
        id: watcher
        stdinEnabled: true
        stdout: SplitParser {
            onRead: line => root.changed(line.trim())
        }
        onExited: if (root.enabled)
            restartTimer.start()
    }

    Timer {
        id: restartTimer
        interval: 1000
        onTriggered: if (root.enabled && !watcher.running)
            root.startWatcher()
    }

    function changed(state) {
        if (state !== "data" && state !== "sensitive")
            return;
        lastChange = Date.now();
        if (ClipboardConfig.autoClear.minutes > 0)
            autoClear.restart();
        if (state === "data" && ClipboardConfig.cleanUrls)
            cleanCurrent(true);
        if (panelOpen)
            refreshSoon.restart();
    }

    // ── auto-clear ─────────────────────────────────────────────────────
    Timer {
        id: autoClear
        interval: Math.max(1, ClipboardConfig.autoClear.minutes) * 60000
        onTriggered: if (root.enabled && ClipboardConfig.autoClear.minutes > 0)
            root.clear()
    }

    Connections {
        target: LockState
        function onLockedChanged() {
            if (LockState.locked && root.enabled && ClipboardConfig.autoClear.onLock)
                root.clear();
        }
    }

    // Empty the system clipboard (and the primary selection); history stays.
    function clear() {
        autoClear.stop();
        sh("wl-copy --clear >/dev/null 2>&1; wl-copy --primary --clear >/dev/null 2>&1; true");
    }

    // ── history ────────────────────────────────────────────────────────
    Timer {
        id: refreshSoon
        interval: 150
        onTriggered: root.refresh()
    }

    onPanelOpenChanged: if (panelOpen)
        refresh()

    function parseLine(line) {
        const tab = line.indexOf("\t");
        if (tab < 0)
            return null;
        const id = line.slice(0, tab);
        const text = line.slice(tab + 1);
        const m = /^\[\[ binary data (.+?) (\w+) (\d+)x(\d+) \]\]$/.exec(text);
        return m ? {
            id: id,
            text: `Image · ${m[3]}×${m[4]} · ${m[2].toUpperCase()} · ${m[1]}`,
            image: true,
            format: m[2],
            size: m[1],
            width: parseInt(m[3]),
            height: parseInt(m[4])
        } : {
            id: id,
            text: text,
            image: false
        };
    }

    function refresh() {
        loading = true;
        run(["cliphist", "-preview-width", "400", "list"], (out, code) => {
            loading = false;
            entries = out.split("\n").map(parseLine).filter(e => e !== null);
        });
    }

    // Decode an image entry into the cache dir; images[id] = its path.
    function decodeImage(entry) {
        if (!entry?.image || images[entry.id] !== undefined)
            return;
        const path = `${cacheDir}/${entry.id}.${entry.format}`;
        const m = Object.assign({}, images);
        m[entry.id] = "";
        images = m;
        sh('mkdir -p "$(dirname "$2")" && cliphist decode "$1" > "$2"', [entry.id, path], (out, code) => {
            const n = Object.assign({}, images);
            n[entry.id] = code === 0 ? path : "";
            images = n;
        });
    }

    function loadDetail(entry) {
        if (!entry || entry.image) {
            detail = null;
            return;
        }
        if (detail?.id === entry.id)
            return;
        const id = entry.id;
        run(["cliphist", "decode", id], (out, code) => {
            if (code === 0)
                detail = {
                    id: id,
                    text: out
                };
        });
    }

    function mimeOf(entry) {
        return entry.image ? `image/${entry.format === "jpeg" ? "jpeg" : entry.format}` : "text/plain;charset=utf-8";
    }

    // Put a history entry back on the clipboard; then(ok).
    function copy(entry, then) {
        sh('cliphist decode "$1" | wl-copy --type "$2" >/dev/null 2>&1', [entry.id, mimeOf(entry)], (out, code) => {
            if (then)
                then(code === 0);
        });
    }

    function copyText(text, then) {
        run(["sh", "-c", 'printf %s "$1" | wl-copy --type "text/plain;charset=utf-8" >/dev/null 2>&1', "sh", text], (out, code) => {
            if (then)
                then(code === 0);
        });
    }

    function remove(entry) {
        sh('printf "%s\\n" "$1" | cliphist delete', [entry.id], () => refresh());
        entries = entries.filter(e => e.id !== entry.id);
    }

    function wipe() {
        run(["cliphist", "wipe"], () => {
            sh('rm -f "$1"/*', [cacheDir]);
            images = {};
            refresh();
        });
    }

    // ── paste ──────────────────────────────────────────────────────────
    // Send the paste shortcut to the focused app (after our panel has given
    // the keyboard back).
    function sendPaste() {
        pasteDelay.restart();
    }

    Timer {
        id: pasteDelay
        interval: 180
        onTriggered: {
            const app = Niri.focusedWindow?.app_id ?? "";
            let terminal = false;
            try {
                terminal = new RegExp(ClipboardConfig.paste.terminals).test(app);
            } catch (e) {}
            Quickshell.execDetached(terminal ? ["wtype", "-M", "ctrl", "-M", "shift", "-k", "v", "-m", "shift", "-m", "ctrl"] : ["wtype", "-M", "ctrl", "-k", "v", "-m", "ctrl"]);
        }
    }

    function paste(entry) {
        panelOpen = false;
        copy(entry, ok => ok && sendPaste());
    }

    // Paste as plain text: the clipboard's text, re-copied as text/plain
    // only (formatting dropped), then pasted.
    function pastePlain() {
        panelOpen = false;
        sh('f="$1/plain"; mkdir -p "$1" && wl-paste --no-newline --type text > "$f" && wl-copy --type "text/plain;charset=utf-8" < "$f" >/dev/null 2>&1; s=$?; rm -f "$f"; exit $s', [cacheDir], (out, code) => {
            if (code === 0)
                sendPaste();
        });
    }

    // ── Clean URL ──────────────────────────────────────────────────────
    function cleanUrl(text) {
        return UrlClean.clean(text);
    }

    function isTrackedUrl(text) {
        return UrlClean.isTracked(text);
    }

    // Clean the URL on the clipboard. From the watcher (auto): also drop the
    // tracked original from history, so only the clean link is kept.
    function cleanCurrent(auto) {
        run(["wl-paste", "--no-newline", "--type", "text"], (out, code) => {
            if (code !== 0 || !UrlClean.isUrl(out))
                return;
            const cleaned = UrlClean.clean(out);
            if (cleaned === out)
                return;
            copyText(cleaned.trim(), () => {
                if (auto)
                    run(["cliphist", "delete-query", out]);
                toast = "Cleaned link";
            });
        });
    }

    // The panel's "Clean link" on a history entry: copies the cleaned URL.
    function cleanEntry(entry) {
        run(["cliphist", "decode", entry.id], (out, code) => {
            if (code !== 0)
                return;
            const cleaned = UrlClean.clean(out);
            if (cleaned === out) {
                toast = "No tracking parameters";
                return;
            }
            copyText(cleaned.trim(), () => {
                toast = "Copied clean link";
                refreshSoon.restart();
            });
        });
    }

    // ── pins ───────────────────────────────────────────────────────────
    JsonStore {
        id: pinStore
        path: `${root.dataDir}/pins.json`
        fallback: []
    }

    function uid() {
        return Date.now().toString(36) + Math.floor(Math.random() * 1e6).toString(36);
    }

    function isPinnedText(text) {
        return pins.some(p => p.kind === "text" && p.text === text);
    }

    function pin(entry) {
        const id = uid();
        if (entry.image) {
            const path = `${dataDir}/pins/${id}.${entry.format}`;
            sh('mkdir -p "$(dirname "$2")" && cliphist decode "$1" > "$2"', [entry.id, path], (out, code) => {
                if (code !== 0)
                    return;
                pinStore.save([{
                        id: id,
                        kind: "image",
                        path: path,
                        mime: mimeOf(entry),
                        label: entry.text,
                        added: Date.now()
                    }].concat(pins));
                toast = "Pinned";
            });
            return;
        }
        run(["cliphist", "decode", entry.id], (out, code) => {
            if (code !== 0 || isPinnedText(out))
                return;
            pinStore.save([{
                    id: id,
                    kind: "text",
                    text: out,
                    added: Date.now()
                }].concat(pins));
            toast = "Pinned";
        });
    }

    function unpin(p) {
        pinStore.save(pins.filter(x => x.id !== p.id));
        if (p.kind === "image")
            run(["rm", "-f", p.path]);
    }

    function movePin(p, delta) {
        const l = Array.from(pins);
        const i = l.findIndex(x => x.id === p.id);
        const j = i + delta;
        if (i < 0 || j < 0 || j >= l.length)
            return;
        l.splice(j, 0, l.splice(i, 1)[0]);
        pinStore.save(l);
    }

    function copyPin(p, then) {
        if (p.kind === "image")
            sh('wl-copy --type "$2" < "$1" >/dev/null 2>&1', [p.path, p.mime], (out, code) => then && then(code === 0));
        else
            copyText(p.text, then);
    }

    function pastePin(p) {
        panelOpen = false;
        copyPin(p, ok => ok && sendPaste());
    }

    IpcHandler {
        target: "clipboard"

        function toggle(): void {
            root.panelOpen = root.enabled && !root.panelOpen;
        }
        function open(): void {
            root.panelOpen = root.enabled;
        }
        function close(): void {
            root.panelOpen = false;
        }
        function pastePlain(): void {
            // The ⌘⇧⌥V bind: types into the app, so not into one left alone.
            if (!Shortcuts.skip("Paste as Plain Text"))
                root.pastePlain();
        }
        function clear(): void {
            root.clear();
        }
        function cleanUrl(): void {
            root.cleanCurrent(false);
        }
        function wipe(): void {
            root.wipe();
        }
        // Settings → Clipboard & Files.
        function settings(): void {
            Panels.settingsSection = "clipboard";
            Panels.settingsOpen = true;
        }
        // For tests: the newest entries, one per line.
        function list(): string {
            return root.entries.slice(0, 20).map(e => `${e.id}\t${e.text}`).join("\n");
        }
        function refresh(): void {
            root.refresh();
        }
        // For tests: recorder and auto-clear state.
        function status(): string {
            return JSON.stringify({
                recording: watcher.running,
                locked: LockState.locked,
                autoClearMinutes: ClipboardConfig.autoClear.minutes,
                clearOnLock: ClipboardConfig.autoClear.onLock,
                autoClearPending: autoClear.running,
                cleanUrls: ClipboardConfig.cleanUrls,
                pins: root.pins.length
            });
        }
    }
}
