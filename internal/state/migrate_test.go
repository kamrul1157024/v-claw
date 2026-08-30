package state

import (
	"os"
	"path/filepath"
	"testing"
)

// A bool added after a state file was written unmarshals to false. For a setting that
// defaults to on, that silently turns it off for every existing user — the opposite of
// what "on by default" means, and invisible unless someone checks.
func TestNewBoolDefaultsOnForOlderFiles(t *testing.T) {
	dir := t.TempDir()

	t.Run("absent means the default", func(t *testing.T) {
		p := filepath.Join(dir, "old.json")
		body := `{"mode":"auto","block_lid_sleep":true,"keep_display_on":true,
		          "lock":{"enabled":true,"policy":"none","idle_minutes":0}}`
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		s, err := Load(p)
		if err != nil {
			t.Fatal(err)
		}
		if !s.WarnOnLidClose {
			t.Fatal("a file written before the setting existed must get the default, not false")
		}
	})

	t.Run("an explicit false is respected", func(t *testing.T) {
		p := filepath.Join(dir, "off.json")
		body := `{"mode":"auto","block_lid_sleep":true,"keep_display_on":true,
		          "warn_on_lid_close":false,
		          "lock":{"enabled":true,"policy":"none","idle_minutes":0}}`
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		s, err := Load(p)
		if err != nil {
			t.Fatal(err)
		}
		if s.WarnOnLidClose {
			t.Fatal("turning the warning off must survive a reload")
		}
	})
}
