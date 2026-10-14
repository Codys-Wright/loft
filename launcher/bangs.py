"""DuckDuckGo-style !bangs for the launcher (unduck's bang list → elephant).

Reads unduck's src/bang.ts (github.com/T3-Content/unduck — DuckDuckGo's bang
list as a JS array) and writes the data file of the `bangs` elephant provider
(launcher/elephant-bangs): a JSON array of {t, s, d, c, sc, u, r}, most used
first (r = DuckDuckGo's usage rank), one entry per trigger, with the search
term placeholder rewritten to %TERM%.

A few studio additions and fixes (EXTRAS) are applied on top: current NixOS
search URLs and the Nix tools DuckDuckGo lacks (noogle, Home Manager options).

usage: python3 bangs.py bang.ts out.json
"""

from __future__ import annotations

import json
import re
import sys

NIX = {"c": "Tech", "sc": "Programming"}
NIXPKGS = "https://search.nixos.org/packages?channel=unstable&query=%TERM%"
NIXOPTS = "https://search.nixos.org/options?channel=unstable&query=%TERM%"

# trigger → fields; replaces DuckDuckGo's entry or adds one.
EXTRAS: dict[str, dict] = {
    "nixpkgs": {**NIX, "s": "NixOS Packages", "d": "search.nixos.org", "r": 3653, "u": NIXPKGS},
    "nixpkg": {**NIX, "s": "NixOS Packages", "d": "search.nixos.org", "r": 200, "u": NIXPKGS},
    "nixopt": {**NIX, "s": "NixOS Options", "d": "search.nixos.org", "r": 274, "u": NIXOPTS},
    "nixopts": {**NIX, "s": "NixOS Options", "d": "search.nixos.org", "r": 274, "u": NIXOPTS},
    "hmopts": {
        **NIX,
        "s": "Home Manager Options",
        "d": "home-manager-options.extranix.com",
        "r": 274,
        "u": "https://home-manager-options.extranix.com/?query=%TERM%&release=master",
    },
    "noogle": {**NIX, "s": "Noogle", "d": "noogle.dev", "r": 274, "u": "https://noogle.dev/q?term=%TERM%"},
    "kagi": {
        "c": "Online Services",
        "sc": "Search",
        "s": "Kagi",
        "d": "kagi.com",
        "r": 1000,
        "u": "https://kagi.com/search?q=%TERM%",
    },
}


def parse(ts: str) -> list[dict]:
    body = ts[ts.index("[") : ts.rindex("]") + 1]
    body = re.sub(r"(?m)^\s*([a-z]+):", r'"\1":', body)  # quote keys
    # single-quoted JS strings (they hold double quotes) → JSON strings
    body = re.sub(
        r"(\"[a-z]+\":\s*)'((?:[^'\\]|\\.)*)'",
        lambda m: m.group(1) + json.dumps(m.group(2).replace("\\'", "'")),
        body,
    )
    body = re.sub(r",(\s*[}\]])", r"\1", body)  # trailing commas
    return json.loads(body)


def convert(bangs: list[dict]) -> list[dict]:
    out: dict[str, dict] = {}
    # Most used first, so a duplicate trigger keeps the popular engine.
    for b in sorted(bangs, key=lambda b: -int(b.get("r") or 0)):
        t = (b.get("t") or "").strip().lower()
        url = b.get("u") or ""
        if not t or not url or t in out or " " in t:
            continue
        out[t] = {
            "t": t,
            "s": b.get("s") or t,
            "d": b.get("d") or "",
            "c": b.get("c") or "",
            "sc": b.get("sc") or "",
            "u": url.replace("{{{s}}}", "%TERM%"),
            "r": int(b.get("r") or 0),
        }
    for t, fields in EXTRAS.items():
        out[t] = {"t": t, **fields}
    return sorted(out.values(), key=lambda b: -b["r"])


def main() -> None:
    src, dst = sys.argv[1:]
    data = convert(parse(open(src, encoding="utf-8").read()))
    with open(dst, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
    print(f"bangs: {len(data)} → {dst}", file=sys.stderr)


if __name__ == "__main__":
    main()
