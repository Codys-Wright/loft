package main

import (
	"strings"

	"github.com/abenz1267/elephant/v2/pkg/common"
)

// Scores sit on the same scale as elephant's apps (fzf: ~16-30 per matched
// character), a little lower, so for an equally good match the app wins —
// except an exact title or keyword, which beats any fuzzy app.
const (
	bonusExact  = 400
	penaltyBase = 12
)

// match scores q against a title and keywords (0 = no match). Every query
// word may hit a different keyword: "settings wifi" → Wi-Fi.
func match(q, title string, keywords []string, exact bool) (int32, []int32) {
	lq := strings.ToLower(strings.TrimSpace(q))
	if lq == "" {
		return 0, nil
	}
	lt := strings.ToLower(title)

	if lq == lt {
		return bonusExact + 30*int32(len(lq)), prefix(len(lq))
	}
	for _, k := range keywords {
		if lq == strings.ToLower(k) {
			return bonusExact + 20*int32(len(lq)), nil
		}
	}

	var best int32
	var bestPos []int32

	if strings.HasPrefix(lt, lq) {
		best, bestPos = 30*int32(len(lq))+40, prefix(len(lq))
	}

	if s, pos, _ := common.FuzzyScore(lq, title, exact); s > best {
		best, bestPos = s, pos
	}
	for _, k := range keywords {
		if s, _, _ := common.FuzzyScore(lq, k, exact); s-8 > best {
			best, bestPos = s-8, nil
		}
	}

	// Word-wise: each query word prefixes some word of the title or keywords.
	if words := strings.Fields(lq); len(words) > 1 {
		hay := strings.Fields(strings.ToLower(strings.ReplaceAll(title+" "+strings.Join(keywords, " "), "-", " ")))
		total := int32(0)
		for _, w := range words {
			w = strings.ReplaceAll(w, "-", "")
			hit := false
			for _, h := range hay {
				if strings.HasPrefix(h, w) || strings.HasPrefix(strings.ReplaceAll(h, "-", ""), w) {
					hit = true
					break
				}
			}
			if !hit {
				total = 0
				break
			}
			total += 26 * int32(len(w))
		}
		if total > best {
			best, bestPos = total, nil
		}
	}

	if best <= 0 {
		return 0, nil
	}
	return best - penaltyBase, bestPos
}

func prefix(n int) []int32 {
	p := make([]int32, n)
	for i := range p {
		p[i] = int32(i)
	}
	return p
}
