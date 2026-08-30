//go:build darwin

package main

import (
	"fmt"
	"time"

	"fyne.io/systray"

	"github.com/kamrul1157024/v-claw/internal/icon"
	"github.com/kamrul1157024/v-claw/internal/state"
	"github.com/kamrul1157024/v-claw/internal/ui"
)

type eventKind int

const (
	evMode eventKind = iota
	evBlockLid
	evKeepDisplay
	evWarnLid
	evTimed
	evLockNow
	evLockEnabled
	evLockPolicy
	evLockIdle
	evOpenWindow
	evPermissions
	evDiagnostics
	evQuit
)

type event struct {
	kind        eventKind
	mode        state.Mode
	dur         time.Duration
	policy      state.Policy
	idleMinutes int
}

// view is everything the menu needs to draw itself. Keeping it a plain struct means the
// menu never reads live state and cannot race the state machine.
type view struct {
	status                string
	glyph                 []byte
	mode                  state.Mode
	blockLid, keepDisplay bool
	warnLid               bool

	lockEnabled bool
	lockPolicy  state.Policy
	lockIdle    int

	// lidHint explains why lid blocking is not guaranteed. The menu no longer shows
	// it — the window does, next to the setting it concerns — but the status line
	// still needs to know.
	lidHint string
}

type menu struct {
	events chan event

	status            *systray.MenuItem
	off, always, auto *systray.MenuItem
	lockNow           *systray.MenuItem

	quit *systray.MenuItem
}

func (a *app) buildMenu() {
	m := &menu{events: make(chan event, 8)}

	systray.SetIcon(icon.Off)
	systray.SetTooltip("v-claw")

	m.status = systray.AddMenuItem("", "")
	m.status.Disable()
	systray.AddSeparator()

	m.off = systray.AddMenuItemCheckbox("Off", "Change nothing", false)
	m.always = systray.AddMenuItemCheckbox("Always awake", "On any power source", false)
	m.auto = systray.AddMenuItemCheckbox("Auto (on AC)", "Only while plugged in", false)
	systray.AddSeparator()

	timed := systray.AddMenuItem("Awake for", "Release automatically")
	t15 := timed.AddSubMenuItem("15 minutes", "")
	t1h := timed.AddSubMenuItem("1 hour", "")
	t4h := timed.AddSubMenuItem("4 hours", "")
	tUntil := timed.AddSubMenuItem("Until I quit", "")
	systray.AddSeparator()

	m.lockNow = systray.AddMenuItem("Lock screen now", "Cover the screen, stay awake")
	systray.AddSeparator()

	openWin := systray.AddMenuItem("Settings…", "Every option, in a window")
	diagItem := systray.AddMenuItem("Diagnostics…", "")
	systray.AddSeparator()

	m.quit = systray.AddMenuItem("Quit v-claw", "")

	// Without the helper there are no windows to open, so say so rather than let the
	// items look broken when clicked.
	if !ui.Available() {
		for _, it := range []*systray.MenuItem{openWin, diagItem} {
			it.Disable()
		}
		openWin.SetTitle("Settings… (helper missing)")
	}

	a.menu = m

	clicks := map[*systray.MenuItem]event{
		m.off:     {kind: evMode, mode: state.ModeOff},
		m.always:  {kind: evMode, mode: state.ModeAlways},
		m.auto:    {kind: evMode, mode: state.ModeAuto},
		t15:       {kind: evTimed, dur: 15 * time.Minute},
		t1h:       {kind: evTimed, dur: time.Hour},
		t4h:       {kind: evTimed, dur: 4 * time.Hour},
		tUntil:    {kind: evTimed, dur: 0},
		m.lockNow: {kind: evLockNow},
		openWin:   {kind: evOpenWindow},
		diagItem:  {kind: evDiagnostics},
		m.quit:    {kind: evQuit},
	}
	for item, ev := range clicks {
		go func(it *systray.MenuItem, e event) {
			for range it.ClickedCh {
				m.events <- e
			}
		}(item, ev)
	}
}

func (m *menu) render(v view) {
	m.status.SetTitle(v.status)
	systray.SetIcon(v.glyph)
	systray.SetTooltip(v.status)

	check(m.off, v.mode == state.ModeOff)
	check(m.always, v.mode == state.ModeAlways)
	check(m.auto, v.mode == state.ModeAuto)

}

func check(it *systray.MenuItem, on bool) {
	if on {
		it.Check()
		return
	}
	it.Uncheck()
}

// view builds what the menu shows. It reports only what is actually true: the status
// never claims a guarantee the current setup cannot deliver.
func (a *app) view(holding bool) view {
	caps := a.capabilities()
	guaranteed := caps.LidBlockAvailable

	v := view{
		mode:        a.st.Mode,
		blockLid:    a.st.BlockLidSleep,
		keepDisplay: a.st.KeepDisplayOn,
		warnLid:     a.st.WarnOnLidClose,
		lockEnabled: a.st.Lock.Enabled,
		lockPolicy:  a.st.Lock.Policy,
		lockIdle:    a.st.Lock.IdleMinutes,
		status:      a.statusLine(),
		glyph:       icon.Off,
	}

	switch {
	case a.st.Mode == state.ModeOff:
		v.glyph = icon.Off
	case holding && a.st.BlockLidSleep && !guaranteed:
		v.glyph = icon.Basic
	case holding:
		v.glyph = icon.Active
	default:
		v.glyph = icon.Armed
	}

	if a.st.BlockLidSleep && !guaranteed {
		v.lidHint = caps.ExplainUnavailable
	}
	return v
}

func (a *app) statusLine() string {
	if a.st.Mode == state.ModeOff {
		return "Off"
	}

	src := "Battery"
	if a.onAC {
		src = "AC Power"
	}

	if !a.st.Wanted(a.onAC, time.Now()) {
		return src + " — armed, waiting for AC"
	}

	tier := "full"
	if !a.capabilities().LidBlockAvailable && a.st.BlockLidSleep {
		tier = "basic, lid best effort"
	}

	// Say it in the one line that is always visible. Awake on battery drains towards
	// flat, and there is no missing adapter to notice.
	if !a.onAC {
		tier = "on battery, draining"
	}

	if a.st.ExpiresAt != nil {
		left := time.Until(*a.st.ExpiresAt).Round(time.Minute)
		return fmt.Sprintf("%s — awake, %s left (%s)", src, left, tier)
	}
	return fmt.Sprintf("%s — awake (%s)", src, tier)
}
