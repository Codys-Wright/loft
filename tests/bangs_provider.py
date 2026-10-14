"""Spotlight's `bangs` elephant provider, end to end (nix flake check: launcher-bangs).

Runs against a live elephant (only the bangs provider loaded) through
`elephant query`/`activate`: ranking, scopes, quicklinks, the default engine,
URL filling — opened URLs land in a log instead of a browser.

usage: python3 bangs_provider.py ELEPHANT OPEN_LOG
"""

import json
import subprocess
import sys
import time

elephant, log = sys.argv[1:]


def query(providers, q, n=8):
    out = subprocess.run([elephant, "query", "--json", f"{providers};{q};{n}"], capture_output=True, text=True, check=True).stdout
    return [json.loads(l)["item"] for l in out.splitlines() if l.startswith("{") and "item" in json.loads(l)]


def activate(identifier, action, q):
    subprocess.run([elephant, "activate", f"bangs;{identifier};{action};{q};"], check=True)


def opened():
    for _ in range(50):
        try:
            lines = open(log).read().split()
            if lines:
                open(log, "w").close()
                return lines[-1]
        except FileNotFoundError:
            pass
        time.sleep(0.1)
    raise AssertionError("nothing opened")


def check(name, cond, got):
    if not cond:
        print(f"FAIL {name}: {got!r}")
        sys.exit(1)
    print(f"ok   {name}")


texts = lambda items: [i["text"] for i in items]

# "!" — quicklinks first, in order, then favorites.
r = query("bangs", "")
check("! lists quicklinks first", texts(r)[:2] == ["YouTube", "GitHub"], texts(r))

# Fuzzy on trigger, name, domain.
check("!nixpk → NixOS Packages", texts(query("bangs", "nixpk"))[0] == "NixOS Packages", texts(query("bangs", "nixpk")))
check("!youtube → YouTube", texts(query("bangs", "youtube"))[0] == "YouTube", texts(query("bangs", "youtube")))
check("!yout finds YouTube", "YouTube" in texts(query("bangs", "yout"))[:3], texts(query("bangs", "yout")))
check("one row per site", texts(query("bangs", "youtube")).count("YouTube") == 1, texts(query("bangs", "youtube")))
r = query("bangs", "nixpk")
check("browse rows scope", r[0]["actions"][0] == "scope" and r[0]["identifier"] == "scope:nixpkgs", r[0])

# The scope.
r = query("bangs", "nixpkgs ")
check("scope row", len(r) == 1 and r[0]["text"] == "Search NixOS Packages", texts(r))
r = query("bangs", "nixpkgs firefox")
check("scoped term", r[0]["text"] == "Search NixOS Packages for “firefox”" and r[0]["actions"][0] == "search", r[0])
activate("search:nixpkgs", "search", "nixpkgs firefox esr")
check("scoped search opens", opened() == "https://search.nixos.org/packages?channel=unstable&query=firefox%20esr", None)
activate("search:maps", "search", "maps a/b & c")
check("term encoding (unduck's)", opened() == "https://google.com/maps?q=a/b%20%26%20c", None)

# Quicklinks in plain queries (several providers → not single).
r = query("bangs,calc", "yt")
check("exact keyword is first", r[0]["text"] == "Search YouTube" and r[0]["actions"][0] == "scope", r[0])
r = query("bangs,calc", "yt lofi")
check("keyword + term", r[0]["text"] == "Search YouTube for “lofi”", r[0])
activate("search:yt", "search", "yt lofi")
check("keyword search opens", opened() == "https://www.youtube.com/results?search_query=lofi", None)
r = query("bangs,calc", "gm")
check("URL quicklink opens the page", r[0]["text"] == "Open Gmail" and r[0]["actions"] == ["open"], r[0])
r = query("bangs,calc", "you")
check("non-exact keyword is ordinary", all(i["score"] < 1000 for i in r), [(i["text"], i["score"]) for i in r])
check("default engine row", any(i["text"] == "Search Google for “you”" for i in r), texts(r))
activate("web:g", "search", "hello world")
check("default engine search", opened() == "https://www.google.com/search?q=hello%20world", None)
r = query("bangs,calc", "github.com")
check("URL row", r[0]["text"] == "Open https://github.com", texts(r))
