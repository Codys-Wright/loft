# studio-linux packages.
#
#   studio                 the CLI: theme engine (render) + manager (cli/studio)
#   studio-themes-builtin  the built-in packs, rendered by that same CLI
#   studio-shell           the Quickshell shell (./src) with its runtime deps on PATH
#   studio-session         niri + studio's base config + the shell, all from the store
#   studio-dev             the same session, loading niri fragments, QML, templates
#                          and themes from a checkout so everything hot-reloads
#   studio-niri            niri settings backend (crates/studio-niri): live outputs,
#                          runtime overrides → <state>/overrides/niri.kdl, keybinds
#
# Both sessions include <state>/overrides/niri.kdl FIRST (niri uses the first
# `output` block matching a monitor, so output overrides must come first) and
# LAST (every other section merges, later wins). Both expose their entry
# config as $STUDIO_NIRI_CONFIG, since niri hides $NIRI_CONFIG from children.
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
        wf-recorder # Screen recording
        gawk # System Monitor: processes (/proc/<pid>/stat)
        gnugrep # System Monitor: hwmon sensors
        iproute2 # Network: local addresses (ip -j addr)
        librespeed-cli # Network: speed test (on demand)
        walker # Spotlight launcher (frontend)
        elephant # launcher data providers
        jq
        coreutils
        cliphist # Clipboard history (recorder + store)
        wl-clipboard # wl-copy / wl-paste: clipboard history, plain-text paste, Clean URL
        wtype # paste / snippet expansion into the focused app
        xdg-utils # Shelf: open parked files and links
        inotify-tools # dev loop: reload after a failed reload (devtools/ReloadToast)
      ];

      # The CLI's own tree: Python package + templates + built-in packs/schema.
      cliSrc = lib.fileset.toSource {
        root = ../.;
        fileset = lib.fileset.unions [
          ../cli
          ../templates
          ../themes
        ];
      };

      # Fonts the shell loads directly (FontLoader), so it looks the same on
      # any machine regardless of installed fonts.
      uiFont = "${pkgs.inter}/share/fonts/truetype/InterVariable.ttf";
      iconFont = "${pkgs.nerd-fonts.symbols-only}/share/fonts/truetype/NerdFonts/Symbols/SymbolsNerdFont-Regular.ttf";

      # Shell keybinds for the packaged session: the IPC command targets the
      # store copy of the shell (studio-dev renders its own for the checkout).
      shellBinds = pkgs.runCommand "studio-shell-binds.kdl" { } ''
        sed 's|@IPC@|"${lib.getExe pkgs.quickshell}" "ipc" "--path" "${../src}" "call"|g' \
          ${../niri/shell-binds.kdl.in} > $out
      '';

      python = pkgs.python3.withPackages (ps: [ ps.jsonschema ]);

      builtinRendered = self'.packages.studio-themes-builtin;

      # Shared by both sessions: the state dir the shell, niri and `studio`
      # agree on, seeded with the default theme from the store.
      seedState = ''
        state="''${STUDIO_STATE_DIR:-''${XDG_STATE_HOME:-$HOME/.local/state}/studio-linux}"
        export STUDIO_STATE_DIR="$state"
        mkdir -p "$state"
        [ -e "$state/current" ] || ln -sfn ${builtinRendered}/default "$state/current"
      '';
    in
    {
      packages = {
        studio-shell = pkgs.writeShellApplication {
          name = "studio-shell";
          runtimeInputs = runtimeDeps ++ [
            self'.packages.studio
            self'.packages.studio-niri
          ];
          text = ''
            if [ -z "''${STUDIO_THEME_FILE:-}" ]; then
              ${seedState}
              export STUDIO_THEME_FILE="$state/current/theme.json"
            fi
            export STUDIO_UI_FONT="${uiFont}" STUDIO_ICON_FONT="${iconFont}"
            # STUDIO_SHELL_SRC runs the QML from a checkout instead (hot reload);
            # the CLI's IPC hooks must target the same path.
            src="''${STUDIO_SHELL_SRC:-${../src}}"
            export STUDIO_SHELL_PATH="$src"
            exec quickshell --path "$src" "$@"
          '';
        };

        studio-session = pkgs.writeShellApplication {
          name = "studio-session";
          runtimeInputs = runtimeDeps ++ [ self'.packages.studio-launcher ];
          text = ''
            ${seedState}
            # The entry config is written at runtime: the theme fragment lives
            # in the (runtime) state dir. It comes after base.kdl so it wins;
            # niri watches it, including `current` being re-pointed.
            dir="''${XDG_RUNTIME_DIR:-/tmp}/studio-session"
            mkdir -p "$dir"
            cat > "$dir/config.kdl" <<EOF
            include optional=true "$state/overrides/niri.kdl"
            include "${../niri}/base.kdl"
            include "${shellBinds}"
            include optional=true "$state/current/niri.kdl"
            include optional=true "$state/overrides/niri.kdl"
            spawn-at-startup "${lib.getExe self'.packages.studio-shell}"
            spawn-at-startup "${lib.getExe self'.packages.studio-launcher}" "service"
            EOF
            export STUDIO_NIRI_CONFIG="$dir/config.kdl"
            exec niri --config "$dir/config.kdl" "$@"
          '';
        };

        studio-dev = pkgs.writeShellApplication {
          name = "studio-dev";
          runtimeInputs = runtimeDeps ++ [
            self'.packages.studio-launcher
            self'.packages.studio
            self'.packages.studio-niri
          ];
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

            # `studio` run against this session: checkout templates + themes,
            # user-installed packs, state in $dir.
            studio_env=(
              "STUDIO_STATE_DIR=$dir"
              "STUDIO_DATA_DIR=$root"
              "STUDIO_THEME_PATH=''${XDG_DATA_HOME:-$HOME/.local/share}/studio-linux/themes:$root/themes"
              "STUDIO_SHELL_PATH=$root/src"
            )

            sed "s|@IPC@|\"quickshell\" \"ipc\" \"--path\" \"$root/src\" \"call\"|g" \
              "$root/niri/shell-binds.kdl.in" > "$dir/shell-binds.kdl"

            # The active theme: `current` → a rendered theme dir. Kept across
            # restarts (`studio --dev theme apply NAME` switches it); rendered
            # when missing (from the default) or still a raw pack from before
            # the renderer (no niri.kdl; re-rendered, keeping the choice).
            if [ ! -e "$dir/current/niri.kdl" ]; then
              theme=default
              [ -e "$dir/current/theme.json" ] && theme="$(readlink -f "$dir/current")"
              env "''${studio_env[@]}" STUDIO_HOOKS=none ${lib.getExe self'.packages.studio} theme apply "$theme" >/dev/null
            fi

            # The theme fragment comes after base.kdl so it wins, then dev-local,
            # then the runtime overrides (also first: see the header comment).
            cat > "$dir/config.kdl" <<EOF
            include optional=true "$dir/overrides/niri.kdl"
            include "$root/niri/base.kdl"
            include "$dir/shell-binds.kdl"
            include optional=true "$dir/current/niri.kdl"
            include optional=true "$root/niri/dev-local.kdl"
            include optional=true "$dir/overrides/niri.kdl"
            spawn-at-startup "env" "STUDIO_STATE_DIR=$dir" "STUDIO_LAUNCHER_DIR=$root/launcher" "studio-launcher" "service"
            spawn-at-startup "env" "STUDIO_DEV=1" "STUDIO_STATE_DIR=$dir" "STUDIO_DATA_DIR=$root" "STUDIO_THEME_PATH=''${XDG_DATA_HOME:-$HOME/.local/share}/studio-linux/themes:$root/themes" "STUDIO_SHELL_PATH=$root/src" "STUDIO_NIRI_CONFIG=$dir/config.kdl" "STUDIO_THEME_FILE=$dir/current/theme.json" "STUDIO_UI_FONT=${uiFont}" "STUDIO_ICON_FONT=${iconFont}" "quickshell" "--path" "$root/src"
            EOF

            # Live everything, not just QML: `studio` runs the checkout's CLI,
            # and fresh `cargo build` binaries (target/debug) shadow the
            # packaged studio-niri & co. niri — and everything it spawns —
            # inherits this PATH.
            mkdir -p "$dir/bin"
            printf '#!/bin/sh\nexec %s -B "%s" "$@"\n' "${python}/bin/python3" "$root/cli/studio" > "$dir/bin/studio"
            chmod +x "$dir/bin/studio"
            export PATH="$dir/bin:$PATH"
            if [ -d "$root/target/debug" ]; then
              export PATH="$root/target/debug:$PATH"
            fi

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
                printf '%s\n' "''${studio_env[@]}"
              } > "$dir/session.env"
            fi

            # Inside KDE: put the window fullscreen + borderless on one monitor,
            # so the nested session is a real full-size output.
            if [ -n "$output" ]; then
              qdbus="$(command -v qdbus || command -v qdbus6 || true)"
              if [ -z "$qdbus" ]; then
                echo "studio-dev: --output needs KDE's qdbus; ignoring" >&2
              else
                sed -e "s/@OUTPUT@/$output/g" -e "s/@PID@/$niri_pid/g" ${./dev/kwin-place.js} > "$dir/kwin-place.js"
                id="$("$qdbus" org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript "$dir/kwin-place.js" studio-dev-place)"
                "$qdbus" org.kde.KWin "/Scripting/Script$id" org.kde.kwin.Script.run >/dev/null
                # Stay loaded long enough to catch the window being mapped.
                (sleep 5; "$qdbus" org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript studio-dev-place >/dev/null) &
              fi
            fi

            wait "$niri_pid"
          '';
        };

        studio-launcher = pkgs.writeShellApplication {
          name = "studio-launcher";
          runtimeInputs = with pkgs; [
            walker
            elephant
            jq
            coreutils
          ];
          text =
            builtins.replaceStrings
              [ "@LAUNCHER@" "@LAYERSHELL@" ]
              [ "${../launcher}" "${pkgs.gtk4-layer-shell}/lib/libgtk4-layer-shell.so" ]
              (builtins.readFile ../launcher/studio-launcher.sh);
        };

        # One renderer for runtime and build time (Python stdlib + jsonschema):
        # `studio theme render` here is what builds studio-themes-builtin.
        studio = pkgs.stdenvNoCC.mkDerivation {
          pname = "studio";
          version = "0.1.0";
          src = cliSrc;
          nativeBuildInputs = [ pkgs.makeWrapper ];
          dontBuild = true;
          installPhase = ''
            mkdir -p $out/share/studio-linux $out/bin
            cp -r cli templates themes $out/share/studio-linux/
            # Reload hooks call quickshell/niri; installs and importers use git;
            # the qylock importer samples (video) backgrounds with ffmpeg, whose
            # libraries Quickshell's closure already carries. The user's own
            # (newer) ones win on PATH.
            makeWrapper ${python}/bin/python3 $out/bin/studio \
              --add-flags "-B $out/share/studio-linux/cli/studio" \
              --set-default STUDIO_SHELL_PATH ${../src} \
              --suffix PATH : ${
                lib.makeBinPath [
                  pkgs.quickshell
                  pkgs.niri
                  pkgs.git
                  pkgs.ffmpeg-headless
                ]
              }
          '';
          meta.mainProgram = "studio";
        };

        # Built-in packs rendered at build time: <name>/{theme.json,niri.kdl,…}
        # plus the `default` alias. Sessions seed `current` from here.
        studio-themes-builtin = pkgs.runCommand "studio-themes-builtin" { } ''
          mkdir -p $out
          for pack in ${cliSrc}/themes/*/; do
            pack="''${pack%/}"
            [ -L "$pack" ] && continue
            ${lib.getExe self'.packages.studio} theme render "$pack" "$out/$(basename "$pack")"
          done
          ln -s "$(readlink ${cliSrc}/themes/default)" $out/default
        '';

        # niri settings backend for the shell's Displays / Input / Layout /
        # Keybinds pages. Its tests run `niri validate` on rendered fragments.
        studio-niri = pkgs.rustPlatform.buildRustPackage {
          pname = "studio-niri";
          version = "0.1.0";
          src = lib.fileset.toSource {
            root = ../.;
            fileset = lib.fileset.unions [
              ../Cargo.toml
              ../Cargo.lock
              ../crates
            ];
          };
          cargoLock.lockFile = ../Cargo.lock;
          nativeCheckInputs = [ pkgs.niri ];
          meta.mainProgram = "studio-niri";
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
