# home-manager module: programs.loft.
#
# Runs the shell and the launcher as systemd user services in the graphical
# session, puts the `loft` CLI on PATH, and writes a niri fragment the
# consumer's own niri config includes (after its binds):
#
#   include optional=true "~/.config/loft/niri.kdl"
#
# The fragment holds the shell keybinds, the active theme's niri.kdl and,
# last, the runtime overrides from Loft Settings (loft-niri), so a
# consumer keeps its own outputs, layout and binds (PLAN §1a) and runtime
# changes win over them.
#
# niri uses the FIRST `output` block matching a monitor, so for display
# overrides to win over the consumer's own output blocks, also include this
# at the very top of the niri config:
#
#   include optional=true "~/.config/loft/niri-early.kdl"
{ self, ... }:
{
  flake.homeManagerModules.default =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.programs.loft;
      sp = self.packages.${pkgs.stdenv.hostPlatform.system};

      # The QML the shell runs: the store copy, or a checkout for live edits.
      shellSrc = if cfg.devSource != null then "${cfg.devSource}/src" else "${self}/src";
      stateDir = "${config.xdg.stateHome}/loft";

      shellBinds = pkgs.runCommand "loft-shell-binds.kdl" { } ''
        sed 's|@IPC@|"${lib.getExe pkgs.quickshell}" "ipc" "--path" "${shellSrc}" "call"|g' \
          ${self}/niri/shell-binds.kdl.in > $out
      '';

      # nix/migrate.sh, with the dirs this module uses (the activation may
      # not have the XDG variables).
      migrate = lib.concatStringsSep " " [
        ''DRY_RUN="''${DRY_RUN:-}"''
        "XDG_STATE_HOME=${lib.escapeShellArg config.xdg.stateHome}"
        "XDG_DATA_HOME=${lib.escapeShellArg config.xdg.dataHome}"
        "XDG_CACHE_HOME=${lib.escapeShellArg config.xdg.cacheHome}"
        "XDG_CONFIG_HOME=${lib.escapeShellArg config.xdg.configHome}"
        (lib.getExe sp.loft-migrate)
      ];

      lockCmd = "${lib.getExe pkgs.quickshell} ipc --path ${shellSrc} call lock lock";

      # The theme + wallpaper library (cli/loft/library.py); "none" = off.
      library = if cfg.library != null then cfg.library else "none";

      env = [
        "LOFT_STATE_DIR=${stateDir}"
        "LOFT_SHELL_SRC=${shellSrc}"
        "LOFT_LIBRARY=${library}"
      ]
      ++ lib.optional (cfg.devSource != null) "LOFT_LAUNCHER_DIR=${cfg.devSource}/launcher"
      # The `spotify` reload hook and Settings → Appearance → Spotify (nix/modules/spotify.nix).
      ++ lib.optionals cfg.spotify.enable [
        "LOFT_SPOTIFY_DIR=${config.xdg.dataHome}/loft/spotify"
        "LOFT_SPOTIFY_CONFIG=${config.xdg.configHome}/loft/spotify.json"
      ]
      # Quickshell is a Qt app with no platform theme: without this it falls
      # back to hicolor and the dock/bar show generic icons.
      ++ lib.optional (cfg.iconTheme != null) "QS_ICON_THEME=${cfg.iconTheme}"
      # niri-loft's place-within-workspace rule is in loft/niri.kdl: the shell
      # may bind wallpapers to workspaces (WorkspaceWallpapers.qml).
      ++ lib.optional workspaceLayers "LOFT_NIRI_WORKSPACE_LAYERS=1"
      # Feature defaults (Features.qml); Settings → General → Features still wins.
      ++ lib.optional (
        featureDefaults != [ ]
      ) "LOFT_FEATURE_DEFAULTS=${lib.concatStringsSep "," featureDefaults}"
      # Workspace icon defaults (WorkspaceIcons.qml); Settings → Menu Bar wins.
      ++ lib.optional (cfg.workspaceIcons != { }) "LOFT_WORKSPACE_ICONS=${workspaceIconsFile}";

      workspaceIconsFile = pkgs.writeText "loft-workspace-icons.json" (
        builtins.toJSON cfg.workspaceIcons
      );

      featureDefaults = cfg.features ++ lib.optional cfg.spaces.enable "spaces";

      # Spaces (docs/SPACES.md): the library folder their documents live in.
      spacesDir = if cfg.library != null then "${cfg.library}/Spaces" else null;

      # Session autostart for spaces (spawn-at-startup in loft/niri.kdl):
      # render spaces.kdl (the spaces' workspaces, rules and Mod+N binds; a
      # no-op when nothing changed), then open the `startup: "login"` spaces.
      spacesStartup = pkgs.writeShellScript "loft-spaces-startup" ''
        ${lib.concatMapStrings (e: "export ${lib.escapeShellArg e}\n") env}
        export PATH="${lib.makeBinPath [ cfg.niriPackage ]}:$PATH"
        ${lib.getExe sp.loft-niri} space render || echo "loft-spaces-startup: render failed" >&2
        exec ${lib.getExe sp.loft-niri} space startup
      '';

      # programs.loft.qt.dolphinLauncher: Dolphin with the theme's style sheet
      # (Places rows inset), when it has been rendered; hiPrio over a plain
      # Dolphin in the same profile.
      dolphinLauncher = lib.hiPrio (
        pkgs.writeShellScriptBin "dolphin" ''
          qss=${lib.escapeShellArg "${stateDir}/current/dolphin.qss"}
          if [ -r "$qss" ]; then
            exec ${lib.getExe cfg.qt.dolphinPackage} -stylesheet "$qss" "$@"
          fi
          exec ${lib.getExe cfg.qt.dolphinPackage} "$@"
        ''
      );

      # The consumer runs a niri that parses `place-within-workspace`.
      workspaceLayers = cfg.niriPackage.passthru.loftWorkspaceLayers or false;
      # …and `title-bar` (nix/niri/title-bar.patch).
      titleBar = cfg.niriPackage.passthru.loftTitleBar or false;

      # programs.loft.keyboard: the seed `loft keys` layers runtime changes on.
      keyboardSeed = {
        inherit (cfg.keyboard)
          groups
          classes
          apps
          remap
          extraGroups
          ;
      };
      keymapConfig = "${stateDir}/xremap/config.json";
      # The keymap as this seed renders it, for when `loft keys xremap` fails
      # at start: a Loft failure never costs the remaps. One per
      # window-manager key (cli/loft/keys.py): ralt in niri, meta in Plasma.
      keymapFallback =
        wmKey:
        pkgs.runCommand "loft-keymap-fallback-${wmKey}.json"
          {
            seed = builtins.toJSON keyboardSeed;
            passAsFile = [ "seed" ];
          }
          ''
            HOME=$TMPDIR LOFT_STATE_DIR=$TMPDIR/state LOFT_KEYMAP_SEED=$seedPath \
              ${lib.getExe sp.loft} keys render --wm-key ${wmKey} --out $out
          '';
      # xremap's per-app remaps need NIRI_SOCKET, which niri doesn't put in
      # the systemd user environment. More than one niri can be running (a
      # stray `niri` from a TTY): take this session's (niri.$WAYLAND_DISPLAY.
      # <pid>.sock) whose niri is alive, else any live one — a stale or
      # foreign socket makes per-app remaps see the wrong window.
      findNiriSocket = pkgs.writeShellScript "loft-keys-niri-socket" ''
        live() {
          local pid=''${1%.sock}; pid=''${pid##*.}
          [ -S "$1" ] && [ -d "/proc/$pid" ]
        }
        pick=""
        if [ -n "''${WAYLAND_DISPLAY:-}" ]; then
          for sock in /run/user/$UID/niri."$WAYLAND_DISPLAY".*.sock; do
            live "$sock" && pick=$sock
          done
        fi
        if [ -z "$pick" ]; then
          for sock in /run/user/$UID/niri.*.sock; do
            live "$sock" && pick=$sock
          done
        fi
        [ -n "$pick" ] && exec ${pkgs.systemd}/bin/systemctl --user set-environment NIRI_SOCKET="$pick"
        exit 0
      '';
      keymapStart = pkgs.writeShellScript "loft-keys-render" ''
        ${lib.concatMapStrings (e: "export ${lib.escapeShellArg e}\n") env}
        ${lib.getExe sp.loft} keys xremap && exit 0
        echo "loft keys xremap failed; using the keymap as Nix configured it" >&2
        mkdir -p "$(dirname ${lib.escapeShellArg keymapConfig})"
        case "''${LOFT_WM_KEY:-}" in
          meta) cp ${keymapFallback "meta"} ${lib.escapeShellArg keymapConfig} ;;
          *) cp ${keymapFallback "ralt"} ${lib.escapeShellArg keymapConfig} ;;
        esac
        chmod 644 ${lib.escapeShellArg keymapConfig}
      '';

      # Loft runs inside niri only. Started by niri's session unit, not
      # graphical-session.target: other desktops (Plasma, GNOME) reach that
      # target too, and must not get a second bar. Requisite (not BindsTo,
      # which would start niri) keeps a crash restart from landing in
      # whatever desktop came next; niri.service's ExecStopPost
      # (loftSessionUnits below) stops the units when niri dies.
      service = description: exec: {
        Unit = {
          Description = description;
          PartOf = [
            "graphical-session.target"
            "niri.service"
          ];
          After = [
            "graphical-session.target"
            "niri.service"
          ];
          Requisite = [ "niri.service" ];
        };
        Service = {
          ExecStart = exec;
          # The window-manager key (cli/loft/keys.py): niri's Mod is Right
          # Alt, so `loft keys …` run by these units renders it that way.
          Environment = env ++ [ "LOFT_WM_KEY=ralt" ];
          Restart = "on-failure";
          RestartSec = 2;
        };
        Install.WantedBy = [ "niri.service" ];
      };

      loftSessionUnits = [
        "loft-shell.service"
        "loft-launcher.service"
      ]
      ++ lib.optional cfg.keyboard.enable "loft-keys.service"
      ++ lib.optional cfg.sleepWatcher "loft-sleep.service";

      # ── Loft as the shell of a Plasma session (programs.loft.plasma) ─────
      # The "Loft" login entry (Loft's NixOS module) records the PID of the
      # startplasma-wayland it execs in $XDG_RUNTIME_DIR/loft/plasma-session.
      # A Plasma session is Loft's while that process lives and no
      # `use plasma` override names it; anything else (the plain "Plasma"
      # entry, a stale marker from an earlier login, which lingering keeps
      # around) is plain Plasma. When in doubt, plasmashell runs.
      loftPlasma = pkgs.writeShellApplication {
        name = "loft-plasma";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.procps
          pkgs.systemd
          pkgs.libnotify
        ];
        text = ''
          rt="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/loft"
          marker="$rt/plasma-session"

          # The process itself (its executable, not its arguments) is Plasma's
          # session leader: the login wrapper execs plasma-dbus-run-session-
          # if-needed, which execs startplasma-wayland (Nix: .…-wrapped), or
          # dbus-run-session when there was no session bus yet.
          alive() {
            local exe
            [ -n "$1" ] || return 1
            exe="$(readlink "/proc/$1/exe" 2>/dev/null)" || return 1
            case "''${exe##*/}" in
              startplasma-wayland | .startplasma-wayland-wrapped | dbus-run-session) return 0 ;;
            esac
            return 1
          }
          session_pid() { cat "$marker" 2>/dev/null || true; }
          is_loft() {
            local pid
            pid="$(session_pid)"
            alive "$pid" || return 1
            [ "$(cat "$marker.plasma" 2>/dev/null || true)" != "$pid" ]
          }
          # This login's startplasma, for `use` in a session that wasn't
          # started from the Loft entry.
          running_plasma() {
            local pid
            pid="$(session_pid)"
            if alive "$pid"; then echo "$pid"; return; fi
            for pid in $(pgrep -u "$(id -u)" || true); do
              case "$(readlink "/proc/$pid/exe" 2>/dev/null)" in
                */startplasma-wayland | */.startplasma-wayland-wrapped) echo "$pid"; return ;;
              esac
            done
          }

          case "''${1:-}" in
            check)
              # ExecCondition: exit 0 runs the unit, 1 skips it.
              case "''${2:-}" in
                loft) is_loft ;;
                plasma) ! is_loft ;;
                *) echo "usage: loft-plasma check loft|plasma" >&2; exit 2 ;;
              esac
              ;;
            status)
              if is_loft; then echo loft; else echo plasma; fi
              ;;
            use)
              pid="$(running_plasma)"
              if [ -z "$pid" ]; then
                echo "loft-plasma: no Plasma session is running" >&2
                exit 1
              fi
              mkdir -p "$rt"
              echo "$pid" > "$marker"
              case "''${2:-}" in
                plasma)
                  echo "$pid" > "$marker.plasma"
                  systemctl --user stop ${plasmaUnits} || true
                  systemctl --user reset-failed ${plasmaUnits} 2>/dev/null || true
                  systemctl --user start plasma-plasmashell.service
                  ;;
                loft)
                  rm -f "$marker.plasma"
                  systemctl --user stop plasma-plasmashell.service || true
                  systemctl --user reset-failed ${plasmaUnits} 2>/dev/null || true
                  systemctl --user start ${plasmaUnits}
                  ;;
                *) echo "usage: loft-plasma use loft|plasma" >&2; exit 2 ;;
              esac
              ;;
            lock-env)
              # ExecStartPre of KWin's unit: Plasma's locker (kscreenlocker_greet,
              # a child of KWin that inherits its environment) shows Loft's
              # design only in Loft sessions. The unit reads this file with
              # EnvironmentFile= right after; a plain "Plasma" login empties it.
              mkdir -p "$rt"
              rm -f "$rt/plasma-lock.env"
              if is_loft; then
                printf '%s\n' PLASMA_DEFAULT_SHELL=dev.loft.desktop QML_XHR_ALLOW_FILE_READ=1 > "$rt/plasma-lock.env"
              fi
              ;;
            fallback)
              # loft-plasma-shell kept crashing (OnFailure): Plasma's shell takes over.
              "$0" use plasma
              notify-send -a Loft "Loft stopped" "Loft's shell kept crashing, so Plasma's shell took over. Run 'loft-plasma use loft' to try again." || true
              ;;
            *)
              echo "usage: loft-plasma status | use loft|plasma | check loft|plasma | lock-env" >&2
              exit 2
              ;;
          esac
        '';
      };

      # A Loft unit in a Plasma session: started with Plasma's workspace,
      # skipped unless this session is Loft's, and Requisite on KWin (like
      # niri.service above) so a crash restart never lands in another desktop.
      plasmaService = description: exec: {
        Unit = {
          Description = description;
          PartOf = [ "graphical-session.target" ];
          After = [
            "plasma-kwin_wayland.service"
            "plasma-ksmserver.service"
          ];
          Requisite = [ "plasma-kwin_wayland.service" ];
        };
        Service = {
          ExecCondition = "${lib.getExe loftPlasma} check loft";
          ExecStart = exec;
          # KWin's shortcuts take Meta, not niri's Right Alt Mod: holding Caps
          # Lock / Esc renders as a private key that sends Meta
          # (cli/loft/keys.py, docs/KWIN.md §4).
          Environment = env ++ [ "LOFT_WM_KEY=meta" ];
          Restart = "on-failure";
          RestartSec = 2;
        };
        Install.WantedBy = [ "plasma-workspace.target" ];
      };

      plasmaSessionUnits = [
        "loft-plasma-shell.service"
        "loft-plasma-launcher.service"
      ]
      ++ lib.optional cfg.keyboard.enable "loft-plasma-keys.service";
      plasmaUnits = lib.concatStringsSep " " plasmaSessionUnits;

      qdbus = "${pkgs.kdePackages.qttools}/bin/qdbus";

      # programs.loft.plasma.kwinPackage: plasma-kwin_wayland.service starts
      # this instead of the system's kwin_wayland_wrapper (same arguments).
      # The wrapper starts `kwin_wayland` from PATH, which in the session is
      # NixOS's /run/wrappers/bin/kwin_wayland (the system's KWin with
      # CAP_SYS_NICE): so a directory with this package's kwin_wayland goes
      # first, pointing at /run/wrappers/bin/loft-kwin_wayland when Loft's
      # NixOS module made that capability wrapper, else at the package.
      kwinPackage = cfg.plasma.kwinPackage;
      kwinLauncher = pkgs.writeShellScript "loft-kwin_wayland_wrapper" ''
        bin="''${XDG_RUNTIME_DIR:-/run/user/$(${pkgs.coreutils}/bin/id -u)}/loft/kwin-bin"
        ${pkgs.coreutils}/bin/mkdir -p "$bin"
        kwin=${kwinPackage}/bin/kwin_wayland
        [ -x /run/wrappers/bin/loft-kwin_wayland ] && kwin=/run/wrappers/bin/loft-kwin_wayland
        ${pkgs.coreutils}/bin/ln -sfn "$kwin" "$bin/kwin_wayland"
        PATH="$bin:$PATH" exec ${kwinPackage}/bin/kwin_wayland_wrapper "$@"
      '';
      # The tile modifier is set while Loft's shell runs, only with a KWin
      # that reads it.
      tileModifierOn = cfg.plasma.kwinPackage != null && cfg.plasma.tileModifier != null;

      # Loft's shortcuts in a Plasma session (cli/loft/kwinkeys.py, docs/KWIN.md
      # §5): the shell binds (+ Settings → Keyboard & Mouse → Keyboard Shortcuts) as a KWin script
      # of kglobalaccel shortcuts, loaded while loft-plasma-shell runs.
      # kglobalaccel lets two actions share a key (and then the other one
      # wins), so Loft also takes its keys off the shortcuts that have them
      # (KWin's Walk Through Windows, Plasma's System Settings…), recorded in
      # kwinShortcutsTaken. On unload the script goes, every Loft action is
      # unregistered and the taken keys are given back: kglobalshortcutsrc
      # ends up as it was, and plain Plasma's shortcuts with it.
      kwinShortcutsTaken = "${stateDir}/kwin-shortcuts-taken.json";
      releaseKwinShortcuts = pkgs.writeShellScript "loft-kwin-shortcuts-release" ''
        [ -e ${lib.escapeShellArg kwinShortcutsTaken} ] || exit 0
        PATH=${lib.makeBinPath [ pkgs.systemd ]}:$PATH \
          ${lib.getExe sp.loft} keys kwin release --record ${lib.escapeShellArg kwinShortcutsTaken}
      '';
      # Global Qt style (programs.loft.qt.global, cli/loft/qtglobal.py):
      # `start` applies it when the switch is on, `stop` puts the recorded
      # kdeglobals / Kvantum keys back. busctl sends KConfig's notifications.
      qtGlobal = verb: "${pkgs.writeShellScript "loft-qt-global" ''
        PATH=$PATH:${lib.makeBinPath [ pkgs.systemd ]}
        ${lib.concatMapStrings (e: "export ${lib.escapeShellArg e}\n") env}
        exec ${lib.getExe sp.loft} qt global "$1"
      ''} ${verb}";
      plasmaShortcuts = pkgs.writeShellScript "loft-plasma-shortcuts" ''
        set -u
        dir="''${XDG_RUNTIME_DIR:-/run/user/$(${pkgs.coreutils}/bin/id -u)}/loft/plasma-keys"
        script=loft-keys
        ${lib.concatMapStrings (e: "export ${lib.escapeShellArg e}\n") env}
        export PATH=${lib.makeBinPath [ pkgs.systemd ]}:$PATH
        unload() {
          ${qdbus} org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript "$script" >/dev/null 2>&1 || true
          if [ -r "$dir/names" ]; then
            while read -r name; do
              [ -n "$name" ] || continue
              ${qdbus} org.kde.kglobalaccel /kglobalaccel org.kde.KGlobalAccel.unregister kwin "$name" >/dev/null 2>&1 || true
            done < "$dir/names"
          fi
          ${releaseKwinShortcuts} || true
        }
        load() {
            # At login this runs as KWin is still starting: its /Scripting
            # object exists before its methods do ("Cannot find
            # loadScript"), and one try left Plasma without Loft's keys.
            # Wait for it (up to 60 s; ExecStartPost's limit is 90).
            i=0
            until ${qdbus} org.kde.KWin /Scripting 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q loadScript; do
              i=$((i + 1))
              if [ "$i" -ge 60 ]; then
                echo "loft-plasma-shortcuts: KWin's scripting interface never came up" >&2
                exit 1
              fi
              ${pkgs.coreutils}/bin/sleep 1
            done
            unload
            ${lib.getExe sp.loft} keys kwin render --binds ${shellBinds} --out "$dir" || exit 1
            id="$(${qdbus} org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript "$dir/$script.js" "$script")" || exit 1
            case "$id" in
              "" | -*) echo "loft-plasma-shortcuts: KWin didn't load $dir/$script.js" >&2; exit 1 ;;
            esac
            # Scripting.start runs every loaded script that isn't running yet
            # (not Script$id.run: KWin reuses ids, so that path can name
            # another script, e.g. loft-kwin's bridge).
            ${qdbus} org.kde.KWin /Scripting org.kde.kwin.Scripting.start >/dev/null || exit 1
            ${lib.getExe sp.loft} keys kwin claim --names "$dir/names" --record ${lib.escapeShellArg kwinShortcutsTaken}
        }
        # One verb at a time: loft-kwin's `heal` (crates/loft-kwin/src/heal.rs)
        # can come while the unit's load or unload runs.
        ${pkgs.coreutils}/bin/mkdir -p "''${dir%/*}"
        exec 9>"$dir.lock"
        ${pkgs.util-linux}/bin/flock 9
        case "''${1:-}" in
          load)
            load
            ;;
          heal)
            # From loft-kwin (docs/KWIN.md §4.18) when KWin lost loft-keys:
            # the same load, unless Loft unloaded it on purpose (no rendered
            # script: `unload` ran) or Loft's shell is starting or stopping
            # (its ExecStartPost loads it; its ExecStopPost unloads it).
            [ -e "$dir/$script.js" ] || exit 0
            systemctl --user is-active --quiet loft-plasma-shell.service || exit 0
            [ "$(${qdbus} org.kde.KWin /Scripting org.kde.kwin.Scripting.isScriptLoaded "$script" 2>/dev/null)" = false ] || exit 0
            echo "loft-plasma-shortcuts: KWin lost $script: loading it again"
            load
            ;;
          unload)
            # The rendered script first: from here on nothing heals it.
            ${pkgs.coreutils}/bin/rm -f "$dir/$script.js"
            unload
            ${pkgs.coreutils}/bin/rm -rf "$dir"
            ;;
          *) echo "usage: loft-plasma-shortcuts load|heal|unload" >&2; exit 2 ;;
        esac
      '';
      # What a shortcut runs: loft-plasma-key@<id>:<n>.service (the KWin
      # script starts a new instance per press) → <dir>/actions/<id>.
      plasmaKeyRun = pkgs.writeShellScript "loft-plasma-key" ''
        id="''${1%%:*}"
        case "$id" in "" | *[!a-z0-9-]*) echo "loft-plasma-key: bad action id '$id'" >&2; exit 2 ;; esac
        f="''${XDG_RUNTIME_DIR:-/run/user/$(${pkgs.coreutils}/bin/id -u)}/loft/plasma-keys/actions/$id"
        [ -r "$f" ] || { echo "loft-plasma-key: no action $id (Loft's shortcuts aren't loaded)" >&2; exit 0; }
        export PATH="${
          lib.makeBinPath [
            pkgs.coreutils
            pkgs.bash
            pkgs.kdePackages.qttools
            pkgs.quickshell
            sp.loft-launcher
            sp.loft
          ]
        }:$PATH"
        exec ${pkgs.bash}/bin/sh "$f"
      '';
    in
    {
      # programs.loft.spotify (./spotify.nix), then studio-linux (Loft's old
      # name): programs.studio-linux.* still works, with a deprecation
      # warning, until consumers move to programs.loft.
      imports = [
        (import ./spotify.nix { inherit self; })
      ]
      ++
        map
          (
            path:
            lib.mkRenamedOptionModule
              (
                [
                  "programs"
                  "studio-linux"
                ]
                ++ path
              )
              (
                [
                  "programs"
                  "loft"
                ]
                ++ path
              )
          )
          [
            [ "enable" ]
            [ "devSource" ]
            [
              "idle"
              "lockAfter"
            ]
            [
              "idle"
              "screenOffAfter"
            ]
            [ "iconTheme" ]
            [ "library" ]
            [ "theme" ]
          ];

      options.programs.loft = {
        enable = lib.mkEnableOption "the Loft shell (Quickshell) and launcher on niri";

        niriPackage = lib.mkOption {
          type = lib.types.package;
          default = pkgs.niri;
          defaultText = lib.literalExpression "pkgs.niri";
          example = lib.literalExpression "inputs.loft.packages.\${pkgs.stdenv.hostPlatform.system}.niri-loft";
          description = ''
            The niri the session runs: set it to the same package as the
            system's niri (`programs.niri.package`). With Loft's `niri-loft`
            (niri + nix/niri/workspace-layers.patch), each workspace's
            wallpaper slides with it on a switch and shows behind it in the
            overview: ~/.config/loft/niri.kdl then includes the
            `place-within-workspace` layer rule (which a stock niri would
            reject) and the shell turns the feature on. Also used for
            `niri msg` in the idle timeouts. On a NixOS host that imports
            Loft's NixOS module, the default is the system's
            `programs.niri.package` instead.
          '';
        };

        plasma.enable = lib.mkEnableOption ''
          Loft as the shell of a KDE Plasma session. The "Loft" login entry
          (Loft's NixOS module, `programs.loft.plasma.enable`) starts Plasma
          with KWin and the KDE services, and Loft's shell and launcher run
          in place of plasmashell; the plain "Plasma" entry keeps plasmashell.
          `loft-plasma use plasma|loft` switches a running session, and
          Plasma's shell takes over if Loft's keeps crashing. On a NixOS host
          with Loft's `programs.loft.plasma.enable`, this defaults to on'';

        plasma.kwinPackage = lib.mkOption {
          type = lib.types.nullOr lib.types.package;
          default = null;
          example = lib.literalExpression "inputs.loft.packages.\${system}.loft-kwin-patched";
          description = ''
            A KWin to run in Plasma sessions instead of the system's, e.g.
            Loft's `loft-kwin-patched` (KWin with kwinrc keys for the
            tile-while-dragging modifier, see `plasma.tileModifier`, and for
            sending the window menus apps with their own title bars ask for
            to Loft, set while Loft's shell runs). Loft's
            drop-in for plasma-kwin_wayland.service starts its
            kwin_wayland_wrapper; plain "Plasma" logins run it too (it behaves
            like stock KWin until the key is set). With Loft's NixOS option
            `programs.loft.plasma.kwinPackage` it keeps CAP_SYS_NICE (realtime
            scheduling) through /run/wrappers/bin/loft-kwin_wayland; set
            only here, KWin runs without it. null: the system's KWin
            (docs/KWIN.md §4.6).
          '';
        };

        plasma.tileModifier = lib.mkOption {
          type = lib.types.nullOr (
            lib.types.enum [
              "Shift"
              "Alt"
              "Ctrl"
              "Meta"
            ]
          );
          default = "Alt";
          description = ''
            The key that, held while dragging a window, shows KWin's tile
            zones and drops the window into one: Alt (Option) as on macOS.
            Set in kwinrc ([Windows] TileWhileMovingModifier) only while
            Loft's shell runs, and put back after. Needs a KWin that reads
            the key (`plasma.kwinPackage = loft-kwin-patched`); without one
            it is left alone. null: never touch it. Alt-drag stays free as
            long as Plasma's window-action modifier (System Settings → Window
            Management → Window Actions, kwinrc [MouseBindings] CommandAllKey)
            is Meta, its default; set to Alt, Alt+drag anywhere in a window
            moves it, and then tiles too.
          '';
        };

        agentSkills = {
          enable = lib.mkEnableOption ''
            Loft's coding-agent skills (skills/ in the Loft repo): `loft`
            (configuring Loft, writing window rules) and `loft-drive` (driving
            a test session), installed into `agentSkills.directory`
          '';
          directory = lib.mkOption {
            type = lib.types.str;
            default = ".claude/skills";
            description = "Where the skills go, relative to the home directory (one folder per skill).";
          };
        };

        devSource = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "/home/me/Development/loft";
          description = ''
            A Loft checkout to run the QML and launcher theme from
            (Quickshell hot-reloads on save). null runs the packaged copy.
          '';
        };

        idle = {
          lockAfter = lib.mkOption {
            type = lib.types.nullOr lib.types.ints.positive;
            default = 300;
            description = "Lock the session after this many idle seconds (null: never). Always locks before sleep.";
          };
          screenOffAfter = lib.mkOption {
            type = lib.types.nullOr lib.types.ints.positive;
            default = 600;
            description = "Turn the monitors off after this many idle seconds (null: never).";
          };
        };

        iconTheme = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = if config.gtk.iconTheme != null then config.gtk.iconTheme.name else null;
          defaultText = lib.literalExpression "config.gtk.iconTheme.name (when set)";
          example = "MacTahoe-blue";
          description = ''
            Icon theme for the shell (dock, bar, menus, switcher) — the same one
            GTK apps and the launcher use, so everything matches. null leaves
            Qt's default (hicolor), which has few app icons.
          '';
        };

        library = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = "${config.home.homeDirectory}/Documents/Loft";
          defaultText = lib.literalExpression ''"''${config.home.homeDirectory}/Documents/Loft"'';
          description = ''
            The theme + wallpaper library: installed packs in `Packs/`,
            your themes in `Themes/`, curated wallpapers in
            `Wallpapers/Topics/<Topic>/`, spaces in `Spaces/`, and the
            Colors / Tones / Themes views `loft library sort` generates.
            `loft library migrate --apply` moves a library from the old
            default (~/Documents/Themes, which becomes a symlink); until
            then the old one is used.
            Packs install here when it exists (otherwise into
            ~/.local/share/loft/themes, which stays searched either
            way). Not created by the module. null turns it off.
          '';
        };

        sleepWatcher = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Run `loft-sleep watch`, a user service that switches Bluetooth off
            before the system sleeps and back on after the wake — only while
            Settings → Everyday → "Turn Bluetooth off during sleep" is on (off
            by default). It listens for logind's PrepareForSleep on the system
            bus and talks to BlueZ as the user; no root.
          '';
        };

        phone = {
          enable = lib.mkEnableOption ''
            the iPhone bridge for Loft's phone feature: installs tether
            (github.com/zackb/tether) and runs its daemon, `tetherd`, as a user
            service (upstream's own unit, tetherd.service). Loft's Phone service
            talks to its socket, $XDG_RUNTIME_DIR/tetherd.sock. The Bluetooth
            half needs the system too — BlueZ with `Experimental = true` and the
            Hands-Free class unit (tether-btclass@hciN) — see
            docs/research/phone-integration.md and Settings → Phone. Turn the
            feature on in Settings → General → Features → iPhone once the phone is paired
          '';
          package = lib.mkOption {
            type = lib.types.package;
            default = pkgs.tether;
            defaultText = lib.literalExpression "pkgs.tether";
            description = "The tether package (tetherd, the `tether` CLI, tether-gtk).";
          };
        };

        gtk = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Style GTK 3/4 and libadwaita apps with the active theme: import
            `<state>/current/gtk.css` from ~/.config/gtk-{3,4}.0/gtk.css
            (palette, window radius, traffic lights, Nautilus's glass sidebar)
            and put the window buttons on the left, macOS style. Needs
            home-manager's `gtk.enable`.
          '';
        };

        qt = {
          enable = lib.mkEnableOption ''
            Qt / KDE apps (Dolphin) in the active theme's Golden Gate look:
            the `qt` render unit's Kvantum theme "Loft" (glass window that niri
            blurs, opaque file view, rounded selection pills) and KDE color
            scheme "Loft". Scoped to the apps in `apps`: Kvantum gets them in
            ~/.config/Kvantum/kvantum.kvconfig [Applications] (the global
            `theme=` is untouched) and each app's own rc file gets
            `[KDE] widgetStyle=kvantum` + `[UiSettings] ColorScheme=Loft`,
            which KDE apps read only without a KDE platform theme, so Plasma
            sessions and other Qt apps keep their look (cli/loft/qtapps.py).
            Apps pick a theme change up when restarted'';
          apps = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "dolphin" ];
            description = "KDE apps (binary names; their rc file is ~/.config/<name>rc) that get the Loft Kvantum theme and color scheme.";
          };
          global = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Theme every Qt / KDE app while Loft is the shell, not only
              `apps`: kdeglobals `[KDE] widgetStyle=kvantum` (`kvantum-dark`
              for a dark theme), `[General] ColorScheme=Loft` with the scheme's
              colour groups, and Kvantum's global `theme=Loft`. The previous
              values are recorded and put back when the shell stops (Plasma or
              niri), so plain Plasma keeps its look (docs/KWIN.md §4.14). The
              default for Settings → Appearance → "Theme all Qt apps", which
              wins once used (`loft qt global on|off`).
            '';
          };
          dolphinDefaults = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Finder-like Dolphin defaults (16 px Places icons, icon-only
              toolbar, locked panels), written into dolphinrc only where the
              key is absent: anything set in Dolphin's own settings wins.
            '';
          };
          dolphinLauncher = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Put a `dolphin` launcher first on PATH that starts
              `dolphinPackage` with `-stylesheet <state>/current/dolphin.qss`
              (the `qt` unit's style sheet: Places rows inset 10 px from the
              sidebar's edges, like Nautilus's). The .desktop entry runs
              `dolphin` from PATH, so the launcher, dock and terminal get it; a
              Dolphin started by D-Bus activation (org.freedesktop.FileManager1,
              "show in folder") runs the system binary and keeps edge-to-edge rows.
            '';
          };
          dolphinPackage = lib.mkOption {
            type = lib.types.package;
            default = pkgs.kdePackages.dolphin;
            defaultText = lib.literalExpression "pkgs.kdePackages.dolphin";
            description = "The Dolphin the launcher starts (use the system's, so the version matches).";
          };
          kvantumPackage = lib.mkOption {
            type = lib.types.package;
            default = pkgs.kdePackages.qtstyleplugin-kvantum;
            defaultText = lib.literalExpression "pkgs.kdePackages.qtstyleplugin-kvantum";
            description = "The Qt 6 Kvantum style plugin, installed into the user profile (its lib/qt-6/plugins must be on QT_PLUGIN_PATH, as on NixOS).";
          };
        };

        gtkBase = {
          dark = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            example = lib.literalExpression ''"''${pkgs.mactahoe-gtk-theme}/share/themes/MacTahoe-Dark-blue/gtk-4.0/gtk.css"'';
            description = ''
              A GTK 4 / libadwaita stylesheet imported under the theme's gtk.css
              while a dark theme is active (a full libadwaita theme such as
              MacTahoe's `-l` CSS). The theme's palette and Loft's Golden Gate
              rules (glass sidebar, edge-to-edge) still win over it.
            '';
          };
          light = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "The same for light themes.";
          };
        };

        features = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [
            "spaces"
            "-island"
          ];
          description = ''
            Defaults for the shell's optional modules (Settings → General → Features,
            ids in src/services/Features.qml): an id turns it on, `-id` off.
            A choice made in Settings → General → Features still wins.
          '';
        };

        windowRules = lib.mkOption {
          type = lib.types.attrsOf (lib.types.attrsOf (lib.types.oneOf [
            lib.types.bool
            lib.types.int
            lib.types.float
            lib.types.str
          ]));
          default = { };
          example = lib.literalExpression ''
            {
              # app id → where its windows open, on niri and under KDE.
              "org.kde.kwrite" = {
                open-on-activity = "Coding";   # a KDE Activity, by name (KWin)
                open-on-desktop = 2;           # KWin: desktop number or name; niri: a name = workspace
                open-on-output = "right";      # a display role (main, left, right, …) or a connector
                open-fullscreen = true;
                follow = false;                # stay where you are
              };
              # a name + match-app-id: a regex, with match-title.
              agents-coding = {
                match-app-id = "^com\.mitchellh\.ghostty$";
                match-title = "^claude";
                open-on-activity = "Coding";
                open-size = "1200x800";
              };
            }
          '';
          description = ''
            Per-app window rules shipped with the config, the same records as
            Settings → Window Rules and `loft windows rule` (fields:
            crates/loft-niri/src/window_rules.rs, docs/KWIN.md §4.17). Written
            to ~/.config/loft/window-rules.json; loft-niri renders them for
            niri under the runtime rules, and under KDE loft-kwin applies
            them as windows open (reloaded when the file changes). A field set
            in Settings / the CLI wins over the same field here.
          '';
        };

        workspaceIcons = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          example = {
            music = "󰝚";
            comms = "💬";
            scratch = "";
          };
          description = ''
            Icons for named niri workspaces in the menu bar (without Spaces),
            by workspace name (case-insensitive): a Nerd Font glyph or an
            emoji; "" = no icon (a dot). They replace the built-in guesses
            (src/services/wsicons.js); a choice made in Settings → Menu Bar →
            Workspace Icons still wins.
          '';
        };

        spaces = {
          enable = lib.mkEnableOption ''
            Spaces (docs/SPACES.md): functional desktops across every
            display. Turns the `spaces` feature on, includes the generated
            `overrides/spaces.kdl` (the spaces' workspaces, window rules and
            the Mod+1…9 / Mod+Shift+1…9 / Mod+Ctrl+arrows binds) in
            ~/.config/loft/niri.kdl, and renders it at login
            (spawn-at-startup), which also opens the spaces whose `startup`
            is `login`. Your niri config must then stop declaring those
            workspaces and binding Mod+1…9 itself (SPACES.md §8.1)'';

          documents = lib.mkOption {
            type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
            default = { };
            example = lib.literalExpression "{ music = lib.importJSON ./spaces/music.json; }";
            description = ''
              Space documents seeded into the library (`<library>/Spaces`)
              when they aren't there yet, never overwritten: edits made in
              Settings → Spaces & Windows → Spaces stay. `"kind": "space"` documents go to
              `<name>.json`, `"space-instance"` ones to `instances/`,
              `"space-template"` ones to `templates/`. As soon as the library
              has any space of its own, those replace the built-in set, so
              list all of them (or none: then the first edit copies the
              built-ins in).
            '';
          };
        };

        keyboard = {
          enable = lib.mkEnableOption ''
            Loft's keyboard layer: macOS-style remaps (Super = Cmd, Esc / Caps
            hold = the window-manager key, Option word navigation, per-app
            extras), run by xremap from the config Loft renders
            (`loft keys xremap`, cli/loft/keys.py). Change it at runtime with
            `loft keys …` (or the loft_keys_* MCP tools); what you set here is
            the seed those changes go on top of. Needs read access to
            /dev/input and /dev/uinput: the user in the `input` and `uinput`
            groups, `hardware.uinput.enable` on NixOS'';

          package = lib.mkOption {
            type = lib.types.package;
            default = pkgs.xremap.niri;
            defaultText = lib.literalExpression "pkgs.xremap.niri";
            description = "xremap, built with niri support (per-app remaps follow the focused niri window).";
          };

          plasmaPackage = lib.mkOption {
            type = lib.types.package;
            default = pkgs.xremap.kde;
            defaultText = lib.literalExpression "pkgs.xremap.kde";
            description = ''
              xremap for a Plasma session (programs.loft.plasma), built with KDE
              support: it loads a KWin script that reports the focused window,
              so per-app remaps follow it.
            '';
          };

          groups = lib.mkOption {
            type = lib.types.attrsOf lib.types.bool;
            default = { };
            example = {
              symbols = true;
              right-ctrl-mod = true;
              browser = false;
            };
            description = ''
              Remap groups on / off by id (`loft keys show` lists them; the
              defaults are cli/loft/keymap/mac.json). `loft keys group` still wins.
            '';
          };

          classes = lib.mkOption {
            type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
            default = { };
            example = {
              daws = {
                name = "DAWs";
                apps = [ "REAPER" ];
              };
            };
            description = ''
              App classes, or more apps for Loft's own (terminals, browsers,
              fileManagers, codeEditors, jetbrains): `{ name; apps; }` by id.
              Groups name a class as `@id` in their application lists.
            '';
          };

          apps = lib.mkOption {
            type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
            default = { };
            example = {
              "dev.cody.term".like = [ "terminals" ];
              REAPER = {
                off = [ "cmd" ];
                remap."Super_L-s" = "Ctrl-s";
              };
            };
            description = ''
              Per-app rules by niri app id: `like` (join classes), `off`
              (groups off in this app), `remap` (the app's own remaps, which
              win over every group). Runtime `loft keys app` changes go on top.
            '';
          };

          remap = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = { };
            example = {
              "Super_L-F1" = "F1";
            };
            description = "Remaps in every app (xremap key names), before the groups.";
          };

          extraGroups = lib.mkOption {
            type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
            default = [ ];
            description = ''
              More groups, after Loft's: `{ id; name; section ? "keymap";
              application ? { only | not = [ … "@class" ]; }; remap; on ? true; }`.
              A group with the id of one of Loft's replaces it.
            '';
          };
        };

        theme = lib.mkOption {
          type = lib.types.str;
          default = "default";
          description = ''
            Theme applied on first start (when nothing is active yet). After
            that the runtime choice (`loft theme apply`, the selector) wins.
          '';
        };
      };

      config = lib.mkIf cfg.enable {
        assertions = [
          {
            assertion = cfg.spaces.documents == { } || spacesDir != null;
            message = "programs.loft.spaces.documents needs programs.loft.library (the documents live in <library>/Spaces).";
          }
        ];

        home.packages = [
          sp.loft
          sp.loft-launcher
        ]
        ++ lib.optional cfg.phone.enable cfg.phone.package
        ++ lib.optionals cfg.plasma.enable [
          loftPlasma
          # The lock screen's shell package, also for hosts without Loft's
          # NixOS module (which installs it system-wide).
          sp.loft-plasma-lockscreen
          # `loft-kwin send|state|shot` for `loft mcp` and terminals (the
          # shell and Spotlight have it on their own PATH).
          sp.loft-kwin
        ]
        ++ lib.optional cfg.qt.enable cfg.qt.kvantumPackage
        ++ lib.optional (cfg.qt.enable && cfg.qt.dolphinLauncher) dolphinLauncher;

        # `loft` in terminals sees the same library as the shell.
        home.sessionVariables.LOFT_LIBRARY = library;

        gtk = lib.mkIf cfg.gtk (
          let
            css = ''
              /* Loft: the active theme (programs.loft.gtk) */
              @import url("file://${stateDir}/current/gtk.css");
            '';
            # GTK 4 only: GTK 3 apps get their base from gtk-theme-name.
            css4 = ''
              /* Loft: base stylesheet for the theme's polarity (programs.loft.gtkBase) */
              @import url("file://${stateDir}/gtk-base.css");
            ''
            + css;
            layout.gtk-decoration-layout = lib.mkDefault "close,minimize,maximize:";
          in
          {
            gtk3.extraCss = css;
            gtk4.extraCss = css4;
            gtk3.extraConfig = layout;
            gtk4.extraConfig = layout;
          }
        );
        xdg.configFile."loft/gtk-base-dark.css" = lib.mkIf (cfg.gtk && cfg.gtkBase.dark != null) {
          text = ''@import url("file://${cfg.gtkBase.dark}");'';
        };
        xdg.configFile."loft/gtk-base-light.css" = lib.mkIf (cfg.gtk && cfg.gtkBase.light != null) {
          text = ''@import url("file://${cfg.gtkBase.light}");'';
        };
        # programs.loft.windowRules: the seed loft-niri merges under the
        # runtime window rules (and loft-kwin applies under KDE).
        xdg.configFile."loft/window-rules.json" = lib.mkIf (cfg.windowRules != { }) {
          text = builtins.toJSON cfg.windowRules;
        };
        # Qt / KDE apps (programs.loft.qt): what the `qt` hook reads, and a
        # first sync so the app is themed before the next `loft theme apply`.
        xdg.configFile."loft/qt.json" = lib.mkIf cfg.qt.enable {
          text = builtins.toJSON {
            inherit (cfg.qt) apps dolphinDefaults global;
            iconTheme = cfg.iconTheme;
          };
        };
        home.activation.loftQt = lib.mkIf cfg.qt.enable (
          lib.hm.dag.entryAfter [ "writeBoundary" ] ''
            run env LOFT_STATE_DIR=${lib.escapeShellArg stateDir} \
              XDG_CONFIG_HOME=${lib.escapeShellArg config.xdg.configHome} \
              XDG_DATA_HOME=${lib.escapeShellArg config.xdg.dataHome} \
              ${lib.getExe sp.loft} qt sync || true
          ''
        );

        # libadwaita reads the button layout from the settings portal (GNOME's
        # key) before settings.ini.
        dconf.settings = lib.mkIf cfg.gtk {
          "org/gnome/desktop/wm/preferences".button-layout = lib.mkDefault "close,minimize,maximize:";
        };

        home.file = lib.mkIf cfg.agentSkills.enable (
          lib.genAttrs' [ "loft" "loft-drive" ] (
            name:
            lib.nameValuePair "${cfg.agentSkills.directory}/${name}/SKILL.md" {
              source = ../../skills/${name}/SKILL.md;
            }
          )
        );

        xdg.configFile."loft/niri.kdl".text = ''
          // Generated by programs.loft — include it after your binds.
          include "${shellBinds}"
          include optional=true "${stateDir}/current/niri.kdl"
        ''
        # Spaces: after the theme, before the runtime overrides (as in
        # loft-session); included once, since a workspace declared twice
        # exists twice.
        + lib.optionalString cfg.spaces.enable ''
          include optional=true "${stateDir}/overrides/spaces.kdl"
          spawn-at-startup "${spacesStartup}"
        ''
        + ''
          include optional=true "${stateDir}/overrides/niri.kdl"
        ''
        + lib.optionalString workspaceLayers ''
          include "${self}/niri/workspace-wallpapers.kdl"
        ''
        + lib.optionalString titleBar ''
          include "${self}/niri/title-bar.kdl"
          include optional=true "${stateDir}/current/niri-loft.kdl"
        ''
        # `loft-live` (nix/dev/loft-live.sh): a checkout's fragments over these
        # while it runs the desktop; the file only exists then.
        + ''
          include optional=true "${stateDir}/dev/niri.kdl"
        '';

        xdg.configFile."loft/niri-early.kdl".text = ''
          // Generated by programs.loft — include it FIRST in your niri
          // config, so display changes from Loft Settings win over your own
          // output blocks (niri uses the first block matching a monitor).
          include optional=true "${stateDir}/overrides/niri.kdl"
        '';

        systemd.user.services.loft-shell =
          lib.recursiveUpdate (service "Loft shell (Quickshell)" (lib.getExe sp.loft-shell))
            {
              # A crash ends the process and the unit restarts it with a clean
              # cgroup. Quickshell's own crash restart re-executes in place, and
              # the crashed image's helpers (nmcli / udisksctl monitors,
              # watchers) live on next to the new ones, then as zombies.
              Service.Environment = env ++ [
                "QS_DISABLE_CRASH_HANDLER=1"
                "LOFT_WM_KEY=ralt"
              ];
              # Stands down while `loft-live` runs a checkout's shell: a
              # switch or a crash restart can't start this one underneath.
              Unit.ConditionPathExists = "!%t/loft-live/active";
              # First start: apply the configured theme if none is active yet.
              Service.ExecStartPre = "${pkgs.writeShellScript "loft-first-theme" ''
                [ -e "${stateDir}/current/theme.json" ] && exit 0
                ${lib.concatMapStrings (e: "export ${e}\n") env}
                ${lib.getExe sp.loft} theme apply ${lib.escapeShellArg cfg.theme} || true
              ''}";
              # Global Qt style under niri too (docs/KWIN.md §4.14): KDE apps
              # read kdeglobals at start; put back when the shell stops.
              Service.ExecStartPost = lib.optional cfg.qt.enable "-${qtGlobal "start"}";
              Service.ExecStopPost = [ "-${qtGlobal "stop"}" ];
            };

        # programs.loft.keyboard: the seed, and xremap on Loft's config. The
        # shell and `loft keys …` rewrite the config; --watch=config reloads it.
        xdg.configFile."loft/keyboard.json" = lib.mkIf cfg.keyboard.enable {
          text = builtins.toJSON keyboardSeed;
        };
        systemd.user.services.loft-keys = lib.mkIf cfg.keyboard.enable (
          lib.recursiveUpdate
            (service "Loft keyboard layer (xremap)" "${lib.getExe cfg.keyboard.package} --mouse --watch=config,device ${keymapConfig}")
            {
              Service.ExecStartPre = [
                "${findNiriSocket}"
                "${keymapStart}"
              ];
            }
        );

        # niri can end without a stop job (a killed session, a crash), and
        # PartOf only follows stop jobs: then the shell and xremap would live
        # on into the next desktop. ExecStopPost runs however niri ended.
        xdg.configFile."systemd/user/niri.service.d/50-loft.conf".text = ''
          [Service]
          ExecStopPost=-${pkgs.systemd}/bin/systemctl --user --no-block stop ${lib.concatStringsSep " " loftSessionUnits}
        '';

        # Idle: lock through the shell (its WlSessionLock) and blank the screens.
        services.swayidle = {
          enable = true;
          # Its lock and blanking go through Loft and niri.
          systemdTarget = lib.mkDefault "niri.service";
          timeouts =
            lib.optional (cfg.idle.lockAfter != null) {
              timeout = cfg.idle.lockAfter;
              command = lockCmd;
            }
            ++ lib.optional (cfg.idle.screenOffAfter != null) {
              timeout = cfg.idle.screenOffAfter;
              command = "${lib.getExe cfg.niriPackage} msg action power-off-monitors";
            };
          events.before-sleep = lockCmd;
          # logind's Lock signal (`loginctl lock-session`): how tetherd's away
          # lock (Settings → Phone) and other session tools reach the shell.
          events.lock = lockCmd;
        };

        # The iPhone bridge (programs.loft.phone): upstream's tetherd.service,
        # with the store path. Not tied to the graphical session — tetherd runs
        # without Wayland, it just skips clipboard sync then.
        systemd.user.services.tetherd = lib.mkIf cfg.phone.enable {
          Unit = {
            Description = "Tether daemon, bridging an iPhone to this computer";
            Documentation = "https://github.com/zackb/tether";
            After = [
              "dbus.socket"
              "network.target"
              "bluetooth.target"
            ];
            StartLimitIntervalSec = 60;
            StartLimitBurst = 3;
          };
          Service = {
            Type = "simple";
            ExecStart = "${cfg.phone.package}/bin/tetherd";
            Restart = "on-failure";
            RestartSec = 3;
            # tetherd keeps its own log in $XDG_STATE_HOME/tether.
            StandardOutput = "null";
            StandardError = "journal";
          };
          Install.WantedBy = [ "default.target" ];
        };

        # Spotlight must open instantly however long it sat idle: walker and
        # elephant stay in RAM (no swap, and their memory — libraries, icons
        # included — isn't reclaimed under pressure). Paging them back in
        # from swap made the first open after a while take seconds.
        systemd.user.services.loft-launcher =
          lib.recursiveUpdate
            (service "Loft launcher (walker + elephant)" "${lib.getExe sp.loft-launcher} service")
            {
              Service.MemorySwapMax = 0;
              Service.MemoryMin = "512M";
              # Stands down while `loft-live` runs a checkout's launcher.
              Unit.ConditionPathExists = "!%t/loft-live/active";
            };

        # Bluetooth off during sleep (crates/loft-sleep); idle until the
        # setting is switched on.
        systemd.user.services.loft-sleep = lib.mkIf cfg.sleepWatcher (
          lib.recursiveUpdate
            (service "Loft sleep watcher (Bluetooth off during sleep)" "${lib.getExe sp.loft-sleep} watch")
            {
              Service.RestartSec = 5;
            }
        );

        # programs.loft.plasma: the shell and launcher in a Plasma session
        # started from the "Loft" entry (see loftPlasma above).
        systemd.user.services.loft-plasma-shell = lib.mkIf cfg.plasma.enable (
          lib.recursiveUpdate (plasmaService "Loft shell in Plasma (Quickshell)" (lib.getExe sp.loft-shell)) {
            Service.Environment = env ++ [
              "QS_DISABLE_CRASH_HANDLER=1"
              "LOFT_WM_KEY=meta"
              # loft-kwin's healer reloads Loft's shortcuts through it
              # (`heal`, docs/KWIN.md §4.18).
              "LOFT_PLASMA_SHORTCUTS=${plasmaShortcuts}"
            ];
            # The same first-start theme as on niri.
            Service.ExecStartPre = config.systemd.user.services.loft-shell.Service.ExecStartPre;
            # While Loft runs: Loft's title bars and Loft's shortcuts; when it
            # stops or crashes, the previous decoration and the shortcuts it
            # took come back (docs/KWIN.md §5: no traces in Plasma). `-`: a
            # failure here costs that piece, never the shell.
            Service.ExecStartPost = [
              "-${lib.getExe sp.loft-kwin-decoration} apply"
              "-${plasmaShortcuts} load"
            ]
            # Global Qt style (docs/KWIN.md §4.14): applies only when on.
            ++ lib.optional cfg.qt.enable "-${qtGlobal "start"}"
            # Option-drag tiles (docs/KWIN.md §4.6).
            ++ lib.optional tileModifierOn "-${lib.getExe sp.loft-kwin-tile-modifier} apply ${cfg.plasma.tileModifier}"
            # Apps' own window menus (GTK, Chromium) are Loft's (docs/KWIN.md §4.4).
            ++ lib.optional (cfg.plasma.kwinPackage != null) "-${lib.getExe sp.loft-kwin-window-menu} apply";
            # revert always: a no-op without a record, and it cleans up after
            # the option is turned off.
            Service.ExecStopPost = [
              "-${lib.getExe sp.loft-kwin-decoration} revert"
              "-${plasmaShortcuts} unload"
              "-${lib.getExe sp.loft-kwin-tile-modifier} revert"
              "-${lib.getExe sp.loft-kwin-window-menu} revert"
              # A no-op without a record (programs.loft.qt off too).
              "-${qtGlobal "stop"}"
            ];
            Unit.ConditionPathExists = "!%t/loft-live/active";
            # Three crashes in a minute: Plasma's shell takes over, so a
            # broken Loft never leaves the session without a desktop.
            Unit.StartLimitIntervalSec = 60;
            Unit.StartLimitBurst = 3;
            Unit.OnFailure = [ "loft-plasma-fallback.service" ];
          }
        );
        # A Loft shortcut's command (see plasmaKeyRun). Instances are per
        # key press; collected as soon as they end, failed or not.
        systemd.user.services."loft-plasma-key@" = lib.mkIf cfg.plasma.enable {
          Unit = {
            Description = "Loft shortcut %i";
            CollectMode = "inactive-or-failed";
          };
          Service = {
            Type = "exec";
            ExecStart = "${plasmaKeyRun} %i";
            Environment = env;
          };
        };
        # The keyboard layer in a Loft Plasma session: xremap with KDE
        # support on the same config as loft-keys (which needs niri and so
        # never runs here; Conflicts makes sure only one xremap does).
        systemd.user.services.loft-plasma-keys = lib.mkIf (cfg.plasma.enable && cfg.keyboard.enable) (
          lib.recursiveUpdate
            (plasmaService "Loft keyboard layer in Plasma (xremap, KDE)" "${lib.getExe cfg.keyboard.plasmaPackage} --mouse --watch=config,device ${keymapConfig}")
            {
              Unit.Conflicts = [ "loft-keys.service" ];
              Service.Environment = env ++ [
                "KDE_SESSION_VERSION=6"
                "LOFT_WM_KEY=meta"
              ];
              Service.ExecStartPre = [ "${keymapStart}" ];
              # xremap's focus script ("xremap") outlives xremap in KWin.
              Service.ExecStopPost = "-${qdbus} org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript xremap";
            }
        );
        systemd.user.services.loft-plasma-launcher = lib.mkIf cfg.plasma.enable (
          lib.recursiveUpdate
            (plasmaService "Loft launcher in Plasma (walker + elephant)" "${lib.getExe sp.loft-launcher} service")
            {
              Service.MemorySwapMax = 0;
              Service.MemoryMin = "512M";
              Unit.ConditionPathExists = "!%t/loft-live/active";
            }
        );
        systemd.user.services.loft-plasma-fallback = lib.mkIf cfg.plasma.enable {
          Unit.Description = "Hand the Plasma session from Loft's shell to plasmashell";
          Service = {
            Type = "oneshot";
            ExecStart = "${lib.getExe loftPlasma} fallback";
          };
        };

        # plasmashell skips itself in a Loft session (and runs otherwise).
        xdg.configFile."systemd/user/plasma-plasmashell.service.d/50-loft.conf" = lib.mkIf cfg.plasma.enable {
          text = ''
            [Service]
            ExecCondition=${lib.getExe loftPlasma} check plasma
            # Keys Loft took for its shortcuts and never gave back (the session
            # ended without stopping Loft's shell): back to their owners.
            ExecStartPre=-${releaseKwinShortcuts}
            # The same for the global Qt style's kdeglobals / Kvantum keys.
            ExecStartPre=-${qtGlobal "stop"}
          '';
        };
        # KWin's drop-in. ExecStopPost, as with niri: KWin can end without a
        # stop job, and PartOf only follows stop jobs.
        # Lock screen (docs/KWIN.md §4.3): in a Loft session KWin starts with
        # PLASMA_DEFAULT_SHELL=dev.loft.desktop, so Plasma's locker draws Loft's
        # design (the shell package from Loft's NixOS module / home.packages).
        # Only KWin's environment: plasmashell and the user manager don't see
        # it, and plain "Plasma" logins keep Breeze's lock screen. Both lines
        # are `-`: no file, or a failing check, just means the stock locker.
        xdg.configFile."systemd/user/plasma-kwin_wayland.service.d/50-loft.conf" = lib.mkIf cfg.plasma.enable {
          text = ''
            [Service]
            ExecStartPre=-${lib.getExe loftPlasma} lock-env
            EnvironmentFile=-%t/loft/plasma-lock.env
          ''
          # Global Qt style (docs/KWIN.md §4.14): KWin reads its widget style
          # once, at start, so a Loft login applies it before KWin starts (the
          # shell's own start would come too late for KWin's menus). Plain
          # "Plasma" logins put back what a session that ended without a stop
          # job left.
          + lib.optionalString cfg.qt.enable ''
            ExecStartPre=-${pkgs.writeShellScript "loft-qt-global-kwin" ''
              if ${lib.getExe loftPlasma} check loft; then exec ${qtGlobal "start"}; else exec ${qtGlobal "stop"}; fi
            ''}
          ''
          + ''
            ExecStopPost=-${pkgs.systemd}/bin/systemctl --user --no-block stop ${plasmaUnits}
          ''
          # programs.loft.plasma.kwinPackage: that KWin, with the stock unit's
          # arguments (plasma-workspace's plasma-kwin_wayland.service:
          # `kwin_wayland_wrapper --xwayland`). For every Plasma login.
          + lib.optionalString (kwinPackage != null) ''
            ExecStart=
            ExecStart=${kwinLauncher} --xwayland
          '';
        };

        # programs.loft.spaces.documents → the library, once (never
        # overwritten: Settings → Spaces & Windows → Spaces edits them there).
        home.activation.loftSpaces = lib.mkIf (cfg.spaces.documents != { } && spacesDir != null) (
          lib.hm.dag.entryAfter [ "writeBoundary" ] (
            lib.concatStrings (
              lib.mapAttrsToList (
                name: doc:
                let
                  sub =
                    {
                      "space-instance" = "instances/";
                      "space-template" = "templates/";
                    }
                    .${doc.kind or "space"} or "";
                  file = "${spacesDir}/${sub}${name}.json";
                  src = pkgs.writeText "loft-space-${name}.json" (builtins.toJSON doc);
                in
                ''
                  if [ ! -e ${lib.escapeShellArg file} ]; then
                    run mkdir -p "$(dirname ${lib.escapeShellArg file})"
                    run install -m 644 ${src} ${lib.escapeShellArg file}
                  fi
                ''
              ) cfg.spaces.documents
            )
          )
        );

        # studio-linux (Loft's old name): move its state, data and cache dirs
        # before anything writes the new ones (nix/migrate.sh), and link the
        # old config dir once home-manager has removed its old files there.
        home.activation.loftMigrate = lib.hm.dag.entryBefore [ "writeBoundary" ] ''
          ${migrate} || echo "loft-migrate failed; studio-linux's state stays where it was" >&2
        '';
        home.activation.loftMigrateConfig = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
          ${migrate} config || true
        '';

        # Restart the shell/launcher when their unit changed — even when the
        # home's systemd.user.startServices is "suggest" (kept so a switch
        # never restarts other user services, e.g. audio). Compares a hash of
        # each unit as systemd now sees it with the one from the last switch.
        home.activation.loftRestart = lib.hm.dag.entryAfter [ "reloadSystemd" ] ''
          # No user manager to talk to (home-manager-<user>.service at boot,
          # or a switch for someone not logged in): nothing runs, so nothing
          # to restart, and the unit hashes stay as they were for the next
          # switch. Like reloadSystemd, skip instead of failing activation.
          export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(${pkgs.coreutils}/bin/id -u)}"
          if [ ! -S "$XDG_RUNTIME_DIR/bus" ]; then
            echo "User systemd daemon not running. Skipping the Loft shell/launcher restart."
          else
            state="''${XDG_STATE_HOME:-$HOME/.local/state}/loft"
            run mkdir -p "$state"
            # Units still running under their studio-linux names (a "suggest"
            # switch leaves removed units running): hand over to the new ones.
            started=" "
            # The same for a plain xremap.service once Loft runs the keyboard
            # layer: two xremaps would remap every key twice.
            for pair in studio-shell:loft-shell studio-launcher:loft-launcher${lib.optionalString cfg.keyboard.enable " xremap:loft-keys"}; do
              if ${pkgs.systemd}/bin/systemctl --user is-active --quiet "''${pair%%:*}.service"; then
                run ${pkgs.systemd}/bin/systemctl --user stop "''${pair%%:*}.service" || true
                run ${pkgs.systemd}/bin/systemctl --user start "''${pair#*:}.service" || true
                started="$started''${pair#*:} "
              fi
            done
            for unit in loft-shell loft-launcher loft-keys${lib.optionalString cfg.plasma.enable " loft-plasma-shell loft-plasma-launcher"}${
              lib.optionalString (cfg.plasma.enable && cfg.keyboard.enable) " loft-plasma-keys"
            }; do
              new="$( { ${pkgs.systemd}/bin/systemctl --user cat "$unit.service" 2>/dev/null || true; } | ${pkgs.coreutils}/bin/sha256sum | cut -d' ' -f1)"
              old="$(cat "$state/$unit.unit-hash" 2>/dev/null || true)"
              if [ "$new" != "$old" ]; then
                case "$started" in
                  *" $unit "*) ;; # just started above
                  *)
                    if ${pkgs.systemd}/bin/systemctl --user is-active --quiet "$unit.service"; then
                      run ${pkgs.systemd}/bin/systemctl --user restart "$unit.service" || true
                    fi
                    ;;
                esac
                [ -n "''${DRY_RUN:-}" ] || echo "$new" > "$state/$unit.unit-hash"
                started="$started$unit "
              fi
            done
            # Installed apps changed (a .desktop added or removed in the profile
            # or the system): the launcher's index watches the old profile path,
            # so re-index by restarting it.
            apps="$( { ${pkgs.coreutils}/bin/ls "$newGenPath/home-path/share/applications" 2>/dev/null; \
              ${pkgs.coreutils}/bin/ls /run/current-system/sw/share/applications 2>/dev/null || true; } \
              | ${pkgs.coreutils}/bin/sha256sum | cut -d' ' -f1)"
            if [ "$apps" != "$(cat "$state/apps.hash" 2>/dev/null || true)" ]; then
              case "$started" in
                *" loft-launcher "*) ;;
                *)
                  if ${pkgs.systemd}/bin/systemctl --user is-active --quiet loft-launcher.service; then
                    run ${pkgs.systemd}/bin/systemctl --user restart loft-launcher.service || true
                  fi
                  ;;
              esac
              [ -n "''${DRY_RUN:-}" ] || echo "$apps" > "$state/apps.hash"
            fi
          fi
        '';
      };
    };
}
