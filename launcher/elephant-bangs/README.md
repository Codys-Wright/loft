### Elephant Bangs (studio-linux)

DuckDuckGo !bangs and Quicklinks for the studio-linux Spotlight.

- `!` lists your quicklinks, favorites and the most used bangs; `!nixpk`, `!youtube`, `!yout`
  fuzzy-find by trigger, name, domain and category.
- Enter or Tab on a bang scopes the launcher to it (`!nixpkgs `): type the term, Enter searches.
  Backspace on the empty term leaves the scope. `!yt lofi` + Enter searches right away.
- Quicklinks are your own keywords (`yt`, `np`, `gm`): an exact keyword is the top result of a
  plain query, `yt lofi` searches directly. They also work as `!yt`, and win over bangs.
- Plain queries get "Search <default engine> for …" and "Open <url>".

Scoping needs walker with launcher/walker-set-query.patch.

#### Files

- `data`: the bang list, JSON `[{t, s, d, c, sc, u, r}]` with `%TERM%` in `u`.
- `settings`: `{ "defaultEngine": "g", "favorites": ["yt"], "quicklinks": [{ "keyword": "yt",
  "name": "YouTube", "bang": "yt" }, { "keyword": "gm", "name": "Gmail", "url": "https://mail.google.com" }] }`,
  re-read when it changes. While missing, `defaults` is used.
