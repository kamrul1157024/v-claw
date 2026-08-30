//go:build darwin

// Package diag builds the report shown by `v-claw diagnose`.
//
// A managed Mac can defeat v-claw in ways that look like bugs: a configuration profile
// forcing an immediate screen lock, or MDM reverting a power setting minutes after it
// is written. The report exists to name the cause. "It did not work" is useless to the
// person reading it.
package diag

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/kamrul1157024/v-claw/internal/daemonctl"
	"github.com/kamrul1157024/v-claw/internal/paths"
	"github.com/kamrul1157024/v-claw/internal/pmsetctl"
	"github.com/kamrul1157024/v-claw/internal/power"
	"github.com/kamrul1157024/v-claw/internal/state"
)

func Report(version string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	var b strings.Builder
	p := func(f string, a ...any) { fmt.Fprintf(&b, f+"\n", a...) }

	p("v-claw diagnostics")
	p("  version        %s", version)
	p("  macOS          %s", run(ctx, "/usr/bin/sw_vers", "-productVersion"))
	p("  model          %s", run(ctx, "/usr/sbin/sysctl", "-n", "hw.model"))
	p("")

	ok, why := daemonctl.Status()
	tier := "basic"
	if ok {
		tier = "full"
	}
	p("tier             %s", tier)
	if !ok {
		p("  reason         %s", why)
	}

	pow := power.New()
	src := "Battery Power"
	if onAC, err := pow.OnAC(); err != nil {
		src = "unknown: " + err.Error()
	} else if onAC {
		src = "AC Power"
	}
	p("power source     %s", src)

	s, serr := state.Load(paths.StateFile())
	switch {
	case serr != nil && os.IsNotExist(serr):
		p("state            not written yet (the app has not run)")
	case serr != nil:
		p("state            UNUSABLE: %v", serr)
	default:
		p("mode             %s", s.Mode)
		p("block lid sleep  %v", s.BlockLidSleep)
		p("keep display on  %v", s.KeepDisplayOn)
		p("virtual lock     enabled=%v policy=%s idle=%dm",
			s.Lock.Enabled, s.Lock.Policy, s.Lock.IdleMinutes)
		if s.Stale(time.Now()) {
			p("  ! heartbeat is stale; the daemon will have released")
		}
	}
	p("")

	p("assertions held by v-claw")
	assertions := run(ctx, "/usr/bin/pmset", "-g", "assertions")
	found := false
	for _, line := range strings.Split(assertions, "\n") {
		if strings.Contains(line, "v-claw") {
			p("  %s", strings.TrimSpace(line))
			found = true
		}
	}
	if !found {
		p("  none")
	}
	p("")

	p("pmset")
	pm := pmsetctl.New()
	for _, k := range []string{"disablesleep", "displaysleep", "sleep"} {
		v, err := pm.Get(ctx, k)
		if err != nil {
			p("  %-16s not reported", k)
			continue
		}
		p("  %-16s %d", k, v)
	}
	p("")

	warnings := profiles(ctx, &b)
	if len(warnings) == 0 {
		p("warnings")
		p("  none")
		return b.String()
	}
	p("warnings")
	for _, w := range warnings {
		p("  ! %s", w)
	}
	return b.String()
}

// profiles reports configuration profiles that can override v-claw. A profile forcing
// an immediate screen lock beats v-claw outright, and the user must be told plainly
// rather than left to think the app is broken.
func profiles(ctx context.Context, b *strings.Builder) []string {
	fmt.Fprintln(b, "configuration profiles")

	out, err := exec.CommandContext(ctx, "/usr/bin/profiles", "show", "-type", "configuration").CombinedOutput()
	text := string(out)

	// profiles exits 0 whether or not anything is installed, so the output decides.
	if err != nil || strings.Contains(text, "no configuration profiles") {
		fmt.Fprintln(b, "  none installed")
		fmt.Fprintln(b)
		return nil
	}
	fmt.Fprintln(b, "  present")
	fmt.Fprintln(b)

	var warn []string
	if strings.Contains(text, "askForPasswordDelay") || strings.Contains(text, "askForPassword") {
		warn = append(warn, "a profile controls the screen lock; v-claw cannot stop the lock firing")
	}
	if strings.Contains(text, "com.apple.MCX") && strings.Contains(text, "Sleep") {
		warn = append(warn, "a profile controls power settings; pmset writes may be reverted")
	}
	return warn
}

func run(ctx context.Context, bin string, args ...string) string {
	out, err := exec.CommandContext(ctx, bin, args...).Output()
	if err != nil {
		return "unknown"
	}
	return strings.TrimSpace(string(out))
}
