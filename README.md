# studio-linux

A desktop for creative work, music production and programming: [niri](https://github.com/niri-wm/niri)
plus our own [Quickshell](https://quickshell.org) shell, with a macOS-inspired Liquid Glass design language
that is fully themeable at runtime.

```sh
nix run github:Codys-Wright/studio-linux      # try it: opens as a nested niri window
```

## Develop

```sh
nix run .#dev                       # nested niri window running ./src, ./niri, ./themes — hot reload on save
nix run .#dev -- --output DP-1      # inside KDE: fullscreen + borderless on that monitor
nix run .#studio -- --dev theme list
nix run .#studio -- --dev theme apply latte   # recolors the running session live
nix run .#shot -- out.png           # screenshot the dev session
```

Inside the nested session Mod is Alt (Super in a real session): Mod+Return terminal,
Mod+O overview, Mod+Shift+E quit.

Status: Phase 0 (dev loop, glass bar + dock placeholder, live themes). See [docs/PLAN.md](docs/PLAN.md). Themes: [studio-linux-themes](https://github.com/Codys-Wright/studio-linux-themes).
