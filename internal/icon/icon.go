// Package icon carries the menu bar art. The bytes are embedded, so the binaries never
// look for a file at runtime.
//
// These are colour images, not macOS template images. A template gets tinted black or
// white by the system, which would throw away the state signal that colour carries.
// Callers must use systray.SetIcon, never SetTemplateIcon.
package icon

import _ "embed"

// Claw states. Two signals carry the state, so neither has to be relied on alone:
// fill against outline, and grey against orange against red.
//
// This matters because the icon is a safety device. An active hold with the lid closed
// is a thermal risk, and it has to be readable at a glance in a crowded menu bar.
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
