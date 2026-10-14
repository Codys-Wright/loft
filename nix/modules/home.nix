# home-manager module: programs.studio-linux.
#
# Runs the shell and the launcher as systemd user services in the graphical
# session, puts the `studio` CLI on PATH, and writes a niri fragment the
# consumer's own niri config includes (after its binds):
#
#   include optional=true "~/.config/studio-linux/niri.kdl"
#
# The fragment holds the shell keybinds, the active theme's niri.kdl and,
# last, the runtime overrides from Studio Settings (studio-niri), so a
# consumer keeps its own outputs, layout and binds (PLAN §1a) and runtime
# changes win over them.
#
# niri uses the FIRST `output` block matching a monitor, so for display
# overrides to win over the consumer's own output blocks, also include this
# at the very top of the niri config:
#
#   include optional=true "~/.config/studio-linux/niri-early.kdl"
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
      cfg = config.programs.studio-linux;
      sp = self.packages.${pkgs.stdenv.hostPlatform.system};

      # The QML the shell runs: the store copy, or a checkout for live edits.
      shellSrc = if cfg.devSource != null then "${cfg.devSource}/src" else "${self}/src";
      stateDir = "${config.xdg.stateHome}/studio-linux";

      shellBinds = pkgs.runCommand "studio-shell-binds.kdl" { } ''
        sed 's|@IPC@|"${lib.getExe pkgs.quickshell}" "ipc" "--path" "${shellSrc}" "call"|g' \
          ${self}/niri/shell-binds.kdl.in > $out
      '';

      lockCmd = "${lib.getExe pkgs.quickshell} ipc --path ${shellSrc} call lock lock";

      # The theme + wallpaper library (cli/studio/library.py); "none" = off.
      library = if cfg.library != null then cfg.library else "none";

      env = [
        "STUDIO_STATE_DIR=${stateDir}"
        "STUDIO_SHELL_SRC=${shellSrc}"
        "STUDIO_LIBRARY=${library}"
      ]
      ++ lib.optional (cfg.devSource != null) "STUDIO_LAUNCHER_DIR=${cfg.devSource}/launcher"
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
      options.programs.studio-linux = {
        enable = lib.mkEnableOption "the studio-linux shell (Quickshell) and launcher on niri";

        devSource = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "/home/me/Development/studio-linux";
          description = ''
            A studio-linux checkout to run the QML and launcher theme from
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
            Colors / Tones / Themes views `studio library sort` generates.
            Packs install here when it exists (otherwise into
            ~/.local/share/studio-linux/themes, which stays searched either
            way). Not created by the module. null turns it off.
          '';
        };

        theme = lib.mkOption {
          type = lib.types.str;
          default = "default";
          description = ''
            Theme applied on first start (when nothing is active yet). After
            that the runtime choice (`studio theme apply`, the selector) wins.
          '';
        };
      };

      config = lib.mkIf cfg.enable {
        home.packages = [
          sp.studio
          sp.studio-launcher
        ];

        # `studio` in terminals sees the same library as the shell.
        home.sessionVariables.STUDIO_LIBRARY = library;

        xdg.configFile."studio-linux/niri.kdl".text = ''
          // Generated by programs.studio-linux — include it after your binds.
          include "${shellBinds}"
          include optional=true "${stateDir}/current/niri.kdl"
          include optional=true "${stateDir}/overrides/niri.kdl"
        '';

        xdg.configFile."studio-linux/niri-early.kdl".text = ''
          // Generated by programs.studio-linux — include it FIRST in your niri
          // config, so display changes from Studio Settings win over your own
          // output blocks (niri uses the first block matching a monitor).
          include optional=true "${stateDir}/overrides/niri.kdl"
        '';

        systemd.user.services.studio-shell =
          lib.recursiveUpdate (service "studio-linux shell (Quickshell)" (lib.getExe sp.studio-shell))
            {
              # First start: apply the configured theme if none is active yet.
              Service.ExecStartPre = "${pkgs.writeShellScript "studio-first-theme" ''
                [ -e "${stateDir}/current/theme.json" ] && exit 0
                ${lib.concatMapStrings (e: "export ${e}\n") env}
                ${lib.getExe sp.studio} theme apply ${lib.escapeShellArg cfg.theme} || true
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

        systemd.user.services.studio-launcher = service "studio-linux launcher (walker + elephant)" "${lib.getExe sp.studio-launcher} service";

        # Restart the shell/launcher when their unit changed — even when the
        # home's systemd.user.startServices is "suggest" (kept so a switch
        # never restarts other user services, e.g. audio). Compares a hash of
        # each unit as systemd now sees it with the one from the last switch.
        home.activation.studioRestart = lib.hm.dag.entryAfter [ "reloadSystemd" ] ''
          state="''${XDG_STATE_HOME:-$HOME/.local/state}/studio-linux"
          mkdir -p "$state"
          for unit in studio-shell studio-launcher; do
            new="$(${pkgs.systemd}/bin/systemctl --user cat "$unit.service" 2>/dev/null | ${pkgs.coreutils}/bin/sha256sum | cut -d' ' -f1)"
            old="$(cat "$state/$unit.unit-hash" 2>/dev/null || true)"
            if [ "$new" != "$old" ]; then
              if ${pkgs.systemd}/bin/systemctl --user is-active --quiet "$unit.service"; then
                run ${pkgs.systemd}/bin/systemctl --user restart "$unit.service" || true
              fi
              [ -n "''${DRY_RUN:-}" ] || echo "$new" > "$state/$unit.unit-hash"
            fi
          done
        '';
      };
    };
}
