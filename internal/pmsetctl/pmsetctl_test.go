package pmsetctl

import (
	"context"
	"errors"
	"strings"
	"testing"
)

type fake struct {
	calls [][]string
	get   string
	err   error
}

func (f *fake) Run(_ context.Context, args ...string) (string, error) {
	f.calls = append(f.calls, args)
	if f.err != nil {
		return "", f.err
	}
	if len(args) > 0 && args[0] == "-g" {
		return f.get, nil
	}
	return "", nil
}

func TestSetDisableSleepArgs(t *testing.T) {
	f := &fake{get: " disablesleep 1\n"}
	c := &Control{R: f}

	if err := c.SetDisableSleep(context.Background(), true); err != nil {
		t.Fatal(err)
	}

	want := []string{"-a", "disablesleep", "1"}
	if got := f.calls[0]; !equal(got, want) {
		t.Fatalf("args = %v, want %v", got, want)
	}
	if got := f.calls[1]; !equal(got, []string{"-g"}) {
		t.Fatalf("every write must be read back, got %v", got)
	}
}

func TestReadBackMismatchIsReported(t *testing.T) {
	// The write appears to succeed but the value reads back as 0. This is what a
	// managed Mac reverting the setting looks like.
	f := &fake{get: " disablesleep 0\n"}
	c := &Control{R: f}

	err := c.SetDisableSleep(context.Background(), true)
	var mm *MismatchError
	if !errors.As(err, &mm) {
		t.Fatalf("want MismatchError, got %v", err)
	}
	if mm.Want != 1 || mm.Have != 0 {
		t.Fatalf("want 1 have 0, got want %d have %d", mm.Want, mm.Have)
	}
}

func TestDisplaySleepScope(t *testing.T) {
	f := &fake{get: " displaysleep 0\n"}
	c := &Control{R: f}

	if err := c.SetDisplaySleep(context.Background(), AC, 0); err != nil {
		t.Fatal(err)
	}
	if got := f.calls[0]; !equal(got, []string{"-c", "displaysleep", "0"}) {
		t.Fatalf("args = %v", got)
	}
}

func TestParseIgnoresAnnotatedValues(t *testing.T) {
	// pmset annotates live values. The annotation must not break the parse.
	out := ` standby              1
 sleep                0 (sleep prevented by caffeinate, powerd)
 hibernatefile        /var/vm/sleepimage
 displaysleep         20
`
	vals, err := parse(out)
	if err != nil {
		t.Fatal(err)
	}
	if vals["sleep"] != 0 {
		t.Fatalf("sleep = %d, want 0", vals["sleep"])
	}
	if vals["displaysleep"] != 20 {
		t.Fatalf("displaysleep = %d, want 20", vals["displaysleep"])
	}
	if _, ok := vals["hibernatefile"]; ok {
		t.Fatal("non-numeric values must be skipped")
	}
}

func TestCustomSplitsPowerSources(t *testing.T) {
	c := &Control{R: &fakeCustom{out: `Battery Power:
 displaysleep         3
 sleep                1
AC Power:
 displaysleep         20
 sleep                0
`}}

	bat, ac, err := c.Custom(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if bat["displaysleep"] != 3 {
		t.Fatalf("battery displaysleep = %d, want 3", bat["displaysleep"])
	}
	if ac["displaysleep"] != 20 {
		t.Fatalf("ac displaysleep = %d, want 20", ac["displaysleep"])
	}
}

type fakeCustom struct{ out string }

func (f *fakeCustom) Run(context.Context, ...string) (string, error) { return f.out, nil }

func TestNoValueReachesAShell(t *testing.T) {
	// The daemon's input is a user-writable file. Confirm arguments are passed as a
	// list, so a value can never be interpreted by a shell.
	f := &fake{get: " displaysleep 0\n"}
	c := &Control{R: f}
	_ = c.SetDisplaySleep(context.Background(), AC, 0)

	for _, call := range f.calls {
		for _, a := range call {
			if strings.ContainsAny(a, ";|&$`") {
				t.Fatalf("shell metacharacter reached an argument: %q", a)
			}
		}
	}
}

func equal(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
