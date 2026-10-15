package main

// "Eject <drive>" and "Eject All": one command per external drive the shell
// lists in <state>/drives.json (src/services/Drives.qml decides what is
// ejectable and does the ejecting: `{ipc} drives eject ID`). Read again
// whenever the file changes, so a drive plugged in a moment ago is there.

import (
	"encoding/json"
	"os"
	"regexp"
	"sync"
	"time"
)

type drive struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Size string `json:"size"`
	Kind string `json:"kind"`
}

var (
	drvMu    sync.Mutex
	drvMTime time.Time
	drvCmds  []*command
	// lsblk kernel names only (sdb, sr0, mmcblk0): they go into a shell line.
	driveID = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)
)

// driveCommands: the current Eject commands (none without drives.json).
func driveCommands() []*command {
	drvMu.Lock()
	defer drvMu.Unlock()
	if config.Drives == "" {
		return nil
	}
	st, err := os.Stat(config.Drives)
	if err != nil {
		drvCmds, drvMTime = nil, time.Time{}
		return nil
	}
	if st.ModTime().Equal(drvMTime) {
		return drvCmds
	}
	drvMTime = st.ModTime()
	drvCmds = nil
	b, err := os.ReadFile(config.Drives)
	if err != nil {
		return nil
	}
	drvCmds = parseDrives(b)
	return drvCmds
}

func parseDrives(b []byte) []*command {
	var f struct {
		Drives []drive `json:"drives"`
	}
	if json.Unmarshal(b, &f) != nil {
		return nil
	}
	var out []*command
	for _, d := range f.Drives {
		if !driveID.MatchString(d.ID) || d.Name == "" {
			continue
		}
		icon := "drive-removable-media"
		if d.Kind == "rom" {
			icon = "media-optical"
		}
		note := d.Size
		out = append(out, &command{
			id:       "eject-" + d.ID,
			title:    "Eject “" + d.Name + "”",
			kind:     "Drive",
			icon:     icon,
			keywords: []string{"eject", "unmount", "safely remove", "usb", d.Name},
			cmd:      "{ipc} drives eject " + d.ID,
			note:     func() string { return note },
		})
	}
	if len(out) > 0 {
		out = append(out, &command{
			id:       "ejectall",
			title:    "Eject All",
			kind:     "Drive",
			icon:     "media-eject",
			keywords: []string{"eject all", "unmount all", "safely remove", "usb", "drives", "disks"},
			cmd:      "{ipc} drives ejectAll",
		})
	}
	return out
}

func driveCommand(id string) *command {
	for _, c := range driveCommands() {
		if c.id == id {
			return c
		}
	}
	return nil
}
