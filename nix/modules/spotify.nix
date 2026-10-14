# home-manager: programs.loft.spotify, Spotify themed by Loft (imported by
# home.nix).
#
# Spicetify patched at runtime instead of at build time: `loft spotify setup`
# (cli/loft/spotify.py) copies the Nix Spotify into a writable dir
# ($XDG_DATA_HOME/loft/spotify), applies Spicetify there with spicetify-themes'
# `text` theme (the one Cozytile uses), the extensions and custom apps below,
# and Loft's live recolor extension; `loft theme apply` then recolors it
# without a restart. A Spotify update from Nix re-copies on the next login or
# launch. This module writes the setup's config, runs it as a user service
# (and after a switch, without waiting for it), and puts a `spotify`
# launcher + desktop entry first on PATH and in the app list.
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.loft;
  scfg = cfg.spotify;
  sp = self.packages.${pkgs.stdenv.hostPlatform.system};
  loft = lib.getExe sp.loft;

  dir = "${config.xdg.dataHome}/loft/spotify";
  configFile = "${config.xdg.configHome}/loft/spotify.json";
  env = [
    "LOFT_STATE_DIR=${config.xdg.stateHome}/loft"
    "LOFT_SPOTIFY_DIR=${dir}"
    "LOFT_SPOTIFY_CONFIG=${configFile}"
  ];

  # `spotify`: set up when needed (a new package, changed extensions), sync
  # the theme, exec the patched copy; the plain package if setup fails.
  launcher = pkgs.runCommand "loft-spotify-launcher" { } ''
    mkdir -p $out/bin $out/share/applications
    cat > $out/bin/spotify <<'EOF'
    #!${pkgs.runtimeShell}
    ${lib.concatMapStrings (e: "export ${e}\n") env}exec ${loft} spotify run -- "$@"
    EOF
    chmod +x $out/bin/spotify
    ln -s ${scfg.package}/share/icons $out/share/icons
    # Same desktop id, name, icon and StartupWMClass (app id `spotify`), so
    # Spotlight, the dock and pinned items see one Spotify: this one.
    sed -e "s|^Exec=.*|Exec=$out/bin/spotify %U|" -e '/^TryExec=/d' \
      ${scfg.package}/share/applications/spotify.desktop > $out/share/applications/spotify.desktop
  '';

  # spicetify, pointed at Loft's install (its config is rewritten by
  # `loft spotify setup`; use `loft spotify …` for lasting changes).
  spicetify = pkgs.writeShellScriptBin "spicetify" ''
    export SPICETIFY_CONFIG=${lib.escapeShellArg "${dir}/spicetify"}
    export SPICETIFY_STATE=${lib.escapeShellArg "${dir}/spicetify-state"}
    exec ${lib.getExe scfg.spicetifyPackage} "$@"
  '';
in
{
  options.programs.loft.spotify = {
    enable = lib.mkEnableOption ''
      Spotify themed by Loft: a writable Spicetify install (spicetify-themes'
      `text` theme) that follows the active Loft theme live. Turn off other
      Spotify / Spicetify setups for this user (e.g. spicetify-nix's
      `programs.spicetify`)'';

    package = lib.mkPackageOption pkgs "spotify" { };

    spicetifyPackage = lib.mkPackageOption pkgs "spicetify-cli" { };

    textTheme = lib.mkOption {
      type = lib.types.path;
      default = sp.loft-spicetify-text;
      defaultText = lib.literalExpression "loft.packages.\${system}.loft-spicetify-text";
      description = ''
        spicetify-themes' `text` theme (a directory with `user.css` and
        `color.ini`). Loft adds the active theme's scheme to its color.ini.
      '';
    };

    extensions = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      example = lib.literalExpression ''
        # spicetify-nix's extension sources:
        map (e: "''${e.src}/''${e.name}") (with spicePkgs.extensions; [ adblock hidePodcasts shuffle ])
      '';
      description = ''
        Spicetify extensions: each a `.js` file, installed under its own file
        name. Loft's live recolor extension (loft-live.js) is always added.
      '';
    };

    customApps = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = {
        marketplace = sp.loft-spicetify-marketplace;
      };
      defaultText = lib.literalExpression "{ marketplace = loft.packages.\${system}.loft-spicetify-marketplace; }";
      example = lib.literalExpression ''{ marketplace = spicePkgs.apps.marketplace.src; lyrics-plus = "''${spicePkgs.apps.lyricsPlus.src}"; }'';
      description = "Spicetify custom apps: name → the app's directory (with its index.js).";
    };
  };

  config = lib.mkIf (cfg.enable && scfg.enable) {
    warnings =
      lib.optional (config.programs ? spicetify && (config.programs.spicetify.enable or false))
        "programs.loft.spotify and programs.spicetify both install a Spotify; turn programs.spicetify off (Loft's follows the Loft theme).";

    xdg.configFile."loft/spotify.json".text = builtins.toJSON {
      package = "${scfg.package}";
      version = scfg.package.version or "";
      spicetify = "${scfg.spicetifyPackage}";
      textTheme = "${scfg.textTheme}";
      extensions = map toString scfg.extensions;
      customApps = lib.mapAttrs (_: toString) scfg.customApps;
    };

    home.packages = [
      (lib.hiPrio launcher)
      spicetify
    ];
    home.sessionVariables.LOFT_SPOTIFY_DIR = dir;

    # At login (and after a switch): copy + patch when the package or the
    # Spicetify inputs changed, else a no-op. Never touches a running Spotify
    # (the update then waits for the next launch, which runs it first).
    systemd.user.services.loft-spotify-setup = {
      Unit.Description = "Loft: keep the themed Spotify up to date (loft spotify setup)";
      Service = {
        Type = "oneshot";
        ExecStart = "${loft} spotify setup";
        Environment = env;
        Nice = 10;
        IOSchedulingClass = "idle";
      };
      Install.WantedBy = [ "default.target" ];
    };
    home.activation.loftSpotify = lib.hm.dag.entryAfter [ "reloadSystemd" ] ''
      run ${pkgs.systemd}/bin/systemctl --user start --no-block loft-spotify-setup.service || true
    '';
  };
}
