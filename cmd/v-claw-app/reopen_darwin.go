//go:build darwin

package main

/*
#cgo darwin LDFLAGS: -framework Carbon

// Defined in reopen_darwin.c. Installs the Carbon handler for the macOS
// "reopen" Apple event, which LaunchServices sends the already-running process
// when the app icon is clicked in Finder, the Dock, or Launchpad.
void installReopenHandler(void);
*/
import "C"

// reopen carries a macOS reopen event from the AppKit main thread into run()'s
// select loop, where openWindow runs on the state-machine goroutine that owns
// a.st and a.windowOpen. Buffered by one and sent non-blocking, so a burst of
// clicks collapses to a single window-open and the callback never blocks the
// main run loop.
var reopen = make(chan struct{}, 1)

//export goHandleReopen
func goHandleReopen() {
	select {
	case reopen <- struct{}{}:
	default:
	}
}

// installReopenHandler overrides AppKit's default reopen handler, which does
// nothing for a window-less LSUIElement app. Called from onReady, after
// systray/AppKit has finished launching, so ours wins the
// (kCoreEventClass, kAEReopenApplication) slot: last installer wins.
func installReopenHandler() { C.installReopenHandler() }
