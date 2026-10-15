# Theme packs: lock / login design (`lock/`)

A theme pack can bring its own lock screen and login screen design. It's
optional: without one, Loft's built-in macOS-style design is used, colored
by the pack's `theme.json`.

```
<pack>/
  theme.json            palette + glass + wallpaper (drives the built-in design too)
  lock/
    Main.qml            the design: one root Item filling the screen
    theme.conf          optional key=value settings, exposed as `config`
    …                   any assets the design references (relative URLs work)
```

The **same `lock/Main.qml` runs in both places**:

| Host | Where the pack comes from | Read |
|---|---|---|
| Lock screen (Quickshell, `src/lock/`) | the user's active theme: the directory of `$LOFT_THEME_FILE`, normally `~/.local/state/loft/current` | at every lock, so `loft theme apply` switches it with no restart |
| Login screen (SDDM theme `loft`, `lock/sddm/`) | `packDir` from the SDDM theme's `theme.conf`, default `/var/lib/loft/greeter` (machine-wide) | when the greeter starts |

A design that fails to compile falls back to the built-in one, so a broken
pack never leaves a screen without a password field.

A pack can ship more than one design (`locks` in `manifest.json`, or
`locks/<name>/Main.qml`), and the user can lock with any installed pack's
design: Settings → Lock Screen lists the theme's own, curated ones and the
rest ranked by color, and remembers the choice per theme (THEME-FORMAT.md,
"Lock designs" and "Vibes"). A `preview.png` next to `Main.qml` is shown in
that picker. The design's `theme.conf` is the one in its own directory.

## The contract

A design gets these names in scope (no imports needed). They're a subset of
SDDM's greeter API plus one Loft object, so a design written for SDDM, such
as a [qylock](https://github.com/Darkkal44/qylock) theme, works mostly
unchanged, and a design written against `lock` works in both hosts.

### `lock`: loft-native (preferred)

| Member | Type | Meaning |
|---|---|---|
| `tryUnlock(password)` | function | Authenticate. Lock: PAM for the session's user. Greeter: `sddm.login()` for the selected user and session. |
| `failed(message)` | signal | The attempt failed (`"Incorrect password"`, `"Too many attempts"`, …). Clear the field and show it. |
| `busy` | bool | An attempt is in progress. |
| `info` | string | Non-error text from PAM/SDDM (e.g. "Place your finger on the reader"). |
| `userName` / `realName` | string | Who is being authenticated. |
| `avatarSources` | list of URLs | Picture candidates in order (`~/.face`, AccountsService). May be empty. |
| `capsLock` | bool | Caps Lock is on. |
| `showInput` | bool | This screen holds keyboard focus (lock: the focused output; greeter: the primary screen). Show the password field only here. |
| `screen` | object | Lock: the Quickshell screen (`name`, `width`, …). Greeter: `null`. |
| `isGreeter` | bool | `true` under SDDM. |
| `theme` | object | The active palette and glass tokens, the same names as the shell's `Theme` (`bg`, `text`, `accent`, `glassFill`, `radius`, `wallpaperGradient`, `fontUi`, `withAlpha()`, …). |
| `wallpaper` | URL | Lock: what the desktop shows on this screen (the theme's chosen / rotated / per-workspace wallpaper). Greeter: the synced `wallpaper.*` (the desktop wallpaper, for the built-in design), else `""`. |

On success the host tears the screen down (lock) or starts the session
(greeter); there is no "unlocked" animation hook yet.

### SDDM-compatible names

| Name | Lock screen | Greeter |
|---|---|---|
| `sddm.login(user, password, session)` | = `lock.tryUnlock(password)`; user and session are ignored | SDDM's own |
| `sddm.loginFailed` / `sddm.loginSucceeded` | `loginFailed` emitted on failure | SDDM's own |
| `sddm.powerOff()`, `reboot()`, `suspend()`, `can*` | no-ops, `can*` = `false` (a lock screen doesn't power off the machine) | SDDM's own |
| `userModel` | one row: the session's user (`name`, `realName`, `homeDir`, `icon`); `lastUser`, `lastIndex` | SDDM's own |
| `sessionModel` | one row, "Current session" | SDDM's own |
| `keyboard.capsLock`, `keyboard.numLock` | caps from the keyboard LEDs; `numLock` writable, no effect | SDDM's own |
| `config` | `lock/theme.conf` as a key → value map | SDDM's `config`, with the pack's `lock/theme.conf` merged in |

Not provided: SDDM's `SddmComponents` QML module, Qt 5 `QtGraphicalEffects`,
and anything outside the shell's QML import path (the lock runs with
qtdeclarative, qtwayland and Quickshell's modules; SDDM with what its
`extraPackages` add). qylock themes that import those need compatibility
modules on the import path. That belongs to the qylock importer
(`loft theme install qylock:…`, Phase 1b).

## A minimal design

```qml
import QtQuick

Rectangle {
    color: lock.theme.bg

    Connections {
        target: lock
        function onFailed(message) { field.text = ""; hint.text = message }
    }

    Column {
        anchors.centerIn: parent
        spacing: 12
        visible: lock.showInput

        Text { text: lock.realName; color: lock.theme.text; font.pixelSize: 28 }
        TextInput {
            id: field
            focus: true
            width: 280
            echoMode: TextInput.Password
            color: lock.theme.text
            enabled: !lock.busy
            onAccepted: lock.tryUnlock(text)
        }
        Text { id: hint; color: lock.theme.urgent }
    }
}
```

## Notes

- **Focus:** the host calls `forceActiveFocus()` on the design's root item.
  Make the root a `FocusScope`, or give your input `focus: true`, so key
  presses reach the field.
- **Greeter environment:** SDDM must run the greeter with
  `QML_XHR_ALLOW_FILE_READ=1` for it to read `theme.json` and
  `lock/theme.conf` (Qt blocks local-file XMLHttpRequest by default). Without
  it the greeter still works, with the built-in palette.
- **Trust:** a design is QML running in the shell (lock) or greeter process.
  Install packs you trust. The greeter only reads packs from a root-owned
  directory, which `loft greeter sync` (= `loft theme apply --greeter`) writes
  through its polkit helper (`programs.loft.greeter`, nixosModules.default).
  The greeter pack is `theme.json` + `greeter.json` (`main`: the design's
  entry under `lock/`, `wallpaper`) + `lock/` + `wallpaper.*`; the greeter
  gives `lock.wallpaper` that image.
