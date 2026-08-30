//go:build darwin

// Command v-claw is the command line face of the app. It reads and writes the same
// state file the menu bar app uses, so the two stay in step with no extra machinery.
package main

import (
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/kamrul1157024/v-claw/internal/diag"
	"github.com/kamrul1157024/v-claw/internal/paths"
	"github.com/kamrul1157024/v-claw/internal/power"
	"github.com/kamrul1157024/v-claw/internal/state"
)

var version = "0.1.0"

const usage = `v-claw — hold the lid open

usage:
  v-claw status                 show what is active right now
  v-claw on [duration]          always awake, optionally with a deadline
  v-claw auto                   awake only while on the power adapter
  v-claw off                    change nothing
  v-claw diagnose               full report, including managed-Mac overrides
  v-claw version

The menu bar app picks changes up within a few seconds.
`

func main() {
	flag.Usage = func() { fmt.Fprint(os.Stderr, usage) }
	flag.Parse()

	if err := run(flag.Args()); err != nil {
		fmt.Fprintln(os.Stderr, "v-claw:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		fmt.Print(usage)
		return nil
	}

	switch args[0] {
	case "status":
		return status()
	case "diagnose":
		fmt.Print(diag.Report(version))
		return nil
	case "version":
		fmt.Println(version)
		return nil
	case "off":
		return setMode(state.ModeOff, 0)
	case "auto":
		return setMode(state.ModeAuto, 0)
	case "on":
		var d time.Duration
		if len(args) > 1 {
			var err error
			if d, err = time.ParseDuration(args[1]); err != nil {
				return fmt.Errorf("bad duration %q: %w", args[1], err)
			}
		}
		return setMode(state.ModeAlways, d)
	default:
		return fmt.Errorf("unknown command %q", args[0])
	}
}

func setMode(m state.Mode, d time.Duration) error {
	s, err := state.Load(paths.StateFile())
	if err != nil {
		s = state.Default()
	}

	s.Mode = m
	s.ExpiresAt = nil
	if d > 0 {
		t := time.Now().Add(d)
		s.ExpiresAt = &t
	}
	// Leave the heartbeat alone. It belongs to the app, and forging it here would
	// stop the daemon's watchdog from noticing a dead app.
	if err := state.Save(paths.StateFile(), s); err != nil {
		return err
	}

	fmt.Printf("mode %s", m)
	if s.ExpiresAt != nil {
		fmt.Printf(", until %s", s.ExpiresAt.Format(time.Kitchen))
	}
	fmt.Println()
	return nil
}

func status() error {
	s, err := state.Load(paths.StateFile())
	if err != nil {
		return fmt.Errorf("no usable state: %w", err)
	}

	onAC, _ := power.New().OnAC()
	src := "battery"
	if onAC {
		src = "AC power"
	}

	fmt.Printf("mode      %s\n", s.Mode)
	fmt.Printf("power     %s\n", src)
	fmt.Printf("awake     %v\n", s.Wanted(onAC, time.Now()))
	if s.ExpiresAt != nil {
		fmt.Printf("expires   %s\n", time.Until(*s.ExpiresAt).Round(time.Second))
	}
	if s.Stale(time.Now()) {
		fmt.Println("warning   the app is not running; the daemon has released")
	}
	return nil
}
