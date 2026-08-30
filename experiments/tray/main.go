//go:build darwin

// Probe: does systray render a template icon and the menu shape v-claw needs?
// Exits on its own after 8s so it cannot be left running.
//
//	go run ./experiments/tray
package main

import (
	"fmt"
	"time"

	"fyne.io/systray"
)

// A 16x16 1-bit PNG, solid square. Placeholder for the claw template icon.
var square = []byte{
	0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
	0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x10,
	0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0xf3, 0xff, 0x61, 0x00, 0x00, 0x00,
	0x27, 0x49, 0x44, 0x41, 0x54, 0x38, 0x8d, 0x63, 0x64, 0x60, 0x18, 0x05,
	0xa3, 0x60, 0x14, 0x8c, 0x02, 0x08, 0x00, 0x00, 0x04, 0x10, 0x00, 0x01,
	0x85, 0x3f, 0xaa, 0x2e, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44,
	0xae, 0x42, 0x60, 0x82,
}

func main() { systray.Run(onReady, func() { fmt.Println("exited cleanly") }) }

func onReady() {
	systray.SetTemplateIcon(square, square)
	systray.SetTooltip("v-claw probe")

	status := systray.AddMenuItem("Status: AC Power - awake (full)", "")
	status.Disable() // the non-clickable honesty line
	systray.AddSeparator()

	off := systray.AddMenuItemCheckbox("Off", "", false)
	always := systray.AddMenuItemCheckbox("Always awake", "", false)
	auto := systray.AddMenuItemCheckbox("Auto (on AC)", "", true)
	systray.AddSeparator()

	timed := systray.AddMenuItem("Awake for", "")
	timed.AddSubMenuItem("15 min", "")
	timed.AddSubMenuItem("1 hour", "")

	lock := systray.AddMenuItem("Virtual lock", "")
	lock.AddSubMenuItemCheckbox("Enabled", "", true)
	lock.AddSubMenuItemCheckbox("Any key unlocks", "", true)

	fmt.Println("tray up: template icon, disabled status line, radio group, submenus")
	fmt.Println("check your menu bar. auto-quits in 8s.")

	go func() {
		deadline := time.After(8 * time.Second)
		for {
			select {
			case <-off.ClickedCh:
				fmt.Println("click: off")
			case <-always.ClickedCh:
				fmt.Println("click: always")
			case <-auto.ClickedCh:
				fmt.Println("click: auto")
			case <-deadline:
				systray.Quit()
				return
			}
		}
	}()
}
