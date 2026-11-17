pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Keyboard repeat under KWin, for Settings → Keyboard & Mouse: KDE keeps it
// in kcminputrc [Keyboard] (RepeatDelay ms, RepeatRate per second), and KWin
// applies a change as soon as it's written with --notify. niri's values come
// from NiriSettings instead; this is only read under KWin.
Singleton {
    id: root

    readonly property bool wanted: Compositor.backend === "kwin"
    property int repeatDelay: 600
    property int repeatRate: 25
    property bool loaded: false

    function setRepeat(delay, rate) {
        repeatDelay = delay;
        repeatRate = rate;
        writer.command = ["sh", "-c", 'kwriteconfig6 --notify --file kcminputrc --group Keyboard --key KeyRepeat repeat'
            + ' && kwriteconfig6 --notify --file kcminputrc --group Keyboard --key RepeatDelay "$1"'
            + ' && kwriteconfig6 --notify --file kcminputrc --group Keyboard --key RepeatRate "$2"', "sh", String(delay), String(rate)];
        writer.running = true;
    }

    function reload() {
        if (wanted)
            reader.running = true;
    }

    Component.onCompleted: reload()

    Process {
        id: reader
        // KDE's defaults when kcminputrc says nothing: 600 ms, 25/s.
        command: ["sh", "-c", 'echo "$(kreadconfig6 --file kcminputrc --group Keyboard --key RepeatDelay --default 600) '
            + '$(kreadconfig6 --file kcminputrc --group Keyboard --key RepeatRate --default 25)"']
        stdout: StdioCollector {
            onStreamFinished: {
                const [d, r] = text.trim().split(/\s+/).map(Number);
                if (d > 0)
                    root.repeatDelay = Math.round(d);
                if (r > 0)
                    root.repeatRate = Math.round(r);
                root.loaded = true;
            }
        }
    }

    Process {
        id: writer
        onExited: code => {
            if (code !== 0)
                console.warn(`KdeInput: kwriteconfig6 failed (${code})`);
        }
    }
}
