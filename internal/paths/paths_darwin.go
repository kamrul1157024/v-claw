package paths

import (
	"os"
	"path/filepath"
)

func sharedDir() string { return "/usr/local/var/v-claw" }

func userDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(os.TempDir(), "v-claw")
	}
	return filepath.Join(home, "Library", "Application Support", "v-claw")
}
