//go:build darwin

package main

import (
	"context"
	"log"
	"os/exec"
	"time"
)

// warnLidClosed plays an audible warning that the machine is still running.
//
// Two short tones rather than one. A single system sound is indistinguishable from any
// other notification, and this one has to be recognised through a closed lid, often
// already inside a bag.
//
// afplay rather than the UI helper: the helper starts lazily and may not be running,
// and this is the one moment where a missing warning matters most.
func warnLidClosed() {
	const sound = "/System/Library/Sounds/Funk.aiff"

	for i := 0; i < 2; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		err := exec.CommandContext(ctx, "/usr/bin/afplay", sound).Run()
		cancel()
		if err != nil {
			log.Printf("could not play the lid warning: %v", err)
			return
		}
		time.Sleep(250 * time.Millisecond)
	}
}
