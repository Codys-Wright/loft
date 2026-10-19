.pragma library

// A niri workspace's icon in the menu bar (WorkspaceIcons.qml); tested by
// tests/wsicons.test.js.
//
// Built-in guesses from common workspace names, Material Design glyphs
// (Nerd Fonts' nf-md range, the icon font the shell ships) by code point so
// a file encoding can't mangle them. Keys are lowercase.
const cp = c => String.fromCodePoint(c);

const groups = [
    [0xF02DC, ["main", "home", "default", "start"]], // home
    [0xF0169, ["code", "dev", "develop", "development", "coding", "programming", "ide", "editor"]], // code-braces
    [0xF075A, ["music", "audio", "daw", "sound", "studio", "spotify"]], // music
    [0xF028C, ["comms", "comm", "communication", "communications", "social", "discord", "slack"]], // forum
    [0xF0B79, ["chat", "chats", "messages", "messaging", "im"]], // chat
    [0xF082E, ["notes", "note", "notebook", "journal", "obsidian"]], // notebook
    [0xF0D19, ["media", "entertainment", "watch", "youtube"]], // play-box-multiple
    [0xF0297, ["gaming", "games", "game", "play", "steam"]], // gamepad-variant
    [0xF0E84, ["research", "study", "learn", "learning"]], // book-search
    [0xF0EC2, ["recording", "record", "rec", "capture"]], // record-circle
    [0xF1720, ["stream", "streaming", "live", "broadcast", "obs"]], // broadcast
    [0xF0493, ["setup", "settings", "config", "configuration", "system", "admin"]], // cog
    [0xF0093, ["lab", "labs", "experiments", "experiment", "sandbox", "test", "testing"]], // flask
    [0xF059F, ["web", "browser", "browse", "browsing", "internet", "www", "firefox"]], // web
    [0xF01EE, ["mail", "email", "inbox"]], // email
    [0xF024B, ["files", "file", "downloads", "finder"]], // folder
    [0xF03D8, ["design", "art", "draw", "drawing", "graphics", "creative"]], // palette
    [0xF0219, ["docs", "doc", "documents", "documentation", "paperwork"]], // file-document
    [0xF03EB, ["writing", "write", "draft", "drafts"]], // pencil
    [0xF018D, ["terminal", "term", "shell", "console", "cli"]], // console
    [0xF0567, ["video", "videos", "editing", "resolve"]], // video
    [0xF02E9, ["photos", "photo", "images", "image", "pictures", "gallery"]], // image
    [0xF00D6, ["work", "office", "job"]], // briefcase
    [0xF0474, ["school", "class", "classes"]], // school
    [0xF14F7, ["reading", "read", "books", "book", "library"]], // book-open-variant
    [0xF00ED, ["calendar", "plan", "planning", "schedule", "agenda", "todo", "tasks"]], // calendar
    [0xF012A, ["stats", "analytics", "monitor", "monitoring", "dashboard", "metrics", "finance"]], // chart-line
    [0xF06A9, ["ai", "agents", "agent", "llm", "claude"]], // robot
    [0xF048B, ["server", "servers", "ops", "infra", "cluster", "homelab", "deploy"]], // server
    [0xF015F, ["cloud"]], // cloud
    [0xF0110, ["shop", "shopping", "store"]], // cart
    [0xF0395, ["news", "feeds", "rss"]], // newspaper
    [0xF0994, ["podcast", "podcasts"]], // podcast
    [0xF01A7, ["3d", "blender", "modeling", "cad"]], // cube-outline
    [0xF0502, ["tv", "movies", "movie", "film"]], // television
    [0xF02CB, ["listen", "headphones"]], // headphones
    [0xF0209, ["hidden"]] // eye-off (Hide parks windows on "hidden-<display>")
];

const builtin = (() => {
    const m = {};
    for (const [c, names] of groups)
        for (const n of names)
            m[n] = cp(c);
    return m;
})();

// [{ icon, names }] rows, for documentation and tests.
function table() {
    return groups.map(([c, names]) => ({ icon: cp(c), names: names }));
}

// The built-in guess for a workspace name ("" = none): the whole name,
// then without trailing digits ("code2"), then its first word that matches
// ("my-music", "Web Browser").
function guess(name) {
    const n = String(name ?? "").trim().toLowerCase();
    if (n === "")
        return "";
    if (builtin[n])
        return builtin[n];
    const bare = n.replace(/[-_ ]*\d+$/, "");
    if (builtin[bare])
        return builtin[bare];
    for (const w of n.split(/[^a-z0-9]+/))
        if (w && builtin[w])
            return builtin[w];
    return "";
}

// A { name: icon } map with its keys lowercased (later keys win).
function normalize(map) {
    const out = {};
    if (!map || typeof map !== "object")
        return out;
    for (const k of Object.keys(map)) {
        const v = map[k];
        if (typeof v === "string")
            out[String(k).trim().toLowerCase()] = v;
    }
    return out;
}

// The icon for a workspace: the user's choice ("" there = explicitly no
// icon), then the Nix default, then the built-in guess. Both maps keyed by
// lowercase name (normalize).
function resolve(name, user, nix) {
    const k = String(name ?? "").trim().toLowerCase();
    if (k === "")
        return "";
    if (user && Object.prototype.hasOwnProperty.call(user, k))
        return user[k];
    if (nix && Object.prototype.hasOwnProperty.call(nix, k))
        return nix[k];
    return guess(k);
}
