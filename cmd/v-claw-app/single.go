//go:build darwin

package main

import (
	"errors"
	"os"
	"syscall"
	"time"

	"github.com/kamrul1157024/v-claw/internal/paths"
	"github.com/kamrul1157024/v-claw/internal/state"
)

// claimSingleInstance takes an exclusive lock on a file that is held for the lifetime
// of the process.
//
// Without it, launching v-claw from Finder or Spotlight while it is already running
// puts a second icon in the menu bar, and the two copies then fight over the state
// file. The lock is advisory but it is released by the kernel when the process dies,
// so a crash cannot leave a stale claim behind the way a PID file would.
func claimSingleInstance() (release func(), taken bool) {
	f, err := os.OpenFile(paths.LockFile(), os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		// Without a lock file the best available answer is to carry on. A missing
		// guard is better than refusing to start at all.
		return func() {}, false
	}

	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, true
		}
		return func() {}, false
	}

	return func() {
		syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		f.Close()
	}, false
}

// raiseRunningInstance asks the copy that is already running to show its window, which
// is what someone clicking the app icon a second time actually wants.
func raiseRunningInstance() {
	s, err := state.Load(paths.StateFile())
	if err != nil {
		return
	}
	s.ShowWindow = true
	s.Heartbeat = time.Now()
	_ = state.Save(paths.StateFile(), s)
}
