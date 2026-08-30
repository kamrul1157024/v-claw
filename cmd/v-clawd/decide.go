//go:build darwin

package main

import (
	"fmt"
	"os"
	"time"

	"github.com/kamrul1157024/v-claw/internal/state"
)

// decision is what the daemon should be doing, and why.
//
// The reason exists because "released" on its own is useless when something goes wrong
// at 3am. Whether the adapter was pulled, a timer ran out, or the app stopped answering
// are very different events, and only the log can tell them apart afterwards.
type decision struct {
	hold   bool
	reason string
}

func (d decision) String() string {
	verb := "released"
	if d.hold {
		verb = "holding"
	}
	return verb + ": " + d.reason
}

// decide maps the current state onto an action. It is pure, so the reasoning can be
// tested without touching pmset or the power source.
func decide(s state.State, loadErr error, onAC bool, acErr error, now time.Time) decision {
	switch {
	case loadErr != nil && os.IsNotExist(loadErr):
		return decision{false, "no state file yet, the app has not run"}

	case loadErr != nil:
		return decision{false, fmt.Sprintf("state file unusable (%v)", loadErr)}

	case s.Stale(now):
		return decision{false, fmt.Sprintf("app stopped responding %s ago",
			now.Sub(s.Heartbeat).Round(time.Second))}

	case acErr != nil:
		return decision{false, fmt.Sprintf("cannot read the power source (%v)", acErr)}

	case s.Mode == state.ModeOff:
		return decision{false, "mode is off"}

	case s.Expired(now):
		return decision{false, "the timer expired"}

	case !s.BlockLidSleep:
		return decision{false, "lid-close blocking is switched off"}

	case s.Mode == state.ModeAuto && !onAC:
		return decision{false, "on battery, and the mode is auto"}
	}

	src := "on battery"
	if onAC {
		src = "on AC power"
	}
	if s.ExpiresAt != nil {
		return decision{true, fmt.Sprintf("mode is %s, %s, %s left",
			s.Mode, src, time.Until(*s.ExpiresAt).Round(time.Second))}
	}
	return decision{true, fmt.Sprintf("mode is %s, %s", s.Mode, src)}
}
