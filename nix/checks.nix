# `nix flake check`: theme engine tests.
#
#   theme-schema    built-in packs (and the test fixture) match themes/schema.json
#   theme-unit      tests/test_*.py: renderer + manager against scratch dirs (greeter
#                   sync + its privileged helper: tests/test_greeter.py), the
#                   cozytile:/qylock: importers against local fake upstream repos, and
#                   vibes (pack collections, ranking, index links), and the Utilities
#                   helpers (ports, flake updates, cleaner, media tools), the capture
#                   helpers (scrolling-capture stitcher down and sideways — sticky panels,
#                   no-overlap fallback, direction detection —, Auto Scroll's stop logic with
#                   a fake loft-pointer, recording zooms, the workspace panorama's layout math
#                   on recorded niri JSON and a run against a fake niri), Apps to leave alone
#                   → xremap (tests/test_keys.py), spaces/templates and the instance fixtures
#                   against schemas/space-1.json, and Spotify themed by Loft
#                   (tests/test_spotify.py: palette → text scheme, wrapper rewriting on a fake
#                   Spotify tree, version-change detection, setup with a fake spicetify, the
#                   `spotify` hook) — all offline
#   theme-golden    rendering the built-ins reproduces tests/golden/ byte for byte, and so
#                   does `loft theme render loft@dark|loft@light` (the facet model's gate;
#                   tests/test_resolve.py also checks imported packs through the v1 adapter
#                   against the frozen v1 renderer, tests/v1_reference.py, and
#                   tests/test_render_units.py the per-unit cache keys and hook diffing)
#   niri-config     base.kdl + each rendered niri.kdl, and base.kdl + shell-binds (the
#                   macOS parity binds, PLAN §5), pass `niri validate`, including
#                   one with motion (speed, niri animations, minimal) and shape (gaps,
#                   focus ring, border) customized
#   niri-workspace-layers  niri/workspace-wallpapers.kdl (the place-within-workspace layer
#                   rule) passes niri-loft's `niri validate` with base.kdl, while stock niri
#                   rejects it (why sessions include it only with niri-loft); building
#                   niri-loft runs niri's test suite with the patch's tests (rule parsing,
#                   capture expansion, a bound surface only on its workspace)
#   ghostty-config  each rendered ghostty.conf passes `ghostty +validate-config`
#   loft-niri       the crate builds and its tests pass (incl. `niri validate`; spaces:
#                   roles over the wallsets fixtures, templates + instances, golden
#                   spaces.kdl validated with base.kdl, activation plans)
#   loft-niri-clippy  `cargo clippy --all-targets -D warnings`
#   loft-appmenu    the global menu daemon builds and its tests pass
#   loft-appmenu-clippy  the same clippy gate for it
#   loft-sleep      the sleep watcher builds and its tests pass (fake BlueZ adapters +
#                   sleep lock: off before sleep, back on after, only what was on)
#   loft-sleep-clippy  the same clippy gate for it
#   spicetify-live  Spotify's live recolor extension (spicetify/loft-live.js): colors.css
#                   re-read cache-busted and swapped in at the same cascade slot
#   loft-input      the test driver builds and its tests pass (keymaps, combos,
#                   script parsing, bind lookup, screenshot geometry), and loft-pointer's
#                   Auto Scroll pacing / stop / restore logic (motion + wheel only, vertical
#                   or horizontal)
#   loft-input-clippy  the same clippy gate for it
#   clipboard-urlclean  Clean URL's tracking-parameter stripping (src/services/urlclean.js)
#   phone-protocol  the iPhone bridge's tetherd protocol (src/services/phone.js): a recorded
#                   subscribed session (tests/fixtures/tether/session.jsonl) replayed through
#                   the reducer — threads, dedup, fresh-message detection, calls, battery;
#                   tests/test_phone_fake.py (theme-unit) checks the fake tetherd the
#                   headless sessions use against the same fixture
#   wallpaper-sets  display roles + set resolution (src/services/wallsets.js), against the
#                   fixture tests/test_wallsets.py checks cli/loft/wallsets.py with
#   workspace-wallpapers  which per-workspace wallpaper surfaces exist (src/services/
#                   wswallpapers.js): active ± 1, the overview's zoom, the grace period
#   island-paging   the Dynamic Island's wheel / swipe paging (src/island/paging.js: one
#                   page per notch or swipe) and that its WheelHandlers take every device
#                   and both axes
#   app-icons       app icon candidates (src/services/appicons.js): names deduplicated,
#                   each themed lookup once (misses too), order-independent entry signature
#   launcher-bangs  Spotlight's bangs provider in a real elephant; building loft-elephant for it
#                   also runs the calculator + commands providers' Go tests (units, time
#                   zones, scoring, script metadata/arguments)
#
# After an intended output change, refresh the goldens from a checkout:
#   for t in tokyonight latte; do rm -rf tests/golden/$t; LOFT_THEME_INDEX=none nix run .#loft -- theme render themes/$t tests/golden/$t; done
{ lib, ... }:
{
  perSystem =
    { pkgs, self', ... }:
    let
      loft = lib.getExe self'.packages.loft;
      builtin = self'.packages.loft-themes-builtin;
      fixture = ../tests/fixtures/glassless;
      python = pkgs.python3.withPackages (ps: [ ps.jsonschema ]);
      testSrc = lib.fileset.toSource {
        root = ../.;
        fileset = lib.fileset.unions [
          ../cli
          ../templates
          ../themes
          ../packs
          ../schemas
          ../spicetify
          ../tests
          ../schemas
          ../spaces
          # tests/test_parity.py: the shell binds' generated block, and the
          # binds niri already has.
          ../niri/shell-binds.kdl.in
          ../niri/base.kdl
        ];
      };
      check =
        name: nativeBuildInputs: script:
        pkgs.runCommand name { inherit nativeBuildInputs; } script;
    in
    {
      checks = {
        theme-schema = check "theme-schema" [ ] ''
          ${loft} theme validate ${../themes}/tokyonight ${../themes}/latte ${fixture}
          touch $out
        '';

        theme-unit = check "theme-unit" [
          pkgs.git
          pkgs.ffmpeg # tests/test_systools.py: a real Make GIF run; test_capture.py: a zoomed export
        ] ''
          export HOME=$TMPDIR LOFT_THEME_INDEX=none
          cd ${testSrc}
          PYTHONPATH=cli PYTHONDONTWRITEBYTECODE=1 ${python}/bin/python3 -m unittest discover -s tests -v
          touch $out
        '';

        theme-golden = check "theme-golden" [ pkgs.diffutils ] ''
          for t in tokyonight latte; do
            diff -ru ${../tests/golden}/$t ${builtin}/$t
          done
          # The facet model's regression gate: the built-in `loft` theme (and
          # the old names, now aliases) renders exactly what the v1 packs did.
          export HOME=$TMPDIR LOFT_THEME_INDEX=none LOFT_LIBRARY=none LOFT_STATE_DIR=$TMPDIR/state
          for pair in loft@dark:tokyonight loft@light:latte tokyonight:tokyonight latte:latte; do
            ${loft} theme render "''${pair%%:*}" "out-''${pair%%:*}"
            diff -ru ${../tests/golden}/''${pair##*:} "out-''${pair%%:*}"
          done
          touch $out
        '';

        niri-config = check "niri-config" [ pkgs.niri ] ''
          export HOME=$TMPDIR LOFT_THEME_INDEX=none
          ${loft} theme render ${fixture} glassless
          # Motion and shape render into niri.kdl too: check a customized look.
          export LOFT_THEME_INDEX=none LOFT_LIBRARY=none LOFT_STATE_DIR=$TMPDIR/state LOFT_HOOKS=none
          ${loft} motion set niri '{"workspace-switch":{"spring":{"damping-ratio":1.0,"stiffness":1000,"epsilon":0.0001}},"window-open":{"duration-ms":150,"curve":"ease-out-expo"},"window-close":{"off":true},"window-resize":{"duration-ms":200,"curve":["cubic-bezier",0.05,0.7,0.1,1.0]}}' --no-apply
          ${loft} motion set speed 1.5 --no-apply
          ${loft} shape set focus '"ring"' --no-apply
          ${loft} shape set gaps 8 --no-apply
          ${loft} shape set border.enabled true --no-apply
          ${loft} theme render loft custom
          ${loft} motion apply motion:minimal --no-apply
          ${loft} shape set focus '"both"' --no-apply
          ${loft} theme render loft@light custom-minimal
          grep -q 'slowdown 0.666667' custom/niri.kdl
          grep -q '^    off$' custom-minimal/niri.kdl
          # The Transparency / Blur dials: the most frosted blur, then none.
          ${loft} theme apply loft >/dev/null
          ${loft} appearance set transparency=1 blur=1 >/dev/null
          ${loft} theme render loft frosted
          ${loft} appearance blur 0 >/dev/null
          ${loft} theme render loft clear
          grep -q '^    passes 4$' frosted/niri.kdl
          grep -A1 '^blur {' clear/niri.kdl | grep -q '^    off$'
          for t in ${builtin}/tokyonight ${builtin}/latte $PWD/glassless $PWD/custom $PWD/custom-minimal $PWD/frosted $PWD/clear; do
            printf 'include "%s"\ninclude "%s"\n' ${../niri}/base.kdl "$t/niri.kdl" > config.kdl
            echo "niri validate: base.kdl + $t/niri.kdl"
            niri validate -c config.kdl
          done
          # The shell's binds (with the macOS parity block, PLAN §5) on top.
          sed 's|@IPC@|"qs" "ipc" "call"|g' ${../niri/shell-binds.kdl.in} > shell-binds.kdl
          printf 'include "%s"\ninclude "%s"\n' ${../niri}/base.kdl "$PWD/shell-binds.kdl" > config.kdl
          echo "niri validate: base.kdl + shell-binds.kdl"
          niri validate -c config.kdl
          touch $out
        '';

        niri-workspace-layers = check "niri-workspace-layers" [ ] ''
          export HOME=$TMPDIR
          printf 'include "%s"\ninclude "%s"\ninclude "%s"\n' ${../niri}/base.kdl ${../niri/workspace-wallpapers.kdl} ${../niri/title-bar.kdl} > config.kdl
          echo "niri-loft validate: base.kdl + workspace-wallpapers.kdl + title-bar.kdl"
          ${lib.getExe self'.packages.niri-loft} validate -c config.kdl
          # …and each theme's title bar colors after them, as the sessions do.
          for t in ${builtin}/tokyonight ${builtin}/latte; do
            printf 'include "%s"\ninclude "%s"\n' "$PWD/config.kdl" "$t/niri-loft.kdl" > themed.kdl
            echo "niri-loft validate: … + $t/niri-loft.kdl"
            ${lib.getExe self'.packages.niri-loft} validate -c themed.kdl
          done
          if ${lib.getExe pkgs.niri} validate -c config.kdl 2>/dev/null; then
            echo "stock niri accepted place-within-workspace: the session gate is stale" >&2
            exit 1
          fi
          touch $out
        '';

        clipboard-urlclean = check "clipboard-urlclean" [ pkgs.nodejs-slim ] ''
          node ${../tests/urlclean.test.js} ${../src/services/urlclean.js}
          touch $out
        '';

        spicetify-live = check "spicetify-live" [ pkgs.nodejs-slim ] ''
          node ${../tests/spicetify-live.test.js} ${../spicetify/loft-live.js}
          touch $out
        '';

        phone-protocol = check "phone-protocol" [ pkgs.nodejs-slim ] ''
          node ${../tests/phone.test.js} ${../src/services/phone.js} ${../tests/fixtures/tether/session.jsonl}
          touch $out
        '';

        wallpaper-sets = check "wallpaper-sets" [ pkgs.nodejs-slim ] ''
          node ${../tests/wallsets.test.js} ${../src/services/wallsets.js} ${../tests/fixtures/wallsets/layouts.json}
          touch $out
        '';

        app-icons = check "app-icons" [ pkgs.nodejs-slim ] ''
          node ${../tests/appicons.test.js} ${../src/services/appicons.js}
          touch $out
        '';

        workspace-icons = check "workspace-icons" [ pkgs.nodejs-slim ] ''
          node ${../tests/wsicons.test.js} ${../src/services/wsicons.js}
          touch $out
        '';

        workspace-wallpapers = check "workspace-wallpapers" [ pkgs.nodejs-slim ] ''
          node ${../tests/wswallpapers.test.js} ${../src/services/wswallpapers.js}
          touch $out
        '';

        island-paging = check "island-paging" [ pkgs.nodejs-slim ] ''
          node ${../tests/island-paging.test.js} ${../src/island/paging.js} ${../src/island/Island.qml}
          touch $out
        '';

        loft-niri = self'.packages.loft-niri;

        loft-niri-clippy = self'.packages.loft-niri.overrideAttrs (old: {
          pname = "loft-niri-clippy";
          nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.clippy ];
          dontCargoBuild = true;
          doCheck = false;
          buildPhase = ''
            cargo clippy --offline -p loft-niri --all-targets -- -D warnings
          '';
          installPhase = "touch $out";
        });

        loft-appmenu = self'.packages.loft-appmenu;

        loft-appmenu-clippy = self'.packages.loft-appmenu.overrideAttrs (old: {
          pname = "loft-appmenu-clippy";
          nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.clippy ];
          dontCargoBuild = true;
          doCheck = false;
          buildPhase = ''
            cargo clippy --offline -p loft-appmenu --all-targets -- -D warnings
          '';
          installPhase = "touch $out";
        });

        loft-sleep = self'.packages.loft-sleep;

        loft-sleep-clippy = self'.packages.loft-sleep.overrideAttrs (old: {
          pname = "loft-sleep-clippy";
          nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.clippy ];
          dontCargoBuild = true;
          doCheck = false;
          buildPhase = ''
            cargo clippy --offline -p loft-sleep --all-targets -- -D warnings
          '';
          installPhase = "touch $out";
        });

        loft-input = self'.packages.loft-input;

        loft-input-clippy = self'.packages.loft-input.overrideAttrs (old: {
          pname = "loft-input-clippy";
          nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.clippy ];
          dontCargoBuild = true;
          doCheck = false;
          buildPhase = ''
            cargo clippy --offline -p loft-input --all-targets -- -D warnings
          '';
          postInstall = "";
          installPhase = "touch $out";
        });

        # Spotlight's bangs provider against a real elephant (only that
        # provider loaded): ranking, scopes, quicklinks, URL filling.
        launcher-bangs = check "launcher-bangs" [ pkgs.python3 ] ''
          export HOME=$TMPDIR XDG_RUNTIME_DIR=$TMPDIR/run XDG_CONFIG_HOME=$TMPDIR/cfg XDG_CACHE_HOME=$TMPDIR/cache
          cfg=$XDG_CONFIG_HOME/elephant
          mkdir -p $XDG_RUNTIME_DIR $cfg
          el=${self'.packages.loft-elephant}
          ignored=$(cd $el/lib/elephant/providers && ls *.so | sed 's/\.so$//' | grep -vx bangs | sed 's/.*/"&"/' | paste -sd, -)
          echo "ignored_providers = [$ignored]" > $cfg/elephant.toml
          printf '#!/bin/sh\necho "$1" >> %s\n' $TMPDIR/opened > $TMPDIR/open
          chmod +x $TMPDIR/open
          {
            echo 'data = "${self'.packages.loft-bangs}/bangs.json"'
            echo "settings = \"$TMPDIR/spotlight.json\""
            echo 'defaults = "${../launcher/spotlight-defaults.json}"'
            echo "command = \"$TMPDIR/open\""
            echo 'favicons = false'
          } > $cfg/bangs.toml
          $el/bin/elephant > elephant.log 2>&1 &
          for _ in $(seq 1 100); do [ -S $XDG_RUNTIME_DIR/elephant/elephant.sock ] && break; sleep 0.1; done
          python3 ${../tests/bangs_provider.py} $el/bin/elephant $TMPDIR/opened || { cat elephant.log; exit 1; }
          kill %1
          touch $out
        '';

        ghostty-config = check "ghostty-config" [ pkgs.ghostty ] ''
          export HOME=$TMPDIR
          for t in ${builtin}/tokyonight ${builtin}/latte; do
            ghostty +validate-config --config-file="$t/ghostty.conf"
          done
          touch $out
        '';
      };
    };
}
