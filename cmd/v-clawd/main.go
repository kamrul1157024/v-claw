//go:build darwin

// Command v-clawd is the only part of v-claw that runs as root.
//
// It watches the state file, and it applies the one setting that needs privilege:
// pmset disablesleep, which blocks lid-close sleep. Everything else v-claw does works
// without it.
//
// The state file is writable by an unprivileged user, so it is untrusted input. The
// daemon validates it against a closed set of values and builds pmset arguments from
// typed constants, never from file content.
package main

import (
	"context"
	"errors"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/kamrul1157024/v-claw/internal/paths"
	"github.com/kamrul1157024/v-claw/internal/pmsetctl"
	"github.com/kamrul1157024/v-claw/internal/power"
	"github.com/kamrul1157024/v-claw/internal/state"
)

// tick bounds how long a missed filesystem event or power notification can leave the
// machine in the wrong state. The wrong state here is a thermal risk, so it is short.
const tick = 10 * time.Second

func main() {
	restore := flag.Bool("restore", false,
		"put the recorded original settings back, then exit; used by uninstall")
	flag.Parse()
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("v-clawd: ")

	if os.Geteuid() != 0 {
		log.Fatal("must run as root; it is installed as a LaunchDaemon")
	}

	d := &daemon{
		pm:  pmsetctl.New(),
		pow: power.New(),
	}

	// Uninstall calls this before deleting the binary. Relying on the running daemon
	// to restore on SIGTERM is not enough: if it already crashed or was killed, the
	// machine would keep v-claw's settings forever.
	if *restore {
		rctx, rcancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer rcancel()
		if err := d.release(rctx); err != nil {
			log.Fatalf("restore failed: %v", err)
		}
		log.Print("original settings restored")
		return
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := d.saveOriginals(ctx); err != nil {
		log.Printf("could not record original settings: %v", err)
	}

	log.Printf("watching %s", paths.SharedStateFile())
	err := state.Watch(ctx, paths.SharedStateFile(), tick, d.apply)

	// Releasing on the way out is what makes `launchctl bootout` leave the machine
	// clean. Use a fresh context: the old one is already cancelled.
	shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if rerr := d.release(shutdown); rerr != nil {
		log.Printf("release on shutdown failed: %v", rerr)
	}

	if err != nil && !errors.Is(err, context.Canceled) {
		log.Fatal(err)
	}
	log.Print("stopped, settings restored")
}

type daemon struct {
	pm     *pmsetctl.Control
	pow    power.Controller
	active bool

	// last is the decision already reported, so only changes reach the log.
	last decision
}

// apply is called on every state change and on every tick.
func (d *daemon) apply(s state.State, loadErr error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	onAC, acErr := d.pow.OnAC()
	want := decide(s, loadErr, onAC, acErr, time.Now())

	// Log the transition, not the tick. This runs every ten seconds, so logging
	// unconditionally would bury the moments that matter under thousands of lines
	// saying nothing changed.
	if want.reason != d.last.reason || want.hold != d.last.hold {
		log.Print(want)
		d.last = want
	}

	if want.hold {
		d.mustHold(ctx, s)
		return
	}
	d.mustRelease(ctx)
}

func (d *daemon) mustHold(ctx context.Context, s state.State) {
	if err := d.hold(ctx, s); err != nil {
		log.Printf("hold failed: %v", err)
	}
}

func (d *daemon) mustRelease(ctx context.Context) {
	if err := d.release(ctx); err != nil {
		log.Printf("release failed: %v", err)
	}
}

func (d *daemon) hold(ctx context.Context, s state.State) error {
	// disablesleep is global rather than per power source, so it is re-applied on every
	// transition rather than set once.
	if err := d.pm.SetDisableSleep(ctx, true); err != nil {
		return err
	}
	if s.KeepDisplayOn {
		if err := d.pm.SetDisplaySleep(ctx, pmsetctl.AC, 0); err != nil {
			return err
		}
	}
	if !d.active {
		log.Print("  pmset: disablesleep=1" + displaysleepNote(s))
		d.active = true
	}
	return nil
}

func displaysleepNote(s state.State) string {
	if s.KeepDisplayOn {
		return ", displaysleep=0 on AC"
	}
	return ""
}

func (d *daemon) release(ctx context.Context) error {
	if err := d.pm.SetDisableSleep(ctx, false); err != nil {
		return err
	}
	if err := d.restoreDisplaySleep(ctx); err != nil {
		return err
	}
	if d.active {
		log.Print("  pmset: disablesleep=0, displaysleep restored")
		d.active = false
	}
	return nil
}
