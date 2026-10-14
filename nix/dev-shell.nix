{
  perSystem =
    { pkgs, ... }:
    {
      formatter = pkgs.nixfmt-tree;

      devShells.default = pkgs.mkShell {
        packages = with pkgs; [
          quickshell # qs, qmlls via the bundled Qt
          kdePackages.qtdeclarative # qmllint / qmlformat
          niri # niri validate
          nixfmt
          (python3.withPackages (ps: [ ps.jsonschema ])) # python3 cli/studio …, tests
        ];
      };
    };
}
