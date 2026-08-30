package state

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestValidateRejectsUnknownValues(t *testing.T) {
	tests := []struct {
		name string
		mut  func(*State)
		ok   bool
	}{
		{"default", func(*State) {}, true},
		{"mode off", func(s *State) { s.Mode = ModeOff }, true},
		{"mode always", func(s *State) { s.Mode = ModeAlways }, true},
		{"unknown mode", func(s *State) { s.Mode = "always-on" }, false},
		{"empty mode", func(s *State) { s.Mode = "" }, false},
		{"shell injection in mode", func(s *State) { s.Mode = "off; rm -rf /" }, false},
		{"unknown policy", func(s *State) { s.Lock.Policy = "pin" }, false},
		{"empty policy", func(s *State) { s.Lock.Policy = "" }, false},
		{"negative idle", func(s *State) { s.Lock.IdleMinutes = -1 }, false},
		{"absurd idle", func(s *State) { s.Lock.IdleMinutes = 1 << 20 }, false},
		{"zero idle is off", func(s *State) { s.Lock.IdleMinutes = 0 }, true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s := Default()
			tc.mut(&s)
			err := s.Validate()
			if tc.ok && err != nil {
				t.Fatalf("want valid, got %v", err)
			}
			if !tc.ok {
				if err == nil {
					t.Fatal("want error, got nil")
				}
				if !errors.Is(err, ErrInvalid) {
					t.Fatalf("want ErrInvalid, got %v", err)
				}
			}
		})
	}
}

func TestWanted(t *testing.T) {
	now := time.Now()
	past := now.Add(-time.Minute)
	future := now.Add(time.Hour)

	tests := []struct {
		name    string
		mode    Mode
		expires *time.Time
		onAC    bool
		want    bool
	}{
		{"auto on AC", ModeAuto, nil, true, true},
		{"auto on battery", ModeAuto, nil, false, false},
		{"always on battery", ModeAlways, nil, false, true},
		{"off on AC", ModeOff, nil, true, false},
		{"always but expired", ModeAlways, &past, true, false},
		{"always not yet expired", ModeAlways, &future, true, true},
		{"auto on AC but expired", ModeAuto, &past, true, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s := Default()
			s.Mode = tc.mode
			s.ExpiresAt = tc.expires
			if got := s.Wanted(tc.onAC, now); got != tc.want {
				t.Fatalf("Wanted(%v) = %v, want %v", tc.onAC, got, tc.want)
			}
		})
	}
}

func TestStale(t *testing.T) {
	now := time.Now()
	s := Default()

	s.Heartbeat = now.Add(-time.Minute)
	if s.Stale(now) {
		t.Fatal("a fresh heartbeat must not be stale")
	}

	s.Heartbeat = now.Add(-StaleAfter - time.Second)
	if !s.Stale(now) {
		t.Fatal("a silent app must go stale, or root holds the machine awake forever")
	}
}

func TestLoadRejectsMalformed(t *testing.T) {
	dir := t.TempDir()
	tests := []struct{ name, body string }{
		{"not json", "{{{"},
		{"truncated", `{"mode":"au`},
		{"unknown mode", `{"mode":"turbo","lock":{"policy":"none"}}`},
		{"empty object", `{}`},
		{"null", `null`},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			p := filepath.Join(dir, "state.json")
			if err := os.WriteFile(p, []byte(tc.body), 0o644); err != nil {
				t.Fatal(err)
			}
			if _, err := Load(p); err == nil {
				t.Fatal("want error, got nil")
			}
		})
	}
}

func TestSaveLoadRoundTrip(t *testing.T) {
	p := filepath.Join(t.TempDir(), "state.json")
	want := Default()
	want.Mode = ModeAlways
	exp := time.Now().Add(time.Hour).Round(time.Second)
	want.ExpiresAt = &exp

	if err := Save(p, want); err != nil {
		t.Fatal(err)
	}
	got, err := Load(p)
	if err != nil {
		t.Fatal(err)
	}
	if got.Mode != want.Mode {
		t.Fatalf("mode = %q, want %q", got.Mode, want.Mode)
	}
	if got.ExpiresAt == nil || !got.ExpiresAt.Equal(exp) {
		t.Fatalf("expires_at = %v, want %v", got.ExpiresAt, exp)
	}
}

func TestSaveRejectsInvalid(t *testing.T) {
	p := filepath.Join(t.TempDir(), "state.json")
	s := Default()
	s.Mode = "nope"
	if err := Save(p, s); err == nil {
		t.Fatal("Save must not write an invalid state")
	}
	if _, err := os.Stat(p); !os.IsNotExist(err) {
		t.Fatal("Save wrote a file despite rejecting the state")
	}
}
