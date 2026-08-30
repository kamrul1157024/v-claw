//go:build darwin

// Command v-claw is the command line face of the app. It reads and writes the same
// state file the menu bar app uses, so the two stay in step with no extra machinery.
package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/kamrul1157024/v-claw/internal/diag"
	"github.com/kamrul1157024/v-claw/internal/paths"
	"github.com/kamrul1157024/v-claw/internal/power"
	"github.com/kamrul1157024/v-claw/internal/state"
)

var version = "0.1.0"

const usage = `v-claw — hold the lid open

usage:
  v-claw open                   open the control panel window
  v-claw status                 show what is active right now
  v-claw on [duration]          always awake, optionally with a deadline
  v-claw auto                   awake only while on the power adapter
  v-claw off                    change nothing
  v-claw logs [-f]              recent log lines from the app and the helper
  v-claw lock-reset             forget the virtual lock password
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
	case "open":
		return openWindow()
	case "status":
		return status()
	case "logs":
		return showLogs(args[1:])
	case "lock-reset":
		return lockReset()
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

// openWindow asks the running app to show its window. Useful when the menu bar is
// full and the tray icon is hidden behind the notch, which macOS does silently.
func openWindow() error {
	s, err := state.Load(paths.StateFile())
	if err != nil {
		return fmt.Errorf("v-claw does not appear to be running: %w", err)
	}
	if s.Stale(time.Now()) {
		return fmt.Errorf("v-claw is not running; start it from /Applications")
	}
	s.ShowWindow = true
	if err := state.Save(paths.StateFile(), s); err != nil {
		return err
	}
	fmt.Println("asked v-claw to open its window")
	return nil
}

// showLogs tails both halves of v-claw at once. Which half misbehaved is rarely
// obvious up front, and correlating two files by hand at the moment something breaks
// is exactly when nobody wants to be looking up paths.
func showLogs(args []string) error {
	follow := len(args) > 0 && (args[0] == "-f" || args[0] == "--follow")

	var present []string
	for _, p := range []string{paths.AppLog(), paths.DaemonLog()} {
		if _, err := os.Stat(p); err == nil {
			present = append(present, p)
			continue
		}
		fmt.Fprintf(os.Stderr, "note: %s does not exist yet\n", p)
	}
	if len(present) == 0 {
		return fmt.Errorf("no logs yet; start v-claw and try again")
	}

	tailArgs := []string{"-n", "40"}
	if follow {
		tailArgs = append(tailArgs, "-f")
	}
	tailArgs = append(tailArgs, present...)

	cmd := exec.Command("/usr/bin/tail", tailArgs...)
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	return cmd.Run()
}

// lockReset forgets the virtual lock password. It is the escape hatch for a forgotten
// one, and it gives nothing away: the virtual lock is a window, not a security
// boundary, so quitting v-claw already removes it.
func lockReset() error {
	out, err := exec.Command("/usr/bin/security", "delete-generic-password",
		"-s", "com.vclaw.virtual-lock").CombinedOutput()
	if err != nil {
		if strings.Contains(string(out), "could not be found") {
			fmt.Println("no virtual lock password was set")
			return nil
		}
		return fmt.Errorf("could not clear the password: %s", out)
	}

	// Leaving the policy pointing at a password that no longer exists would make the
	// lock fail open silently. Say so, and move it back to the honest setting.
	s, lerr := state.Load(paths.StateFile())
	if lerr == nil && s.Lock.Policy == state.PolicyPassword {
		s.Lock.Policy = state.PolicyNone
		if err := state.Save(paths.StateFile(), s); err != nil {
			return err
		}
		fmt.Println("password cleared; the virtual lock is back to \"any key unlocks\"")
		return nil
	}
	fmt.Println("password cleared")
	return nil
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
