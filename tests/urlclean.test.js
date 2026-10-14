// Unit tests for src/services/urlclean.js (Clean URL), run by `nix flake check`
// (clipboard-urlclean): node tests/urlclean.test.js src/services/urlclean.js
const fs = require("fs");
const assert = require("assert");

// The QML library is plain JS behind a `.pragma library` line.
const src = fs.readFileSync(process.argv[2], "utf8").replace(/^\.pragma library.*$/m, "");
const lib = new Function(`${src}; return { clean, isUrl, isTracked };`)();

const cases = [
    ["https://example.com/a?utm_source=x&utm_medium=y", "https://example.com/a"],
    ["https://example.com/a?id=7&utm_campaign=z#top", "https://example.com/a?id=7#top"],
    ["https://shop.example.com/i/42?color=red&fbclid=IwAR1&gclid=abc", "https://shop.example.com/i/42?color=red"],
    ["https://www.youtube.com/watch?v=dQw4w9WgXcQ&si=abc&t=42", "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42"],
    ["https://youtu.be/dQw4w9WgXcQ?si=abc", "https://youtu.be/dQw4w9WgXcQ"],
    ["https://open.spotify.com/track/1?si=abc", "https://open.spotify.com/track/1"],
    ["https://x.com/user/status/1?s=20&t=abc", "https://x.com/user/status/1"],
    // `si`, `s`, `t` mean something elsewhere: kept.
    ["https://example.com/search?s=shoes&t=1&si=2", "https://example.com/search?s=shoes&t=1&si=2"],
    ["https://example.com/page?id=7", "https://example.com/page?id=7"],
    ["  https://example.com/?UTM_Source=x  ", "https://example.com/"],
    // Not a lone URL: untouched.
    ["see https://example.com/?utm_source=x", "see https://example.com/?utm_source=x"],
    ["plain text", "plain text"]
];

for (const [input, want] of cases)
    assert.strictEqual(lib.clean(input), want, `clean(${JSON.stringify(input)})`);

assert.strictEqual(lib.isTracked("https://example.com/?fbclid=1"), true);
assert.strictEqual(lib.isTracked("https://example.com/?id=1"), false);
assert.strictEqual(lib.isUrl("ftp://example.com"), false);
console.log(`urlclean: ${cases.length} cases ok`);
