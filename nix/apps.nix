# nix run github:Codys-Wright/studio-linux    → studio-session (store)
# nix run .#dev                                → studio-dev (live checkout, hot reload)
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
        default = app self'.packages.studio-session "Run studio-linux (nested window inside a running session)";
        dev = app self'.packages.studio-dev "Run studio-linux from a checkout with hot reload";
        studio = app self'.packages.studio "studio CLI: theme engine + manager (list/current/apply/render/new/install/remove/export; --dev for the dev session)";
        shot = app self'.packages.studio-shot "Screenshot a studio-dev session (crop, zoom, coordinate grid, marks)";
        input = app self'.packages.studio-input "Drive a studio-dev session with a virtual mouse and keyboard";
      };
    };
}
