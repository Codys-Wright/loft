package main

// Script commands, Raycast-style: executable files with metadata comments.
//
//	#!/usr/bin/env bash
//	# @raycast.schemaVersion 1          (optional; "@title" works as well as "@raycast.title")
//	# @raycast.title Copy Wi-Fi IP
//	# @raycast.mode compact             silent | compact | fullOutput | inline
//	# @raycast.icon 📶                   emoji, icon name or image path
//	# @raycast.packageName Network
//	# @raycast.description …
//	# @raycast.argument1 { "type": "text", "placeholder": "length", "optional": true }
//	# @raycast.needsConfirmation true
//	# @raycast.currentDirectoryPath ~
//	# @keyword ip                       (Loft) another name to type
//
// Comments may start with #, //, -- or ;. Raycast's community scripts work
// as they are. Built-in scripts (launcher/scripts) come first; a user script
// with the same file name replaces one.

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode"

	"github.com/abenz1267/elephant/v2/pkg/common"
)

type scriptArg struct {
	Type           string `json:"type"`
	Placeholder    string `json:"placeholder"`
	Optional       bool   `json:"optional"`
	PercentEncoded bool   `json:"percentEncoded"`
}

type script struct {
	id       string // file name: what spotlight.json's scripts.disabled lists
	path     string
	builtin  bool
	title    string
	mode     string
	icon     string
	pkg      string
	desc     string
	keywords []string
	args     []scriptArg
	confirm  bool
	cwd      string
	mtime    time.Time
	size     int64
}

func (s *script) required() int {
	n := 0
	for _, a := range s.args {
		if !a.Optional {
			n++
		}
	}
	return n
}

var reMeta = regexp.MustCompile(`^\s*(?:#|//|--|;)\s*@(?:raycast\.)?([A-Za-z0-9]+)\s*(.*?)\s*$`)

func parseScript(path string) *script {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()

	s := &script{path: path, id: filepath.Base(path), mode: "compact"}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 64*1024)
	for n := 0; sc.Scan() && n < 80; n++ {
		m := reMeta.FindStringSubmatch(sc.Text())
		if m == nil {
			continue
		}
		key, val := strings.ToLower(m[1]), m[2]
		switch {
		case key == "title":
			s.title = val
		case key == "mode":
			s.mode = val
		case key == "icon":
			s.icon = val
		case key == "packagename":
			s.pkg = val
		case key == "description":
			s.desc = val
		case key == "keyword" || key == "keywords" || key == "alias":
			for _, k := range strings.Split(val, ",") {
				if k = strings.TrimSpace(k); k != "" {
					s.keywords = append(s.keywords, k)
				}
			}
		case key == "needsconfirmation":
			s.confirm = val == "true"
		case key == "currentdirectorypath":
			s.cwd = val
		case strings.HasPrefix(key, "argument"):
			var a scriptArg
			if json.Unmarshal([]byte(val), &a) == nil && len(s.args) < 3 {
				s.args = append(s.args, a)
			}
		}
	}
	if s.title == "" {
		return nil
	}
	switch s.mode {
	case "silent", "compact", "fullOutput", "inline":
	default:
		s.mode = "compact"
	}
	return s
}

var (
	scriptMu    sync.Mutex
	scriptCache = map[string]*script{}
)

// loadScripts lists the scripts of both folders (user ones win by name).
func loadScripts() []*script {
	scriptMu.Lock()
	defer scriptMu.Unlock()

	byID := map[string]*script{}
	order := []string{}
	for _, d := range []struct {
		dir     string
		builtin bool
	}{{config.BuiltinScripts, true}, {config.Scripts, false}} {
		if d.dir == "" {
			continue
		}
		entries, err := os.ReadDir(d.dir)
		if err != nil {
			continue
		}
		for _, e := range entries {
			name := e.Name()
			if strings.HasPrefix(name, ".") || strings.HasSuffix(name, ".md") || strings.HasSuffix(name, "~") {
				continue
			}
			p := filepath.Join(d.dir, name)
			st, err := os.Stat(p)
			if err != nil || st.IsDir() || st.Size() > 1<<20 {
				continue
			}
			s := scriptCache[p]
			if s == nil || !s.mtime.Equal(st.ModTime()) || s.size != st.Size() {
				s = parseScript(p)
				if s == nil {
					delete(scriptCache, p)
					continue
				}
				s.mtime, s.size, s.builtin = st.ModTime(), st.Size(), d.builtin
				scriptCache[p] = s
			}
			if _, seen := byID[s.id]; !seen {
				order = append(order, s.id)
			}
			byID[s.id] = s
		}
	}
	out := make([]*script, 0, len(order))
	for _, id := range order {
		out = append(out, byID[id])
	}
	slices.SortStableFunc(out, func(a, b *script) int { return strings.Compare(strings.ToLower(a.title), strings.ToLower(b.title)) })
	return out
}

func findScript(id string) *script {
	for _, s := range loadScripts() {
		if s.id == id {
			return s
		}
	}
	return nil
}

// scriptInvocation: "copy wifi ip", "generate password 32" → the script and
// the text after its title (or keyword). ok=false: q doesn't start with one.
func scriptInvocation(q string, list []*script) (*script, string, bool) {
	trimmed := strings.TrimLeft(q, " ")
	lq := strings.ToLower(trimmed)
	var best *script
	bestLen := 0
	rest := ""
	for _, s := range list {
		// Still typing the title ("flake update" → Flake Update Summary):
		// not a keyword ("flake") with arguments.
		if strings.HasPrefix(strings.ToLower(s.title), strings.TrimRight(lq, " ")) {
			continue
		}
		for _, name := range append([]string{s.title}, s.keywords...) {
			n := strings.ToLower(name) + " "
			if strings.HasPrefix(lq, n) && len(n) > bestLen && len(n) <= len(trimmed) {
				best, bestLen, rest = s, len(n), trimmed[len(n):]
			}
		}
	}
	return best, rest, best != nil
}

// splitArgs: as many arguments as the script takes; the last one gets the
// rest of the line. "double quotes" group words.
func splitArgs(rest string, n int) []string {
	if n == 0 {
		return nil
	}
	var out []string
	r := strings.TrimSpace(rest)
	for len(out) < n-1 && r != "" {
		if r[0] == '"' {
			if end := strings.IndexByte(r[1:], '"'); end >= 0 {
				out = append(out, r[1:end+1])
				r = strings.TrimSpace(r[end+2:])
				continue
			}
		}
		word, more, _ := strings.Cut(r, " ")
		out = append(out, word)
		r = strings.TrimSpace(more)
	}
	if r != "" {
		out = append(out, strings.Trim(r, `"`))
	}
	return out
}

func placeholders(s *script) string {
	var p []string
	for _, a := range s.args {
		t := a.Placeholder
		if t == "" {
			t = "argument"
		}
		if a.Optional {
			t = "[" + t + "]"
		} else {
			t = "<" + t + ">"
		}
		p = append(p, t)
	}
	return strings.Join(p, " ")
}

// scriptIcon: an icon name/path, or "" when it's an emoji (shown in the title).
func scriptIcon(s *script) (icon, emoji string) {
	i := s.icon
	switch {
	case i == "":
		return "utilities-terminal", ""
	case strings.HasPrefix(i, "/") || strings.HasPrefix(i, "~"):
		return expandHome(i), ""
	case strings.HasPrefix(i, "http"):
		return "utilities-terminal", ""
	case strings.ContainsFunc(i, func(r rune) bool { return r > 0x2000 }):
		if p := emojiPNG(i); p != "" {
			return p, ""
		}
		return "", i
	case strings.Contains(i, "."): // "icon.png" next to the script
		return filepath.Join(filepath.Dir(s.path), i), ""
	}
	return i, ""
}

// emojiPNG renders an emoji icon once (ImageMagick + Pango, elephant's
// cache), so it sits in the icon column like Raycast's; "" if it can't.
var (
	emojiMu     sync.Mutex
	emojiFailed = map[string]bool{}
)

func emojiPNG(e string) string {
	p := common.CacheFile(fmt.Sprintf("loft-emoji/%x.png", e))
	if _, err := os.Stat(p); err == nil {
		return p
	}
	emojiMu.Lock()
	defer emojiMu.Unlock()
	if emojiFailed[e] {
		return ""
	}
	_ = os.MkdirAll(filepath.Dir(p), 0o755)
	markup := `<span font="Noto Color Emoji 48">` + strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;").Replace(e) + `</span>`
	cmd := exec.Command("magick", "-background", "none", "-size", "96x96", "-gravity", "center", "pango:"+markup, p+".tmp.png")
	if err := cmd.Run(); err != nil || os.Rename(p+".tmp.png", p) != nil {
		emojiFailed[e] = true
		return ""
	}
	return p
}

func expandHome(p string) string {
	if p == "~" || strings.HasPrefix(p, "~/") {
		h, _ := os.UserHomeDir()
		return filepath.Join(h, strings.TrimPrefix(p, "~"))
	}
	return p
}

// ── Running ──────────────────────────────────────────────────────────────

var reANSI = regexp.MustCompile(`\x1b\[[0-9;?]*[ -/]*[@-~]`)

func runScript(s *script, args []string) {
	for i, a := range s.args {
		if i < len(args) && a.PercentEncoded {
			args[i] = url.QueryEscape(args[i])
		}
	}

	argv := append([]string{s.path}, args...)
	if st, err := os.Stat(s.path); err == nil && st.Mode()&0o111 == 0 {
		// Not executable: its #! line says how.
		if interp := shebang(s.path); interp != nil {
			argv = append(interp, argv...)
		} else {
			notify(s.title, "Not executable: chmod +x "+s.path, "dialog-error")
			return
		}
	}

	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Dir = filepath.Dir(s.path)
	if s.cwd != "" {
		cmd.Dir = expandHome(s.cwd)
	}
	cmd.Env = append(os.Environ(), "LOFT_SCRIPT_MODE="+s.mode)
	if config.ShellPath != "" {
		cmd.Env = append(cmd.Env, "LOFT_SHELL_PATH="+config.ShellPath)
	}
	var out bytes.Buffer
	cmd.Stdout = &limited{&out, 1 << 20}
	cmd.Stderr = cmd.Stdout
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	// Something the script left running (wl-copy's clipboard server) may keep
	// stdout open: stop reading shortly after the script itself exits.
	cmd.WaitDelay = 500 * time.Millisecond

	go func() {
		err := cmd.Run()
		if errors.Is(err, exec.ErrWaitDelay) {
			err = nil
		}
		text := strings.TrimRight(reANSI.ReplaceAllString(out.String(), ""), "\n ")
		last := text
		if i := strings.LastIndexByte(text, '\n'); i >= 0 {
			last = text[i+1:]
		}
		icon, emoji := scriptIcon(s)
		title := s.title
		if emoji != "" {
			title = emoji + "  " + s.title
		}
		if err != nil {
			msg := last
			if msg == "" {
				msg = err.Error()
			}
			notify(s.title+" failed", msg, "dialog-error")
			return
		}
		switch s.mode {
		case "silent":
			if last != "" {
				notify(title, last, icon)
			}
		case "fullOutput":
			if text == "" {
				notify(title, "Done (no output)", icon)
				return
			}
			showOutput(s.title, text)
		default: // compact, inline
			if last == "" {
				last = "Done"
			}
			notify(title, last, icon)
		}
	}()
}

type limited struct {
	b   *bytes.Buffer
	max int
}

func (l *limited) Write(p []byte) (int, error) {
	if room := l.max - l.b.Len(); room > 0 {
		l.b.Write(p[:min(len(p), room)])
	}
	return len(p), nil
}

func shebang(path string) []string {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	line, _ := bufio.NewReader(f).ReadString('\n')
	if !strings.HasPrefix(line, "#!") {
		return nil
	}
	return strings.Fields(strings.TrimSpace(line[2:]))
}

// showOutput: fullOutput mode's result view — Spotlight again (walker's dmenu
// mode), one row per line; Enter copies that line.
func showOutput(title, text string) {
	cmd := exec.Command("walker", "--dmenu", "--placeholder", title+" — Enter copies a line")
	cmd.Stdin = strings.NewReader(text + "\n")
	out, err := cmd.Output()
	if err != nil {
		slog.Error(Name, "output view", err)
		return
	}
	if sel := strings.TrimRight(string(out), "\n"); sel != "" {
		copyText(sel)
	}
}

func copyText(s string) {
	cmd := exec.Command("wl-copy", "-n")
	cmd.Stdin = strings.NewReader(s)
	_ = cmd.Run()
}

func notify(title, body, icon string) {
	args := []string{"-a", "Spotlight", "-t", "4000", "-h", "boolean:transient:true"}
	// Only image files: themed names a banner can't resolve draw as a
	// "missing icon" checkerboard.
	if strings.HasPrefix(icon, "/") {
		args = append(args, "-i", icon)
	}
	args = append(args, title)
	if body != "" {
		args = append(args, body)
	}
	if err := exec.Command("notify-send", args...).Start(); err != nil {
		slog.Error(Name, "notify", err)
	}
}

// ── New script (Settings → Spotlight → New Script) ───────────────────────

const template = `#!/usr/bin/env bash
# Loft Spotlight script command (Raycast-compatible metadata).
#
# @raycast.schemaVersion 1
# @raycast.title %s
# @raycast.mode compact
# @raycast.icon 🧪
# @raycast.packageName My Scripts
# @raycast.description What it does, shown under the title.
# @raycast.argument1 { "type": "text", "placeholder": "name", "optional": true }
#
# Modes: silent (a banner only for output), compact (last line as a banner),
# fullOutput (every line in Spotlight; Enter copies one).
set -euo pipefail

echo "Hello, ${1:-world}!"
`

// newScript writes a template into the user folder; the file's path.
func newScript(title string) (string, error) {
	if config.Scripts == "" {
		return "", fmt.Errorf("no scripts folder configured")
	}
	if err := os.MkdirAll(config.Scripts, 0o755); err != nil {
		return "", err
	}
	base := strings.Map(func(r rune) rune {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			return unicode.ToLower(r)
		}
		return '-'
	}, title)
	p := filepath.Join(config.Scripts, base+".sh")
	for n := 2; ; n++ {
		if _, err := os.Stat(p); os.IsNotExist(err) {
			break
		}
		p = filepath.Join(config.Scripts, fmt.Sprintf("%s-%d.sh", base, n))
	}
	return p, os.WriteFile(p, []byte(fmt.Sprintf(template, title)), 0o755)
}
