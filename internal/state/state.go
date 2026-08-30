// Package state owns the file the tray app writes and the privileged daemon reads.
//
// The daemon runs as root and acts on this file, so a user who can write it can make
// root change power settings. Treat every field as untrusted input: validate against a
// closed set of values, and never let a value from here reach a shell.
package state

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

type Mode string

const (
	ModeOff    Mode = "off"
	ModeAlways Mode = "always"
	ModeAuto   Mode = "auto"
)

type Policy string

const (
	// PolicyNone dismisses on any key. A privacy screen and nothing more.
	PolicyNone Policy = "none"
	// PolicyPassword uses v-claw's own password, kept in the Keychain. Deliberately
	// not the macOS account password: prompting for that in a full-screen window is
	// the shape of a phishing attack and trains the wrong reflex.
	PolicyPassword Policy = "password"
	// policyAuth was Touch ID with a macOS password fallback. Retired: the system
	// prompt is a surface v-claw does not control, and the "fail open after three
	// failures" valve it needed was itself the bypass — cancel three times and the
	// lock opened. Existing values are coerced to PolicyNone on load.
	policyAuth Policy = "auth"
)

// StaleAfter is how long the daemon waits on a silent heartbeat before releasing
// everything. It guards against a crashed app leaving the machine unable to sleep.
const StaleAfter = 5 * time.Minute

// HeartbeatInterval is how often a running app refreshes Heartbeat.
const HeartbeatInterval = time.Minute

type Lock struct {
	Enabled     bool   `json:"enabled"`
	Policy      Policy `json:"policy"`
	IdleMinutes int    `json:"idle_minutes"`
	Hotkey      string `json:"hotkey"`
	Engaged     bool   `json:"engaged"`
}

type State struct {
	Mode          Mode       `json:"mode"`
	BlockLidSleep bool       `json:"block_lid_sleep"`
	KeepDisplayOn bool       `json:"keep_display_on"`
	ExpiresAt     *time.Time `json:"expires_at"`
	Heartbeat     time.Time  `json:"heartbeat"`
	Lock          Lock       `json:"lock"`

	// WarnOnLidClose plays a sound when the lid shuts while v-claw is holding the
	// machine awake. On by default: closing a lid is the universal gesture for "this
	// is now asleep", and a machine that quietly keeps running inside a bag is the
	// one genuinely dangerous thing this app can do.
	WarnOnLidClose bool `json:"warn_on_lid_close"`

	// LidWarnSound names the alert. Validated against a closed list before it is ever
	// turned into a path.
	LidWarnSound string `json:"lid_warn_sound"`

	// LidWarnEverySeconds repeats the warning while the lid stays shut and the machine
	// stays awake. A single chime at the moment of closing is easily missed — the lid
	// is already moving, the room may be noisy, and the person is usually walking away.
	// Repeating is what makes it reach someone who has stopped paying attention.
	// Zero warns once and then stays quiet.
	LidWarnEverySeconds int `json:"lid_warn_every_seconds"`

	// ShowWindow is a request from the CLI for the running app to open its window.
	// The app clears it once handled. It lives here rather than in a separate channel
	// because the state file is already the one thing both processes share, and a
	// second IPC mechanism for one boolean is not worth the moving parts.
	// The daemon ignores it.
	ShowWindow bool `json:"show_window"`
}

func Default() State {
	return State{
		Mode:                ModeAuto,
		BlockLidSleep:       true,
		KeepDisplayOn:       true,
		WarnOnLidClose:      true,
		LidWarnSound:        "Funk",
		LidWarnEverySeconds: 15,
		Heartbeat:           time.Now(),
		Lock: Lock{
			Enabled: true,
			Policy:  PolicyNone,
			Hotkey:  "ctrl+cmd+q",
		},
	}
}

var ErrInvalid = errors.New("invalid state")

// Validate rejects anything outside the closed set of accepted values. The daemon
// calls this before acting, and it must reject rather than repair: a silently
// corrected value would hide a bug or an attack.
func (s State) Validate() error {
	switch s.Mode {
	case ModeOff, ModeAlways, ModeAuto:
	default:
		return fmt.Errorf("%w: mode %q", ErrInvalid, s.Mode)
	}

	switch s.Lock.Policy {
	case PolicyNone, PolicyPassword:
	default:
		return fmt.Errorf("%w: lock.policy %q", ErrInvalid, s.Lock.Policy)
	}

	if s.Lock.IdleMinutes < 0 || s.Lock.IdleMinutes > 24*60 {
		return fmt.Errorf("%w: lock.idle_minutes %d", ErrInvalid, s.Lock.IdleMinutes)
	}

	if s.LidWarnEverySeconds < 0 || s.LidWarnEverySeconds > 3600 {
		return fmt.Errorf("%w: lid_warn_every_seconds %d", ErrInvalid, s.LidWarnEverySeconds)
	}
	return nil
}

// Expired reports whether a timed override has run out.
func (s State) Expired(now time.Time) bool {
	return s.ExpiresAt != nil && !now.Before(*s.ExpiresAt)
}

// Stale reports whether the app has stopped refreshing the heartbeat.
func (s State) Stale(now time.Time) bool {
	return now.Sub(s.Heartbeat) > StaleAfter
}

// Wanted reports whether v-claw should be holding the machine awake right now.
func (s State) Wanted(onAC bool, now time.Time) bool {
	if s.Expired(now) {
		return false
	}
	switch s.Mode {
	case ModeAlways:
		return true
	case ModeAuto:
		return onAC
	default:
		return false
	}
}

func Load(path string) (State, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return State{}, err
	}
	var s State
	if err := json.Unmarshal(b, &s); err != nil {
		return State{}, fmt.Errorf("%w: %v", ErrInvalid, err)
	}
	// A retired policy must not make the file unloadable, which would silently reset
	// every other setting too.
	if s.Lock.Policy == policyAuth {
		s.Lock.Policy = PolicyNone
	}

	// A bool added after a state file was written unmarshals to false, which for an
	// opt-out setting silently means "off" for everyone who already had v-claw. Absent
	// and explicitly false have to be told apart.
	var probe struct {
		WarnOnLidClose      *bool   `json:"warn_on_lid_close"`
		LidWarnSound        *string `json:"lid_warn_sound"`
		LidWarnEverySeconds *int    `json:"lid_warn_every_seconds"`
	}
	if json.Unmarshal(b, &probe) == nil {
		d := Default()
		if probe.WarnOnLidClose == nil {
			s.WarnOnLidClose = d.WarnOnLidClose
		}
		if probe.LidWarnSound == nil || s.LidWarnSound == "" {
			s.LidWarnSound = d.LidWarnSound
		}
		if probe.LidWarnEverySeconds == nil {
			s.LidWarnEverySeconds = d.LidWarnEverySeconds
		}
	}
	if err := s.Validate(); err != nil {
		return State{}, err
	}
	return s, nil
}

// Save writes atomically. The daemon watches this path, and a partial read of a
// half-written file would be acted on by root.
func Save(path string, s State) error {
	if err := s.Validate(); err != nil {
		return err
	}
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	b = append(b, '\n')

	tmp, err := os.CreateTemp(filepath.Dir(path), ".state-*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())

	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmp.Name(), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}
