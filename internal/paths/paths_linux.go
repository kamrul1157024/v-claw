package paths

import (
	"os"
	"path/filepath"
)

func sharedDir() string { return "/run/v-claw" }

func userDir() string {
	if xdg := os.Getenv("XDG_RUNTIME_DIR"); xdg != "" {
		return filepath.Join(xdg, "v-claw")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(os.TempDir(), "v-claw")
	}
	return filepath.Join(home, ".config", "v-claw")
}
