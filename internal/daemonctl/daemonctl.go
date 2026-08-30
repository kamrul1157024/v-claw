//go:build darwin

// Package daemonctl reports whether the privileged helper is installed and running.
//
// The answer drives what the UI is allowed to claim. Without the daemon, v-claw can
// only make a best effort at blocking lid-close sleep, and it must say so rather than
// promise a guarantee it cannot keep.
package daemonctl

import (
	"context"
	"os/exec"
	"strings"
	"time"
)

const (
	Label = "com.vclaw.daemon"
	Plist = "/Library/LaunchDaemons/com.vclaw.daemon.plist"
	Exe   = "/usr/local/libexec/v-clawd"
)

// Status reports whether lid blocking is available, and if not, why. The reason is
// shown to the user, so it must name the cause and the fix.
func Status() (ok bool, reason string) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	out, err := exec.CommandContext(ctx, "/bin/launchctl", "print", "system/"+Label).CombinedOutput()
	if err != nil {
		return false, "helper not installed — run `sudo make install-daemon` for guaranteed lid blocking"
	}
	if !strings.Contains(string(out), "state = running") {
		return false, "helper is installed but not running — check `sudo launchctl print system/" + Label + "`"
	}
	return true, ""
}
