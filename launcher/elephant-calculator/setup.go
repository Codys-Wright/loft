// Package main is elephant's "calculator" provider for Loft's Spotlight:
// math, units, currencies (qalc) and time zones, one row with the answer.
// Enter copies it. See README.md.
//
// Built into elephant's own provider tree (nix/packages.nix loft-elephant),
// like the bangs provider.
package main

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/abenz1267/elephant/v2/internal/comm/handlers"
	"github.com/abenz1267/elephant/v2/internal/util"
	"github.com/abenz1267/elephant/v2/pkg/common"
	"github.com/abenz1267/elephant/v2/pkg/pb/pb"
)

var (
	Name       = "calculator"
	NamePretty = "Calculator"
	config     *Config
)

//go:embed README.md
var readme string

type Config struct {
	common.Config `koanf:",squash"`
	Settings      string `koanf:"settings" desc:"spotlight.json (currencyRates: download rates daily)" default:""`
	Command       string `koanf:"command" desc:"copies a result (stdin)" default:"wl-copy -n"`
	QalcConfig    string `koanf:"qalc_config" desc:"qalc's own config dir (XDG_CONFIG_HOME for qalc)" default:"<cache>/loft/qalc"`
}

const (
	ActionCopy       = "copy"
	ActionCopyNumber = "copy_number"
	ActionCopyFull   = "copy_full"

	scoreAnswer = 2_000_000 // above apps and web rows: the answer is the point
)

func Setup() {
	LoadConfig()
	go maybeUpdateRates()
}

func LoadConfig() {
	config = &Config{
		Config:  common.Config{Icon: "accessories-calculator"},
		Command: "wl-copy -n",
	}
	common.LoadConfig(Name, config)
	if config.NamePretty != "" {
		NamePretty = config.NamePretty
	}
}

func Available() bool {
	if _, err := exec.LookPath("qalc"); err != nil {
		slog.Info(Name, "available", "qalc not found: time zones only")
	}
	return true
}

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

var examples = []struct{ q, what string }{
	{"5 km to mi", "Units"},
	{"72f to c", "Temperature"},
	{"100 usd in eur", "Currency"},
	{"3pm PT in Berlin", "Time zones"},
	{"time in Tokyo", "Time zones"},
	{"15% of 80", "Percentages"},
	{"sqrt(2) * pi", "Math"},
}

func Query(conn net.Conn, query string, single bool, exact bool, format uint8) []*pb.QueryResponse_Item {
	q := strings.TrimSpace(query)
	if q == "" {
		if !single {
			return nil
		}
		// "=" alone: what it can do.
		items := []*pb.QueryResponse_Item{}
		for i, e := range examples {
			items = append(items, &pb.QueryResponse_Item{
				Identifier: "example:" + e.q,
				Text:       e.q,
				Subtext:    e.what,
				Icon:       config.Icon,
				Provider:   Name,
				Score:      int32(100 - i),
				Actions:    []string{"try"},
			})
		}
		return items
	}

	if r := timeQuery(q, time.Now()); r != nil {
		return []*pb.QueryResponse_Item{answer(r.text, r.sub, r.copy, r.copy, "preferences-system-time")}
	}

	r := evaluate(q)
	if r == nil {
		return nil
	}
	sign := "≈"
	if r.exact {
		sign = "="
	}
	sub := fmt.Sprintf("%s %s %s", r.parsed, sign, r.full)
	if r.text == r.full {
		sub = r.parsed
	}
	if r.money {
		sub += "  ·  " + ratesNote(r.stale)
		go maybeUpdateRates()
	}
	it := answer(r.text, sub, r.text, r.full, config.Icon)
	it.Identifier += "\x1f" + number(r.text)
	return []*pb.QueryResponse_Item{it}
}

// answer: Identifier carries what Enter copies ("copy\x1ffull\x1fnumber").
func answer(text, sub, copy, full, icon string) *pb.QueryResponse_Item {
	return &pb.QueryResponse_Item{
		Identifier: "r\x1f" + copy + "\x1f" + full,
		Text:       text,
		Subtext:    sub,
		Icon:       icon,
		Provider:   Name,
		Score:      scoreAnswer,
		Actions:    []string{ActionCopy, ActionCopyNumber, ActionCopyFull},
	}
}

func Activate(single bool, identifier, action string, query string, args string, format uint8, conn net.Conn) {
	if strings.HasPrefix(identifier, "example:") {
		// The patched walker replaces the query (launcher/walker-set-query.patch).
		sendQuery("=" + strings.TrimPrefix(identifier, "example:"))
		return
	}
	parts := strings.Split(identifier, "\x1f")
	if len(parts) < 3 {
		return
	}
	value := parts[1]
	switch action {
	case ActionCopyFull:
		value = parts[2]
	case ActionCopyNumber:
		if len(parts) > 3 {
			value = parts[3]
		} else {
			value = number(value)
		}
	}
	cmd := exec.Command("sh", "-c", config.Command)
	cmd.Stdin = strings.NewReader(value)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		slog.Error(Name, "copy", err)
		return
	}
	go cmd.Wait()
}

// ── Settings (spotlight.json, shared with the bangs provider) ───────────

var (
	setMu    sync.Mutex
	setMTime time.Time
	wantRate bool
)

func currencyRatesEnabled() bool {
	setMu.Lock()
	defer setMu.Unlock()
	st, err := os.Stat(config.Settings)
	if err != nil {
		return false
	}
	if !st.ModTime().Equal(setMTime) {
		setMTime = st.ModTime()
		var s struct {
			CurrencyRates bool `json:"currencyRates"`
		}
		if b, err := os.ReadFile(config.Settings); err == nil && json.Unmarshal(b, &s) == nil {
			wantRate = s.CurrencyRates
		}
	}
	return wantRate
}

var updating sync.Mutex

// maybeUpdateRates downloads exchange rates when that's turned on and the
// last attempt is over a day old.
func maybeUpdateRates() {
	if config.Settings == "" || !currencyRatesEnabled() {
		return
	}
	if !updating.TryLock() {
		return
	}
	defer updating.Unlock()

	stamp := filepath.Join(qalcConfigDir(), "rates-attempt")
	if st, err := os.Stat(stamp); err == nil && time.Since(st.ModTime()) < 24*time.Hour {
		return
	}
	_ = os.MkdirAll(qalcConfigDir(), 0o755)
	_ = os.WriteFile(stamp, nil, 0o644)

	cmd := exec.Command("qalc", "-e", "1")
	cmd.Env = qalcEnv()
	if out, err := cmd.CombinedOutput(); err != nil {
		slog.Error(Name, "rates", err, "out", string(out))
		return
	}
	slog.Info(Name, "rates", "updated")
}

// sendQuery replaces walker's query text (needs the patched walker).
func sendQuery(text string) {
	handlers.ProviderUpdated <- "menus:%SETQUERY%" + text
}
