// Package power is the boundary between v-claw and the operating system.
//
// Every OS call that keeps the machine awake lives here, behind one interface with one
// implementation per platform. Nothing above this package may import "C", and nothing
// above it may use platform vocabulary: callers ask to block lid sleep, not to set
// pmset disablesleep.
//
// macOS ships first. Linux and Windows follow, and on Linux a logind inhibitor blocks
// lid close with no privilege at all, so callers must read Caps rather than assume the
// macOS shape.
package power

import "errors"

var ErrUnsupported = errors.New("power: not supported on this platform")

// Options is what the caller wants held. Nothing here names an OS mechanism.
type Options struct {
	KeepDisplayOn bool
	BlockLidSleep bool
}

// Caps describes what this platform can actually deliver, so the UI can tell the truth
// without knowing which platform it is running on.
type Caps struct {
	// LidBlockNeedsPrivilege is false on Linux, where a logind inhibitor is free.
	LidBlockNeedsPrivilege bool
	// LidBlockAvailable reports whether lid blocking can be done right now, including
	// any privileged helper being installed and running.
	LidBlockAvailable bool
	// ExplainUnavailable is shown to the user when LidBlockAvailable is false. It must
	// name the cause, because "it did not work" is useless to the person reading it.
	ExplainUnavailable string
}

// Controller holds the machine awake. Implementations are not safe for concurrent use.
type Controller interface {
	// OnAC reports whether the power adapter is connected.
	OnAC() (bool, error)

	// IdleSeconds is time since the last user input, for the virtual lock idle trigger.
	IdleSeconds() (float64, error)

	// LidClosed reports whether the lid is shut, and whether this machine has one.
	// A desktop reports known=false and must not be treated as permanently open.
	LidClosed() (closed, known bool)

	// Hold keeps the machine awake until Release. Calling it again replaces the
	// previous options. It must be safe to call when already holding.
	Hold(Options) error

	// Release drops everything. It must be safe to call when not holding.
	Release() error

	// Holding reports the current state.
	Holding() bool

	// Capabilities reports what this platform can deliver.
	Capabilities() Caps
}

// New returns the controller for the current platform.
func New() Controller { return newController() }
