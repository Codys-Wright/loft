"""cozytile: Darkkal44/Cozytile's five desktop themes as studio packs.

Upstream layout (what this reads; everything else is never downloaded):

  .config/rofi/theme_scripts/<Name>          the theme switcher: `wal [-b BG] -i ~/Wallpaper/<file>`
                                             (+ `wal -f ~/Wallpaper/<json>` for Carbon)
  .config/rofi/settings/launcher/<name>.rasi rofi globals: background, background-alt, foreground,
                                             selected, active, urgent
  Themes/<Name>/.config/qtile/config.py      bar colors (bar bg, widget bg, widget fg = the accent)
  Themes/<Name>/.config/dunst/dunstrc        notification colors (fallback text/bg)
  Wallpaper/<file>, Wallpaper/e-ink.json     wallpapers, Carbon's pywal colorscheme
  sddm-themes/<Name>/                        SDDM greeter, qylock format (→ the pack's greeter/,
                                             declared as its lock design; its Background is
                                             the same file as the switcher's wallpaper)

Wallpapers: the switcher's (default), the SDDM background when it differs,
and the shipped wallpapers no theme sets (e.g. the pexels fern), each given
to the theme whose palette is closest to the image's own colors.

Palette (dark themes): bg = the `wal -b` background (= qtile's bar color),
surface = qtile's widget background, text = rofi foreground, accent = qtile's
workspace/widget foreground, accent2 = the rofi/qtile/SDDM highlight that
differs most from the accent; overlay/subtext are mixed from those and
urgent/ok/warn are harmonized semantic hues (Cozytile has no red/green/yellow
roles). A theme whose switcher loads a pywal JSON (Carbon) takes bg, text
and accent from that JSON's special colors instead; polarity follows bg.

Upstream has no license; packs say NOASSERTION and nothing is redistributed
from this repo.
"""

from __future__ import annotations

import json
import re
import shutil
from collections import Counter
from pathlib import Path

from .. import color, palette, vibes
from .upstream import ImporterError, Upstream, literal

NAME = "cozytile"
URL = "https://github.com/Darkkal44/Cozytile"
LICENSE = "NOASSERTION"
DESCRIPTION = "Darkkal44's Cozytile qtile rice themes (Cozy, Sakura, Natura, Everforest, Carbon)"

HEX = r"#[0-9a-fA-F]{6}"


def pack_name(theme: str) -> str:
    return f"cozytile-{theme.lower()}"


def list_themes(up: Upstream) -> list[str]:
    up.dir  # noqa: B018 — fetch first, so fetch errors surface as they are
    try:
        entries = up.ls("Themes")
    except ImporterError as e:
        raise ImporterError(f"{up.url} @ {up.ref} has no Themes/ directory; has the upstream layout changed?") from e
    return sorted(n for n, typ in entries if typ == "tree")


def resolve(up: Upstream, theme: str) -> str:
    """Case-insensitive theme lookup (`cozytile:sakura` → Sakura)."""
    for t in list_themes(up):
        if t.lower() == theme.lower() or pack_name(t) == theme.lower():
            return t
    raise ImporterError(f"no Cozytile theme '{theme}' (have: {', '.join(list_themes(up))})")


# ── parsers (pure; unit-tested) ─────────────────────────────────────────────


def parse_rasi(text: str) -> dict[str, str]:
    """Color variables of a rofi theme's global `* { … }` block."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    m = re.search(r"\*\s*\{(.*?)\}", text, flags=re.S)
    if not m:
        return {}
    out = {}
    for key, val in re.findall(r"([\w-]+)\s*:\s*(" + HEX + r")\b", m.group(1)):
        out[key] = val.lower()
    return out


def parse_qtile(text: str) -> dict[str, str]:
    """Bar colors from a qtile config.py, by how often each is used.

    `background=` is used for the bar and the widget pills: the most
    frequent one is the widget background, the second the bar background.
    The most frequent `foreground=` is the widget text color, which is the
    theme's accent. `active` / `block_highlight_text_color` are the
    workspace indicator colors.
    """
    text = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
    pairs = re.findall(r"\b(\w+)\s*=\s*[\"'](" + HEX + r")[\"']", text)
    by_key: dict[str, Counter] = {}
    for key, val in pairs:
        by_key.setdefault(key, Counter())[val.lower()] += 1
    out: dict[str, str] = {}
    bgs = [c for c, _ in by_key.get("background", Counter()).most_common()]
    if bgs:
        out["widget_bg"] = bgs[0]
        if len(bgs) > 1:
            out["bar_bg"] = bgs[1]
    fgs = by_key.get("foreground", Counter()).most_common()
    if fgs:
        out["widget_fg"] = fgs[0][0]
    for key in ("active", "block_highlight_text_color", "inactive"):
        if key in by_key:
            out[key] = by_key[key].most_common(1)[0][0]
    return out


def parse_dunst(text: str) -> dict[str, str]:
    """[urgency_normal] background/foreground of a dunstrc."""
    sect = re.search(r"^\[urgency_normal\](.*?)(?=^\[|\Z)", text, flags=re.S | re.M)
    out = {}
    if sect:
        for key in ("background", "foreground"):
            m = re.search(rf"^\s*{key}\s*=\s*\"?({HEX})", sect.group(1), flags=re.M)
            if m:
                out[key] = m.group(1).lower()
    return out


def parse_switcher(text: str) -> dict[str, str]:
    """`wal -b BG -i ~/Wallpaper/F` (+ `wal -f ~/Wallpaper/J`) from a theme script."""
    out = {}
    m = re.search(r"\bwal\b[^\n&|;]*?-i\s+[\"']?~/(Wallpaper/[^\s\"'&;|]+)", text)
    if m:
        out["wallpaper"] = m.group(1)
    m = re.search(r"\bwal\b[^\n&|;]*?-b\s+#?([0-9a-fA-F]{6})\b", text)
    if m:
        out["wal_bg"] = "#" + m.group(1).lower()
    m = re.search(r"\bwal\b[^\n&|;]*?-f\s+[\"']?~/(Wallpaper/[^\s\"'&;|]+\.json)", text)
    if m:
        out["pywal_json"] = m.group(1)
    return out


def parse_pywal(text: str) -> dict[str, str]:
    data = json.loads(text)
    out = {f"special.{k}": v.lower() for k, v in data.get("special", {}).items()}
    out.update({k: v.lower() for k, v in data.get("colors", {}).items()})
    return out


def parse_conf(text: str) -> dict[str, str]:
    """key=value lines of an SDDM theme.conf (first section wins)."""
    out = {}
    for line in text.splitlines():
        if "=" in line and not line.lstrip().startswith(("#", ";", "[")):
            k, v = line.split("=", 1)
            out.setdefault(k.strip(), v.strip())
    return out


def derive(
    *,
    rasi: dict[str, str],
    qtile: dict[str, str],
    dunst: dict[str, str],
    switcher: dict[str, str],
    pywal: dict[str, str] | None = None,
    sddm: dict[str, str] | None = None,
) -> tuple[str, dict[str, str]]:
    """(polarity, palette) from a Cozytile theme's parsed configs."""
    sddm = sddm or {}
    sddm_accent = sddm.get("accentColor", "")
    sddm_accent = sddm_accent.lower() if re.fullmatch(HEX, sddm_accent) else None
    if pywal:
        bg = pywal.get("special.background")
        text = pywal.get("special.foreground")
        accent = pywal.get("special.cursor") or pywal.get("color4")
        surface = None
        cands = [sddm_accent, rasi.get("selected"), rasi.get("active"), pywal.get("color5")]
    else:
        bg = switcher.get("wal_bg") or qtile.get("bar_bg") or rasi.get("background") or dunst.get("background")
        surface = qtile.get("widget_bg") or rasi.get("background-alt")
        if surface and bg and color.hex6(surface) == color.hex6(bg):
            surface = None
        text = rasi.get("foreground") or dunst.get("foreground")
        accent = qtile.get("active") or qtile.get("widget_fg") or rasi.get("selected") or sddm_accent
        cands = [qtile.get("block_highlight_text_color"), rasi.get("active"), rasi.get("selected"), rasi.get("urgent"), sddm_accent]
    if not bg or not text or not accent:
        raise ImporterError("could not find bg/text/accent colors in the theme's rofi/qtile/dunst config")
    cands = [c for c in cands if c]
    accent2 = palette.pick_distinct(accent, cands)
    return palette.scheme(bg=bg, text=text, accent=accent, accent2=accent2, surface=surface)


# ── install ─────────────────────────────────────────────────────────────────


def _read(root: Path, rel: str) -> str:
    p = root / rel
    return p.read_text(encoding="utf-8", errors="replace") if p.is_file() else ""


def _config_paths(theme: str) -> list[str]:
    low = theme.lower()
    return [
        f".config/rofi/theme_scripts/{theme}",
        f".config/rofi/settings/launcher/{low}.rasi",
        f"Themes/{theme}/.config/qtile/config.py",
        f"Themes/{theme}/.config/dunst/dunstrc",
    ]


def _asset_patterns(up: Upstream, theme: str, switcher: dict[str, str]) -> list[str]:
    wanted = [literal(f"sddm-themes/{theme}") + "/"] if _has_sddm(up, theme) else []
    for key in ("wallpaper", "pywal_json"):
        if switcher.get(key):
            wanted.append(literal(switcher[key]))
    return wanted


def prefetch(up: Upstream, themes: list[str]) -> None:
    """Download what `install` will read for all themes in two round trips
    (configs, then the wallpapers/greeters they name) instead of two per theme."""
    root = up.checkout(*(literal(p) for t in themes for p in _config_paths(t)))
    up.checkout(*(pat for t in themes for pat in _asset_patterns(up, t, parse_switcher(_read(root, _config_paths(t)[0])))))


def _palette_of(up: Upstream, theme: str) -> tuple[str, dict[str, str], dict[str, str], dict[str, str] | None]:
    """(polarity, palette, switcher, pywal) of a theme from its configs."""
    script, rasi, qtile, dunst = _config_paths(theme)
    root = up.checkout(*map(literal, (script, rasi, qtile, dunst)))
    switcher = parse_switcher(_read(root, script))
    has_sddm = _has_sddm(up, theme)
    extra = [literal(switcher["pywal_json"])] if switcher.get("pywal_json") else []
    if has_sddm:
        extra.append(literal(f"sddm-themes/{theme}/theme.conf"))
    if extra:
        up.checkout(*extra)
    pywal = None
    if switcher.get("pywal_json") and (root / switcher["pywal_json"]).is_file():
        try:
            pywal = parse_pywal(_read(root, switcher["pywal_json"]))
        except (ValueError, AttributeError) as e:
            raise ImporterError(f"{switcher['pywal_json']}: {e}") from e
    sddm_conf = parse_conf(_read(root, f"sddm-themes/{theme}/theme.conf")) if has_sddm else {}
    polarity, pal = derive(
        rasi=parse_rasi(_read(root, rasi)),
        qtile=parse_qtile(_read(root, qtile)),
        dunst=parse_dunst(_read(root, dunst)),
        switcher=switcher,
        pywal=pywal,
        sddm=sddm_conf,
    )
    return polarity, pal, switcher, pywal


IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp"}


def orphan_owners(
    orphans: dict[str, list[tuple[str, float]]], palettes: dict[str, tuple[str, dict[str, str]]]
) -> dict[str, list[str]]:
    """Which themes get each wallpaper no theme script uses: the one whose
    palette is closest to the image's own (vibes.palette_distance), or every
    theme when the image couldn't be sampled. {orphan: [themes]}"""
    out: dict[str, list[str]] = {}
    for name, swatches in orphans.items():
        if not swatches or not palettes:
            out[name] = sorted(palettes)
            continue
        ipol, ipal = palette.scheme(swatches=swatches)
        out[name] = [min(palettes, key=lambda t: (vibes.palette_distance(palettes[t][1], ipal, palettes[t][0], ipol), t))]
    return out


def _orphans(up: Upstream) -> dict[str, list[str]]:
    """{Wallpaper/<file>: [themes]} for the shipped wallpapers no theme sets,
    computed once per upstream (it reads every theme's configs)."""
    cached = getattr(up, "_cozytile_orphans", None)
    if cached is not None:
        return cached
    themes = list_themes(up)
    # Batch the small config downloads: every theme's configs, then their
    # SDDM theme.conf / pywal files, in two round trips.
    root = up.checkout(*(literal(p) for t in themes for p in _config_paths(t)))
    up.checkout(
        *(literal(f"sddm-themes/{t}/theme.conf") for t in themes if _has_sddm(up, t)),
        *(literal(j) for t in themes if (j := parse_switcher(_read(root, _config_paths(t)[0])).get("pywal_json"))),
    )
    palettes: dict[str, tuple[str, dict[str, str]]] = {}
    used: set[str] = set()
    for t in themes:
        try:
            pol, pal, switcher, _ = _palette_of(up, t)
        except ImporterError:
            continue
        palettes[t] = (pol, pal)
        used.update(switcher.get(k, "") for k in ("wallpaper", "pywal_json"))
    try:
        entries = up.ls("Wallpaper")
    except ImporterError:
        entries = []
    files = [f"Wallpaper/{n}" for n, typ in entries if typ == "blob" and Path(n).suffix.lower() in IMAGE_SUFFIXES]
    orphans = [f for f in files if f not in used]
    swatches: dict[str, list[tuple[str, float]]] = {}
    if orphans:
        root = up.checkout(*map(literal, orphans))
        for f in orphans:
            swatches[f] = palette.quantize(palette.sample(root / f))
    result = orphan_owners(swatches, palettes)
    up._cozytile_orphans = result  # type: ignore[attr-defined]
    return result


def wallpaper_name(rel: str) -> str:
    """A tidy file name for wallpapers/ ("pexels-… (1).jpg" → "pexels-…-1.jpg")."""
    p = Path(rel)
    stem = re.sub(r"[^a-z0-9._-]+", "-", p.stem.lower()).strip("-._") or "wallpaper"
    return stem + p.suffix.lower()


def install(theme: str, dest: Path, up: Upstream | None = None) -> dict:
    """Write the pack for `theme` into dest (a new, empty directory).

    Wallpapers: the one the theme switcher sets is the default (when the SDDM
    theme's Background is the same file, the greeter's copy is referenced
    instead of a second copy), the SDDM background if it differs, and every
    wallpaper the rice ships that no theme sets, given to the theme whose
    palette is closest to the image's colors (→ wallpapers/). The SDDM theme
    (qylock format) is the pack's default lock design.
    """
    own = up is None
    up = up or Upstream(URL)
    try:
        theme = resolve(up, theme)
        polarity, pal, switcher, pywal = _palette_of(up, theme)
        root = up.dir
        sddm_dir = f"sddm-themes/{theme}"
        has_sddm = _has_sddm(up, theme)
        up.checkout(*_asset_patterns(up, theme, switcher))
        sddm_conf = parse_conf(_read(root, f"{sddm_dir}/theme.conf")) if has_sddm else {}
        orphans = [f for f, owners in _orphans(up).items() if theme in owners]

        dest.mkdir(parents=True, exist_ok=True)
        theme_json: dict = {"polarity": polarity, "palette": pal, "glass": palette.glass(polarity, pal)}
        if has_sddm:
            shutil.copytree(root / sddm_dir, dest / "greeter", ignore=shutil.ignore_patterns(".gitkeep", ".git"))
            manifest_lock = {"name": theme.lower(), "format": "qylock", "path": "greeter"}
        greeter_bg = None
        if has_sddm and sddm_conf.get("background") and (dest / "greeter" / sddm_conf["background"]).is_file():
            greeter_bg = f"greeter/{sddm_conf['background']}"

        images: list[str] = []
        wall_src = root / switcher["wallpaper"] if switcher.get("wallpaper") else None
        if wall_src and wall_src.is_file():
            if greeter_bg and (dest / greeter_bg).read_bytes() == wall_src.read_bytes():
                images.append(greeter_bg)
                greeter_bg = None
            else:
                rel = f"wallpapers/{wallpaper_name(switcher['wallpaper'])}"
                (dest / "wallpapers").mkdir(exist_ok=True)
                shutil.copyfile(wall_src, dest / rel)
                images.append(rel)
        if greeter_bg:
            images.append(greeter_bg)
        for f in orphans:
            if (root / f).is_file():
                (dest / "wallpapers").mkdir(exist_ok=True)
                shutil.copyfile(root / f, dest / "wallpapers" / wallpaper_name(f))
        if images:
            theme_json["wallpaper"] = {"image": images[0]}
            if images[1:]:
                theme_json["wallpaper"]["images"] = images[1:]

        (dest / "theme.json").write_text(json.dumps(theme_json, indent=2) + "\n")
        manifest = {
            "name": pack_name(theme),
            "author": "Darkkal44",
            "version": "0.0.0+" + up.commit[:12],
            "license": LICENSE,
            "source": URL,
            "description": f"Cozytile {theme} (imported: palette from its "
            + (f"pywal {Path(switcher['pywal_json']).name}" if pywal else "qtile/rofi config")
            + ")",
            "upstream": {"importer": NAME, "url": up.url, "ref": up.ref, "commit": up.commit, "path": f"Themes/{theme}"},
        }
        if has_sddm:
            manifest["lock"] = manifest_lock
        (dest / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        return manifest
    finally:
        if own:
            up.close()


def _has_sddm(up: Upstream, theme: str) -> bool:
    if not any(n == "sddm-themes" and t == "tree" for n, t in up.ls("")):
        return False
    return any(n == theme and t == "tree" for n, t in up.ls("sddm-themes"))
