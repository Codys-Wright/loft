# Lock screen + login greeter (PLAN §4.5).
#
#   loft-sddm-theme    the `loft` SDDM theme: $out/share/sddm/themes/loft
#   loft-plasma-lockscreen  Plasma's lock screen with the same design: the shell
#                      package $out/share/plasma/shells/dev.loft.desktop
#   loft-greeter-install  the privileged helper `loft greeter sync` runs through
#                      pkexec (cli/loft/greeter_helper.py; nix/modules/nixos.nix
#                      installs it with its polkit rule)
#   greeter-preview    `nix run .#greeter-preview [THEME_DIR]` — the greeter in SDDM's
#                      test mode; LOFT_GREETER_PACK=DIR previews it with that pack dir
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

      # The shared design into $dir: design/ + components/ (with `qs.*`
      # imports rewritten), services/Theme.qml (the stand-in), the fonts and
      # the bundled default theme. Fails if the design needs anything a
      # non-Quickshell host lacks. Used by the SDDM theme and Plasma's locker.
      shareDesign = name: dir: ''
        mkdir -p ${dir}/design ${dir}/components ${dir}/services ${dir}/fonts ${dir}/default
        cp ${../lock/sddm/services}/{qmldir,Theme.qml} ${dir}/services/
        cp ${../themes/default/theme.json} ${dir}/default/theme.json
        cp ${uiFont} ${dir}/fonts/InterVariable.ttf
        cp ${iconFont} ${dir}/fonts/SymbolsNerdFont-Regular.ttf

        # qs.<dir> → "../<dir>": every file lands one level below the root.
        share() { sed -E 's|^import qs\.([a-z]+)$|import "../\1"|' "$1" > "$2"; }
        for f in ${../src/lock/design}/*.qml; do share "$f" ${dir}/design/"$(basename "$f")"; done
        for c in GlassSurface Icon; do share ${../src/components}/$c.qml ${dir}/components/$c.qml; done

        # The design must stay host-agnostic: no Quickshell, and only the
        # modules provided above.
        if grep -rnE '^import (Quickshell|qs\.)' ${dir}; then
          echo "${name}: the shared lock design imports something the host lacks" >&2
          exit 1
        fi
        for imp in $(grep -rhoE '^import "(\.\./)?[a-z]+"' ${dir} | sort -u | sed -E 's|.*"(\.\./)?([a-z]+)"|\2|'); do
          [ -d ${dir}/$imp ] || { echo "${name}: missing shared module $imp" >&2; exit 1; }
        done
      '';

      loft-sddm-theme = pkgs.runCommand "loft-sddm-theme" { } ''
        dir=$out/share/sddm/themes/loft
        mkdir -p $dir
        cp ${../lock/sddm}/{Main.qml,metadata.desktop,theme.conf} $dir/
        ${shareDesign "loft-sddm-theme" "$dir"}
      '';

      # Plasma's locker with Loft's design (docs/KWIN.md §4.3): the shell
      # package dev.loft.desktop, holding only lockscreen/ (KPackage falls
      # back to org.kde.plasma.desktop for the rest). kscreenlocker_greet
      # loads it when PLASMA_DEFAULT_SHELL=dev.loft.desktop (the home-manager
      # module sets that on KWin's unit in Loft sessions).
      loft-plasma-lockscreen = pkgs.runCommand "loft-plasma-lockscreen" { } ''
        pkg=$out/share/plasma/shells/dev.loft.desktop
        dir=$pkg/contents/lockscreen
        mkdir -p $dir
        cp ${../lock/plasma/metadata.json} $pkg/metadata.json
        cp ${../lock/plasma/contents/lockscreen}/*.qml $dir/
        ${shareDesign "loft-plasma-lockscreen" "$dir"}
      '';

      # QML modules pack designs (qylock / SDDM themes) import beyond what
      # sddm-greeter brings; the NixOS module adds the same as sddm's extraPackages.
      greeterQmlPackages = [
        pkgs.kdePackages.qt5compat
        pkgs.kdePackages.qtmultimedia
        pkgs.kdePackages.qtsvg
      ];

      loft-greeter-install =
        pkgs.runCommand "loft-greeter-install" { meta.mainProgram = "loft-greeter-install"; }
          ''
            mkdir -p $out/bin
            { echo "#!${pkgs.python3}/bin/python3 -IB"; cat ${../cli/loft/greeter_helper.py}; } > $out/bin/loft-greeter-install
            chmod +x $out/bin/loft-greeter-install
          '';

      greeter-preview = pkgs.writeShellApplication {
        name = "loft-greeter-preview";
        runtimeInputs = [ sddm ];
        text = ''
          # Reading theme.json from QML needs this (also set it in the real
          # greeter's environment, see README).
          export QML_XHR_ALLOW_FILE_READ=1
          export QML_IMPORT_PATH="${
            lib.concatMapStringsSep ":" (p: "${p}/lib/qt-6/qml") greeterQmlPackages
          }''${QML_IMPORT_PATH:+:$QML_IMPORT_PATH}"
          export QT_PLUGIN_PATH="${pkgs.kdePackages.qtmultimedia}/lib/qt-6/plugins''${QT_PLUGIN_PATH:+:$QT_PLUGIN_PATH}"
          theme="''${1:-${loft-sddm-theme}/share/sddm/themes/loft}"
          # LOFT_GREETER_PACK=DIR: a copy of the theme reading that pack dir
          # instead of /var/lib/loft/greeter (e.g. one `loft greeter sync` made).
          if [ -n "''${LOFT_GREETER_PACK:-}" ]; then
            tmp=$(mktemp -d)
            trap 'rm -rf "$tmp"' EXIT
            cp -r "$theme"/. "$tmp"/
            chmod -R u+w "$tmp"
            sed -i "s|^packDir=.*|packDir=$LOFT_GREETER_PACK|" "$tmp/theme.conf"
            theme=$tmp
            sddm-greeter-qt6 --test-mode --theme "$theme"
            exit
          fi
          exec sddm-greeter-qt6 --test-mode --theme "$theme"
        '';
      };
    in
    {
      packages = {
        inherit loft-sddm-theme loft-greeter-install loft-plasma-lockscreen;
        loft-greeter-preview = greeter-preview;
      };

      apps.greeter-preview = {
        type = "app";
        program = lib.getExe greeter-preview;
        meta.description = "Preview the Loft login screen (SDDM test mode, opens a window)";
      };

      checks.loft-sddm-theme = loft-sddm-theme;
      checks.loft-plasma-lockscreen = loft-plasma-lockscreen;
    };
}
