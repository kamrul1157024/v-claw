//go:build darwin

package main

import (
	"context"
	"os/exec"
	"time"
)

// notify posts a user notification.
//
// Notifications are deliberately rare. The one that matters is "v-claw released
// unexpectedly", and it must not be lost among routine ones. Plugging and unplugging
// in auto mode is already visible in the menu bar and is not announced.
func notify(title, body string) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// osascript takes the text as a literal argument, so nothing here is interpreted
	// as a shell command.
	script := `display notification (item 2 of (get argv)) with title (item 1 of (get argv))`
	_ = exec.CommandContext(ctx, "/usr/bin/osascript", "-e", script, title, body).Run()
}
