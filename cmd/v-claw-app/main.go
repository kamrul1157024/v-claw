//go:build darwin

// Command v-claw-app is the menu bar app.
//
// It runs unprivileged. It holds the OS awake-assertions itself, and it writes the
// state file that the privileged daemon reads for the one setting that needs root.
// Everything here works with no admin rights at all.
package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"fyne.io/systray"

	"github.com/kamrul1157024/v-claw/internal/daemonctl"
	"github.com/kamrul1157024/v-claw/internal/paths"
	"github.com/kamrul1157024/v-claw/internal/power"
	"github.com/kamrul1157024/v-claw/internal/state"
)

// poll bounds how long a missed power notification can leave the menu bar showing
// something untrue. The icon is a safety device, so it is short.
const poll = 5 * time.Second

func main() {
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("v-claw: ")
	systray.Run(onReady, func() { log.Print("exited") })
}

func onReady() {
	a := &app{
		pow:  power.New(),
		st:   load(),
		lock: newLockController(),
	}
	a.buildMenu()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)

	go a.run(ctx)
	go func() {
		<-ctx.Done()
		stop()
		systray.Quit()
	}()
}

func load() state.State {
	s, err := state.Load(paths.StateFile())
	if err != nil {
		// A missing or unusable file is normal on first run. Start from the default
		// rather than refusing to launch.
		return state.Default()
	}
	// A timed override must not survive a restart. The user set a deadline, not a mode.
	if s.Expired(time.Now()) {
		s.ExpiresAt = nil
	}
	return s
}

type app struct {
	pow  power.Controller
	st   state.State
	lock *lockController

	menu *menu

	// written is the last state this process saved. Anything on disk that differs
	// from it was written by the CLI, so it is adopted rather than overwritten.
	written state.State

	onAC bool
}

// sameIntent compares everything the user chose, ignoring the heartbeat. The heartbeat
// changes on a timer and is not a user decision, so it must not count as a change.
func sameIntent(a, b state.State) bool {
	a.Heartbeat, b.Heartbeat = time.Time{}, time.Time{}
	if (a.ExpiresAt == nil) != (b.ExpiresAt == nil) {
		return false
	}
	if a.ExpiresAt != nil && !a.ExpiresAt.Equal(*b.ExpiresAt) {
		return false
	}
	a.ExpiresAt, b.ExpiresAt = nil, nil
	return a == b
}

// run is the single owner of the state machine. Every menu click posts into the same
// loop, so nothing mutates state concurrently.
func (a *app) run(ctx context.Context) {
	t := time.NewTicker(poll)
	defer t.Stop()

	beat := time.NewTicker(state.HeartbeatInterval)
	defer beat.Stop()

	a.sync()

	for {
		select {
		case <-ctx.Done():
			a.shutdown()
			return
		case <-t.C:
			a.sync()
		case <-beat.C:
			// The daemon releases everything if this stops. That is what stops a
			// crashed app from leaving root holding the machine awake forever.
			a.st.Heartbeat = time.Now()
			a.save()
		case ev := <-a.menu.events:
			a.handle(ev)
			a.sync()
		case <-a.lock.unlocked:
			a.st.Lock.Engaged = false
			a.save()
			a.sync()
		}
	}
}

func (a *app) handle(ev event) {
	now := time.Now()
	switch ev.kind {
	case evMode:
		a.st.Mode = ev.mode
		a.st.ExpiresAt = nil
	case evBlockLid:
		a.st.BlockLidSleep = !a.st.BlockLidSleep
	case evKeepDisplay:
		a.st.KeepDisplayOn = !a.st.KeepDisplayOn
	case evTimed:
		// A timer is the main defence against forgetting an active hold, so it also
		// switches to always-awake: a timed hold that only applies on AC is confusing.
		a.st.Mode = state.ModeAlways
		if ev.dur == 0 {
			a.st.ExpiresAt = nil
		} else {
			t := now.Add(ev.dur)
			a.st.ExpiresAt = &t
		}
	case evLockNow:
		a.engageLock()
	case evLockEnabled:
		a.st.Lock.Enabled = !a.st.Lock.Enabled
	case evLockPolicy:
		a.st.Lock.Policy = ev.policy
	case evLockIdle:
		a.st.Lock.IdleMinutes = ev.idleMinutes
	case evQuit:
		a.shutdown()
		systray.Quit()
		return
	}
	a.save()
}

// sync reconciles the OS with the current state. It is the only place assertions are
// taken or dropped.
func (a *app) sync() {
	now := time.Now()
	a.adoptExternal()

	onAC, err := a.pow.OnAC()
	if err != nil {
		log.Printf("cannot read power source: %v", err)
	}
	a.onAC = onAC

	// An expired override is cleared here rather than by a dedicated timer, so there
	// is one path that can change the mode.
	if a.st.Expired(now) {
		a.st.Mode = state.ModeOff
		a.st.ExpiresAt = nil
		a.save()
		notify("v-claw released", "The timer expired. The machine can sleep again.")
	}

	want := a.st.Wanted(a.onAC, now)
	if want {
		err = a.pow.Hold(power.Options{
			KeepDisplayOn: a.st.KeepDisplayOn,
			BlockLidSleep: a.st.BlockLidSleep,
		})
	} else {
		err = a.pow.Release()
	}
	if err != nil {
		log.Printf("power: %v", err)
	}

	a.maybeIdleLock()
	a.menu.render(a.view(want))
}

func (a *app) maybeIdleLock() {
	if !a.st.Lock.Enabled || a.st.Lock.IdleMinutes == 0 || a.st.Lock.Engaged {
		return
	}
	idle, err := a.pow.IdleSeconds()
	if err != nil {
		return
	}
	if idle >= float64(a.st.Lock.IdleMinutes*60) {
		a.engageLock()
	}
}

func (a *app) engageLock() {
	if a.st.Lock.Engaged {
		return
	}
	if err := a.lock.engage(a.st.Lock.Policy, a.statusLine()); err != nil {
		log.Printf("lock: %v", err)
		notify("v-claw could not lock", err.Error())
		return
	}
	a.st.Lock.Engaged = true
	a.save()
}

// adoptExternal picks up changes made by the CLI. Without this the app would clobber
// them on its next write, and `v-claw off` would appear to do nothing.
func (a *app) adoptExternal() {
	ext, err := state.Load(paths.StateFile())
	if err != nil || sameIntent(ext, a.written) {
		return
	}
	a.st = ext
	// Save rather than just adopt. The CLI leaves the heartbeat as it found it, so
	// without this the file keeps a stale timestamp until the next beat, and the
	// daemon's watchdog would read a live app as dead and release.
	a.save()
}

func (a *app) save() {
	a.st.Heartbeat = time.Now()
	if err := state.Save(paths.StateFile(), a.st); err != nil {
		// The state directory only exists once the daemon is installed. Without it
		// the app still works; it just cannot ask for privileged lid blocking.
		if !os.IsNotExist(err) {
			log.Printf("cannot write state: %v", err)
		}
		return
	}
	a.written = a.st
}

func (a *app) shutdown() {
	a.lock.close()
	if err := a.pow.Release(); err != nil {
		log.Printf("release on exit: %v", err)
	}
	// Mark the state inactive so the daemon does not wait out the staleness window.
	a.st.Mode = state.ModeOff
	a.st.Lock.Engaged = false
	a.save()
}

func (a *app) capabilities() power.Caps {
	caps := a.pow.Capabilities()
	ok, reason := daemonctl.Status()
	caps.LidBlockAvailable = ok
	caps.ExplainUnavailable = reason
	return caps
}
