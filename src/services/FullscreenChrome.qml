pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The menu bar and the Dynamic Island in full screen, as on macOS: while a
// display shows a fullscreen window (Displays.fullscreenOn: niri's
// fullscreen, not maximized-to-edges) its bar and island slide away; the
// pointer resting at the very top edge of that display slides the bar back
// down over the app (Bar.qml: a 1 px input strip, a short dwell), with the
// island in it. It goes away again once the pointer leaves the bar, the
// island and any menu opened from it. Other displays are unaffected; the
// overview shows everything as usual.
//
// While the island is away, an incoming call and notification banners still
// drop down from the top edge; volume / brightness changes show in the pill
// at the bottom of the screen (Osd.qml) instead.
//
// Settings → Menu Bar: "Hide in full screen" (Settings.menubar
// .hideInFullscreen; off = the bar stays, drawn over the app on a solid
// strip), "Show when the pointer reaches the top" (.revealAtTop).
// Settings → Dynamic Island: "Hide in full screen" (Settings.island
// .hideInFullscreen).
//
// IPC `fullscreen status | reveal OUTPUT | conceal OUTPUT` (testing).
Singleton {
    id: root

    // Settings.menubar is a plain map (AppMenu.pref); absent = on.
    readonly property bool barHides: Settings.menubar.hideInFullscreen !== false
    readonly property bool revealAtTop: Settings.menubar.revealAtTop !== false
    readonly property bool islandHides: Settings.island.hideInFullscreen !== false

    // Output name → true while it shows a fullscreen window (overview closed).
    readonly property var fullscreen: {
        const out = {};
        if (Niri.overviewOpen)
            return out;
        for (const s of Quickshell.screens)
            if (Displays.fullscreenOn(s))
                out[s.name] = true;
        return out;
    }

    // Output name → true while the pointer has brought the bar back (Bar.qml).
    property var revealed: ({})
    // Output name → true while that output's island is hovered or open
    // (Island.qml): keeps a revealed bar down.
    property var islandBusy: ({})
    // Output name → true while a bar menu or the Control Center is open there
    // (Bar.qml, which sees MenuState): the bar and island stay, also when the
    // menu was opened from the keyboard (Mod+F10).
    property var menuOpen: ({})

    function fullscreenOn(name) {
        return fullscreen[name] === true;
    }
    function revealedOn(name) {
        return revealed[name] === true && fullscreenOn(name);
    }
    // The bar steps aside on this output (until revealed).
    function barHidesOn(name) {
        return barHides && fullscreenOn(name);
    }
    // The bar is away right now.
    function barConcealedOn(name) {
        return barHidesOn(name) && !revealedOn(name) && !menuOpenOn(name);
    }
    // The island is away right now (calls and banners still come down).
    function islandConcealedOn(name) {
        return islandHides && fullscreenOn(name) && !revealedOn(name) && !menuOpenOn(name);
    }
    function menuOpenOn(name) {
        return menuOpen[name] === true;
    }

    // name → bool maps, replaced (not mutated) so bindings see the change.
    function flagged(map, name, on) {
        if ((map[name] === true) === on)
            return map;
        const m = Object.assign({}, map);
        if (on)
            m[name] = true;
        else
            delete m[name];
        return m;
    }
    function setRevealed(name, on) {
        revealed = flagged(revealed, name, on);
    }
    function setIslandBusy(name, on) {
        islandBusy = flagged(islandBusy, name, on);
    }
    function setMenuOpen(name, on) {
        menuOpen = flagged(menuOpen, name, on);
    }

    // Leaving full screen forgets the reveal, so the next one starts hidden.
    onFullscreenChanged: {
        for (const name in revealed)
            if (!fullscreenOn(name))
                setRevealed(name, false);
    }

    IpcHandler {
        target: "fullscreen"

        function status(): string {
            return JSON.stringify({
                fullscreen: Object.keys(root.fullscreen),
                revealed: Object.keys(root.revealed),
                islandBusy: Object.keys(root.islandBusy),
                menuOpen: Object.keys(root.menuOpen),
                barConcealed: Quickshell.screens.filter(s => root.barConcealedOn(s.name)).map(s => s.name),
                islandConcealed: Quickshell.screens.filter(s => root.islandConcealedOn(s.name)).map(s => s.name),
                settings: {
                    barHides: root.barHides,
                    revealAtTop: root.revealAtTop,
                    islandHides: root.islandHides
                }
            });
        }
        function reveal(output: string): void {
            root.setRevealed(output, true);
        }
        function conceal(output: string): void {
            root.setRevealed(output, false);
        }
    }
}
