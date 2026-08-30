package paths

import (
	"os"
	"path/filepath"
)

func sharedDir() string {
	if pd := os.Getenv("PROGRAMDATA"); pd != "" {
		return filepath.Join(pd, "v-claw")
	}
	return filepath.Join(os.TempDir(), "v-claw")
}

func userDir() string {
	if ad := os.Getenv("APPDATA"); ad != "" {
		return filepath.Join(ad, "v-claw")
	}
	return filepath.Join(os.TempDir(), "v-claw")
}
