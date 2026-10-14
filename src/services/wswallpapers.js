.pragma library

// Which per-workspace wallpaper surfaces should exist (WorkspaceWallpapers.qml);
// tested by tests/wswallpapers.test.js.
//
// workspaces: niri's [{ output, idx, name, is_active }]; screens: output names.
// opts: { overview: bool, zoom: overview zoom (0..1], all: bool (every
// workspace, for measurements), live: the current plan's entries (an entry
// keeps its full-size decode while it stays) }.
// Returns { "<screen>|<ref>": { screen, ref, scale } }.

// A workspace's reference in the layer namespace: its name, else its 1-based
// index on its output (niri reads a number as an index).
function refOf(ws) {
    return ws.name ? ws.name : String(ws.idx);
}

function keyOf(screen, ref) {
    return `${screen}|${ref}`;
}

// Workspaces the overview shows on each side of the active one: workspace d
// sits d × zoom × height from the center, and shows while its near edge is
// inside the screen: d × zoom < 1/2 + zoom/2 (gaps only shrink this).
function overviewRadius(zoom) {
    const z = zoom > 0 && zoom <= 1 ? zoom : 0.5;
    return Math.max(1, Math.ceil(0.5 / z + 0.5) - 1);
}

function plan(workspaces, screens, opts) {
    const o = opts || {};
    const zoom = o.zoom > 0 && o.zoom <= 1 ? o.zoom : 0.5;
    const live = o.live || {};
    const out = {};
    for (const screen of screens) {
        const list = workspaces.filter(w => w.output === screen).sort((a, b) => a.idx - b.idx);
        const at = list.findIndex(w => w.is_active);
        if (at < 0)
            continue;
        // Normal view: the active one and a neighbor each way (a switch or a
        // swipe slides one in). Overview: what its zoom shows, plus one more
        // each way for the next scroll.
        const r = o.overview ? overviewRadius(zoom) + 1 : 1;
        list.forEach((w, i) => {
            const d = Math.abs(i - at);
            if (!o.all && d > r)
                return;
            const ref = refOf(w);
            const key = keyOf(screen, ref);
            const had = live[key];
            // Full size for what a switch can show; the overview's zoom for
            // what only the overview shows (unless it is already full size).
            const full = o.all || d <= 1 || (had && !had.until && had.scale === 1);
            out[key] = { screen, ref, scale: full ? 1 : zoom };
        });
    }
    return out;
}

// The next live map: wanted entries (until 0) plus ones kept for `grace` ms
// after they stopped being wanted. { live, changed, pending }.
function step(live, wanted, now, grace) {
    const next = {};
    let changed = false;
    for (const [key, w] of Object.entries(wanted)) {
        const had = live[key];
        next[key] = { screen: w.screen, ref: w.ref, scale: w.scale, until: 0 };
        if (!had || had.until !== 0 || had.scale !== w.scale)
            changed = true;
    }
    for (const [key, had] of Object.entries(live)) {
        if (wanted[key])
            continue;
        const until = had.until === 0 ? now + grace : had.until;
        if (until > now) {
            next[key] = Object.assign({}, had, { until });
            if (had.until === 0)
                changed = true;
        } else {
            changed = true;
        }
    }
    return {
        live: changed ? next : live,
        changed,
        pending: Object.values(next).some(e => e.until > 0)
    };
}
