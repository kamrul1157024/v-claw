//go:build darwin

package diag

import (
	"context"
	"os/exec"
	"strings"
	"time"
)

// RestartAuth describes whether restarting this Mac actually demands a credential.
//
// This matters more than it looks. The virtual lock is cleared by a restart, which is
// its recovery path for a forgotten password. That is only safe because the restart
// itself lands on a login window: the lock's real floor is the account password,
// enforced by macOS rather than by v-claw.
//
// Turn on automatic login and that floor disappears. Restarting then walks straight to
// the desktop, and the virtual lock becomes decoration. Nothing warns the user, so
// v-claw has to.
type RestartAuth struct {
	Required   bool
	FileVault  bool
	AutoLogin  string // the user configured for automatic login, empty when off
	GuestLogin bool
	Warning    string
}

func CheckRestartAuth() RestartAuth {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	r := RestartAuth{
		AutoLogin:  autoLoginUser(ctx),
		FileVault:  fileVaultOn(ctx),
		GuestLogin: guestEnabled(ctx),
	}
	r.Required = r.AutoLogin == ""

	switch {
	case !r.Required:
		r.Warning = "automatic login is on for \"" + r.AutoLogin +
			"\", so restarting reaches the desktop without a password. " +
			"That makes the virtual lock trivial to bypass."
	case r.GuestLogin:
		r.Warning = "the guest account is enabled, so a restart offers a way in " +
			"without your password. The virtual lock is weaker than it looks."
	}
	return r
}

func autoLoginUser(ctx context.Context) string {
	out, err := exec.CommandContext(ctx, "/usr/bin/defaults", "read",
		"/Library/Preferences/com.apple.loginwindow", "autoLoginUser").Output()
	if err != nil {
		// The key is absent when automatic login is off, and `defaults` exits non-zero.
		return ""
	}
	return strings.TrimSpace(string(out))
}

func fileVaultOn(ctx context.Context) bool {
	out, err := exec.CommandContext(ctx, "/usr/bin/fdesetup", "status").Output()
	if err != nil {
		return false
	}
	return strings.Contains(string(out), "FileVault is On")
}

func guestEnabled(ctx context.Context) bool {
	out, err := exec.CommandContext(ctx, "/usr/bin/defaults", "read",
		"/Library/Preferences/com.apple.loginwindow", "GuestEnabled").Output()
	if err != nil {
		return false
	}
	return strings.TrimSpace(string(out)) == "1"
}
