// Package paths resolves every filesystem location v-claw uses.
//
// Nothing else in the tree hardcodes a path. Linux and Windows follow macOS, and their
// conventions differ, so resolution lives behind one function per platform.
package paths

import (
	"os"
	"path/filepath"
)

// StateFile is the state the app and CLI read and write.
//
// It prefers the shared directory, which the privileged daemon also reads. That
// directory only exists once the daemon is installed, and creating it needs admin. A
// user who never gets admin must still be able to change settings and have them
// persist, so this falls back to a per-user directory.
//
// The fallback is invisible to the daemon by design: with no daemon installed there is
// nothing to coordinate with.
func StateFile() string {
	if usableSharedDir() {
		return filepath.Join(sharedDir(), "state.json")
	}
	dir := userDir()
	// Best effort. Callers already handle a failing write.
	_ = os.MkdirAll(dir, 0o755)
	return filepath.Join(dir, "state.json")
}

// LockFile guards against a second copy of the app running. It sits beside the state
// file so it lands in whichever directory that resolved to.
func LockFile() string { return filepath.Join(filepath.Dir(StateFile()), "app.lock") }

// AppLog and DaemonLog are where each half writes. The daemon runs as root and logs
// under /var/log; the app runs as you. Both are fixed paths because launchd needs a
// literal string in the plist, not something resolved at runtime.
func AppLog() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(os.TempDir(), "v-claw.log")
	}
	return filepath.Join(home, "Library", "Logs", "v-claw.log")
}
func DaemonLog() string { return "/var/log/v-clawd.log" }

// SharedStateFile is the path the privileged daemon watches. It never falls back,
// because root must not read a state file out of one user's home directory.
func SharedStateFile() string { return filepath.Join(sharedDir(), "state.json") }

// OriginalFile records settings captured before v-claw first changed them, so
// uninstall can restore the machine exactly. The daemon owns it.
func OriginalFile() string { return filepath.Join(sharedDir(), "original.json") }

// SharedDir is where `make install-daemon` creates state, owned by the installing user.
func SharedDir() string { return sharedDir() }

func usableSharedDir() bool {
	info, err := os.Stat(sharedDir())
	if err != nil || !info.IsDir() {
		return false
	}
	// Existing but unwritable would make every save fail silently, so probe it.
	f, err := os.CreateTemp(sharedDir(), ".probe-*")
	if err != nil {
		return false
	}
	name := f.Name()
	f.Close()
	os.Remove(name)
	return true
}
