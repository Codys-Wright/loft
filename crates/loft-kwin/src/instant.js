// loft_instant: a KWin effect (installed and loaded by loft-kwin while Loft's
// shell runs; docs/KWIN.md §4.22). Spotlight (walker) and the shell's own
// layer surfaces (menus, Control Center, OSD, switcher …) appear and go at
// once, as under niri: KWin types a layer surface by its namespace, and
// "walker" and "loft:…" are no type KWin knows, so they are normal windows,
// which Scale, Glide and Fade animate. This effect grabs them on open and on
// close (WindowAddedGrabRole / WindowClosedGrabRole), KWin's way of telling
// the other effects to leave a window alone: they skip it, or cancel what
// they started when the grab lands after them. App windows are untouched,
// so the effects picked in Settings → Layout & Motion still run for them.
"use strict";

// The executables of Loft's surfaces (KWin's window class is the client's
// executable name, twice, for a Wayland window).
const CLASSES = ["walker", ".walker-wrapped", "quickshell", ".quickshell-wrapped", "qs", ".qs-wrapped"];

function isLoftSurface(w) {
    const exe = String(w.windowClass || "").split(" ")[0];
    if (CLASSES.indexOf(exe) < 0) {
        return false;
    }
    // Layer surfaces only: they can't be moved and skip the switcher. The
    // shell's app windows (Settings, the clipboard scratchpad …) are
    // toplevels and keep their open and close animations.
    return !w.moveable && w.skipSwitcher;
}

effects.windowAdded.connect(function (w) {
    if (isLoftSurface(w)) {
        effect.grab(w, Effect.WindowAddedGrabRole, true);
    }
});

effects.windowClosed.connect(function (w) {
    if (isLoftSurface(w)) {
        effect.grab(w, Effect.WindowClosedGrabRole, true);
    }
});
