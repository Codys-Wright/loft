# nix run github:Codys-Wright/loft            → loft-session (store)
# nix run .#dev                                → loft-dev (live checkout, hot reload)
# nix run .#dev -- --session NAME              → an isolated, named test session
# nix run .#input / .#shot -- --session NAME … → drive / screenshot it (docs/TESTING.md)
{ lib, ... }:
{
  perSystem =
    { self', ... }:
    let
      app = pkg: description: {
        type = "app";
        program = lib.getExe pkg;
        meta = { inherit description; };
      };
    in
    {
      apps = {
        default = app self'.packages.loft-session "Run Loft (nested window inside a running session)";
        dev = app self'.packages.loft-dev "Run Loft from a checkout with hot reload";
        loft = app self'.packages.loft "loft CLI: theme engine + manager (list/current/apply/render/new/install/remove/export; --dev for the dev session)";
        shot = app self'.packages.loft-shot "Screenshot a loft-dev session (crop, zoom, coordinate grid, marks)";
        input = app self'.packages.loft-input "Drive a loft-dev session with a virtual mouse and keyboard";
      };
    };
}
