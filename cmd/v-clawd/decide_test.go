//go:build darwin

package main

import (
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/kamrul1157024/v-claw/internal/state"
)

func TestDecideReportsWhy(t *testing.T) {
	now := time.Now()
	fresh := func() state.State {
		s := state.Default()
		s.Heartbeat = now
		return s
	}
	past := now.Add(-time.Minute)

	tests := []struct {
		name    string
		state   state.State
		loadErr error
		onAC    bool
		acErr   error
		hold    bool
		reason  string // substring
	}{
		{
			name: "auto on AC holds", state: fresh(), onAC: true,
			hold: true, reason: "mode is auto, on AC power",
		},
		{
			name: "auto on battery releases", state: fresh(), onAC: false,
			hold: false, reason: "on battery, and the mode is auto",
		},
		{
			name:  "always holds on battery",
			state: func() state.State { s := fresh(); s.Mode = state.ModeAlways; return s }(),
			hold:  true, reason: "mode is always, on battery",
		},
		{
			name:  "off releases",
			state: func() state.State { s := fresh(); s.Mode = state.ModeOff; return s }(),
			onAC:  true, hold: false, reason: "mode is off",
		},
		{
			name: "expired timer releases",
			state: func() state.State {
				s := fresh()
				s.Mode = state.ModeAlways
				s.ExpiresAt = &past
				return s
			}(),
			onAC: true, hold: false, reason: "timer expired",
		},
		{
			name: "stale app releases",
			state: func() state.State {
				s := fresh()
				s.Heartbeat = now.Add(-state.StaleAfter - time.Minute)
				return s
			}(),
			onAC: true, hold: false, reason: "app stopped responding",
		},
		{
			name:  "lid blocking off releases",
			state: func() state.State { s := fresh(); s.BlockLidSleep = false; return s }(),
			onAC:  true, hold: false, reason: "lid-close blocking is switched off",
		},
		{
			name:  "missing file is not an error worth alarming about",
			state: state.State{}, loadErr: os.ErrNotExist,
			hold: false, reason: "the app has not run",
		},
		{
			name:  "unusable file says so",
			state: state.State{}, loadErr: errors.New("bad json"),
			hold: false, reason: "state file unusable",
		},
		{
			name:  "unreadable power source releases",
			state: fresh(), acErr: errors.New("IOKit said no"),
			hold: false, reason: "cannot read the power source",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := decide(tc.state, tc.loadErr, tc.onAC, tc.acErr, now)
			if got.hold != tc.hold {
				t.Fatalf("hold = %v, want %v (reason %q)", got.hold, tc.hold, got.reason)
			}
			if !strings.Contains(got.reason, tc.reason) {
				t.Fatalf("reason = %q, want it to contain %q", got.reason, tc.reason)
			}
		})
	}
}

// Every release must say why. A log line reading only "released" is useless when
// something goes wrong unattended.
func TestEveryDecisionHasAReason(t *testing.T) {
	now := time.Now()
	s := state.Default()
	s.Heartbeat = now

	for _, onAC := range []bool{true, false} {
		for _, mode := range []state.Mode{state.ModeOff, state.ModeAuto, state.ModeAlways} {
			s.Mode = mode
			d := decide(s, nil, onAC, nil, now)
			if strings.TrimSpace(d.reason) == "" {
				t.Fatalf("mode=%s onAC=%v produced no reason", mode, onAC)
			}
			if !strings.HasPrefix(d.String(), "holding: ") && !strings.HasPrefix(d.String(), "released: ") {
				t.Fatalf("unexpected log line %q", d.String())
			}
		}
	}
}
