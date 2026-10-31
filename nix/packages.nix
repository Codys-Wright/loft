# Loft packages.
#
#   loft                   the CLI: theme engine (render) + manager (cli/loft)
#   loft-themes-builtin    the built-in packs, rendered by that same CLI
#   loft-shell             the Quickshell shell (./src) with its runtime deps on PATH
#   loft-session           niri-loft + Loft's base config + the shell, all from the store
#   niri-loft              niri + nix/niri/workspace-layers.patch (per-workspace
#                          wallpapers: the `place-within-workspace` layer rule)
#                          + title-bar.patch + toplevel-export.patch
#                          (hyprland-toplevel-export-v1: window thumbnails in the
#                          app switcher and the dock preview)
#   loft-dev               the same session, loading niri fragments, QML, templates
#                          and themes from a checkout so everything hot-reloads
#   loft-niri              niri settings backend (crates/loft-niri): live outputs,
#                          runtime overrides → <state>/overrides/niri.kdl, keybinds
#   loft-appmenu           global menu daemon (crates/loft-appmenu): AppMenu registrar
#                          + DBusMenu / org.gtk.Menus reader for the bar
#   loft-sleep             sleep watcher (crates/loft-sleep): Bluetooth off before
#                          sleep, back on after (user service, programs.loft)
#   loft-input             test driver (crates/loft-input): loft-input (virtual
#                          mouse + keyboard) and loft-shot (screenshots), see
#                          docs/TESTING.md
#   loft-pointer           Auto Scroll for scrolling capture (the same crate):
#                          pointer motion + wheel notches over the capture area
#
# Both sessions include <state>/overrides/spaces.kdl once, after the theme
# (`loft-niri space render`: the spaces' workspaces, rules and binds).
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
        # niri-loft, not stock niri: the session runs it, and loft-niri's
        # `niri validate` must accept its place-within-workspace rule.
        self'.packages.niri-loft
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

      # The CLI's own tree: Python package + templates + built-in packs/schema,
      # the built-in v2 pack (packs/loft) and the facet schemas.
      cliSrc = lib.fileset.toSource {
        root = ../.;
        fileset = lib.fileset.unions [
          ../cli
          ../templates
          ../themes
          ../packs
          ../schemas
          ../spicetify
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

      # QtMultimedia for the shell (video wallpapers, camera mirror): stock,
      # plus fixes so VAAPI frames reach the GPU textures without a copy on
      # NVIDIA, without hangs (qtmultimedia-loft below).
      qtMultimedia = self'.packages.qtmultimedia-loft;

      # QML modules imported lock designs (qylock / SDDM themes) expect, so they
      # load without a desktop session providing them.
      lockQmlPath = lib.concatMapStringsSep ":" (p: "${p}/lib/qt-6/qml") [
        pkgs.kdePackages.qt5compat
        qtMultimedia
        pkgs.kdePackages.sddm.unwrapped
      ];

      # QtMultimedia's plugins for video wallpapers and the camera mirror (its
      # QML is in lockQmlPath). Video decodes on the GPU through VA-API (Mesa,
      # or nvidia-vaapi-driver on NVIDIA) and reaches the scene graph without
      # a copy (qtmultimedia-loft). Stock Qt can't export nvidia-vaapi-driver's
      # surfaces, so it copied every frame back through vaGetImage on the GUI
      # thread, which also segfaulted (nvGetImage) under VRAM pressure. Vulkan
      # decoding (lighter on VRAM) has no zero-copy path in Qt 6.11: its frames
      # are downloaded too (5K: ~37 % of the GUI thread per video), and CUDA
      # likewise. No VA-API driver: Qt decodes in software, off the GUI
      # thread. An explicit QT_FFMPEG_DECODING_HW_DEVICE_TYPES wins.
      qtMultimediaEnv = ''
        export QT_PLUGIN_PATH="${qtMultimedia}/lib/qt-6/plugins''${QT_PLUGIN_PATH:+:$QT_PLUGIN_PATH}"
        export QT_FFMPEG_DECODING_HW_DEVICE_TYPES="''${QT_FFMPEG_DECODING_HW_DEVICE_TYPES:-vaapi}"
        export LOFT_QT_VAAPI_ZERO_COPY=1
        # nvidia-vaapi-driver-loft ahead of the system's drivers (libva takes
        # the first match per name, so Mesa's still come from the system).
        export LIBVA_DRIVERS_PATH="${self'.packages.nvidia-vaapi-driver-loft}/lib/dri:''${LIBVA_DRIVERS_PATH:-/run/opengl-driver/lib/dri}"
        # nvidia-vaapi-driver keeps exported frames it no longer uses, up to
        # VRAM/64 (256 MB on a 16 GB card); a wallpaper never asks for them
        # again. Off: −150 MB steady and −330 MB at start per 5120x1440 video,
        # same CPU (docs/TESTING.md, measured on THEBATTLESHIP).
        export NVD_MAX_DETACHED_BACKING_IMAGES="''${NVD_MAX_DETACHED_BACKING_IMAGES:-0}"
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
            self'.packages.loft-sleep # Settings → Everyday: `loft-sleep status`
            self'.packages.loft-pointer # scrolling capture → Auto
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
            include optional=true "$state/overrides/spaces.kdl"
            include optional=true "$state/overrides/niri.kdl"
            include "${../niri/workspace-wallpapers.kdl}"
            include "${../niri/title-bar.kdl}"
            include optional=true "$state/current/niri-loft.kdl"
            spawn-at-startup "${lib.getExe self'.packages.loft-shell}"
            spawn-at-startup "${lib.getExe self'.packages.loft-launcher}" "service"
            EOF
            export LOFT_NIRI_CONFIG="$dir/config.kdl"
            # niri-loft: per-workspace wallpapers (WorkspaceWallpapers.qml).
            export LOFT_NIRI_WORKSPACE_LAYERS=1
            exec ${lib.getExe self'.packages.niri-loft} --config "$dir/config.kdl" "$@"
          '';
        };

        # niri + nix/niri/workspace-layers.patch: the `place-within-workspace`
        # layer rule binds a background / bottom layer surface to one workspace,
        # so per-workspace wallpapers slide with their workspace and show behind
        # it in the overview (niri/workspace-wallpapers.kdl, the shell's
        # WorkspaceWallpapers). Nothing bound = stock niri. The version string
        # carries "workspace-layers" (how the shell detects it at runtime), and
        # `passthru.loftWorkspaceLayers` tells sessions / programs.loft to include
        # the rule. niri's own test suite (with the patch's tests) runs in the build.
        # QtMultimedia with nix/qt/qtmultimedia-nvidia-vaapi.patch, for video
        # wallpapers on NVIDIA (nvidia-vaapi-driver):
        #  - Qt exports decoded VAAPI surfaces as one composed layer, which the
        #    driver refuses ("vaExportSurfaceHandle failed"); Qt then copies
        #    every frame back to the CPU (vaGetImage) on the GUI thread, ~40 ms
        #    per 5K frame. The patch falls back to one layer per plane, so
        #    NVDEC frames are imported as EGL images (zero copy).
        #  - hardware decoders get one thread instead of frame threads, with
        #    which the driver now and then loses a surface and the GUI thread
        #    waits forever (waitSurfaceResolved).
        qtmultimedia-loft = pkgs.kdePackages.qtmultimedia.overrideAttrs (old: {
          pname = "qtmultimedia-loft";
          # Qt 6.12 rewrote qffmpeghwaccel_vaapi.cpp (DmaBufPlane +
          # importDmaBufTextures): the same changes, rebased.
          patches =
            (old.patches or [ ])
            ++ [
              (
                if lib.versionAtLeast old.version "6.12" then
                  ./qt/qtmultimedia-nvidia-vaapi-6.12.patch
                else
                  ./qt/qtmultimedia-nvidia-vaapi.patch
              )
            ];
        });

        # nvidia-vaapi-driver + nix/qt/nvidia-vaapi-driver-no-hang.patch, for
        # the shell only (qtMultimediaEnv): a decoder torn down with frames
        # still queued (a wallpaper player stopping) left them "resolving"
        # forever, and exporting one on the GUI thread (vaExportSurfaceHandle
        # → waitSurfaceResolved) froze the whole shell. The resolve thread now
        # releases its queue on exit, and the wait gives up after 1 s.
        nvidia-vaapi-driver-loft = pkgs.nvidia-vaapi-driver.overrideAttrs (old: {
          pname = "nvidia-vaapi-driver-loft";
          patches = (old.patches or [ ]) ++ [ ./qt/nvidia-vaapi-driver-no-hang.patch ];
        });

        # …+ nix/niri/title-bar.patch: a KWin-style server-side title bar (traffic
        # lights, centered title) above every window that lets niri decorate it;
        # the tile reserves its height. `layout { title-bar { … } }` and the
        # window rule of the same name (niri/title-bar.kdl,
        # docs/WINDOW-DECORATIONS.md). The version string carries "title-bar"
        # and `passthru.loftTitleBar` gates the fragment like the layer rule.
        niri-loft = pkgs.niri.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [
            ./niri/workspace-layers.patch
            ./niri/title-bar.patch
            ./niri/toplevel-export.patch
          ];
          env = (old.env or { }) // {
            NIRI_BUILD_COMMIT = "Nixpkgs, loft: workspace-layers, title-bar, toplevel-export";
          };
          passthru = (old.passthru or { }) // {
            loftWorkspaceLayers = true;
            loftTitleBar = true;
            loftToplevelExport = true;
          };
        });

        # niri-loft + nix/dev/niri-headless-outputs.patch: NIRI_HEADLESS_OUTPUTS=WxH,…
        # runs niri on that many virtual outputs (its test backend, made usable at
        # runtime: 60 Hz pacing, screencopy, `niri msg output headless-N off|on` as
        # hotplug). niri's nested (winit) backend has exactly one output, so this is
        # how `loft-dev --outputs` gets a multi-monitor session.
        loft-niri-headless = self'.packages.niri-loft.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [ ./dev/niri-headless-outputs.patch ];
          doCheck = false;
        });

        loft-dev = pkgs.writeShellApplication {
          name = "loft-dev";
          runtimeInputs = runtimeDeps ++ [
            self'.packages.loft-launcher
            self'.packages.loft
            self'.packages.loft-niri
            self'.packages.loft-appmenu
            self'.packages.loft-sleep
            self'.packages.loft-input # loft-input / loft-shot inside the session
            self'.packages.loft-live # `loft-dev live …`
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
                "@NIRI_HEADLESS@"
                "@NIRI_LOFT@"
                "@NIRI_STOCK@"
              ]
              [
                (lib.getExe self'.packages.loft)
                "${python}/bin/python3"
                uiFont
                iconFont
                lockQmlPath
                "${qtMultimedia}/lib/qt-6/plugins"
                "${./dev/kwin-place.js}"
                (lib.getExe' pkgs.sway-unwrapped "sway")
                "${pkgs.mesa}/share/glvnd/egl_vendor.d/50_mesa.json"
                (lib.getExe self'.packages.loft-niri-headless)
                (lib.getExe self'.packages.niri-loft)
                (lib.getExe pkgs.niri)
              ]
              (builtins.readFile ./dev/loft-dev.sh);
        };

        # The checkout on the real desktop (nix/dev/loft-live.sh): the installed
        # shell and launcher stand down while it runs.
        loft-live = pkgs.writeShellApplication {
          name = "loft-live";
          runtimeInputs = runtimeDeps ++ [
            self'.packages.loft-launcher
            self'.packages.loft
            self'.packages.loft-niri
            self'.packages.loft-appmenu
            pkgs.nix
          ];
          text =
            builtins.replaceStrings
              [
                "@PYTHON@"
                "@UI_FONT@"
                "@ICON_FONT@"
                "@LOCK_QML_PATH@"
                "@QT_MM_PLUGINS@"
              ]
              [
                "${python}/bin/python3"
                uiFont
                iconFont
                lockQmlPath
                "${qtMultimedia}/lib/qt-6/plugins"
              ]
              (builtins.readFile ./dev/loft-live.sh);
        };

        # niri-loft for a session that `loft-live --niri` can switch: when
        # <state>/dev/niri (a checkout's niri-loft build) exists, the compositor
        # started at login is that one — if it accepts the config; otherwise,
        # and without it, the installed niri-loft. Use it as programs.niri.package.
        # Back to the installed one: `loft-live stop --niri` (or remove the link
        # from a TTY) and log in again.
        niri-loft-live =
          let
            niri = self'.packages.niri-loft;
            wrapper = pkgs.writeShellScript "niri" ''
              dev="''${XDG_STATE_HOME:-$HOME/.local/state}/loft/dev/niri/bin/niri"
              if [ -x "$dev" ]; then
                if [ "''${1:-}" != "--session" ]; then
                  exec "$dev" "$@"
                elif "$dev" validate >/dev/null 2>&1; then
                  echo "niri-loft-live: running the dev niri $(readlink -f "$dev")" >&2
                  exec "$dev" "$@"
                else
                  echo "niri-loft-live: the dev niri rejects the config; running the installed one" >&2
                fi
              fi
              exec ${lib.getExe niri} "$@"
            '';
          in
          pkgs.runCommand "niri-loft-live-${niri.version}"
            {
              inherit (niri) version;
              passthru = niri.passthru // {
                providedSessions = niri.passthru.providedSessions or [ "niri" ];
                # Read off programs.niri.package by niri-flake's module (portals).
                cargoBuildNoDefaultFeatures = niri.cargoBuildNoDefaultFeatures or false;
                cargoBuildFeatures = niri.cargoBuildFeatures or [ ];
              };
              meta = niri.meta // {
                mainProgram = "niri";
              };
            }
            ''
              # Everything but the binary (small: units, sessions, completions),
              # pointing at this package's niri instead.
              mkdir -p $out/bin
              cp -r --no-preserve=mode ${niri}/share ${niri}/lib $out/
              cp ${wrapper} $out/bin/niri
              sed 's|${niri}|'"$out"'|g' ${niri}/lib/systemd/user/niri.service > $out/lib/systemd/user/niri.service
              sed 's|${niri}|'"$out"'|g' ${niri}/bin/niri-session > $out/bin/niri-session
              chmod +x $out/bin/niri-session
              grep -rl ${niri} $out/lib $out/share $out/bin/niri-session && { echo "niri-loft-live: still points at ${niri}" >&2; exit 1; } || true
            '';

        # The keyboard layer by hand (programs.loft.keyboard runs it as a
        # service): `loft keys xremap` renders Loft's keymap (cli/loft/keys.py)
        # and xremap follows it. `--dual-role-only`: just Esc / Caps tap =
        # Escape, hold = the window-manager key — what a nested dev session
        # wants, since inside another desktop xremap can't tell which app is
        # focused. Needs read access to /dev/input and /dev/uinput (the input
        # + uinput groups).
        loft-keys = pkgs.writeShellApplication {
          name = "loft-keys";
          text = ''
            loft=${lib.getExe self'.packages.loft}
            if [ "''${1:-}" = "--dual-role-only" ]; then
              cfg="''${XDG_RUNTIME_DIR:-/tmp}/loft-keys-dual.json"
              "$loft" keys render --group dual-role --out "$cfg"
              exec ${pkgs.xremap}/bin/xremap --watch=device --mouse "$cfg"
            fi
            "$loft" keys xremap
            cfg="''${LOFT_STATE_DIR:-''${XDG_STATE_HOME:-$HOME/.local/state}/loft}/xremap/config.json"
            exec ${pkgs.xremap.niri}/bin/xremap --watch=config,device --mouse "$cfg"
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
            cp -r cli templates themes packs schemas spicetify $out/share/loft/
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
                  self'.packages.loft-niri # `loft windows …`, panorama
                  pkgs.niri
                  pkgs.git
                  pkgs.ffmpeg-headless
                  pkgs.imagemagick # loft media convert / watermark; `loft mcp` downscales screenshots
                  pkgs.grim # `loft mcp`: screenshot_output / screenshot_window
                  pkgs.wl-clipboard # `loft mcp`: keeps the clipboard text across niri's window render
                ]
              }
          '';
          meta.mainProgram = "loft";
        };

        # Spotify themed by Loft (cli/loft/spotify.py, programs.loft.spotify):
        # spicetify-themes' `text` theme (MIT), the theme Cozytile uses, whose
        # color.ini Loft merges the active theme's scheme into …
        loft-spicetify-text = pkgs.fetchFromGitHub {
          owner = "spicetify";
          repo = "spicetify-themes";
          rev = "c432012478e1f2e2ffccca8e943e188af40d6190";
          sparseCheckout = [ "text" ];
          hash = "sha256-mg/iVr8JVlfNlCALqzY45PrFDu2A5EqvLgkdC+zCpe4=";
          postFetch = ''
            mv $out/text $TMPDIR/text
            rm -rf $out
            mkdir -p $out
            cp $TMPDIR/text/{user.css,color.ini,README.md} $out/
          '';
        };

        # … and the Marketplace custom app (MIT), its prebuilt `dist` branch.
        loft-spicetify-marketplace = pkgs.fetchFromGitHub {
          owner = "spicetify";
          repo = "spicetify-marketplace";
          rev = "3b4a4836e3fac8bac93a5c0490fd9ebc3d76600b";
          hash = "sha256-tQhN0Wl4S1zqShvFHILbtZSPvDbi4EZYzAQLh3FGVQg=";
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
              # Spaces: built-in templates (compiled in), the shared wallsets
              # role fixtures, instance fixtures, and base.kdl for `niri validate`.
              ../spaces
              ../tests/fixtures/wallsets
              ../tests/fixtures/spaces
              ../niri/base.kdl
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

        # Bluetooth off during sleep (crates/loft-sleep): a user service
        # (programs.loft) listening for logind's PrepareForSleep.
        loft-sleep = pkgs.rustPlatform.buildRustPackage {
          pname = "loft-sleep";
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
            "loft-sleep"
          ];
          cargoTestFlags = [
            "-p"
            "loft-sleep"
          ];
          meta.mainProgram = "loft-sleep";
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
              ../spaces # loft-niri (a dependency) compiles the built-in spaces in
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

        # Auto Scroll for scrolling capture: `loft capture scroll` runs
        # `loft-pointer scroll` after the user presses Auto in the HUD. Just
        # that binary (its tests run in loft-input).
        loft-pointer = self'.packages.loft-input.overrideAttrs (old: {
          pname = "loft-pointer";
          doCheck = false;
          postInstall = ''
            rm $out/bin/loft-input $out/bin/loft-shot
          '';
          meta = old.meta // {
            mainProgram = "loft-pointer";
          };
        });

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
