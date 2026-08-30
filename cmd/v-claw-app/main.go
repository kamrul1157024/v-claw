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
	"github.com/kamrul1157024/v-claw/internal/diag"
	"github.com/kamrul1157024/v-claw/internal/paths"
	"github.com/kamrul1157024/v-claw/internal/power"
	"github.com/kamrul1157024/v-claw/internal/state"
	"github.com/kamrul1157024/v-claw/internal/ui"
)

// poll bounds how long a missed power notification can leave the menu bar showing
// something untrue. The icon is a safety device, so it is short.
const poll = 5 * time.Second

// version is reported by diagnostics. Kept in step with cmd/v-claw.
const version = "0.1.0"

func main() {
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("v-claw: ")
	systray.Run(onReady, func() { log.Print("exited") })
}

func onReady() {
	a := &app{
		pow: power.New(),
		st:  load(),
		ui:  ui.New(),
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
	pow power.Controller
	st  state.State
	ui  *ui.UI

	menu *menu

	// windowOpen tracks whether the control panel is showing, so state pushes stop
	// when nothing is watching. The panel is the primary interface when the menu bar
	// is full, which on a notched Mac with many status items is common.
	windowOpen bool

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
		case ev := <-a.ui.Events():
			a.handleUI(ev)
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
	case evOpenWindow:
		a.openWindow()
		return
	case evPermissions:
		if err := a.ui.Permissions(a.uiState()); err != nil {
			log.Printf("permissions: %v", err)
		}
		return
	case evDiagnostics:
		go func() {
			if err := a.ui.Diagnostics(diag.Report(version)); err != nil {
				log.Printf("diagnostics: %v", err)
			}
		}()
		return
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
		_ = a.ui.Notify("v-claw released", "The timer expired. The machine can sleep again.")
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

	// The CLI asks for the window this way, because a full menu bar can leave the
	// tray icon invisible with no other way to reach the app.
	if a.st.ShowWindow {
		a.st.ShowWindow = false
		a.save()
		a.openWindow()
	}

	a.maybeIdleLock()
	a.menu.render(a.view(want))

	if a.windowOpen {
		if err := a.ui.Push(a.uiState()); err != nil {
			a.windowOpen = false
		}
	}
}

// uiState is the whole truth handed to the helper on every change. Sending everything
// rather than deltas means a dropped message cannot leave the window showing something
// that is no longer true.
func (a *app) uiState() ui.State {
	caps := a.capabilities()
	tier := "full"
	if !caps.LidBlockAvailable {
		tier = "basic"
	}

	var expires *int
	if a.st.ExpiresAt != nil {
		secs := int(time.Until(*a.st.ExpiresAt).Seconds())
		expires = &secs
	}

	hint := ""
	if a.st.BlockLidSleep && !caps.LidBlockAvailable {
		hint = caps.ExplainUnavailable
	}

	return ui.State{
		Mode:             string(a.st.Mode),
		BlockLidSleep:    a.st.BlockLidSleep,
		KeepDisplayOn:    a.st.KeepDisplayOn,
		ExpiresInSeconds: expires,
		OnAC:             a.onAC,
		Holding:          a.pow.Holding(),
		Tier:             tier,
		StatusLine:       a.statusLine(),
		LidHint:          hint,
		LockEnabled:      a.st.Lock.Enabled,
		LockPolicy:       string(a.st.Lock.Policy),
		LockIdleMinutes:  a.st.Lock.IdleMinutes,
		HotkeyEnabled:    false,
	}
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
	if err := a.ui.Lock(string(a.st.Lock.Policy), a.statusLine()); err != nil {
		log.Printf("lock: %v", err)
		return
	}
	a.st.Lock.Engaged = true
	a.save()
}

// handleUI applies what the user did in the control panel. It mirrors handle() for the
// menu, because both drive the same state.
func (a *app) handleUI(ev ui.Event) {
	switch ev.Ev {
	case "setMode":
		a.st.Mode = state.Mode(ev.Mode)
		a.st.ExpiresAt = nil
	case "setFlag":
		switch ev.Flag {
		case "block_lid_sleep":
			a.st.BlockLidSleep = ev.Value
		case "keep_display_on":
			a.st.KeepDisplayOn = ev.Value
		}
	case "setTimer":
		a.st.ExpiresAt = nil
		if ev.Seconds > 0 {
			a.st.Mode = state.ModeAlways
			t := time.Now().Add(time.Duration(ev.Seconds) * time.Second)
			a.st.ExpiresAt = &t
		}
	case "setLock":
		if ev.Enabled != nil {
			a.st.Lock.Enabled = *ev.Enabled
		}
		if ev.Policy != "" {
			a.st.Lock.Policy = state.Policy(ev.Policy)
		}
		if ev.IdleMinutes != nil {
			a.st.Lock.IdleMinutes = *ev.IdleMinutes
		}
	case "lockNow":
		a.engageLock()
	case "unlocked":
		a.st.Lock.Engaged = false
	case "windowClosed":
		a.windowOpen = false
	case "diagnose":
		// Built here rather than in the helper: the helper is deliberately ignorant
		// of pmset, launchd and configuration profiles.
		go func() {
			if err := a.ui.Diagnostics(diag.Report(version)); err != nil {
				log.Printf("diagnostics: %v", err)
			}
		}()
		return
	case "quit":
		a.shutdown()
		systray.Quit()
		return
	case "ready", "error":
		return
	}
	a.save()
}

func (a *app) openWindow() {
	a.windowOpen = true
	if err := a.ui.Show(a.uiState()); err != nil {
		log.Printf("cannot open window: %v", err)
		a.windowOpen = false
	}
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
	a.ui.Close()
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
