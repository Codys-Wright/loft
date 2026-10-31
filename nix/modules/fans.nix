# NixOS module: programs.loft.fanControl — set hwmon fans from the shell (issue #7).
#
#   imports = [ inputs.loft.nixosModules.default ];
#   programs.loft.fanControl.enable = true;
#
# System Monitor → Disks & Sensors lists every hwmon pwm output; with this
# on, a writable one can be put on a manual speed or a temperature curve.
# The shell never writes /sys: `loft fans …` runs `loft-fan-control`
# (cli/loft/fan_helper.py) through pkexec, which validates the request and
# records it in /var/lib/loft/fans.json; a polkit rule lets active local
# users of `group` do that without a password. The root `loft-fans` service
# (the same helper's `run`) is the only writer of pwm[N] / pwm[N]_enable: it
# saves each fan's original pwm_enable before taking it and writes it back on
# exit, on a crash (ExecStopPost) and before suspend (Conflicts=sleep.target;
# restarted on resume). /etc/loft/fans.json tells the CLI the helper's path
# and the limits below.
#
# Checks: fans-module (the options land in /etc, polkit and the unit) and
# fans-vm (a NixOS VM: the service runs; a wheel user changes a setting
# through pkexec without a password; a user outside the group is refused; the
# service commands are refused under pkexec).
{ self, ... }:
{
  perSystem =
    { pkgs, lib, ... }:
    let
      machine = {
        imports = [ self.nixosModules.default ];
        programs.loft.fanControl.enable = true;
      };
    in
    {
      packages.loft-fan-control =
        pkgs.runCommand "loft-fan-control" { meta.mainProgram = "loft-fan-control"; }
          ''
            mkdir -p $out/bin
            { echo "#!${pkgs.python3}/bin/python3 -IB"; cat ${../../cli/loft/fan_helper.py}; } > $out/bin/loft-fan-control
            chmod +x $out/bin/loft-fan-control
          '';

      checks.fans-module =
        let
          sys = self.inputs.nixpkgs.lib.nixosSystem {
            modules = [
              machine
              {
                nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system;
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
          helper = lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.loft-fan-control;
          unit = c.systemd.services.loft-fans;
        in
        assert unit.serviceConfig.ExecStart == "${helper} run";
        assert unit.serviceConfig.ExecStopPost == "${helper} restore";
        assert builtins.elem "sleep.target" unit.conflicts;
        pkgs.runCommand "fans-module" { } ''
          grep -q '"helper":"${helper}"' ${c.environment.etc."loft/fans.json".source}
          grep -q '"allowStop":false' ${c.environment.etc."loft/fans.json".source}
          grep -q 'isInGroup("wheel")' ${pkgs.writeText "polkit.js" c.security.polkit.extraConfig}
          grep -q '${helper}' ${pkgs.writeText "polkit.js" c.security.polkit.extraConfig}
          grep -q 'loft-fans.service' ${pkgs.writeText "resume" c.powerManagement.resumeCommands}
          touch $out
        '';

      checks.fans-vm = pkgs.testers.runNixOSTest {
        name = "loft-fans";
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
        };
        testScript = ''
          import json
          machine.wait_for_unit("loft-fans.service")
          machine.wait_until_succeeds("test -f /run/loft-fans/daemon.pid")
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

          # A VM has no pwm fans: everything is read-only, nothing fails.
          assert as_alice("loft fans status --json", "status") == "0"
          s = json.loads(machine.succeed("cat /tmp/status.log"))
          assert s["enabled"] and s["daemon"] and s["fans"] == [], s

          # Through pkexec, no password: the setting file is root's.
          assert as_alice("loft fans reset", "reset") == "0"
          machine.succeed("stat -c '%U %a' /var/lib/loft/fans.json | grep -qx 'root 644'")
          # A fan that doesn't exist is refused by the helper, as root.
          assert as_alice("loft fans manual hwmon0/pwm1 50", "manual") == "1"
          machine.succeed("grep -q 'no such channel' /tmp/manual.log")

          helper = json.loads(machine.succeed("cat /etc/loft/fans.json"))["helper"]
          pk = "/run/wrappers/bin/pkexec --disable-internal-agent"
          # Not in the group (and not an active local session): refused.
          machine.fail(f"su - bob -c '{pk} {helper} reset'")
          # The service's own commands are refused under pkexec.
          assert as_alice(f"{pk} {helper} run --once", "run") != "0"
          machine.succeed("grep -q 'belongs to the loft-fans service' /tmp/run.log")

          # Stopping the service runs restore and leaves no daemon behind.
          machine.succeed("systemctl stop loft-fans.service")
          machine.fail("test -e /run/loft-fans/daemon.pid")
        '';
      };
    };

  flake.nixosModules.fanControl =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.programs.loft.fanControl;
      sp = self.packages.${pkgs.stdenv.hostPlatform.system};
      helper = lib.getExe sp.loft-fan-control;
    in
    {
      options.programs.loft.fanControl = {
        enable = lib.mkEnableOption "fan control from the Loft shell (manual speeds and temperature curves for hwmon pwm fans, through a polkit-gated helper)";

        group = lib.mkOption {
          type = lib.types.str;
          default = "wheel";
          description = "Members of this group (active, local sessions) may change fan settings without a password.";
        };

        minPercent = lib.mkOption {
          type = lib.types.ints.between 10 100;
          default = 25;
          description = "The lowest speed a manual setting or curve may ask for, in %.";
        };

        allowStop = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Whether a fan may be stopped (0 %). Even then each fan needs its own
            "Allow stopping" in the shell; without both, 0 % means minPercent.
          '';
        };

        criticalTemp = lib.mkOption {
          type = lib.types.ints.between 50 110;
          default = 90;
          description = "At or over this temperature (°C, the fan's source or any CPU sensor) every controlled fan runs at 100 %.";
        };

        interval = lib.mkOption {
          type = lib.types.ints.between 1 10;
          default = 2;
          description = "Seconds between the service's updates.";
        };
      };

      config = lib.mkIf cfg.enable {
        environment.systemPackages = [ sp.loft-fan-control ];

        environment.etc."loft/fans.json".text = builtins.toJSON {
          inherit helper;
          inherit (cfg)
            group
            minPercent
            allowStop
            criticalTemp
            interval
            ;
        };

        systemd.tmpfiles.rules = [ "d /var/lib/loft 0755 root root -" ];

        systemd.services.loft-fans = {
          description = "Loft fan control (hwmon pwm: manual speeds and curves)";
          wantedBy = [ "multi-user.target" ];
          # Fans go back to automatic before suspend; resumeCommands restarts it.
          conflicts = [ "sleep.target" ];
          before = [ "sleep.target" ];
          restartTriggers = [ config.environment.etc."loft/fans.json".source ];
          serviceConfig = {
            ExecStart = "${helper} run";
            # Also after a crash or SIGKILL: every fan it took goes back.
            ExecStopPost = "${helper} restore";
            Restart = "on-failure";
            RestartSec = 5;
            RuntimeDirectory = "loft-fans";
            RuntimeDirectoryPreserve = "yes";
            # Reads /etc and /var/lib/loft, writes only /sys and /run/loft-fans.
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            PrivateNetwork = true;
            NoNewPrivileges = true;
            RestrictAddressFamilies = "AF_UNIX";
          };
        };

        powerManagement.resumeCommands = lib.mkAfter ''
          ${config.systemd.package}/bin/systemctl --no-block start loft-fans.service
        '';

        security.polkit.enable = true;
        # `loft fans …` runs the helper through pkexec, whose setuid wrapper
        # NixOS no longer installs by default.
        security.polkit.enablePkexecWrapper = lib.mkDefault true;
        security.polkit.extraConfig = ''
          // Loft: `loft fans …` changes a fan's setting (System Monitor → Sensors).
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
