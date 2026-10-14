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

## Lock screen and login screen

`Mod+Ctrl+Q` (Ctrl+Cmd+Q on a Mac) locks: a session lock with PAM, a big clock, now playing
and a frosted card with the password field. The same design is the login screen, shipped as the
SDDM theme `studio` (`packages.studio-sddm-theme`). A theme pack can replace both with its own
`lock/Main.qml` ([docs/THEME-FORMAT-LOCK.md](docs/THEME-FORMAT-LOCK.md)).

```sh
nix run .#greeter-preview           # the login screen in SDDM's test mode (opens a window)
qs ipc --path <shell> call lock lock
```

Locking on idle (swayidle):

```sh
swayidle -w timeout 300 'studio-lock' before-sleep 'studio-lock'
# where studio-lock = quickshell ipc --path <shell src> call lock lock
```

Using the login screen on NixOS:

```nix
environment.systemPackages = [ studio-linux.packages.${system}.studio-sddm-theme ];
services.displayManager.sddm = {
  theme = "studio";
  # lets the greeter read /var/lib/studio-linux/greeter/theme.json
  settings.General.GreeterEnvironment = "QML_XHR_ALLOW_FILE_READ=1";
};
# optional: a dedicated PAM service for the lock (default: "login")
security.pam.services.studio-lock = { };   # + STUDIO_LOCK_PAM=studio-lock in the shell's environment
```

Status: Phase 0 (dev loop, glass bar + dock placeholder, live themes). See [docs/PLAN.md](docs/PLAN.md). Themes: [studio-linux-themes](https://github.com/Codys-Wright/studio-linux-themes).
