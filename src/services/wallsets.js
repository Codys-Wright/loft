.pragma library

// Wallpaper sets: display roles from the live layout, sets resolved onto it,
// and the arrangement on screen captured as a set. The same rules as
// cli/loft/wallsets.py (the CLI's `loft wallpaper set …`); both are
// tested against tests/fixtures/wallsets/layouts.json (tests/wallsets.test.js).
//
// A layout is { outputs: [{ name, identity, x, y, width, height }] (logical),
// main: connector or identity ("" = the largest), workspaces: [{ output, idx, name }] }.

const ULTRAWIDE = 2.2;

function area(o) {
    return o.width * o.height;
}

function ident(o) {
    return o.identity || o.name;
}

// The display named by `main` (connector or identity), else the largest
// (ties: leftmost, then topmost).
function mainOutput(outputs, main) {
    if (!outputs || outputs.length === 0)
        return null;
    if (main) {
        const hit = outputs.find(o => o.name === main || o.identity === main);
        if (hit)
            return hit;
    }
    return outputs.slice().sort((a, b) => area(b) - area(a) || a.x - b.x || a.y - b.y)[0];
}

function shapeOf(o) {
    if (o.height > o.width)
        return "portrait";
    return o.width / Math.max(o.height, 1) >= ULTRAWIDE ? "ultrawide" : "landscape";
}

function cmp(a, b) {
    for (let i = 0; i < a.length; i++) {
        if (a[i] < b[i])
            return -1;
        if (a[i] > b[i])
            return 1;
    }
    return 0;
}

// connector → roles, most specific first: position (main / left / right /
// top / bottom of main, -2 … further out), shape, display-N by x, "*".
function roles(outputs, main) {
    const m = mainOutput(outputs, main);
    const out = {};
    if (!m)
        return out;
    const groups = { left: [], right: [], top: [], bottom: [] };
    const mx2 = m.x + m.width, my2 = m.y + m.height;
    const mcx = m.x + m.width / 2, mcy = m.y + m.height / 2;
    for (const o of outputs) {
        if (o === m)
            continue;
        const ox2 = o.x + o.width, oy2 = o.y + o.height;
        const cx = o.x + o.width / 2, cy = o.y + o.height / 2;
        if (ox2 <= m.x)
            groups.left.push([m.x - ox2, Math.abs(cy - mcy), o.name]);
        else if (o.x >= mx2)
            groups.right.push([o.x - mx2, Math.abs(cy - mcy), o.name]);
        else if (oy2 <= m.y)
            groups.top.push([m.y - oy2, Math.abs(cx - mcx), o.name]);
        else if (o.y >= my2)
            groups.bottom.push([o.y - my2, Math.abs(cx - mcx), o.name]);
    }
    const positional = {};
    positional[m.name] = "main";
    for (const d of ["left", "right", "top", "bottom"])
        groups[d].sort(cmp).forEach((t, i) => positional[t[2]] = i === 0 ? d : `${d}-${i + 1}`);
    const ordinal = {};
    outputs.slice().sort((a, b) => cmp([a.x, a.y, a.name], [b.x, b.y, b.name])).forEach((o, i) => ordinal[o.name] = `display-${i + 1}`);
    for (const o of outputs)
        out[o.name] = (positional[o.name] ? [positional[o.name]] : []).concat([shapeOf(o), ordinal[o.name], "*"]);
    return out;
}

// How a workspace's choice is stored: its name, else <identity>#<idx>.
function wsKey(ws, identity) {
    return ws.name ? ws.name : `${identity}#${ws.idx}`;
}

function workspacesOf(layout, output) {
    return (layout.workspaces || []).filter(w => w.output === output).sort((a, b) => a.idx - b.idx);
}

// A set on a live layout → { displays: { identity: path }, workspaces: { ws key: path } }.
function resolveSet(set, layout) {
    const rs = roles(layout.outputs || [], layout.main);
    const disp = set.displays || {};
    const wsp = set.workspaces || {};
    const out = { displays: {}, workspaces: {} };
    for (const o of layout.outputs || []) {
        const r = (rs[o.name] || []).find(r => disp[r]);
        if (r)
            out.displays[ident(o)] = disp[r];
        for (const w of workspacesOf(layout, o.name)) {
            let p = w.name ? wsp[w.name] : undefined;
            if (!p) {
                const k = (rs[o.name] || []).map(r => `${r}#${w.idx}`).find(k => wsp[k]);
                p = k ? wsp[k] : undefined;
            }
            if (p)
                out.workspaces[wsKey(w, ident(o))] = p;
        }
    }
    return out;
}

// How many displays a set names by a specific role (not "*").
function coverage(set, layout) {
    const rs = roles(layout.outputs || [], layout.main);
    const disp = set.displays || {};
    return (layout.outputs || []).filter(o => (rs[o.name] || []).some(r => r !== "*" && disp[r])).length;
}

// The set covering the most displays (first on ties), or null.
function bestSet(sets, layout) {
    let best = null, n = 0;
    for (const s of sets || []) {
        const c = coverage(s, layout);
        if (c > n) {
            best = s;
            n = c;
        }
    }
    return best;
}

// The arrangement on screen as a set: each display's base image under its
// primary role, each workspace showing something else under its name (or
// <primary role>#<idx>). effective = { displays: { identity: base },
// workspaces: { ws key: path } }.
function capture(name, layout, effective) {
    const rs = roles(layout.outputs || [], layout.main);
    const out = { name: name, displays: {}, workspaces: {} };
    for (const o of layout.outputs || []) {
        const primary = rs[o.name][0];
        const base = effective.displays[ident(o)];
        if (base)
            out.displays[primary] = base;
        for (const w of workspacesOf(layout, o.name)) {
            const p = effective.workspaces[wsKey(w, ident(o))];
            if (p && p !== base)
                out.workspaces[w.name || `${primary}#${w.idx}`] = p;
        }
    }
    return out;
}
