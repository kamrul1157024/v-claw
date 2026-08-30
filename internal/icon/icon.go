// Package icon carries the menu bar art. The bytes are embedded, so the binaries never
// look for a file at runtime.
//
// Menu bar icons must be template images: one colour plus alpha. macOS tints them black
// in light mode and white in dark mode. A colour render cannot be used.
package icon

import _ "embed"

// Claw states. Fill against outline is the primary signal, because the icon is a safety
// device: an active hold with the lid closed is a thermal risk, and it must be readable
// at a glance in a crowded menu bar.
var (
	//go:embed png/off.png
	Off []byte

	//go:embed png/armed.png
	Armed []byte

	//go:embed png/active.png
	Active []byte

	//go:embed png/basic.png
	Basic []byte

	//go:embed png/overridden.png
	Overridden []byte
)
