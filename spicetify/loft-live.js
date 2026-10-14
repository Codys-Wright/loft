// loft-live.js: Loft's Spicetify extension. Recolors a running Spotify when
// the Loft theme changes, without a restart (playback keeps going).
//
// `loft theme apply` (the `spotify` hook, cli/loft/spotify.py) rewrites
// xpui/colors.css, the file Spicetify links as <link href="colors.css"> with
// the scheme's --spice-* / --spice-rgb-* variables. This re-reads it from
// Spotify's own app origin (cache-busted) and, when it changed, puts the new
// rules in a <style> right after that link: the same place in the cascade,
// so the text theme's user.css (which derives --spice-sidebar etc. from them)
// still wins over it exactly as on a cold start.
//
// Installed by `loft spotify setup`; nothing to configure.
(function (root) {
    "use strict";

    const STYLE_ID = "loft-live-colors";
    const POLL_MS = 1500;

    // { name: value } of every custom property in a colors.css text.
    function parseVars(css) {
        const out = {};
        const re = /(--spice-[\w-]+)\s*:\s*([^;}]+)/g;
        let m;
        while ((m = re.exec(css)) !== null)
            out[m[1]] = m[2].trim();
        return out;
    }

    // A colors.css worth applying: a :root block with the core variables.
    function looksValid(css) {
        const v = parseVars(css);
        return "--spice-main" in v && "--spice-text" in v && "--spice-rgb-main" in v;
    }

    // Put css into our <style>, right after Spicetify's colors.css link.
    function applyCss(doc, css) {
        let style = doc.getElementById(STYLE_ID);
        if (!style) {
            style = doc.createElement("style");
            style.id = STYLE_ID;
            const link = doc.querySelector('link[href^="colors.css"]');
            if (link && link.parentNode)
                link.parentNode.insertBefore(style, link.nextSibling);
            else
                (doc.head || doc.documentElement).appendChild(style);
        }
        if (style.textContent !== css)
            style.textContent = css;
        return style;
    }

    // One poller: fetch(url) → text; apply when it changed since the last read.
    function createPoller(doc, fetchFn, now) {
        let last = null;
        let busy = false;
        return async function tick() {
            if (busy)
                return false;
            busy = true;
            try {
                const res = await fetchFn(`colors.css?loft=${now()}`, { cache: "no-store" });
                if (!res || !res.ok)
                    return false;
                const css = await res.text();
                if (css === last || !looksValid(css))
                    return false;
                last = css;
                // (The first read may equal what Spotify loaded; applying it is harmless.)
                applyCss(doc, css);
                return true;
            } catch (e) {
                return false;
            } finally {
                busy = false;
            }
        };
    }

    // Order- and whitespace-insensitive form of a colors.css (tests).
    function normalize(css) {
        const v = parseVars(css);
        return Object.keys(v).sort().map(k => `${k}:${v[k].replace(/\s+/g, "").toLowerCase()}`).join(";");
    }

    function start() {
        const doc = root.document;
        const tick = createPoller(doc, (u, o) => root.fetch(u, o), () => Date.now());
        tick();
        root.setInterval(() => {
            if (!doc.hidden)
                tick();
        }, POLL_MS);
        doc.addEventListener("visibilitychange", () => {
            if (!doc.hidden)
                tick();
        });
    }

    const api = { parseVars, looksValid, applyCss, createPoller, normalize, STYLE_ID };
    if (typeof module !== "undefined" && module.exports)
        module.exports = api;
    else if (root && root.document)
        start();
})(typeof window !== "undefined" ? window : globalThis);
