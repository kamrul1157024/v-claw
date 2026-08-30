// Package pmsetctl drives /usr/bin/pmset. It is a private detail of the darwin
// implementation and nothing outside it should import this package.
//
// The daemon runs as root and its input comes from a user-writable file, so this
// package never builds a command from that input. Callers pass typed values, this
// package renders the argument list, and no shell is involved anywhere.
//
// Every write is read back. A managed Mac can revert a pmset value minutes later, and
// a write that did not stick must surface as a failure rather than as a lie in the UI.
package pmsetctl

import (
	"bufio"
	"context"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

const bin = "/usr/bin/pmset"

// Runner exists so tests can assert the exact argument list without touching the
// system. Production uses execRunner.
type Runner interface {
	Run(ctx context.Context, args ...string) (string, error)
}

type execRunner struct{}

func (execRunner) Run(ctx context.Context, args ...string) (string, error) {
	out, err := exec.CommandContext(ctx, bin, args...).CombinedOutput()
	if err != nil {
		return string(out), fmt.Errorf("pmset %s: %w: %s", strings.Join(args, " "), err, out)
	}
	return string(out), nil
}

type Control struct{ R Runner }

func New() *Control { return &Control{R: execRunner{}} }

// Scope is the pmset power-source flag. It is a closed set, and it is the only place
// these strings appear.
type Scope string

const (
	All     Scope = "-a"
	AC      Scope = "-c"
	Battery Scope = "-b"
)

// MismatchError reports that a write did not survive a read-back. On a managed Mac
// this usually means a configuration profile is overriding v-claw.
type MismatchError struct {
	Key        string
	Want, Have int
}

func (e *MismatchError) Error() string {
	return fmt.Sprintf("pmset %s did not stick: wrote %d, read back %d", e.Key, e.Want, e.Have)
}

// SetDisableSleep controls the undocumented flag that blocks lid-close sleep.
//
// The flag is global rather than per power source, so the daemon must flip it on every
// transition instead of setting it once.
func (c *Control) SetDisableSleep(ctx context.Context, on bool) error {
	return c.set(ctx, All, "disablesleep", boolInt(on))
}

// SetDisplaySleep sets the display sleep timeout in minutes. Zero means never, which is
// how v-claw stops the screensaver, and therefore the lock, from ever starting.
func (c *Control) SetDisplaySleep(ctx context.Context, s Scope, minutes int) error {
	return c.set(ctx, s, "displaysleep", minutes)
}

// absentMeansZero lists keys that pmset omits from `pmset -g` when they are off,
// rather than reporting them as 0. Treating absence as an error would make a
// successful release look like a failure and log on every tick.
var absentMeansZero = map[string]bool{"disablesleep": true}

func (c *Control) set(ctx context.Context, s Scope, key string, val int) error {
	if _, err := c.R.Run(ctx, string(s), key, strconv.Itoa(val)); err != nil {
		return err
	}

	have, err := c.readBack(ctx, s, key)
	if err != nil {
		return err
	}
	if have != val {
		return &MismatchError{Key: key, Want: val, Have: have}
	}
	return nil
}

// readBack reads the value that was just written, from the same scope it was written
// to.
//
// This has to go through `pmset -g custom` for a scoped write. `pmset -g` reports only
// the power source in use, so setting the AC value while running on battery reads back
// the battery value and looks like a failure that never happened.
func (c *Control) readBack(ctx context.Context, s Scope, key string) (int, error) {
	if s == All {
		return c.Get(ctx, key)
	}

	battery, ac, err := c.Custom(ctx)
	if err != nil {
		return 0, err
	}

	vals := ac
	if s == Battery {
		vals = battery
	}
	v, ok := vals[key]
	if !ok {
		if absentMeansZero[key] {
			return 0, nil
		}
		return 0, fmt.Errorf("pmset: %q not present for scope %q", key, s)
	}
	return v, nil
}

// Get reads a live value from `pmset -g`.
func (c *Control) Get(ctx context.Context, key string) (int, error) {
	out, err := c.R.Run(ctx, "-g")
	if err != nil {
		return 0, err
	}
	vals, err := parse(out)
	if err != nil {
		return 0, err
	}
	v, ok := vals[key]
	if !ok {
		if absentMeansZero[key] {
			return 0, nil
		}
		return 0, fmt.Errorf("pmset: %q not present in output", key)
	}
	return v, nil
}

// Custom reads the per-power-source settings from `pmset -g custom`, so the original
// values can be recorded before v-claw changes anything.
func (c *Control) Custom(ctx context.Context) (battery, ac map[string]int, err error) {
	out, err := c.R.Run(ctx, "-g", "custom")
	if err != nil {
		return nil, nil, err
	}

	battery, ac = map[string]int{}, map[string]int{}
	cur := battery

	sc := bufio.NewScanner(strings.NewReader(out))
	for sc.Scan() {
		line := sc.Text()
		switch {
		case strings.HasPrefix(line, "Battery Power"):
			cur = battery
			continue
		case strings.HasPrefix(line, "AC Power"):
			cur = ac
			continue
		}
		if k, v, ok := parseLine(line); ok {
			cur[k] = v
		}
	}
	return battery, ac, sc.Err()
}

func parse(out string) (map[string]int, error) {
	vals := map[string]int{}
	sc := bufio.NewScanner(strings.NewReader(out))
	for sc.Scan() {
		if k, v, ok := parseLine(sc.Text()); ok {
			vals[k] = v
		}
	}
	return vals, sc.Err()
}

// parseLine reads " key  value" lines. pmset annotates some values, as in
// "sleep 0 (sleep prevented by caffeinate)", so only the first field after the key is
// considered and non-numeric values are skipped.
func parseLine(line string) (string, int, bool) {
	f := strings.Fields(line)
	if len(f) < 2 {
		return "", 0, false
	}
	v, err := strconv.Atoi(f[1])
	if err != nil {
		return "", 0, false
	}
	return f[0], v, true
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}
