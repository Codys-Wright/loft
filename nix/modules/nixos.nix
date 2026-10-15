# NixOS module: programs.loft.greeter — the login screen follows the lock screen.
#
#   imports = [ inputs.loft.nixosModules.default ];
#   programs.loft.greeter.enable = true;
#
# Installs the `loft` SDDM theme (lock/sddm, nix/lock.nix) and makes it the
# greeter, with what pack designs need (QML_XHR_ALLOW_FILE_READ for reading
# the pack, qt5compat/qtmultimedia/qtsvg for qylock designs). The greeter
# reads /var/lib/loft/greeter, which `loft greeter sync` fills through
# `loft-greeter-install` (cli/loft/greeter_helper.py) run by pkexec; a polkit
# rule lets active local users of `group` do that without a password.
# /etc/loft/greeter.json tells the CLI the helper's path and whether a
# `loft theme apply` re-syncs the greeter (followLock). PLAN §4.5.
#
# Checks: greeter-module (the options land in sddm.conf / polkit / etc) and
# greeter-vm (a NixOS VM: a wheel user logged in on tty1 runs `loft greeter
# sync` → pkexec → helper without a password; a user outside the group is
# refused; a theme change re-syncs in the background).
{ self, ... }:
{
  perSystem =
    { pkgs, lib, ... }:
    let
      machine = {
        imports = [ self.nixosModules.default ];
        programs.loft.greeter.enable = true;
        # What a desktop module (the fleet's MacTahoe) does; ours must win.
        services.displayManager.sddm.theme = lib.mkOverride 900 "MacTahoe-Dark";
      };
    in
    {
      checks.greeter-module =
        let
          sys = self.inputs.nixpkgs.lib.nixosSystem {
            modules = [
              machine
              {
                nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system;
                services.displayManager.sddm.enable = true;
                boot.loader.grub.enable = false;
                fileSystems."/" = {
                  device = "nodev";
                  fsType = "tmpfs";
                };
                system.stateVersion = "25.11";
              }
            ];
          };
          c = sys.config;
          sddmConf = c.environment.etc."sddm.conf.d/00-nixos.conf".source;
        in
        assert c.services.displayManager.sddm.theme == "loft";
        pkgs.runCommand "greeter-module" { } ''
          grep -qx 'Current=loft' ${sddmConf}
          grep -qx 'GreeterEnvironment=QML_XHR_ALLOW_FILE_READ=1' ${sddmConf}
          grep -q '"helper":"${
            lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.loft-greeter-install
          }"' \
            ${c.environment.etc."loft/greeter.json".source}
          grep -q 'isInGroup("wheel")' ${pkgs.writeText "polkit.js" c.security.polkit.extraConfig}
          touch $out
        '';

      checks.greeter-vm = pkgs.testers.runNixOSTest {
        name = "loft-greeter";
        nodes.machine = {
          imports = [ machine ];
          environment.systemPackages = [ self.packages.${pkgs.stdenv.hostPlatform.system}.loft ];
          users.users.alice = {
            isNormalUser = true;
            extraGroups = [ "wheel" ];
            password = "alice";
          };
          users.users.bob = {
            isNormalUser = true;
            password = "bob";
          };
          environment.variables = {
            LOFT_THEME_INDEX = "none";
            LOFT_LIBRARY = "none";
            LOFT_HOOKS = "greeter";
          };
        };
        testScript = ''
          import json
          machine.wait_for_unit("multi-user.target")
          machine.wait_until_tty_matches("1", "login: ")
          machine.send_chars("alice\n")
          machine.wait_until_tty_matches("1", "Password: ")
          machine.send_chars("alice\n")
          machine.wait_until_succeeds("pgrep -u alice bash")

          def as_alice(cmd, done):
              machine.send_chars(f"{cmd} > /tmp/{done}.log 2>&1; echo $? > /tmp/{done}.rc\n")
              machine.wait_for_file(f"/tmp/{done}.rc")
              print(machine.succeed(f"cat /tmp/{done}.log"))
              return machine.succeed(f"cat /tmp/{done}.rc").strip()

          assert as_alice("loft theme apply loft", "apply") == "0"
          # The first apply already follows, in the background; it logs the outcome.
          synclog = "/home/alice/.local/state/loft/greeter-sync.log"
          machine.wait_until_succeeds(f"grep -q 'loft-greeter-install\\|failed' {synclog}", timeout=120)
          print(machine.succeed(f"cat {synclog}"))
          machine.succeed("test -f /var/lib/loft/greeter/greeter.json")
          assert as_alice("loft greeter sync", "sync") == "0"
          meta = json.loads(machine.succeed("cat /var/lib/loft/greeter/greeter.json"))
          assert meta["user"] == "alice", meta
          machine.succeed("test -L /var/lib/loft/greeter")
          machine.succeed("stat -c '%U %a' /var/lib/loft/greeter/theme.json | grep -qx 'root 644'")

          # A theme change re-syncs in the background (followLock).
          key = meta["key"]
          assert as_alice("loft material set glass.opacity 0.3", "set") == "0"
          machine.wait_until_succeeds(
              f"! grep -q '\"key\": \"{key}\"' /var/lib/loft/greeter/greeter.json", timeout=60
          )

          # Not in the group (and not an active local session): refused.
          helper = json.loads(machine.succeed("cat /etc/loft/greeter.json"))["helper"]
          machine.fail(f"su - bob -c '/run/wrappers/bin/pkexec --disable-internal-agent {helper} reset'")
          machine.succeed("test -L /var/lib/loft/greeter")

          # Reset: back to the built-in design.
          assert as_alice("loft greeter reset", "reset") == "0"
          machine.fail("test -e /var/lib/loft/greeter")
        '';
      };
    };

  flake.nixosModules.default =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.programs.loft.greeter;
      sddm = config.services.displayManager.sddm;
      sp = self.packages.${pkgs.stdenv.hostPlatform.system};
      helper = lib.getExe sp.loft-greeter-install;
    in
    {
      options.programs.loft.greeter = {
        enable = lib.mkEnableOption "the Loft login screen (SDDM theme `loft`), showing the lock design you sync to it";

        group = lib.mkOption {
          type = lib.types.str;
          default = "wheel";
          description = "Members of this group (active, local sessions) may install the login screen's design without a password.";
        };

        followLock = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Whether `loft theme apply` (and lock facet changes) re-sync the login
            screen in the background by default. Each user can override it with
            `loft greeter follow on|off`.
          '';
        };

        maxSize = lib.mkOption {
          type = lib.types.ints.positive;
          default = 512;
          description = "Largest greeter pack the helper accepts, in MiB (video backgrounds count).";
        };
      };

      config = lib.mkIf cfg.enable {
        services.displayManager.sddm = {
          # Above mkDefault and the mkOverride 900 a desktop module may use
          # for its own theme, below a plain definition in the host config.
          theme = lib.mkOverride 800 "loft";
          extraPackages = [
            pkgs.kdePackages.qt5compat
            pkgs.kdePackages.qtmultimedia
            pkgs.kdePackages.qtsvg
          ];
          # sddm.nix sets this for its kwin greeter compositor; settings
          # replace it, so keep that value alongside ours.
          settings.General.GreeterEnvironment = lib.concatStringsSep "," (
            lib.optional (
              sddm.wayland.enable && sddm.wayland.compositor == "kwin"
            ) "QT_WAYLAND_SHELL_INTEGRATION=layer-shell"
            ++ [ "QML_XHR_ALLOW_FILE_READ=1" ]
          );
        };

        environment.systemPackages = [
          sp.loft-sddm-theme
          sp.loft-greeter-install
        ];

        environment.etc."loft/greeter.json".text = builtins.toJSON {
          inherit helper;
          inherit (cfg) followLock group;
          maxBytes = cfg.maxSize * 1024 * 1024;
        };

        systemd.tmpfiles.rules = [
          "d /var/lib/loft 0755 root root -"
          "d /var/lib/loft/themes 0755 root root -"
        ];

        security.polkit.enable = true;
        # `loft greeter sync` runs the helper through pkexec, whose setuid
        # wrapper NixOS no longer installs by default.
        security.polkit.enablePkexecWrapper = lib.mkDefault true;
        security.polkit.extraConfig = ''
          // Loft: `loft greeter sync` installs the login screen's design.
          polkit.addRule(function (action, subject) {
            if (action.id == "org.freedesktop.policykit.exec" &&
                action.lookup("program") == "${helper}" &&
                subject.local && subject.active &&
                subject.isInGroup("${cfg.group}")) {
              return polkit.Result.YES;
            }
          });
        '';
      };
    };
}
