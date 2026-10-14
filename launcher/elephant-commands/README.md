### Elephant Commands (Loft)

Spotlight's commands: the session, Loft's panels and Settings pages, a few niri window
actions, your script commands, and the `?` help.

- `lock`, `shut down`, `restart`, `log out`, `sleep`, `empty trash`: Enter asks first (the
  query becomes "Shut Down?"; Enter again runs it, Esc cancels).
- `dnd`, `caffeine`, `settings wifi`, `wallpaper settings`, `maximize`, `float`, `overview`
- Script commands: executable files with Raycast metadata (`# @raycast.title …`, `@mode`,
  `@icon`, `@argument1 { "placeholder": "…" }`, `@needsConfirmation`), from Loft's built-in
  folder and yours (`scripts`). `generate password 32` runs a script with its arguments; Enter
  on a script that needs some types its title so you can add them. Ctrl+E edits the script,
  Ctrl+R shows it in its folder. Modes: `silent` and `compact` end in a banner, `fullOutput`
  lists the output in Spotlight (Enter copies a line).
- `?` lists every prefix (`=`, `!`, `/`, `:`, `.`, `$`, `>`, `+`, `;`) with examples.

#### Files

- `settings`: spotlight.json; `scripts.disabled` lists turned-off scripts by file name.
- `dry_run`: tests log power / session / trash commands there instead of running them.
