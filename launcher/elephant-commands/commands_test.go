package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func testConfig(t *testing.T) {
	t.Helper()
	dir := t.TempDir()
	builtin := os.Getenv("LOFT_BUILTIN_SCRIPTS") // the nix build: launcher/scripts
	if builtin == "" {
		builtin = "../scripts"
	}
	config = &Config{Scripts: filepath.Join(dir, "user"), BuiltinScripts: builtin, MinChars: 2}
	config.MinScore = 20
	cmds = builtins()
	for _, c := range cmds {
		cmdByID[c.id] = c
	}
}

func top(t *testing.T, q string) string {
	t.Helper()
	best, bestScore := "", int32(0)
	for _, c := range cmds {
		if s, _ := match(q, c.title, c.keywords, false); s > bestScore {
			best, bestScore = c.id, s
		}
	}
	return best
}

func TestMatchBuiltins(t *testing.T) {
	testConfig(t)
	cases := map[string]string{
		"lock":           "lock",
		"shut down":      "shutdown",
		"shutdown":       "shutdown",
		"reboot":         "restart",
		"settings wifi":  "cc-wifi",
		"wifi":           "cc-wifi",
		"dnd":            "dnd",
		"caffeine":       "caffeine",
		"maximize":       "maximize",
		"empty trash":    "emptytrash",
		"wallpaper sett": "settings-wallpaper",
		"keyboard":       "settings-input",
	}
	for q, want := range cases {
		if got := top(t, q); got != want {
			t.Errorf("%q → %q, want %q", q, got, want)
		}
	}
	if s, _ := match("xyzzy", "Lock Screen", []string{"lock"}, false); s != 0 {
		t.Errorf("no match must score 0, got %d", s)
	}
}

func TestParseBuiltinScripts(t *testing.T) {
	testConfig(t)
	if _, err := os.Stat(config.BuiltinScripts); err != nil {
		t.Skip("no launcher/scripts")
	}
	list := loadScripts()
	titles := map[string]*script{}
	for _, s := range list {
		titles[s.title] = s
		if !s.builtin {
			t.Errorf("%s should be built-in", s.id)
		}
	}
	for _, want := range []string{"Toggle Dark Mode", "Restart Shell", "Copy Wi-Fi IP", "Flake Update Summary", "Generate Password"} {
		if titles[want] == nil {
			t.Errorf("missing built-in script %q", want)
		}
	}
	pw := titles["Generate Password"]
	if pw == nil || len(pw.args) != 1 || !pw.args[0].Optional || pw.mode != "compact" || pw.icon != "🔑" {
		t.Errorf("Generate Password metadata: %+v", pw)
	}
	if fs := titles["Flake Update Summary"]; fs == nil || fs.mode != "fullOutput" {
		t.Errorf("Flake Update Summary mode: %+v", fs)
	}
}

func TestUserScriptOverridesAndArgs(t *testing.T) {
	testConfig(t)
	if err := os.MkdirAll(config.Scripts, 0o755); err != nil {
		t.Fatal(err)
	}
	body := `#!/bin/sh
// @title Restart Shell
# @raycast.mode silent
`
	if err := os.WriteFile(filepath.Join(config.Scripts, "restart-shell.sh"), []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	p, err := newScript("Say Hello")
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Base(p) != "say-hello.sh" {
		t.Errorf("new script path %s", p)
	}

	var restart, hello *script
	for _, s := range loadScripts() {
		switch s.title {
		case "Restart Shell":
			restart = s
		case "Say Hello":
			hello = s
		}
	}
	if restart == nil || restart.builtin {
		t.Fatalf("the user's restart-shell.sh must replace the built-in: %+v", restart)
	}
	if hello == nil || len(hello.args) != 1 {
		t.Fatalf("template: %+v", hello)
	}

	s, rest, ok := scriptInvocation("say hello Ada Lovelace", []*script{hello, restart})
	if !ok || s != hello || rest != "Ada Lovelace" {
		t.Errorf("invocation: %v %q %v", s, rest, ok)
	}
	if got := splitArgs(rest, 1); !reflect.DeepEqual(got, []string{"Ada Lovelace"}) {
		t.Errorf("one arg takes the rest: %q", got)
	}
	if got := splitArgs(`"New York" big apple`, 2); !reflect.DeepEqual(got, []string{"New York", "big apple"}) {
		t.Errorf("quotes: %q", got)
	}
	if _, _, ok := scriptInvocation("say hellox", []*script{hello}); ok {
		t.Errorf("a title needs a space after it")
	}
	hello.keywords = []string{"say"}
	if _, _, ok := scriptInvocation("say hel", []*script{hello}); ok {
		t.Errorf("a keyword followed by more of the title is still the title")
	}
	if s, rest, ok := scriptInvocation("say Bob", []*script{hello}); !ok || s != hello || rest != "Bob" {
		t.Errorf("keyword invocation: %v %q %v", s, rest, ok)
	}
}

func TestHelpCoversPrefixes(t *testing.T) {
	testConfig(t)
	items := helpItems("")
	var prefixes []string
	for _, it := range items {
		prefixes = append(prefixes, strings.TrimPrefix(it.Identifier, "help:"))
	}
	for _, p := range []string{"=", "!", "/", ":", ".", "$", ">", "?"} {
		found := false
		for _, x := range prefixes {
			found = found || x == p
		}
		if !found {
			t.Errorf("help misses %q", p)
		}
	}
	if len(helpItems("emoji")) == 0 {
		t.Errorf("help should filter")
	}
}

// The shell's system menu runs power / session commands with the "now"
// action (it confirmed already): straight to execute, logged in dry-run mode.
func TestActivateNowRunsWithoutConfirm(t *testing.T) {
	testConfig(t)
	log := filepath.Join(t.TempDir(), "dry.log")
	config.DryRun = log
	Activate(false, "cmd:shutdown", ActionNow, "", "", 0, nil)
	b, err := os.ReadFile(log)
	if err != nil || !strings.Contains(string(b), "command shutdown: systemctl poweroff") {
		t.Fatalf("dry-run log = %q, %v", b, err)
	}
	pendMu.Lock()
	p := pending
	pendMu.Unlock()
	if p != nil {
		t.Fatalf("now must not ask for confirmation")
	}
}

// The shell's drives.json → "Eject “USB STICK”" + "Eject All"; odd ids
// (they go into a shell line) are skipped; the file is re-read when it changes.
func TestDriveCommands(t *testing.T) {
	testConfig(t)
	f := filepath.Join(t.TempDir(), "drives.json")
	config.Drives = f
	if got := driveCommands(); got != nil {
		t.Fatalf("no file → no commands, got %d", len(got))
	}
	os.WriteFile(f, []byte(`{"drives":[{"id":"sdb","name":"USB STICK","size":"29G","kind":"disk"},{"id":"x; rm -rf ~","name":"bad","kind":"disk"}]}`), 0o644)
	got := driveCommands()
	if len(got) != 2 || got[0].id != "eject-sdb" || got[0].title != "Eject “USB STICK”" || got[0].cmd != "{ipc} drives eject sdb" || got[1].id != "ejectall" {
		t.Fatalf("drive commands = %+v", got)
	}
	if s, _ := match("eject usb", got[0].title, got[0].keywords, false); s <= config.MinScore {
		t.Errorf("“eject usb” should match, score %d", s)
	}
	if driveCommand("ejectall") == nil {
		t.Errorf("Activate must find ejectall")
	}
	os.WriteFile(f, []byte(`{"drives":[]}`), 0o644)
	os.Chtimes(f, time.Now().Add(time.Second), time.Now().Add(time.Second))
	if got := driveCommands(); len(got) != 0 {
		t.Errorf("drives gone → no commands, got %d", len(got))
	}
}
