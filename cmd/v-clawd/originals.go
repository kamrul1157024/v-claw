//go:build darwin

package main

import (
	"context"
	"encoding/json"
	"os"

	"github.com/kamrul1157024/v-claw/internal/paths"
	"github.com/kamrul1157024/v-claw/internal/pmsetctl"
)

// originals holds the settings as they were before v-claw first changed anything, so
// the machine can be restored exactly. Written once and never overwritten: a second
// write after v-claw is already active would record v-claw's own values as the
// originals and make the damage permanent.
type originals struct {
	DisplaySleepAC      int `json:"displaysleep_ac"`
	DisplaySleepBattery int `json:"displaysleep_battery"`
}

func (d *daemon) saveOriginals(ctx context.Context) error {
	if _, err := os.Stat(paths.OriginalFile()); err == nil {
		return nil
	}

	bat, ac, err := d.pm.Custom(ctx)
	if err != nil {
		return err
	}

	b, err := json.MarshalIndent(originals{
		DisplaySleepAC:      ac["displaysleep"],
		DisplaySleepBattery: bat["displaysleep"],
	}, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(paths.OriginalFile(), append(b, '\n'), 0o644)
}

func (d *daemon) restoreDisplaySleep(ctx context.Context) error {
	b, err := os.ReadFile(paths.OriginalFile())
	if err != nil {
		// With no record there is nothing safe to restore. Leave the value alone
		// rather than guess one.
		return nil
	}

	var o originals
	if err := json.Unmarshal(b, &o); err != nil {
		return nil
	}
	if o.DisplaySleepAC == 0 {
		return nil
	}
	return d.pm.SetDisplaySleep(ctx, pmsetctl.AC, o.DisplaySleepAC)
}
