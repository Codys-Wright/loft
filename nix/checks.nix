# `nix flake check`: theme engine tests.
#
#   theme-schema    built-in packs (and the test fixture) match themes/schema.json
#   theme-unit      tests/test_*.py: renderer + manager against scratch dirs, the
#                   cozytile:/qylock: importers against local fake upstream repos, and
#                   vibes (pack collections, ranking, index links) — all offline
#   theme-golden    rendering the built-ins reproduces tests/golden/ byte for byte
#   niri-config     base.kdl + each rendered niri.kdl passes `niri validate`
#   ghostty-config  each rendered ghostty.conf passes `ghostty +validate-config`
#   studio-niri     the crate builds and its tests pass (incl. `niri validate`)
#   studio-niri-clippy  `cargo clippy --all-targets -D warnings`
#   studio-appmenu  the global menu daemon builds and its tests pass
#   studio-appmenu-clippy  the same clippy gate for it
#   studio-input    the test driver builds and its tests pass (keymaps, combos,
#                   script parsing, bind lookup, screenshot geometry)
#   studio-input-clippy  the same clippy gate for it
#   clipboard-urlclean  Clean URL's tracking-parameter stripping (src/services/urlclean.js)
#   wallpaper-sets  display roles + set resolution (src/services/wallsets.js), against the
#                   fixture tests/test_wallsets.py checks cli/studio/wallsets.py with
#
# After an intended output change, refresh the goldens from a checkout:
#   for t in tokyonight latte; do rm -rf tests/golden/$t; STUDIO_THEME_INDEX=none nix run .#studio -- theme render themes/$t tests/golden/$t; done
{ lib, ... }:
{
  perSystem =
    { pkgs, self', ... }:
    let
      studio = lib.getExe self'.packages.studio;
      builtin = self'.packages.studio-themes-builtin;
      fixture = ../tests/fixtures/glassless;
      python = pkgs.python3.withPackages (ps: [ ps.jsonschema ]);
      testSrc = lib.fileset.toSource {
        root = ../.;
        fileset = lib.fileset.unions [
          ../cli
          ../templates
          ../themes
          ../tests
        ];
      };
      check =
        name: nativeBuildInputs: script:
        pkgs.runCommand name { inherit nativeBuildInputs; } script;
    in
    {
      checks = {
        theme-schema = check "theme-schema" [ ] ''
          ${studio} theme validate ${../themes}/tokyonight ${../themes}/latte ${fixture}
          touch $out
        '';

        theme-unit = check "theme-unit" [ pkgs.git ] ''
          export HOME=$TMPDIR STUDIO_THEME_INDEX=none
          cd ${testSrc}
          PYTHONPATH=cli PYTHONDONTWRITEBYTECODE=1 ${python}/bin/python3 -m unittest discover -s tests -v
          touch $out
        '';

        theme-golden = check "theme-golden" [ pkgs.diffutils ] ''
          for t in tokyonight latte; do
            diff -ru ${../tests/golden}/$t ${builtin}/$t
          done
          touch $out
        '';

        niri-config = check "niri-config" [ pkgs.niri ] ''
          export HOME=$TMPDIR STUDIO_THEME_INDEX=none
          ${studio} theme render ${fixture} glassless
          for t in ${builtin}/tokyonight ${builtin}/latte $PWD/glassless; do
            printf 'include "%s"\ninclude "%s"\n' ${../niri}/base.kdl "$t/niri.kdl" > config.kdl
            echo "niri validate: base.kdl + $t/niri.kdl"
            niri validate -c config.kdl
          done
          touch $out
        '';

        clipboard-urlclean = check "clipboard-urlclean" [ pkgs.nodejs-slim ] ''
          node ${../tests/urlclean.test.js} ${../src/services/urlclean.js}
          touch $out
        '';

        wallpaper-sets = check "wallpaper-sets" [ pkgs.nodejs-slim ] ''
          node ${../tests/wallsets.test.js} ${../src/services/wallsets.js} ${../tests/fixtures/wallsets/layouts.json}
          touch $out
        '';

        studio-niri = self'.packages.studio-niri;

        studio-niri-clippy = self'.packages.studio-niri.overrideAttrs (old: {
          pname = "studio-niri-clippy";
          nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.clippy ];
          dontCargoBuild = true;
          doCheck = false;
          buildPhase = ''
            cargo clippy --offline -p studio-niri --all-targets -- -D warnings
          '';
          installPhase = "touch $out";
        });

        studio-appmenu = self'.packages.studio-appmenu;

        studio-appmenu-clippy = self'.packages.studio-appmenu.overrideAttrs (old: {
          pname = "studio-appmenu-clippy";
          nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.clippy ];
          dontCargoBuild = true;
          doCheck = false;
          buildPhase = ''
            cargo clippy --offline -p studio-appmenu --all-targets -- -D warnings
          '';
          installPhase = "touch $out";
        });

        studio-input = self'.packages.studio-input;

        studio-input-clippy = self'.packages.studio-input.overrideAttrs (old: {
          pname = "studio-input-clippy";
          nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.clippy ];
          dontCargoBuild = true;
          doCheck = false;
          buildPhase = ''
            cargo clippy --offline -p studio-input --all-targets -- -D warnings
          '';
          postInstall = "";
          installPhase = "touch $out";
        });

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
