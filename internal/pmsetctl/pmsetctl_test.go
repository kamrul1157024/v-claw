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

// A managed Mac can revert a value minutes after it is written, so a mismatch on a
// scoped setting must surface rather than be assumed away.
func TestReadBackMismatchIsReported(t *testing.T) {
	f := &scopeFake{live: "", custom: "AC Power:\n displaysleep 20\n"}
	c := &Control{R: f}

	err := c.SetDisplaySleep(context.Background(), AC, 0)
	var mm *MismatchError
	if !errors.As(err, &mm) {
		t.Fatalf("want MismatchError, got %v", err)
	}
	if mm.Want != 0 || mm.Have != 20 {
		t.Fatalf("want 0 have 20, got want %d have %d", mm.Want, mm.Have)
	}
}

// disablesleep is verified against IORegistry, not pmset, so these paths no longer
// touch the fake runner's output at all. What matters is that the write itself is
// still a fixed argument list.
func TestDisableSleepWriteArgs(t *testing.T) {
	f := &fake{get: " displaysleep 20\n"}
	c := &Control{R: f}
	_ = c.SetDisableSleep(context.Background(), true)

	if got := f.calls[0]; !equal(got, []string{"-a", "disablesleep", "1"}) {
		t.Fatalf("args = %v", got)
	}
}

func TestMissingKeyStillErrors(t *testing.T) {
	c := &Control{R: &fake{get: " sleep 0\n"}}
	if _, err := c.Get(context.Background(), "displaysleep"); err == nil {
		t.Fatal("a genuinely missing key must not be silently read as zero")
	}
}

// `pmset -g` reports only the power source in use. Verifying a scoped write against it
// meant that setting the AC value while running on battery read back the battery value
// and reported a failure that never happened. Scoped writes must read back from
// `pmset -g custom`.
func TestScopedWriteReadsBackFromItsOwnScope(t *testing.T) {
	f := &scopeFake{
		// The live view shows battery, because that is the source in use.
		live: " displaysleep 3\n",
		custom: `Battery Power:
 displaysleep         3
AC Power:
 displaysleep         20
`,
	}
	c := &Control{R: f}

	if err := c.SetDisplaySleep(context.Background(), AC, 20); err != nil {
		t.Fatalf("writing the AC value while on battery must verify against AC: %v", err)
	}
	if got := f.calls[0]; !equal(got, []string{"-c", "displaysleep", "20"}) {
		t.Fatalf("args = %v", got)
	}

	// A genuine mismatch must still be caught.
	if err := c.SetDisplaySleep(context.Background(), Battery, 20); err == nil {
		t.Fatal("want a mismatch when the battery scope disagrees")
	}
}

type scopeFake struct {
	calls        [][]string
	live, custom string
}

func (f *scopeFake) Run(_ context.Context, args ...string) (string, error) {
	f.calls = append(f.calls, args)
	if len(args) == 2 && args[0] == "-g" && args[1] == "custom" {
		return f.custom, nil
	}
	if len(args) == 1 && args[0] == "-g" {
		return f.live, nil
	}
	return "", nil
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
