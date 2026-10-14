# `nix flake check`: theme engine tests.
#
#   theme-schema    built-in packs (and the test fixture) match themes/schema.json
#   theme-unit      tests/test_studio.py: renderer + manager against scratch dirs
#   theme-golden    rendering the built-ins reproduces tests/golden/ byte for byte
#   niri-config     base.kdl + each rendered niri.kdl passes `niri validate`
#   ghostty-config  each rendered ghostty.conf passes `ghostty +validate-config`
#
# After an intended output change, refresh the goldens from a checkout:
#   for t in tokyonight latte; do rm -rf tests/golden/$t; nix run .#studio -- theme render themes/$t tests/golden/$t; done
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
          export HOME=$TMPDIR
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
          export HOME=$TMPDIR
          ${studio} theme render ${fixture} glassless
          for t in ${builtin}/tokyonight ${builtin}/latte $PWD/glassless; do
            printf 'include "%s"\ninclude "%s"\n' ${../niri}/base.kdl "$t/niri.kdl" > config.kdl
            echo "niri validate: base.kdl + $t/niri.kdl"
            niri validate -c config.kdl
          done
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
