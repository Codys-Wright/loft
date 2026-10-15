// Package main is elephant's "commands" provider for Loft's Spotlight:
// system commands (Lock, Log Out, Restart, Shut Down, Sleep, Empty Trash, Do
// Not Disturb, Keep Awake), Loft's panels and Settings pages, curated niri
// window actions, Raycast-style script commands, and the "?" help.
//
// Dangerous commands ask first: Enter turns the query into "Shut Down?" with
// one row, "Shut Down — Enter to confirm"; Enter again runs it. The query
// change needs the patched walker (launcher/walker-set-query.patch), like
// the bangs provider's scopes.
//
// Built into elephant's own provider tree (nix/packages.nix loft-elephant).
package main

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/abenz1267/elephant/v2/internal/comm/handlers"
	"github.com/abenz1267/elephant/v2/internal/util"
	"github.com/abenz1267/elephant/v2/pkg/common"
	"github.com/abenz1267/elephant/v2/pkg/common/history"
	"github.com/abenz1267/elephant/v2/pkg/pb/pb"
)

var (
	Name       = "commands"
	NamePretty = "Commands & Scripts"
	config     *Config
	h          = history.Load(Name)
	cmds       []*command
	cmdByID    = map[string]*command{}
)

//go:embed README.md
var readme string

type Config struct {
	common.Config  `koanf:",squash"`
	ShellIPC       string `koanf:"shell_ipc" desc:"the shell's IPC command, {ipc} in commands" default:"quickshell ipc --any-display call"`
	ShellPath      string `koanf:"shell_path" desc:"the shell's QML dir (LOFT_SHELL_PATH for scripts)" default:""`
	Scripts        string `koanf:"scripts" desc:"your script commands" default:"~/.local/share/loft/scripts"`
	BuiltinScripts string `koanf:"builtin_scripts" desc:"Loft's own script commands" default:""`
	Settings       string `koanf:"settings" desc:"spotlight.json (scripts.disabled)" default:""`
	DryRun         string `koanf:"dry_run" desc:"tests: log power / session / trash commands to this file instead of running them" default:""`
	MinChars       int    `koanf:"min_chars" desc:"shortest query that lists commands next to apps" default:"2"`
}

const (
	ActionRun     = "run"
	ActionConfirm = "confirm"
	ActionCancel  = "cancel"
	ActionQuery   = "query"
	ActionScope   = "scope"
	ActionEdit    = "edit"
	ActionReveal  = "reveal"
	ActionNew     = "new"
	// The caller already asked (the shell's system menu: Restart… → its own
	// confirm dialog): run a built-in command without Spotlight's confirm
	// step. Same command line and dry-run logging as Spotlight's.
	ActionNow = "now"

	scoreTop = 100_000_000 // a confirmation or a script with its arguments
)

func Setup() {
	LoadConfig()
	cmds = builtins()
	for _, c := range cmds {
		cmdByID[c.id] = c
	}
}

func LoadConfig() {
	h, _ := os.UserHomeDir()
	config = &Config{
		Config:   common.Config{Icon: "system-run", MinScore: 20},
		ShellIPC: "quickshell ipc --any-display call",
		Scripts:  h + "/.local/share/loft/scripts",
		MinChars: 2,
	}
	common.LoadConfig(Name, config)
	config.Scripts = expandHome(config.Scripts)
	if config.NamePretty != "" {
		NamePretty = config.NamePretty
	}
}

func Available() bool { return true }

func PrintDoc(write bool) {
	if !write {
		fmt.Println(readme)
		fmt.Println()
	}
	util.PrintConfig(config, Name, write)
}

func Icon() string                                    { return config.Icon }
func HideFromProviderlist() bool                      { return config.HideFromProviderlist }
func State(provider string) *pb.ProviderStateResponse { return &pb.ProviderStateResponse{} }

// ── Settings: spotlight.json's scripts.disabled ──────────────────────────

var (
	setMu    sync.Mutex
	setMTime time.Time
	disabled = map[string]bool{}
)

func scriptDisabled(id string) bool {
	setMu.Lock()
	defer setMu.Unlock()
	if st, err := os.Stat(config.Settings); err == nil && !st.ModTime().Equal(setMTime) {
		setMTime = st.ModTime()
		var s struct {
			Scripts struct {
				Disabled []string `json:"disabled"`
			} `json:"scripts"`
		}
		if b, err := os.ReadFile(config.Settings); err == nil && json.Unmarshal(b, &s) == nil {
			disabled = map[string]bool{}
			for _, d := range s.Scripts.Disabled {
				disabled[d] = true
			}
		}
	}
	return disabled[id]
}

func enabledScripts() []*script {
	var out []*script
	for _, s := range loadScripts() {
		if !scriptDisabled(s.id) {
			out = append(out, s)
		}
	}
	return out
}

// ── Help ("?") ───────────────────────────────────────────────────────────

var help = []struct{ prefix, title, sub, icon string }{
	{"", "Apps, windows, commands & scripts", "Just type: firefox · lock · settings wifi · maximize · copy wifi ip", "system-search"},
	{"=", "Calculator & conversions", "5 km to mi · 72f to c · 100 usd in eur · 3pm PT in Berlin  (also without =)", "accessories-calculator"},
	{"!", "Web search & !bangs", "!yt lofi · !nixpk firefox · quicklinks without the !: yt lofi, gm", "web-browser"},
	{"/", "Files", "/report.pdf — your home folder, recent first; Ctrl+Enter opens the folder", "system-file-manager"},
	{":", "Clipboard history", ":invoice — Enter copies; Ctrl+D removes", "edit-paste"},
	{".", "Emoji & symbols", ".smile · .arrow · .degree", "face-smile"},
	{"$", "Windows", "$firefox — switch to an open window (they're in plain results too)", "preferences-system-windows"},
	{">", "Run a shell command", ">htop — Shift+Enter runs it in a terminal", "utilities-terminal"},
	{"+", "Todo", "+buy milk — Enter saves", "checkbox-checked"},
	{";", "Search sources", "; — every provider (niri actions, bluetooth, …)", "view-list-symbolic"},
	{"?", "This help", "Settings → Spotlight: quicklinks, default engine, script commands", "help-about"},
}

func helpItems(q string) []*pb.QueryResponse_Item {
	var items []*pb.QueryResponse_Item
	for i, e := range help {
		it := &pb.QueryResponse_Item{
			Identifier: "help:" + e.prefix,
			Text:       e.title,
			Subtext:    e.sub,
			Icon:       e.icon,
			Provider:   Name,
			Actions:    []string{ActionQuery},
			Score:      int32(scoreTop - i),
		}
		if e.prefix != "" {
			it.Text = e.prefix + "   " + e.title
		}
		if q != "" {
			s, _ := match(q, e.title, []string{e.prefix}, false)
			if s <= 0 {
				continue
			}
			it.Score = s - 40 // commands first: "?lock" is for Lock Screen
		}
		items = append(items, it)
	}
	return items
}

// ── Query ────────────────────────────────────────────────────────────────

func Query(conn net.Conn, query string, single bool, exact bool, format uint8) []*pb.QueryResponse_Item {
	trim := strings.TrimSpace(query)

	if c := pendingFor(trim); c != nil {
		return confirmItems(c)
	}

	// Settings → Spotlight lists the scripts: `elephant query "commands;#scripts;500"`.
	if single && trim == "#scripts" {
		return scriptListing()
	}

	var items []*pb.QueryResponse_Item
	if single {
		items = helpItems(trim)
		if trim == "" {
			return items
		}
	}

	scripts := enabledScripts()

	// "generate password 32": a script and its arguments.
	if s, rest, ok := scriptInvocation(query, scripts); ok && len(s.args) > 0 {
		return append(items, scriptArgsItem(s, rest))
	}

	if len([]rune(trim)) < config.MinChars && !single {
		return items
	}

	for _, c := range cmds {
		s, pos := match(trim, c.title, c.keywords, exact)
		if s <= config.MinScore {
			continue
		}
		s += h.CalcUsageScore(query, "cmd:"+c.id)
		items = append(items, commandItem(c, s, pos))
	}
	for _, sc := range scripts {
		kw := append([]string{sc.pkg}, sc.keywords...)
		s, pos := match(trim, sc.title, kw, exact)
		if s <= config.MinScore {
			continue
		}
		s += h.CalcUsageScore(query, "script:"+sc.id)
		items = append(items, scriptItem(sc, s, pos))
	}
	return items
}

func commandItem(c *command, score int32, pos []int32) *pb.QueryResponse_Item {
	sub := c.kind
	if c.note != nil {
		if n := c.note(); n != "" {
			sub += "  ·  " + n
		}
	}
	it := &pb.QueryResponse_Item{
		Identifier: "cmd:" + c.id,
		Text:       c.title,
		Subtext:    sub,
		Icon:       c.icon,
		Provider:   Name,
		Score:      score,
		Actions:    []string{ActionRun},
	}
	switch {
	case c.query != "":
		it.Actions = []string{ActionQuery}
	case c.confirm:
		it.Actions = []string{ActionConfirm}
	}
	if len(pos) > 0 {
		it.Fuzzyinfo = &pb.QueryResponse_Item_FuzzyInfo{Field: "text", Positions: pos}
	}
	return it
}

func scriptSub(s *script) string {
	parts := []string{"Script"}
	if s.pkg != "" {
		parts[0] = s.pkg
	}
	if s.desc != "" {
		parts = append(parts, s.desc)
	}
	if p := placeholders(s); p != "" {
		parts = append(parts, p)
	}
	return strings.Join(parts, "  ·  ")
}

func scriptItem(s *script, score int32, pos []int32) *pb.QueryResponse_Item {
	icon, emoji := scriptIcon(s)
	text := s.title
	if emoji != "" {
		text = emoji + "  " + s.title
		pos = nil
	}
	it := &pb.QueryResponse_Item{
		Identifier: "script:" + s.id,
		Text:       text,
		Subtext:    scriptSub(s),
		Icon:       icon,
		Provider:   Name,
		Score:      score,
	}
	switch {
	case s.required() > 0:
		it.Actions = []string{ActionScope, ActionEdit, ActionReveal}
	case s.confirm:
		it.Actions = []string{ActionConfirm, ActionEdit, ActionReveal}
	case len(s.args) > 0:
		it.Actions = []string{ActionRun, ActionScope, ActionEdit, ActionReveal}
	default:
		it.Actions = []string{ActionRun, ActionEdit, ActionReveal}
	}
	if len(pos) > 0 {
		it.Fuzzyinfo = &pb.QueryResponse_Item_FuzzyInfo{Field: "text", Positions: pos}
	}
	return it
}

// scriptArgsItem: "Generate Password 32" → one row that runs it with "32".
func scriptArgsItem(s *script, rest string) *pb.QueryResponse_Item {
	it := scriptItem(s, scoreTop, nil)
	args := splitArgs(rest, len(s.args))
	switch {
	case len(args) < s.required():
		it.Subtext = "Type " + placeholders(s) + "  ·  " + it.Subtext
		it.Actions = []string{ActionEdit, ActionReveal}
	case len(args) == 0:
		it.Subtext = "Enter runs it  ·  optional: " + placeholders(s)
	default:
		quoted := make([]string, len(args))
		for i, a := range args {
			quoted[i] = "“" + a + "”"
		}
		it.Text += " " + strings.Join(quoted, " ")
		it.Subtext = "Enter runs it  ·  " + it.Subtext
	}
	if len(args) >= s.required() {
		if s.confirm {
			it.Actions = []string{ActionConfirm, ActionEdit, ActionReveal}
		} else {
			it.Actions = []string{ActionRun, ActionEdit, ActionReveal}
		}
	}
	return it
}

// scriptListing: every script, disabled ones too, for Settings (JSON in the
// subtext: {id, title, mode, path, builtin, disabled, args, pkg, icon};
// the first row is {dir}, your scripts folder).
func scriptListing() []*pb.QueryResponse_Item {
	dir, _ := json.Marshal(map[string]string{"dir": config.Scripts})
	items := []*pb.QueryResponse_Item{{Identifier: "dir", Text: "Scripts folder", Subtext: string(dir), Provider: Name, Score: 20000}}
	for i, s := range loadScripts() {
		b, _ := json.Marshal(map[string]any{
			"id": s.id, "title": s.title, "mode": s.mode, "path": s.path, "builtin": s.builtin,
			"disabled": scriptDisabled(s.id), "args": placeholders(s), "pkg": s.pkg, "icon": s.icon, "desc": s.desc,
		})
		items = append(items, &pb.QueryResponse_Item{
			Identifier: "script:" + s.id, Text: s.title, Subtext: string(b), Provider: Name, Score: int32(10000 - i),
		})
	}
	return items
}

// ── Confirmation ─────────────────────────────────────────────────────────

type pendingConfirm struct {
	at     time.Time
	prompt string // the query that shows the confirm row: "Shut Down?"
	cmd    *command
	script *script
	args   []string
}

var (
	pendMu  sync.Mutex
	pending *pendingConfirm
)

func pendingFor(q string) *pendingConfirm {
	pendMu.Lock()
	defer pendMu.Unlock()
	if pending == nil || time.Since(pending.at) > 2*time.Minute {
		return nil
	}
	if !strings.EqualFold(q, pending.prompt) {
		return nil
	}
	return pending
}

func askConfirm(p *pendingConfirm) {
	p.at = time.Now()
	pendMu.Lock()
	pending = p
	pendMu.Unlock()
	setQuery(p.prompt)
}

func confirmItems(p *pendingConfirm) []*pb.QueryResponse_Item {
	title, icon, note := "", "", ""
	if p.cmd != nil {
		title, icon = p.cmd.title, p.cmd.icon
		if p.cmd.note != nil {
			note = p.cmd.note()
		}
	} else {
		title = p.script.title
		icon, _ = scriptIcon(p.script)
	}
	sub := "Enter to confirm  ·  Esc cancels"
	if note != "" {
		sub = note + "  ·  " + sub
	}
	return []*pb.QueryResponse_Item{
		{Identifier: "confirmed", Text: title, Subtext: sub, Icon: icon, Provider: Name, Score: scoreTop, Actions: []string{ActionRun}},
		{Identifier: "cancel", Text: "Cancel", Subtext: "Back to Spotlight", Icon: "dialog-cancel", Provider: Name, Score: scoreTop - 1, Actions: []string{ActionCancel}},
	}
}

// ── Activate ─────────────────────────────────────────────────────────────

func Activate(single bool, identifier, action string, query string, args string, format uint8, conn net.Conn) {
	kind, id, _ := strings.Cut(identifier, ":")

	switch {
	case identifier == "cancel" || action == ActionCancel:
		pendMu.Lock()
		pending = nil
		pendMu.Unlock()
		setQuery("")
		return

	case identifier == "confirmed":
		pendMu.Lock()
		p := pending
		pending = nil
		pendMu.Unlock()
		if p == nil || time.Since(p.at) > 2*time.Minute {
			return
		}
		if p.cmd != nil {
			execute(p.cmd)
			h.Save(p.cmd.title, "cmd:"+p.cmd.id)
		} else {
			runScript(p.script, p.args)
			h.Save(p.script.title, "script:"+p.script.id)
		}
		return

	case kind == "help":
		setQuery(id)
		return

	case kind == "cmd":
		c := cmdByID[id]
		if c == nil {
			return
		}
		switch {
		case action == ActionNow:
			if c.query == "" {
				execute(c)
			}
			return // not a Spotlight pick: no history
		case c.query != "":
			setQuery(c.query)
		case action == ActionConfirm || c.confirm:
			askConfirm(&pendingConfirm{prompt: c.title + "?", cmd: c})
			return // used when confirmed
		default:
			execute(c)
		}
		h.Save(query, identifier)

	case kind == "script":
		s := findScript(id)
		if s == nil {
			return
		}
		switch action {
		case ActionEdit:
			open(s.path)
			return
		case ActionReveal:
			open(dirOf(s.path))
			return
		case ActionScope:
			setQuery(s.title + " ")
			return
		}
		var argv []string
		if inv, rest, ok := scriptInvocation(query, []*script{s}); ok && inv == s {
			argv = splitArgs(rest, len(s.args))
		}
		if len(argv) < s.required() {
			setQuery(s.title + " ")
			return
		}
		if action == ActionConfirm || s.confirm {
			askConfirm(&pendingConfirm{prompt: s.title + "?", script: s, args: argv})
			return
		}
		runScript(s, argv)
		h.Save(query, identifier)

	case kind == "new": // Settings → New Script: elephant activate "commands;new:Title;new;;"
		p, err := newScript(id)
		if err != nil {
			notify("New Script", err.Error(), "dialog-error")
			return
		}
		open(p)
	}
}

func dirOf(p string) string {
	if i := strings.LastIndexByte(p, '/'); i > 0 {
		return p[:i]
	}
	return p
}

// execute runs a command (after its delay, so Spotlight is gone first).
func execute(c *command) {
	line := strings.ReplaceAll(c.cmd, "{ipc}", config.ShellIPC)
	if c.danger && logDry("command "+c.id, line) {
		return
	}
	go func() {
		if c.delay > 0 {
			time.Sleep(time.Duration(c.delay) * time.Millisecond)
		}
		run(line)
	}()
}

// logDry: in dry-run mode (tests), record instead of running; true = skipped.
func logDry(what string, argv ...string) bool {
	if config.DryRun == "" {
		return false
	}
	f, err := os.OpenFile(config.DryRun, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err == nil {
		fmt.Fprintf(f, "%s %s: %s\n", time.Now().Format(time.RFC3339), what, strings.Join(argv, " "))
		f.Close()
	}
	slog.Info(Name, "dry-run", what)
	return true
}

func run(line string) {
	cmd := exec.Command("sh", "-c", line)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		slog.Error(Name, "run", err, "cmd", line)
		return
	}
	go cmd.Wait()
}

func open(target string) {
	cmd := exec.Command("xdg-open", target)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err == nil {
		go cmd.Wait()
	}
}

// setQuery replaces walker's query text (needs the patched walker).
func setQuery(text string) {
	handlers.ProviderUpdated <- "menus:%SETQUERY%" + text
}
