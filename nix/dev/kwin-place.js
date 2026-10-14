// KWin script (Plasma 6): put the nested niri window fullscreen and
// borderless on one output, so the dev session behaves like a real monitor.
// The output name and niri's PID are substituted in by studio-dev. The script handles the
// window whether it is already mapped or appears shortly after.
const target = workspace.screens.find(s => s.name === "@OUTPUT@");

// Only the niri this studio-dev started (@PID@): other nested niri windows
// (e.g. test sessions) are left alone.
function place(w) {
    if (!w || w.pid !== @PID@) return;
    if (!target) { print("studio-dev: no output @OUTPUT@"); return; }
    w.noBorder = true;
    workspace.sendClientToScreen(w, target);
    w.fullScreen = true;
    print(`studio-dev: placed "${w.caption}" on ${target.name}`);
}

workspace.windowList().forEach(place);
workspace.windowAdded.connect(place);
