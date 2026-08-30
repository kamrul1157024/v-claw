//go:build darwin

package main

import (
	"context"
	"log"
	"os/exec"
	"time"
)

// WarnSounds is the closed set of choices. A name from the state file is untrusted
// input and must never reach a filesystem path unchecked.
var WarnSounds = []string{"Funk", "Basso", "Sosumi", "Submarine", "Hero", "Glass"}

const defaultWarnSound = "Funk"

func soundPath(name string) string {
	for _, s := range WarnSounds {
		if s == name {
			return "/System/Library/Sounds/" + s + ".aiff"
		}
	}
	return "/System/Library/Sounds/" + defaultWarnSound + ".aiff"
}

// warnLidClosed plays an audible warning that the machine is still running.
//
// Two short tones rather than one. A single system sound is indistinguishable from any
// other notification, and this one has to be recognised through a closed lid, often
// already inside a bag.
//
// afplay rather than the UI helper: the helper starts lazily and may not be running,
// and this is the one moment where a missing warning matters most.
//
// Preview uses this same function, so what you hear when testing is exactly what plays
// when it matters.
func warnLidClosed(sound string) {
	path := soundPath(sound)

	for i := 0; i < 2; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		err := exec.CommandContext(ctx, "/usr/bin/afplay", path).Run()
		cancel()
		if err != nil {
			log.Printf("could not play the lid warning: %v", err)
			return
		}
		time.Sleep(250 * time.Millisecond)
	}
}
