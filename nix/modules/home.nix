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
      # Quickshell is a Qt app with no platform theme: without this it falls
      # back to hicolor and the dock/bar show generic icons.
      ++ lib.optional (cfg.iconTheme != null) "QS_ICON_THEME=${cfg.iconTheme}";

      service = description: exec: {
        Unit = {
          Description = description;
          PartOf = [ "graphical-session.target" ];
          After = [ "graphical-session.target" ];
        };
        Service = {
          ExecStart = exec;
          Environment = env;
          Restart = "on-failure";
          RestartSec = 2;
        };
        # Started by niri's session unit, not graphical-session.target — other
        # desktops (Plasma, GNOME) reach that target too, and must not get
        # a second bar.
        Install.WantedBy = [ "niri.service" ];
      };
    in
    {
      # studio-linux (Loft's old name): programs.studio-linux.* still works,
      # with a deprecation warning, until consumers move to programs.loft.
      imports =
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
          default = "${config.home.homeDirectory}/Documents/Themes";
          defaultText = lib.literalExpression ''"''${config.home.homeDirectory}/Documents/Themes"'';
          description = ''
            The theme + wallpaper library: installed packs in `Packs/`,
            curated wallpapers in `Wallpapers/Topics/<Topic>/`, and the
            Colors / Tones / Themes views `loft library sort` generates.
            Packs install here when it exists (otherwise into
            ~/.local/share/loft/themes, which stays searched either
            way). Not created by the module. null turns it off.
          '';
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
        home.packages = [
          sp.loft
          sp.loft-launcher
        ];

        # `loft` in terminals sees the same library as the shell.
        home.sessionVariables.LOFT_LIBRARY = library;

        xdg.configFile."loft/niri.kdl".text = ''
          // Generated by programs.loft — include it after your binds.
          include "${shellBinds}"
          include optional=true "${stateDir}/current/niri.kdl"
          include optional=true "${stateDir}/overrides/niri.kdl"
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
              # First start: apply the configured theme if none is active yet.
              Service.ExecStartPre = "${pkgs.writeShellScript "loft-first-theme" ''
                [ -e "${stateDir}/current/theme.json" ] && exit 0
                ${lib.concatMapStrings (e: "export ${e}\n") env}
                ${lib.getExe sp.loft} theme apply ${lib.escapeShellArg cfg.theme} || true
              ''}";
            };

        # Idle: lock through the shell (its WlSessionLock) and blank the screens.
        services.swayidle = {
          enable = true;
          timeouts =
            lib.optional (cfg.idle.lockAfter != null) {
              timeout = cfg.idle.lockAfter;
              command = lockCmd;
            }
            ++ lib.optional (cfg.idle.screenOffAfter != null) {
              timeout = cfg.idle.screenOffAfter;
              command = "${lib.getExe pkgs.niri} msg action power-off-monitors";
            };
          events = [
            {
              event = "before-sleep";
              command = lockCmd;
            }
          ];
        };

        systemd.user.services.loft-launcher = service "Loft launcher (walker + elephant)" "${lib.getExe sp.loft-launcher} service";

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
          state="''${XDG_STATE_HOME:-$HOME/.local/state}/loft"
          run mkdir -p "$state"
          # Units still running under their studio-linux names (a "suggest"
          # switch leaves removed units running): hand over to the new ones.
          started=" "
          for pair in studio-shell:loft-shell studio-launcher:loft-launcher; do
            if ${pkgs.systemd}/bin/systemctl --user is-active --quiet "''${pair%%:*}.service"; then
              run ${pkgs.systemd}/bin/systemctl --user stop "''${pair%%:*}.service" || true
              run ${pkgs.systemd}/bin/systemctl --user start "''${pair#*:}.service" || true
              started="$started''${pair#*:} "
            fi
          done
          for unit in loft-shell loft-launcher; do
            new="$(${pkgs.systemd}/bin/systemctl --user cat "$unit.service" 2>/dev/null | ${pkgs.coreutils}/bin/sha256sum | cut -d' ' -f1)"
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
            fi
          done
        '';
      };
    };
}
