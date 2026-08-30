//go:build darwin

// Reports the lid state as v-claw sees it, and cross-checks against ioreg.
//
// The warning sound fires on an open-to-closed transition, so a misread here would
// either miss the warning entirely or fire it constantly.
package main

import (
	"fmt"
	"os/exec"
	"strings"

	"github.com/kamrul1157024/v-claw/internal/power"
)

func main() {
	closed, known := power.New().LidClosed()

	out, _ := exec.Command("/usr/sbin/ioreg", "-r", "-k", "AppleClamshellState").Output()
	var truth string
	for _, l := range strings.Split(string(out), "\n") {
		if strings.Contains(l, "AppleClamshellState") {
			truth = strings.TrimSpace(l)
			break
		}
	}

	fmt.Printf("v-claw: closed=%v known=%v\n", closed, known)
	fmt.Printf("ioreg:  %s\n", truth)

	agree := (strings.Contains(truth, "Yes") && closed) ||
		(strings.Contains(truth, "No") && !closed)
	fmt.Printf("agree:  %v\n", agree && known)
}
