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
}

// apply is called on every state change and on every tick.
func (d *daemon) apply(s state.State, err error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	if err != nil {
		// A missing file means the app has not run yet, which is not an error worth
		// logging every tick. Anything else is malformed or hostile input: log it and
		// release, but never act on a partial parse.
		if !os.IsNotExist(err) {
			log.Printf("ignoring unusable state: %v", err)
		}
		d.mustRelease(ctx)
		return
	}

	now := time.Now()

	// A crashed or force-quit app must not leave root holding the machine awake with
	// no UI left to turn it off.
	if s.Stale(now) {
		if d.active {
			log.Printf("app heartbeat is %s old, releasing", now.Sub(s.Heartbeat).Round(time.Second))
		}
		d.mustRelease(ctx)
		return
	}

	onAC, err := d.pow.OnAC()
	if err != nil {
		log.Printf("cannot read power source, releasing: %v", err)
		d.mustRelease(ctx)
		return
	}

	if s.Wanted(onAC, now) && s.BlockLidSleep {
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
		log.Print("holding: lid-close sleep blocked")
		d.active = true
	}
	return nil
}

func (d *daemon) release(ctx context.Context) error {
	if err := d.pm.SetDisableSleep(ctx, false); err != nil {
		return err
	}
	if err := d.restoreDisplaySleep(ctx); err != nil {
		return err
	}
	if d.active {
		log.Print("released")
		d.active = false
	}
	return nil
}
