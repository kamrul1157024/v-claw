//go:build darwin

// Package ui drives the native helper process that draws v-claw's windows.
//
// Everything the user sees beyond the menu bar item lives in a separate binary: the
// control panel, the permissions window, the virtual lock and notifications. Go has no
// good binding for any of that, and keeping it out of process means a bug in the UI
// cannot take down the part that is actually holding the machine awake.
//
// The helper is stateless. This package pushes the whole state on every change and the
// helper renders it, so the two can never disagree about what is true.
package ui

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
)

// helperName sits beside the app binary inside the bundle. It is resolved relative to
// the running executable, never through PATH, so a binary earlier in PATH cannot be
// substituted for it.
const helperName = "v-claw-ui"

// State is what the helper needs to draw itself. The field names are the wire format.
type State struct {
	Mode             string `json:"mode"`
	BlockLidSleep    bool   `json:"blockLidSleep"`
	KeepDisplayOn    bool   `json:"keepDisplayOn"`
	ExpiresInSeconds *int   `json:"expiresInSeconds"`
	OnAC             bool   `json:"onAC"`
	Holding          bool   `json:"holding"`
	Tier             string `json:"tier"`
	StatusLine       string `json:"statusLine"`
	LidHint          string `json:"lidHint"`
	LockEnabled      bool   `json:"lockEnabled"`
	LockPolicy       string `json:"lockPolicy"`
	LockIdleMinutes  int    `json:"lockIdleMinutes"`
	HotkeyEnabled    bool   `json:"hotkeyEnabled"`

	// RestartAuthWarning is non-empty when a restart would reach the desktop without
	// a password. The virtual lock leans on restart being authenticated, so when that
	// stops being true the user has to be told.
	RestartAuthWarning string `json:"restartAuthWarning"`
}

// Event is what the user did. Pointer fields distinguish "not sent" from "sent false",
// because the lock controls report only the field that changed.
type Event struct {
	Ev          string `json:"ev"`
	Mode        string `json:"mode"`
	Flag        string `json:"flag"`
	Value       bool   `json:"value"`
	Seconds     int    `json:"seconds"`
	Policy      string `json:"policy"`
	Enabled     *bool  `json:"enabled"`
	IdleMinutes *int   `json:"idleMinutes"`
	Message     string `json:"message"`

	// Reported once when a password lock engages. Diagnostic only.
	KeyWindow    bool `json:"keyWindow"`
	CanBecomeKey bool `json:"canBecomeKey"`
}

type command struct {
	Cmd     string `json:"cmd"`
	State   *State `json:"state,omitempty"`
	Policy  string `json:"policy,omitempty"`
	Message string `json:"message,omitempty"`
	Title   string `json:"title,omitempty"`
	Body    string `json:"body,omitempty"`
	Text    string `json:"text,omitempty"`
}

type UI struct {
	events chan Event

	mu   sync.Mutex
	cmd  *exec.Cmd
	in   io.WriteCloser
	dead bool
}

func New() *UI { return &UI{events: make(chan Event, 16)} }

// Events delivers what the user did in the helper's windows.
func (u *UI) Events() <-chan Event { return u.events }

// Available reports whether the helper binary is present, so the caller can disable
// the menu items rather than fail silently when they are clicked.
func Available() bool { _, err := helperPath(); return err == nil }

func (u *UI) Show(s State) error        { return u.send(command{Cmd: "show", State: &s}) }
func (u *UI) Push(s State) error        { return u.send(command{Cmd: "state", State: &s}) }
func (u *UI) Hide() error               { return u.send(command{Cmd: "hide"}) }
func (u *UI) Permissions(s State) error { return u.send(command{Cmd: "permissions", State: &s}) }
func (u *UI) Unlock() error             { return u.send(command{Cmd: "unlock"}) }
func (u *UI) Diagnostics(t string) error {
	return u.send(command{Cmd: "diagnostics", Text: t})
}

func (u *UI) Lock(policy, message string) error {
	return u.send(command{Cmd: "lock", Policy: policy, Message: message})
}

func (u *UI) Notify(title, body string) error {
	return u.send(command{Cmd: "notify", Title: title, Body: body})
}

// Close stops the helper. Closing stdin is enough: the helper treats that as the app
// having gone away and exits, which drops any lock window with it.
func (u *UI) Close() {
	u.mu.Lock()
	defer u.mu.Unlock()
	if u.in != nil {
		u.in.Close()
	}
	if u.cmd != nil && u.cmd.Process != nil {
		_ = u.cmd.Process.Kill()
	}
}

func (u *UI) send(c command) error {
	u.mu.Lock()
	defer u.mu.Unlock()

	if err := u.ensure(); err != nil {
		return err
	}

	b, err := json.Marshal(c)
	if err != nil {
		return err
	}
	if _, err := fmt.Fprintf(u.in, "%s\n", b); err != nil {
		// The helper died. Drop it so the next call starts a fresh one rather than
		// leaving the UI permanently broken.
		u.reap()
		return fmt.Errorf("ui helper: %w", err)
	}
	return nil
}

// ensure starts the helper on first use and after a crash. Lazy start keeps the helper
// out of memory for anyone who only ever uses the menu bar.
func (u *UI) ensure() error {
	if u.cmd != nil && !u.dead {
		return nil
	}

	path, err := helperPath()
	if err != nil {
		return err
	}

	cmd := exec.Command(path)
	in, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	cmd.Stderr = os.Stderr

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("cannot start ui helper: %w", err)
	}

	u.cmd, u.in, u.dead = cmd, in, false
	go u.read(cmd, out)
	return nil
}

func (u *UI) read(cmd *exec.Cmd, out io.Reader) {
	sc := bufio.NewScanner(out)
	for sc.Scan() {
		var ev Event
		if err := json.Unmarshal(sc.Bytes(), &ev); err != nil {
			log.Printf("ui helper: unreadable event %q", sc.Text())
			continue
		}
		switch ev.Ev {
		case "error":
			log.Printf("ui helper: %s", ev.Message)
		case "lockInput":
			// No failsafe acts on this. It exists so a lock that swallows keystrokes
			// leaves evidence rather than a mystery.
			if !ev.KeyWindow {
				log.Printf("lock window did not take keyboard focus (canBecomeKey=%v)", ev.CanBecomeKey)
			}
		}
		select {
		case u.events <- ev:
		default:
			log.Print("ui helper: dropping event, channel full")
		}
	}
	_ = cmd.Wait()

	u.mu.Lock()
	u.dead = true
	u.mu.Unlock()
}

func (u *UI) reap() {
	if u.cmd != nil && u.cmd.Process != nil {
		_ = u.cmd.Process.Kill()
	}
	u.dead = true
}

func helperPath() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	p := filepath.Join(filepath.Dir(exe), helperName)
	if _, err := os.Stat(p); err != nil {
		return "", fmt.Errorf("ui helper missing at %s: run `make build`", p)
	}
	return p, nil
}
