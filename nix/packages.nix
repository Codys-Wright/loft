# Loft packages.
#
#   loft                   the CLI: theme engine (render) + manager (cli/loft)
#   loft-themes-builtin    the built-in packs, rendered by that same CLI
#   loft-shell             the Quickshell shell (./src) with its runtime deps on PATH
#   loft-session           niri + Loft's base config + the shell, all from the store
#   loft-dev               the same session, loading niri fragments, QML, templates
#                          and themes from a checkout so everything hot-reloads
#   loft-niri              niri settings backend (crates/loft-niri): live outputs,
#                          runtime overrides → <state>/overrides/niri.kdl, keybinds
#   loft-appmenu           global menu daemon (crates/loft-appmenu): AppMenu registrar
#                          + DBusMenu / org.gtk.Menus reader for the bar
#   loft-input             test driver (crates/loft-input): loft-input (virtual
#                          mouse + keyboard) and loft-shot (screenshots), see
#                          docs/TESTING.md
#
# Both sessions include <state>/overrides/niri.kdl FIRST (niri uses the first
# `output` block matching a monitor, so output overrides must come first) and
# LAST (every other section merges, later wins). Both expose their entry
# config as $LOFT_NIRI_CONFIG, since niri hides $NIRI_CONFIG from children.
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
        ffmpeg # also Utilities → Media Tools (compress, GIF, watermark, audio)
        imagemagick # Utilities → Media Tools: convert / watermark images (png, jpg, webp, avif)
        satty
        # Text from screen: English OCR (add languages with
        # tesseract.override { enableLanguages = [ … ]; }) and QR codes.
        (tesseract.override { enableLanguages = [ "eng" ]; })
        (zbar.override {
          enableVideo = false;
          withXorg = false;
          enableDbus = false;
        })
        self'.packages.loft-walker # Spotlight launcher (frontend)
        self'.packages.loft-elephant # launcher data providers
        jq
        coreutils
        cliphist # Clipboard history (recorder + store)
        wl-clipboard # wl-copy / wl-paste: clipboard history, plain-text paste, Clean URL
        wtype # paste / snippet expansion into the focused app
        xdg-utils # Shelf: open parked files and links
        inotify-tools # dev loop: reload after a failed reload (devtools/ReloadToast); dock folders live
        glib # gio: the dock's Trash (gio trash, empty) and trash:/// · gdbus: Show in Files
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
      # store copy of the shell (loft-dev renders its own for the checkout).
      shellBinds = pkgs.runCommand "loft-shell-binds.kdl" { } ''
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

      builtinRendered = self'.packages.loft-themes-builtin;

      # Shared by both sessions: the state dir the shell, niri and `loft`
      # agree on, seeded with the default theme from the store. Without an
      # explicit state dir, studio-linux's (Loft's old name) moves here first.
      seedState = ''
        if [ -z "''${LOFT_STATE_DIR:-}" ]; then
          ${lib.getExe self'.packages.loft-migrate} || true
        fi
        state="''${LOFT_STATE_DIR:-''${XDG_STATE_HOME:-$HOME/.local/state}/loft}"
        export LOFT_STATE_DIR="$state"
        mkdir -p "$state"
        [ -e "$state/current" ] || ln -sfn ${builtinRendered}/default "$state/current"
      '';
    in
    {
      packages = {
        loft-shell = pkgs.writeShellApplication {
          name = "loft-shell";
          runtimeInputs = runtimeDeps ++ [
            self'.packages.loft
            self'.packages.loft-niri
            self'.packages.loft-appmenu
          ];
          text = ''
            if [ -z "''${LOFT_THEME_FILE:-}" ]; then
              ${seedState}
              export LOFT_THEME_FILE="$state/current/theme.json"
            fi
            export LOFT_UI_FONT="${uiFont}" LOFT_ICON_FONT="${iconFont}"
            # Island timers ring with the freedesktop alarm.
            export LOFT_ALARM_SOUND="''${LOFT_ALARM_SOUND:-${pkgs.sound-theme-freedesktop}/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga}"
            export QML_IMPORT_PATH="${lockQmlPath}''${QML_IMPORT_PATH:+:$QML_IMPORT_PATH}"
            ${qtMultimediaEnv}
            # LOFT_SHELL_SRC runs the QML from a checkout instead (hot reload);
            # the CLI's IPC hooks must target the same path.
            src="''${LOFT_SHELL_SRC:-${../src}}"
            export LOFT_SHELL_PATH="$src"
            exec quickshell --path "$src" "$@"
          '';
        };

        loft-session = pkgs.writeShellApplication {
          name = "loft-session";
          runtimeInputs = runtimeDeps ++ [ self'.packages.loft-launcher ];
          text = ''
            ${seedState}
            # The entry config is written at runtime: the theme fragment lives
            # in the (runtime) state dir. It comes after base.kdl so it wins;
            # niri watches it, including `current` being re-pointed.
            dir="''${XDG_RUNTIME_DIR:-/tmp}/loft-session"
            mkdir -p "$dir"
            cat > "$dir/config.kdl" <<EOF
            include optional=true "$state/overrides/niri.kdl"
            include "${../niri}/base.kdl"
            include "${shellBinds}"
            include optional=true "$state/current/niri.kdl"
            include optional=true "$state/overrides/niri.kdl"
            spawn-at-startup "${lib.getExe self'.packages.loft-shell}"
            spawn-at-startup "${lib.getExe self'.packages.loft-launcher}" "service"
            EOF
            export LOFT_NIRI_CONFIG="$dir/config.kdl"
            exec niri --config "$dir/config.kdl" "$@"
          '';
        };

        loft-dev = pkgs.writeShellApplication {
          name = "loft-dev";
          runtimeInputs = runtimeDeps ++ [
            self'.packages.loft-launcher
            self'.packages.loft
            self'.packages.loft-niri
            self'.packages.loft-appmenu
            self'.packages.loft-input # loft-input / loft-shot inside the session
            pkgs.dbus # dbus-run-session: the private bus of isolated sessions
          ];
          text =
            builtins.replaceStrings
              [
                "@LOFT@"
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
                (lib.getExe self'.packages.loft)
                "${python}/bin/python3"
                uiFont
                iconFont
                lockQmlPath
                "${pkgs.kdePackages.qtmultimedia}/lib/qt-6/plugins"
                "${./dev/kwin-place.js}"
                (lib.getExe' pkgs.sway-unwrapped "sway")
                "${pkgs.mesa}/share/glvnd/egl_vendor.d/50_mesa.json"
              ]
              (builtins.readFile ./dev/loft-dev.sh);
        };

        # The keyboard layer (keyboard/keys.nix): Esc / Caps tap = Escape,
        # hold = the window-manager key; Super = Cmd for apps. Needs read
        # access to /dev/input and /dev/uinput (the input + uinput groups).
        loft-keys =
          let
            keys = import ../keyboard/keys.nix { inherit lib; };
            config = name: cfg: pkgs.writeText name (builtins.toJSON cfg);
          in
          pkgs.writeShellApplication {
            name = "loft-keys";
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

        # DuckDuckGo-style !bangs for Spotlight: unduck's bang list
        # (github.com/T3-Content/unduck) → bangs.json, the data of the `bangs`
        # elephant provider (launcher/elephant-bangs). Pinned; bump rev + hash
        # to refresh the list (launcher/bangs.py adds a few Nix engines).
        loft-bangs =
          let
            unduck = pkgs.fetchFromGitHub {
              owner = "T3-Content";
              repo = "unduck";
              rev = "c1b821de0ffa286cfd964817d1918c5e90545db4";
              hash = "sha256-w1a5a51uJ2ehzi2ehMh5VIMDBRAjjUz35cA8yi+gBd4=";
            };
          in
          pkgs.runCommand "loft-bangs" { nativeBuildInputs = [ pkgs.python3 ]; } ''
            mkdir -p $out
            python3 ${../launcher/bangs.py} ${unduck}/src/bang.ts $out/bangs.json
          '';

        # elephant with the `bangs` provider (!bangs, Quicklinks, the default
        # engine) built in its own provider tree: Go plugins only load into
        # the exact binary (toolchain + dependency versions) they were built
        # with, so the provider is built by elephant's own derivation.
        # The calculator (math, units, currencies, time zones) and commands
        # (system, Settings pages, window actions, script commands, "?" help)
        # providers are built the same way; their Go tests run here too.
        loft-elephant = pkgs.elephant.overrideAttrs (old: {
          postPatch = (old.postPatch or "") + ''
            for p in bangs calculator commands; do
              cp -r ${../launcher}/elephant-$p internal/providers/$p
              chmod -R u+w internal/providers/$p
            done
          '';
          postBuild = (old.postBuild or "") + ''
            HOME=$TMPDIR XDG_CACHE_HOME=$TMPDIR/cache XDG_DATA_HOME=$TMPDIR/data \
              LOFT_BUILTIN_SCRIPTS=${../launcher/scripts} PATH=${pkgs.libqalculate}/bin:$PATH \
              go test ./internal/providers/calculator ./internal/providers/commands
          '';
        });

        # walker + launcher/walker-set-query.patch: lets an elephant provider
        # replace the query text — how a !bang becomes a sub-search scope.
        loft-walker = pkgs.walker.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [ ../launcher/walker-set-query.patch ];
        });

        loft-launcher = pkgs.writeShellApplication {
          name = "loft-launcher";
          runtimeInputs = [
            self'.packages.loft-walker
            self'.packages.loft-elephant
            self'.packages.loft # script commands (Toggle Dark Mode)
            pkgs.libnotify # script commands: banners (notify-send)
            pkgs.glib # Empty Trash (gio trash)
            pkgs.wl-clipboard # calculator / scripts: copy
            pkgs.iproute2 # Copy Wi-Fi IP
            pkgs.xdg-utils # script commands: edit / show in folder
            pkgs.quickshell # opens Settings → Spotlight (Create Quicklink)
            pkgs.jq
            pkgs.coreutils
          ];
          text =
            builtins.replaceStrings
              [ "@LAUNCHER@" "@LAYERSHELL@" "@BANGS@" "@SHELL@" ]
              [
                "${../launcher}"
                "${pkgs.gtk4-layer-shell}/lib/libgtk4-layer-shell.so"
                "${self'.packages.loft-bangs}/bangs.json"
                "${../src}"
              ]
              (builtins.readFile ../launcher/loft-launcher.sh);
        };

        # One renderer for runtime and build time (Python stdlib + jsonschema):
        # `loft theme render` here is what builds loft-themes-builtin.
        loft = pkgs.stdenvNoCC.mkDerivation {
          pname = "loft";
          version = "0.1.0";
          src = cliSrc;
          nativeBuildInputs = [ pkgs.makeWrapper ];
          dontBuild = true;
          installPhase = ''
            mkdir -p $out/share/loft $out/bin
            cp -r cli templates themes $out/share/loft/
            # Utilities + Media Tools: Spotlight finds them; "Open With" in any file manager.
            install -Dm644 -t $out/share/applications ${../applications}/*.desktop
            # Reload hooks call quickshell/niri; installs and importers use git;
            # the qylock importer samples (video) backgrounds with ffmpeg, whose
            # libraries Quickshell's closure already carries. The user's own
            # (newer) ones win on PATH.
            makeWrapper ${python}/bin/python3 $out/bin/loft \
              --add-flags "-B $out/share/loft/cli/loft" \
              --set-default LOFT_SHELL_PATH ${../src} \
              --suffix PATH : ${
                lib.makeBinPath [
                  pkgs.quickshell
                  pkgs.niri
                  pkgs.git
                  pkgs.ffmpeg-headless
                  pkgs.imagemagick # loft media convert / watermark
                ]
              }
          '';
          meta.mainProgram = "loft";
        };

        # Built-in packs rendered at build time: <name>/{theme.json,niri.kdl,…}
        # plus the `default` alias. Sessions seed `current` from here.
        loft-themes-builtin = pkgs.runCommand "loft-themes-builtin" { } ''
          mkdir -p $out
          for pack in ${cliSrc}/themes/*/; do
            pack="''${pack%/}"
            [ -L "$pack" ] && continue
            LOFT_THEME_INDEX=none ${lib.getExe self'.packages.loft} theme render "$pack" "$out/$(basename "$pack")"
          done
          ln -s "$(readlink ${cliSrc}/themes/default)" $out/default
        '';

        # niri settings backend for the shell's Displays / Input / Layout /
        # Keybinds pages. Its tests run `niri validate` on rendered fragments.
        loft-niri = pkgs.rustPlatform.buildRustPackage {
          pname = "loft-niri";
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
            "loft-niri"
          ];
          cargoTestFlags = [
            "-p"
            "loft-niri"
          ];
          nativeCheckInputs = [ pkgs.niri ];
          meta.mainProgram = "loft-niri";
        };

        # Global menu daemon for the bar (src/services/AppMenu.qml runs it).
        loft-appmenu = pkgs.rustPlatform.buildRustPackage {
          pname = "loft-appmenu";
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
            "loft-appmenu"
          ];
          cargoTestFlags = [
            "-p"
            "loft-appmenu"
          ];
          meta.mainProgram = "loft-appmenu";
        };

        # Test driver for agents (crates/loft-input): `loft-input` — a
        # virtual mouse + keyboard for a session (Wayland virtual-pointer /
        # virtual-keyboard; niri binds via IPC) — and `loft-shot` —
        # screenshots with crop/zoom/grid/marks in global coordinates.
        # See docs/TESTING.md.
        loft-input = pkgs.rustPlatform.buildRustPackage {
          pname = "loft-input";
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
            "loft-input"
          ];
          cargoTestFlags = [
            "-p"
            "loft-input"
          ];
          nativeBuildInputs = [ pkgs.makeWrapper ];
          postInstall = ''
            for b in loft-input loft-shot; do
              wrapProgram $out/bin/$b --prefix PATH : ${
                lib.makeBinPath [
                  pkgs.grim
                  pkgs.niri
                ]
              }
            done
          '';
          meta.mainProgram = "loft-input";
        };

        # Screenshot a session: `nix run .#shot -- out.png` (the dev session),
        # `nix run .#shot -- --session NAME --grid --max 1600`. Same package.
        loft-shot = self'.packages.loft-input.overrideAttrs (old: {
          meta = old.meta // {
            mainProgram = "loft-shot";
          };
        });

        # The one-time move from studio-linux's paths (nix/migrate.sh), run by
        # the sessions and the home-manager activation.
        loft-migrate = pkgs.writeShellApplication {
          name = "loft-migrate";
          runtimeInputs = [
            pkgs.coreutils
            pkgs.gnugrep
            pkgs.gnused
          ];
          text = builtins.readFile ./migrate.sh;
        };

        default = self'.packages.loft-session;
      };
    };
}
