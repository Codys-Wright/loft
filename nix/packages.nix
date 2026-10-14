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
#   studio-appmenu         global menu daemon (crates/studio-appmenu): AppMenu registrar
#                          + DBusMenu / org.gtk.Menus reader for the bar
#   studio-input           test driver (crates/studio-input): studio-input (virtual
#                          mouse + keyboard) and studio-shot (screenshots), see
#                          docs/TESTING.md
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
        pipewire # pw-metadata: per-app output (Sound mixer)
        ddcutil # Control Center → Display: external monitor brightness (DDC/CI)
        brightnessctl # Control Center → Display: laptop backlight
        # nmcli (Wi-Fi details, VPNs) and busctl (Bluetooth RSSI) come from the
        # system's NetworkManager / systemd, matching the running daemons.
        # Capture: frozen frames, crop/GIF/trim/mic track, clipboard, annotate.
        grim
        ffmpeg
        satty
        # Text from screen: English OCR (add languages with
        # tesseract.override { enableLanguages = [ … ]; }) and QR codes.
        (tesseract.override { enableLanguages = [ "eng" ]; })
        (zbar.override {
          enableVideo = false;
          withXorg = false;
          enableDbus = false;
        })
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

      # QML modules imported lock designs (qylock / SDDM themes) expect, so they
      # load without a desktop session providing them.
      lockQmlPath = lib.concatMapStringsSep ":" (p: "${p}/lib/qt-6/qml") [
        pkgs.kdePackages.qt5compat
        pkgs.kdePackages.qtmultimedia
        pkgs.kdePackages.sddm.unwrapped
      ];

      # QtMultimedia's plugins for the camera mirror (its QML is in lockQmlPath).
      qtMultimediaEnv = ''
        export QT_PLUGIN_PATH="${pkgs.kdePackages.qtmultimedia}/lib/qt-6/plugins''${QT_PLUGIN_PATH:+:$QT_PLUGIN_PATH}"
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
            self'.packages.studio-appmenu
          ];
          text = ''
            if [ -z "''${STUDIO_THEME_FILE:-}" ]; then
              ${seedState}
              export STUDIO_THEME_FILE="$state/current/theme.json"
            fi
            export STUDIO_UI_FONT="${uiFont}" STUDIO_ICON_FONT="${iconFont}"
            export QML_IMPORT_PATH="${lockQmlPath}''${QML_IMPORT_PATH:+:$QML_IMPORT_PATH}"
            ${qtMultimediaEnv}
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
            self'.packages.studio-appmenu
            self'.packages.studio-input # studio-input / studio-shot inside the session
            pkgs.dbus # dbus-run-session: the private bus of isolated sessions
          ];
          text =
            builtins.replaceStrings
              [
                "@STUDIO@"
                "@PYTHON@"
                "@UI_FONT@"
                "@ICON_FONT@"
                "@LOCK_QML_PATH@"
                "@QT_MM_PLUGINS@"
                "@KWIN_PLACE@"
                "@SWAY@"
                "@MESA_EGL_VENDOR@"
              ]
              [
                (lib.getExe self'.packages.studio)
                "${python}/bin/python3"
                uiFont
                iconFont
                lockQmlPath
                "${pkgs.kdePackages.qtmultimedia}/lib/qt-6/plugins"
                "${./dev/kwin-place.js}"
                (lib.getExe' pkgs.sway-unwrapped "sway")
                "${pkgs.mesa}/share/glvnd/egl_vendor.d/50_mesa.json"
              ]
              (builtins.readFile ./dev/studio-dev.sh);
        };

        # The keyboard layer (keyboard/keys.nix): Esc / Caps tap = Escape,
        # hold = the window-manager key; Super = Cmd for apps. Needs read
        # access to /dev/input and /dev/uinput (the input + uinput groups).
        studio-keys =
          let
            keys = import ../keyboard/keys.nix { inherit lib; };
            config = name: cfg: pkgs.writeText name (builtins.toJSON cfg);
          in
          pkgs.writeShellApplication {
            name = "studio-keys";
            text = ''
              if [ "''${1:-}" = "--dual-role-only" ]; then
                exec ${pkgs.xremap}/bin/xremap --watch=device --mouse ${
                  config "keys-dual.json" (keys {
                    appKeys = false;
                  })
                }
              fi
              exec ${pkgs.xremap.niri}/bin/xremap --watch=device --mouse ${config "keys.json" (keys { })}
            '';
          };

        # DuckDuckGo-style !bangs for Spotlight (!yt lofi, !gh niri, !w …):
        # unduck's bang list (github.com/T3-Content/unduck) → elephant's
        # websearch.toml. Pinned; bump rev + hash to refresh.
        studio-bangs =
          let
            unduck = pkgs.fetchFromGitHub {
              owner = "T3-Content";
              repo = "unduck";
              rev = "c1b821de0ffa286cfd964817d1918c5e90545db4";
              hash = "sha256-w1a5a51uJ2ehzi2ehMh5VIMDBRAjjUz35cA8yi+gBd4=";
            };
          in
          pkgs.runCommand "studio-bangs" { nativeBuildInputs = [ pkgs.python3 ]; } ''
            mkdir -p $out
            python3 ${../launcher/bangs.py} ${unduck}/src/bang.ts $out/websearch.toml
          '';

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
              [ "@LAUNCHER@" "@LAYERSHELL@" "@BANGS@" ]
              [
                "${../launcher}"
                "${pkgs.gtk4-layer-shell}/lib/libgtk4-layer-shell.so"
                "${self'.packages.studio-bangs}/websearch.toml"
              ]
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
            STUDIO_THEME_INDEX=none ${lib.getExe self'.packages.studio} theme render "$pack" "$out/$(basename "$pack")"
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
          cargoBuildFlags = [
            "-p"
            "studio-niri"
          ];
          cargoTestFlags = [
            "-p"
            "studio-niri"
          ];
          nativeCheckInputs = [ pkgs.niri ];
          meta.mainProgram = "studio-niri";
        };

        # Global menu daemon for the bar (src/services/AppMenu.qml runs it).
        studio-appmenu = pkgs.rustPlatform.buildRustPackage {
          pname = "studio-appmenu";
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
          cargoBuildFlags = [
            "-p"
            "studio-appmenu"
          ];
          cargoTestFlags = [
            "-p"
            "studio-appmenu"
          ];
          meta.mainProgram = "studio-appmenu";
        };

        # Test driver for agents (crates/studio-input): `studio-input` — a
        # virtual mouse + keyboard for a session (Wayland virtual-pointer /
        # virtual-keyboard; niri binds via IPC) — and `studio-shot` —
        # screenshots with crop/zoom/grid/marks in global coordinates.
        # See docs/TESTING.md.
        studio-input = pkgs.rustPlatform.buildRustPackage {
          pname = "studio-input";
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
          cargoBuildFlags = [
            "-p"
            "studio-input"
          ];
          cargoTestFlags = [
            "-p"
            "studio-input"
          ];
          nativeBuildInputs = [ pkgs.makeWrapper ];
          postInstall = ''
            for b in studio-input studio-shot; do
              wrapProgram $out/bin/$b --prefix PATH : ${
                lib.makeBinPath [
                  pkgs.grim
                  pkgs.niri
                ]
              }
            done
          '';
          meta.mainProgram = "studio-input";
        };

        # Screenshot a session: `nix run .#shot -- out.png` (the dev session),
        # `nix run .#shot -- --session NAME --grid --max 1600`. Same package.
        studio-shot = self'.packages.studio-input.overrideAttrs (old: {
          meta = old.meta // {
            mainProgram = "studio-shot";
          };
        });

        default = self'.packages.studio-session;
      };
    };
}
