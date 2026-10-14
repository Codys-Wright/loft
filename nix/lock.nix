# Lock screen + login greeter (PLAN §4.5).
#
#   loft-sddm-theme    the `loft` SDDM theme: $out/share/sddm/themes/loft
#   greeter-preview    `nix run .#greeter-preview` — the greeter in SDDM's test mode
#
# The Quickshell lock itself ships with the shell (src/lock/). The SDDM theme
# reuses its design: src/lock/design + the glass components are copied in
# with Quickshell's `qs.*` module imports rewritten to relative directory
# imports, and lock/sddm/services/Theme.qml stands in for the shell's Theme.
{ lib, ... }:
{
  perSystem =
    { pkgs, self', ... }:
    let
      uiFont = "${pkgs.inter}/share/fonts/truetype/InterVariable.ttf";
      iconFont = "${pkgs.nerd-fonts.symbols-only}/share/fonts/truetype/NerdFonts/Symbols/SymbolsNerdFont-Regular.ttf";

      sddm = pkgs.kdePackages.sddm;

      loft-sddm-theme = pkgs.runCommand "loft-sddm-theme" { } ''
        dir=$out/share/sddm/themes/loft
        mkdir -p $dir/design $dir/components $dir/services $dir/fonts $dir/default

        cp ${../lock/sddm}/{Main.qml,metadata.desktop,theme.conf} $dir/
        cp ${../lock/sddm/services}/{qmldir,Theme.qml} $dir/services/
        cp ${../themes/default/theme.json} $dir/default/theme.json
        cp ${uiFont} $dir/fonts/InterVariable.ttf
        cp ${iconFont} $dir/fonts/SymbolsNerdFont-Regular.ttf

        # qs.<dir> → "../<dir>": every file lands one level below the theme root.
        share() { sed -E 's|^import qs\.([a-z]+)$|import "../\1"|' "$1" > "$2"; }
        for f in ${../src/lock/design}/*.qml; do share "$f" $dir/design/"$(basename "$f")"; done
        for c in GlassSurface Icon; do share ${../src/components}/$c.qml $dir/components/$c.qml; done

        # The design must stay host-agnostic: no Quickshell, and only the
        # modules provided above.
        if grep -rnE '^import (Quickshell|qs\.)' $dir; then
          echo "loft-sddm-theme: the shared lock design imports something sddm-greeter lacks" >&2
          exit 1
        fi
        for imp in $(grep -rhoE '^import "\.\./[a-z]+"' $dir | sort -u | sed -E 's|.*/([a-z]+)"|\1|'); do
          [ -d $dir/$imp ] || { echo "loft-sddm-theme: missing shared module $imp" >&2; exit 1; }
        done
      '';

      greeter-preview = pkgs.writeShellApplication {
        name = "loft-greeter-preview";
        runtimeInputs = [ sddm ];
        text = ''
          # Reading theme.json from QML needs this (also set it in the real
          # greeter's environment, see README).
          export QML_XHR_ALLOW_FILE_READ=1
          exec sddm-greeter-qt6 --test-mode --theme "''${1:-${loft-sddm-theme}/share/sddm/themes/loft}"
        '';
      };
    in
    {
      packages = {
        inherit loft-sddm-theme;
        loft-greeter-preview = greeter-preview;
      };

      apps.greeter-preview = {
        type = "app";
        program = lib.getExe greeter-preview;
        meta.description = "Preview the Loft login screen (SDDM test mode, opens a window)";
      };

      checks.loft-sddm-theme = loft-sddm-theme;
    };
}
