# studio-linux packages.
#
#   studio-shell    the Quickshell shell (./src) with its runtime deps on PATH
#   studio-session  niri + studio's base config + the shell, all from the store
#   studio-dev      the same session, loading niri fragments, QML and themes
#                   from a checkout so niri and Quickshell hot-reload on save
#
# Both sessions run nested as a window when started inside a Wayland/X11
# session (niri's winit backend), or as a full session from a TTY.
{ lib, ... }:
{
  perSystem =
    { pkgs, self', ... }:
    let
      # Programs the shell and the base niri config call at runtime.
      runtimeDeps = with pkgs; [
        quickshell
        niri
        foot # the demo session's terminal (Mod+Return); consumers bind their own
        gammastep # Night Light
        coreutils
      ];

      builtinThemes = ../themes;

      # Fonts the shell loads directly (FontLoader), so it looks the same on
      # any machine regardless of installed fonts.
      uiFont = "${pkgs.inter}/share/fonts/truetype/InterVariable.ttf";
      iconFont = "${pkgs.nerd-fonts.symbols-only}/share/fonts/truetype/NerdFonts/Symbols/SymbolsNerdFont-Regular.ttf";

      # One niri config tree in the store: studio's base fragments plus a
      # session entry that starts the shell.
      sessionConfig = pkgs.runCommand "studio-niri-config" { } ''
        mkdir -p $out
        cp ${../niri}/*.kdl $out/
        sed 's|@IPC@|"${lib.getExe pkgs.quickshell}" "ipc" "--path" "${../src}" "call"|g' \
          ${../niri/shell-binds.kdl.in} > $out/shell-binds.kdl
        cat > $out/config.kdl <<EOF
        include "base.kdl"
        include "shell-binds.kdl"
        spawn-at-startup "${lib.getExe self'.packages.studio-shell}"
        EOF
      '';
    in
    {
      packages = {
        studio-shell = pkgs.writeShellApplication {
          name = "studio-shell";
          runtimeInputs = runtimeDeps;
          text = ''
            state="''${STUDIO_STATE_DIR:-''${XDG_STATE_HOME:-$HOME/.local/state}/studio-linux}"
            if [ -z "''${STUDIO_THEME_FILE:-}" ]; then
              mkdir -p "$state"
              [ -e "$state/current" ] || ln -sfn ${builtinThemes}/default "$state/current"
              export STUDIO_THEME_FILE="$state/current/theme.json"
            fi
            export STUDIO_UI_FONT="${uiFont}" STUDIO_ICON_FONT="${iconFont}"
            exec quickshell --path ${../src} "$@"
          '';
        };

        studio-session = pkgs.writeShellApplication {
          name = "studio-session";
          runtimeInputs = runtimeDeps;
          text = ''
            exec niri --config ${sessionConfig}/config.kdl "$@"
          '';
        };

        studio-dev = pkgs.writeShellApplication {
          name = "studio-dev";
          runtimeInputs = runtimeDeps;
          text = ''
            usage() { echo "usage: studio-dev [--output NAME] [CHECKOUT]" >&2; exit 2; }
            output=""
            root=""
            while [ $# -gt 0 ]; do
              case "$1" in
                --output) [ $# -ge 2 ] || usage; output="$2"; shift 2 ;;
                -h|--help) usage ;;
                *) root="$1"; shift ;;
              esac
            done
            root="$(realpath "''${root:-$PWD}")"
            if [ ! -f "$root/src/shell.qml" ] || [ ! -f "$root/niri/base.kdl" ]; then
              echo "studio-dev: $root is not a studio-linux checkout (pass its path, or run from inside it)" >&2
              exit 1
            fi

            # The entry config lives outside the checkout; it includes the live
            # fragments by absolute path, so niri watches and reloads them.
            dir="''${XDG_RUNTIME_DIR:-/tmp}/studio-dev"
            mkdir -p "$dir"

            # The active theme is a symlink to a theme dir; re-pointing it
            # recolors the running shell (what `studio theme apply` will do).
            # Kept across restarts; reset with `ln -sfn "$root/themes/NAME" "$dir/current"`.
            [ -e "$dir/current" ] || ln -sfn "$(realpath "$root/themes/default")" "$dir/current"

            sed "s|@IPC@|\"quickshell\" \"ipc\" \"--path\" \"$root/src\" \"call\"|g" \
              "$root/niri/shell-binds.kdl.in" > "$dir/shell-binds.kdl"

            cat > "$dir/config.kdl" <<EOF
            include "$root/niri/base.kdl"
            include "$dir/shell-binds.kdl"
            include optional=true "$root/niri/dev-local.kdl"
            spawn-at-startup "env" "STUDIO_THEME_FILE=$dir/current/theme.json" "STUDIO_UI_FONT=${uiFont}" "STUDIO_ICON_FONT=${iconFont}" "quickshell" "--path" "$root/src"
            EOF

            echo "studio-dev: niri config $dir/config.kdl, shell from $root/src"
            niri --config "$dir/config.kdl" &
            niri_pid=$!
            trap 'kill $niri_pid 2>/dev/null' INT TERM

            # Record how to reach this session (used by `nix run .#shot`).
            sock=""
            for _ in $(seq 1 50); do
              for s in "''${XDG_RUNTIME_DIR:-/tmp}"/niri.wayland-*."$niri_pid".sock; do
                [ -S "$s" ] && sock="$s"
              done
              [ -n "$sock" ] && break
              sleep 0.2
            done
            if [ -n "$sock" ]; then
              display="$(basename "$sock" | cut -d. -f2)"
              {
                printf 'NIRI_SOCKET=%s\nWAYLAND_DISPLAY=%s\n' "$sock" "$display"
                printf 'STUDIO_STATE_DIR=%s\nSTUDIO_THEME_PATH=%s\nSTUDIO_SHELL_PATH=%s\n' "$dir" "$root/themes" "$root/src"
              } > "$dir/session.env"
            fi

            # Inside KDE: put the window fullscreen + borderless on one monitor,
            # so the nested session is a real full-size output.
            if [ -n "$output" ]; then
              qdbus="$(command -v qdbus || command -v qdbus6 || true)"
              if [ -z "$qdbus" ]; then
                echo "studio-dev: --output needs KDE's qdbus; ignoring" >&2
              else
                sed "s/@OUTPUT@/$output/g" ${./dev/kwin-place.js} > "$dir/kwin-place.js"
                id="$("$qdbus" org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript "$dir/kwin-place.js" studio-dev-place)"
                "$qdbus" org.kde.KWin "/Scripting/Script$id" org.kde.kwin.Script.run >/dev/null
                # Stay loaded long enough to catch the window being mapped.
                (sleep 5; "$qdbus" org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript studio-dev-place >/dev/null) &
              fi
            fi

            wait "$niri_pid"
          '';
        };

        studio = pkgs.writeShellApplication {
          name = "studio";
          runtimeInputs = [
            pkgs.quickshell
            pkgs.coreutils
          ];
          text =
            builtins.replaceStrings [ "@BUILTIN_THEMES@" "@SHELL_SRC@" ] [ "${builtinThemes}" "${../src}" ]
              (builtins.readFile ../cli/studio.sh);
        };

        # Screenshot the running studio-dev session: `nix run .#shot -- out.png`.
        studio-shot = pkgs.writeShellApplication {
          name = "studio-shot";
          runtimeInputs = [ pkgs.grim ];
          text = ''
            env="''${XDG_RUNTIME_DIR:-/tmp}/studio-dev/session.env"
            [ -f "$env" ] || { echo "studio-shot: no studio-dev session running" >&2; exit 1; }
            # shellcheck disable=SC1090
            . "$env"
            out="''${1:-studio-$(date +%Y%m%d-%H%M%S).png}"
            WAYLAND_DISPLAY="$WAYLAND_DISPLAY" grim "$out"
            echo "$out"
          '';
        };

        default = self'.packages.studio-session;
      };
    };
}
