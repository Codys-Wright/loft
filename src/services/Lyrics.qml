pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris

// Synced lyrics for the playing track (opt-in: Settings → Dynamic Island →
// Lyrics). `loft island lyrics` asks lrclib.net — that sends the artist,
// title, album and length there — and caches the answer. The current line
// follows the player's position.
Singleton {
    id: root

    readonly property bool enabled: Settings.island.lyrics
    readonly property var player: Mpris.players.values.find(p => p.isPlaying) ?? Mpris.players.values[0] ?? null
    readonly property string key: player ? `${player.trackArtist}\u0001${player.trackTitle}` : ""

    // [[ms, line], …]
    property var lines: []
    property string loadedKey: ""
    property real position: 0 // ms
    readonly property int index: {
        let i = -1;
        for (let k = 0; k < lines.length; k++) {
            if (lines[k][0] <= position + 300)
                i = k;
            else
                break;
        }
        return i;
    }
    readonly property string current: index >= 0 ? lines[index][1] : ""
    readonly property string upcoming: index + 1 < lines.length ? lines[index + 1][1] : ""
    readonly property bool has: enabled && lines.length > 0 && loadedKey === key

    onKeyChanged: fetch()
    onEnabledChanged: fetch()

    function fetch() {
        lines = [];
        if (!enabled || !player || !player.trackTitle)
            return;
        loadedKey = "";
        proc.want = key;
        proc.next = ["loft", "island", "lyrics", "--json", "--artist", player.trackArtist || "", "--title", player.trackTitle, "--album", player.trackAlbum || "", "--duration", String(Math.round(player.length || 0))];
        if (proc.running)
            proc.again = true;
        else
            proc.running = true;
    }

    // MPRIS doesn't push the position: poll it while lyrics are up.
    Timer {
        interval: 250
        repeat: true
        running: root.has && (root.player?.isPlaying ?? false)
        onTriggered: {
            root.player.positionChanged();
            root.position = root.player.position * 1000;
        }
    }

    Process {
        id: proc
        property string want: ""
        property var next: []
        property bool again: false
        command: next
        onExited: if (again) {
            again = false;
            running = true;
        }
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const d = JSON.parse(text);
                    if (proc.want === root.key) {
                        root.lines = d.synced ?? [];
                        root.loadedKey = root.key;
                    }
                } catch (e) {}
            }
        }
    }
}
