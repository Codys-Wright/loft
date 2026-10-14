// KWin script (Plasma 6): put the nested niri window fullscreen and
// borderless on one output, so the dev session behaves like a real monitor.
// The output name is substituted in by studio-dev. The script handles the
// window whether it is already mapped or appears shortly after.
const target = workspace.screens.find(s => s.name === "@OUTPUT@");

function place(w) {
    if (!w || (w.resourceClass !== "niri" && !w.caption.startsWith("niri"))) return;
    if (!target) { print("studio-dev: no output @OUTPUT@"); return; }
    w.noBorder = true;
    workspace.sendClientToScreen(w, target);
    w.fullScreen = true;
    print(`studio-dev: placed "${w.caption}" on ${target.name}`);
}

workspace.windowList().forEach(place);
workspace.windowAdded.connect(place);
