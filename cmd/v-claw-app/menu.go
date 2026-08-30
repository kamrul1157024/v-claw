//go:build darwin

package main

import (
	"fmt"
	"time"

	"fyne.io/systray"

	"github.com/kamrul1157024/v-claw/internal/icon"
	"github.com/kamrul1157024/v-claw/internal/state"
)

type eventKind int

const (
	evMode eventKind = iota
	evBlockLid
	evKeepDisplay
	evTimed
	evLockNow
	evLockEnabled
	evLockPolicy
	evLockIdle
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

	lockEnabled bool
	lockPolicy  state.Policy
	lockIdle    int

	// lidHint is shown when lid blocking is not guaranteed. Empty when it is.
	lidHint string
}

type menu struct {
	events chan event

	status                *systray.MenuItem
	off, always, auto     *systray.MenuItem
	blockLid, keepDisplay *systray.MenuItem
	lidHint               *systray.MenuItem

	lockNow                *systray.MenuItem
	lockEnabled            *systray.MenuItem
	policyNone, policyAuth *systray.MenuItem
	idleOff, idle5, idle15 *systray.MenuItem

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

	m.blockLid = systray.AddMenuItemCheckbox("Block lid sleep", "", false)
	m.keepDisplay = systray.AddMenuItemCheckbox("Keep display on", "", false)
	m.lidHint = systray.AddMenuItem("", "")
	m.lidHint.Disable()
	m.lidHint.Hide()
	systray.AddSeparator()

	timed := systray.AddMenuItem("Awake for", "Release automatically")
	t15 := timed.AddSubMenuItem("15 minutes", "")
	t1h := timed.AddSubMenuItem("1 hour", "")
	t4h := timed.AddSubMenuItem("4 hours", "")
	tUntil := timed.AddSubMenuItem("Until I quit", "")
	systray.AddSeparator()

	m.lockNow = systray.AddMenuItem("Lock screen now", "Cover the screen, stay awake")
	lock := systray.AddMenuItem("Virtual lock", "")
	m.lockEnabled = lock.AddSubMenuItemCheckbox("Enabled", "", false)
	lock.AddSeparator()
	m.policyNone = lock.AddSubMenuItemCheckbox("Any key unlocks", "A privacy screen only", false)
	m.policyAuth = lock.AddSubMenuItemCheckbox("Touch ID or password", "", false)
	lock.AddSeparator()
	m.idleOff = lock.AddSubMenuItemCheckbox("No idle lock", "", false)
	m.idle5 = lock.AddSubMenuItemCheckbox("Lock after 5 min idle", "", false)
	m.idle15 = lock.AddSubMenuItemCheckbox("Lock after 15 min idle", "", false)
	systray.AddSeparator()

	m.quit = systray.AddMenuItem("Quit v-claw", "")

	a.menu = m

	clicks := map[*systray.MenuItem]event{
		m.off:         {kind: evMode, mode: state.ModeOff},
		m.always:      {kind: evMode, mode: state.ModeAlways},
		m.auto:        {kind: evMode, mode: state.ModeAuto},
		m.blockLid:    {kind: evBlockLid},
		m.keepDisplay: {kind: evKeepDisplay},
		t15:           {kind: evTimed, dur: 15 * time.Minute},
		t1h:           {kind: evTimed, dur: time.Hour},
		t4h:           {kind: evTimed, dur: 4 * time.Hour},
		tUntil:        {kind: evTimed, dur: 0},
		m.lockNow:     {kind: evLockNow},
		m.lockEnabled: {kind: evLockEnabled},
		m.policyNone:  {kind: evLockPolicy, policy: state.PolicyNone},
		m.policyAuth:  {kind: evLockPolicy, policy: state.PolicyAuth},
		m.idleOff:     {kind: evLockIdle, idleMinutes: 0},
		m.idle5:       {kind: evLockIdle, idleMinutes: 5},
		m.idle15:      {kind: evLockIdle, idleMinutes: 15},
		m.quit:        {kind: evQuit},
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
	check(m.blockLid, v.blockLid)
	check(m.keepDisplay, v.keepDisplay)

	if v.lidHint == "" {
		m.lidHint.Hide()
	} else {
		m.lidHint.SetTitle(v.lidHint)
		m.lidHint.Show()
	}

	check(m.lockEnabled, v.lockEnabled)
	check(m.policyNone, v.lockPolicy == state.PolicyNone)
	check(m.policyAuth, v.lockPolicy == state.PolicyAuth)
	check(m.idleOff, v.lockIdle == 0)
	check(m.idle5, v.lockIdle == 5)
	check(m.idle15, v.lockIdle == 15)
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

	if a.st.ExpiresAt != nil {
		left := time.Until(*a.st.ExpiresAt).Round(time.Minute)
		return fmt.Sprintf("%s — awake, %s left (%s)", src, left, tier)
	}
	return fmt.Sprintf("%s — awake (%s)", src, tier)
}
