pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Downloads in progress, as a live activity in the island: `loft island
// downloads --watch` follows the download folder (inotify) for browsers'
// temp files (.crdownload, .part, …) and reports their size, speed and —
// when the browser's metadata says — the total. When one lands, a
// "Downloaded" banner offers Open / Show in Files and drags the file out.
Singleton {
    id: root

    readonly property bool enabled: Settings.island.downloads
    readonly property string folder: Settings.island.downloadsDir

    // [{ name, temp, path, size, total, progress?, speed, started }]
    property var active: []
    readonly property var primary: active.length ? active.slice().sort((a, b) => b.size - a.size)[0] : null
    property string watching: ""

    function uri(path) {
        return "file://" + path.split("/").map(encodeURIComponent).join("/");
    }

    function open(path) {
        Quickshell.execDetached(["xdg-open", path]);
    }

    function show(path) {
        Quickshell.execDetached(["loft", "dock", "show", path]);
    }

    // 1.2 MB, 340 KB
    function size(bytes) {
        const u = ["B", "KB", "MB", "GB", "TB"];
        let v = bytes, i = 0;
        while (v >= 1000 && i < u.length - 1) {
            v /= 1000;
            i++;
        }
        return `${v >= 100 || i === 0 ? Math.round(v) : v.toFixed(1)} ${u[i]}`;
    }

    // "3.4 MB of 12 MB · 2.1 MB/s" or "3.4 MB · 2.1 MB/s"
    function detail(d) {
        if (!d)
            return "";
        const amount = d.total ? `${size(d.size)} of ${size(d.total)}` : size(d.size);
        return d.speed > 0 ? `${amount} · ${size(d.speed)}/s` : amount;
    }

    function finished(f) {
        Notifications.show({
            appName: "Downloads",
            appIcon: "folder-download",
            summary: "Downloaded",
            body: `${f.name} · ${size(f.size)}`,
            image: "",
            glyph: "󰇚",
            glyphColor: Theme.accent,
            file: f.path,
            actions: [
                {
                    identifier: "default",
                    text: "Open",
                    invoke: () => root.open(f.path)
                },
                {
                    identifier: "show",
                    text: "Show in Files",
                    invoke: () => root.show(f.path)
                }
            ]
        });
    }

    Process {
        id: watcher
        running: root.enabled && !root.restarting
        command: ["loft", "island", "downloads", "--watch"].concat(root.folder !== "" ? [root.folder] : [])
        stdout: SplitParser {
            onRead: line => {
                let d;
                try {
                    d = JSON.parse(line);
                } catch (e) {
                    return;
                }
                root.watching = d.folder ?? "";
                root.active = d.active ?? [];
                for (const f of d.finished ?? [])
                    root.finished(f);
            }
        }
        onRunningChanged: if (!running)
            root.active = []
    }

    // The folder setting changed: restart the watcher on the new one.
    property bool restarting: false
    onFolderChanged: {
        restarting = true;
        restart.restart();
    }
    Timer {
        id: restart
        interval: 200
        onTriggered: root.restarting = false
    }

    IpcHandler {
        target: "downloads"

        function list(): string {
            return JSON.stringify(root.active.map(d => ({ name: d.name, size: d.size, total: d.total })));
        }
        // Exercise the banner without downloading anything.
        function test(): void {
            root.finished({ name: "sample.zip", path: "/tmp/sample.zip", size: 12345678 });
        }
    }
}
