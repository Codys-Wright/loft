package main

// The built-in commands: the session, Loft's panels and Settings pages, and a
// curated handful of niri window actions (niri's own list, the niriactions
// provider, is ~130 raw actions including "quit" — still there under ";").

import (
	"fmt"
	"os"
	"path/filepath"
)

type command struct {
	id       string
	title    string
	kind     string // shown as the subtext: System, Settings, Window, Loft
	icon     string
	keywords []string
	cmd      string // shell; {ipc} = `quickshell ipc … call`
	query    string // instead of cmd: put this into Spotlight's search field
	confirm  bool   // Enter asks first ("Shut Down?" → Enter again)
	danger   bool   // power / session / data: logged instead of run in dry-run mode
	delay    int    // ms to wait first (window actions: let Spotlight close)
	note     func() string
}

func builtins() []*command {
	c := []*command{
		// ── Session ─────────────────────────────────────────────────────
		{id: "lock", title: "Lock Screen", kind: "System", icon: "system-lock-screen", keywords: []string{"lock"}, cmd: "{ipc} lock lock", danger: true, delay: 250},
		{id: "logout", title: "Log Out", kind: "System", icon: "system-log-out", keywords: []string{"logout", "sign out", "log off", "exit", "quit niri"}, cmd: "niri msg action quit --skip-confirmation", confirm: true, danger: true},
		{id: "restart", title: "Restart", kind: "System", icon: "system-reboot", keywords: []string{"reboot", "restart computer"}, cmd: "systemctl reboot", confirm: true, danger: true},
		{id: "shutdown", title: "Shut Down", kind: "System", icon: "system-shutdown", keywords: []string{"shutdown", "power off", "poweroff", "turn off"}, cmd: "systemctl poweroff", confirm: true, danger: true},
		{id: "sleep", title: "Sleep", kind: "System", icon: "system-suspend", keywords: []string{"suspend", "standby"}, cmd: "systemctl suspend", confirm: true, danger: true, note: sleepNote},
		{id: "emptytrash", title: "Empty Trash", kind: "System", icon: "user-trash-full", keywords: []string{"trash", "bin", "recycle"}, cmd: "gio trash --empty", confirm: true, danger: true, note: trashNote},
		{id: "dnd", title: "Toggle Do Not Disturb", kind: "System", icon: "notifications-disabled", keywords: []string{"dnd", "do not disturb", "focus", "silence", "notifications"}, cmd: "{ipc} controlcenter toggleDnd"},
		{id: "caffeine", title: "Toggle Keep Awake", kind: "System", icon: "caffeine", keywords: []string{"caffeine", "amphetamine", "keep awake", "inhibit idle", "no sleep"}, cmd: "{ipc} keepawake toggle"},
		{id: "displaysoff", title: "Turn Off Displays", kind: "System", icon: "video-display", keywords: []string{"monitors off", "screen off", "blank"}, cmd: "niri msg action power-off-monitors", delay: 400},

		// ── Loft ────────────────────────────────────────────────────────
		{id: "controlcenter", title: "Control Center", kind: "Loft", icon: "preferences-system", keywords: []string{"quick settings"}, cmd: "{ipc} controlcenter toggle"},
		{id: "settings", title: "Settings", kind: "Loft", icon: "preferences-system", keywords: []string{"preferences", "system settings"}, cmd: "{ipc} settings toggle"},
		{id: "themes", title: "Themes", kind: "Loft", icon: "preferences-desktop-theme", keywords: []string{"theme", "colors", "appearance"}, cmd: "{ipc} themes open"},
		{id: "nexttheme", title: "Next Theme", kind: "Loft", icon: "preferences-desktop-theme", keywords: []string{"cycle theme", "switch theme"}, cmd: "{ipc} themes cycle"},
		{id: "wallpapers", title: "Wallpapers", kind: "Loft", icon: "preferences-desktop-wallpaper", keywords: []string{"background", "wallpaper"}, cmd: "{ipc} wallpaper toggle"},
		{id: "clipboard", title: "Clipboard History", kind: "Loft", icon: "edit-paste", keywords: []string{"paste", "copied"}, query: ":"},
		{id: "emoji", title: "Emoji & Symbols", kind: "Loft", icon: "face-smile", keywords: []string{"emoji", "symbols", "characters"}, query: "."},
		{id: "files", title: "Search Files", kind: "Loft", icon: "system-file-manager", keywords: []string{"find file", "documents"}, query: "/"},
		{id: "snippets", title: "Snippets", kind: "Loft", icon: "accessories-text-editor", keywords: []string{"text expansion"}, cmd: "{ipc} snippets toggle"},
		{id: "monitor", title: "System Monitor", kind: "Loft", icon: "utilities-system-monitor", keywords: []string{"activity monitor", "task manager", "processes", "cpu"}, cmd: "{ipc} monitor toggle"},
		{id: "capture", title: "Screenshot", kind: "Loft", icon: "applets-screenshooter", keywords: []string{"capture", "screen capture", "screen recording", "record"}, cmd: "{ipc} capture toggle", delay: 250},
		{id: "capturearea", title: "Capture Area", kind: "Loft", icon: "applets-screenshooter", keywords: []string{"screenshot area", "screenshot selection"}, cmd: "{ipc} capture area", delay: 250},
		{id: "scratchpad", title: "Scratchpad", kind: "Loft", icon: "accessories-text-editor", keywords: []string{"notes", "quick note"}, cmd: "{ipc} scratchpad toggle"},
		{id: "clearnotifications", title: "Clear Notifications", kind: "Loft", icon: "edit-clear-all", keywords: []string{"dismiss notifications"}, cmd: "{ipc} notifications clear"},
		{id: "nextoutput", title: "Next Audio Output", kind: "Loft", icon: "audio-speakers", keywords: []string{"switch speakers", "headphones", "sound output"}, cmd: "{ipc} audio nextOutput"},
		{id: "mutemic", title: "Toggle Microphone Mute", kind: "Loft", icon: "microphone-sensitivity-muted", keywords: []string{"mute mic", "unmute"}, cmd: "{ipc} mic toggleMute"},
		{id: "quickpanel", title: "Quick Panel", kind: "Loft", icon: "view-app-grid", keywords: []string{"palette", "tools"}, cmd: "{ipc} quickpanel toggle", delay: 250},
		{id: "utilities", title: "Utilities", kind: "Loft", icon: "applications-utilities", keywords: []string{"tools"}, cmd: "{ipc} utilities open"},
		{id: "ports", title: "Port Manager", kind: "Loft", icon: "network-server", keywords: []string{"ports", "listening", "kill port"}, cmd: "{ipc} utilities ports"},
		{id: "updates", title: "Flake Updates", kind: "Loft", icon: "system-software-update", keywords: []string{"update", "nix flake update", "upgrades"}, cmd: "{ipc} utilities updates"},
		{id: "cleaner", title: "Cleaner", kind: "Loft", icon: "edit-clear", keywords: []string{"disk space", "nix store", "garbage"}, cmd: "{ipc} utilities cleaner"},
		{id: "mediatools", title: "Media Tools", kind: "Loft", icon: "applications-multimedia", keywords: []string{"convert video", "compress", "ffmpeg"}, cmd: "{ipc} utilities media"},
		{id: "help", title: "Spotlight Help", kind: "Loft", icon: "help-about", keywords: []string{"?", "help", "prefixes", "tips"}, query: "?"},

		// ── Windows (niri) ──────────────────────────────────────────────
		{id: "maximize", title: "Maximize Window", kind: "Window", icon: "window-maximize", keywords: []string{"zoom", "fill", "maximise"}, cmd: "niri msg action maximize-column", delay: 200},
		{id: "fullscreen", title: "Fullscreen Window", kind: "Window", icon: "view-fullscreen", keywords: []string{"full screen", "enter fullscreen"}, cmd: "niri msg action fullscreen-window", delay: 200},
		{id: "float", title: "Toggle Floating Window", kind: "Window", icon: "window-new", keywords: []string{"float", "tile", "floating"}, cmd: "niri msg action toggle-window-floating", delay: 200},
		{id: "center", title: "Center Window", kind: "Window", icon: "format-justify-center", keywords: []string{"centre"}, cmd: "niri msg action center-column", delay: 200},
		{id: "widen", title: "Expand Window to Available Width", kind: "Window", icon: "zoom-fit-best", keywords: []string{"fill width", "grow"}, cmd: "niri msg action expand-column-to-available-width", delay: 200},
		{id: "presetwidth", title: "Cycle Window Width", kind: "Window", icon: "zoom-in", keywords: []string{"resize", "column width"}, cmd: "niri msg action switch-preset-column-width", delay: 200},
		{id: "nextdisplay", title: "Move Window to Next Display", kind: "Window", icon: "video-display", keywords: []string{"other monitor", "move to monitor"}, cmd: "niri msg action move-window-to-monitor-next", delay: 200},
		{id: "nextworkspace", title: "Move Window to Next Workspace", kind: "Window", icon: "go-down", keywords: []string{"move to workspace", "next desktop"}, cmd: "niri msg action move-window-to-workspace-down", delay: 200},
		{id: "closewindow", title: "Close Window", kind: "Window", icon: "window-close", keywords: []string{"quit window"}, cmd: "niri msg action close-window", delay: 200},
		{id: "overview", title: "Overview", kind: "Window", icon: "view-grid", keywords: []string{"mission control", "expose", "workspaces", "all windows"}, cmd: "niri msg action toggle-overview", delay: 200},
		{id: "hotkeys", title: "Keyboard Shortcuts", kind: "Window", icon: "preferences-desktop-keyboard-shortcuts", keywords: []string{"hotkeys", "keybinds", "shortcuts"}, cmd: "niri msg action show-hotkey-overlay", delay: 200},
	}

	// Settings pages (src/settings/SettingsApp.qml) and the Control Center's
	// modules: "settings wifi", "wallpaper settings", "keybinds".
	for _, p := range []struct {
		id, title, icon string
		kw              []string
	}{
		{"appearance", "Appearance", "preferences-desktop-theme", []string{"theme", "glass", "transparency"}},
		{"wallpaper", "Wallpaper", "preferences-desktop-wallpaper", []string{"background"}},
		{"lockscreen", "Lock Screen", "system-lock-screen", []string{"lock screen settings"}},
		{"dock", "Dock", "user-desktop", []string{"taskbar"}},
		{"island", "Dynamic Island", "preferences-system-notifications", []string{"island"}},
		{"displays", "Displays", "video-display", []string{"monitors", "resolution", "scale", "arrangement"}},
		{"input", "Keyboard & Mouse", "input-keyboard", []string{"keyboard", "mouse", "trackpad", "touchpad", "pointer"}},
		{"layout", "Layout & Motion", "preferences-desktop", []string{"gaps", "animations", "window layout"}},
		{"keybinds", "Keybinds", "preferences-desktop-keyboard-shortcuts", []string{"shortcuts", "hotkeys"}},
		{"system", "System", "computer", []string{"about this computer"}},
		{"sound", "Sound", "audio-volume-high", []string{"audio", "volume", "output", "input"}},
		{"capture", "Capture", "applets-screenshooter", []string{"screenshots", "recording"}},
		{"features", "Features", "preferences-other", []string{"modules", "enable"}},
		{"clipboard", "Clipboard & Files", "edit-paste", []string{"clipboard settings", "shelf"}},
		{"snippets", "Snippets", "accessories-text-editor", []string{"snippets settings", "text expansion"}},
		{"spotlight", "Spotlight", "system-search", []string{"quicklinks", "scripts", "bangs", "search engine", "launcher"}},
		{"menubar", "Menu Bar", "preferences-desktop", []string{"bar", "status bar", "top bar"}},
		{"desktopmenu", "Desktop Menu", "preferences-desktop", []string{"right click menu"}},
		{"about", "About", "help-about", []string{"version"}},
	} {
		c = append(c, &command{
			id: "settings-" + p.id, title: p.title + " Settings", kind: "Settings", icon: p.icon,
			keywords: append([]string{"settings", "preferences", p.title}, p.kw...),
			cmd:      "{ipc} settings open " + p.id,
		})
	}
	for _, p := range []struct {
		id, title, icon string
		kw              []string
	}{
		{"wifi", "Wi-Fi", "network-wireless", []string{"wifi", "wireless", "network", "internet"}},
		{"bluetooth", "Bluetooth", "bluetooth", []string{"bt", "headphones", "pair"}},
		{"display", "Brightness", "display-brightness", []string{"display", "night light", "brightness"}},
		{"focus", "Focus", "notifications-disabled", []string{"do not disturb", "focus timer", "pomodoro"}},
		{"nowPlaying", "Now Playing", "media-playback-start", []string{"music", "media", "player"}},
	} {
		c = append(c, &command{
			id: "cc-" + p.id, title: p.title, kind: "Control Center", icon: p.icon,
			keywords: append([]string{"settings", "control center"}, p.kw...),
			cmd:      "{ipc} controlcenter " + p.id,
		})
	}
	return c
}

// sleepNote: suspend is risky on some machines (NVIDIA: may not wake).
func sleepNote() string {
	if _, err := os.Stat("/proc/driver/nvidia"); err == nil {
		return "NVIDIA GPU: this machine may not wake from sleep"
	}
	return ""
}

func trashDir() string {
	d := os.Getenv("XDG_DATA_HOME")
	if d == "" {
		h, _ := os.UserHomeDir()
		d = filepath.Join(h, ".local", "share")
	}
	return filepath.Join(d, "Trash", "files")
}

func trashNote() string {
	entries, err := os.ReadDir(trashDir())
	switch {
	case err != nil || len(entries) == 0:
		return "The Trash is empty"
	case len(entries) == 1:
		return "1 item, erased permanently"
	}
	return fmt.Sprintf("%d items, erased permanently", len(entries))
}
