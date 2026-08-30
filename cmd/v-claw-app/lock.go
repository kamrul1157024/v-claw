//go:build darwin

package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"

	"github.com/kamrul1157024/v-claw/internal/state"
)

// helperName is shipped beside the app binary inside the bundle. It is resolved
// relative to the running executable and never through PATH.
const helperName = "v-claw-lock"

// lockController runs the virtual lock as a separate process.
//
// The window is deeply native and Go has no good binding for it. A helper also fails
// open by construction: kill it and the desktop returns, which is what the design
// requires. The virtual lock is a privacy screen, not a security boundary.
type lockController struct {
	mu       sync.Mutex
	cmd      *exec.Cmd
	unlocked chan struct{}
}

func newLockController() *lockController {
	return &lockController{unlocked: make(chan struct{}, 1)}
}

type lockRequest struct {
	Policy  string `json:"policy"`
	Message string `json:"message"`
}

func (l *lockController) engage(policy state.Policy, message string) error {
	l.mu.Lock()
	defer l.mu.Unlock()

	if l.cmd != nil {
		return nil
	}

	path, err := helperPath()
	if err != nil {
		return err
	}

	cmd := exec.Command(path)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	cmd.Stderr = os.Stderr

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("cannot start lock helper: %w", err)
	}

	req, _ := json.Marshal(lockRequest{Policy: string(policy), Message: message})
	if _, err := fmt.Fprintf(stdin, "lock %s\n", req); err != nil {
		_ = cmd.Process.Kill()
		return err
	}

	l.cmd = cmd
	go l.wait(cmd, stdout)
	return nil
}

// wait reports the helper finishing, however it finished. A crash is treated the same
// as a clean unlock, because a locked screen with no process behind it must not leave
// the machine appearing locked.
func (l *lockController) wait(cmd *exec.Cmd, stdout interface{ Read([]byte) (int, error) }) {
	sc := bufio.NewScanner(stdout)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if strings.HasPrefix(line, "error") {
			log.Printf("lock helper: %s", line)
		}
	}
	_ = cmd.Wait()

	l.mu.Lock()
	l.cmd = nil
	l.mu.Unlock()

	select {
	case l.unlocked <- struct{}{}:
	default:
	}
}

func (l *lockController) close() {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.cmd != nil && l.cmd.Process != nil {
		_ = l.cmd.Process.Kill()
	}
}

func helperPath() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	p := filepath.Join(filepath.Dir(exe), helperName)
	if _, err := os.Stat(p); err != nil {
		return "", fmt.Errorf("lock helper missing at %s: run `make build`", p)
	}
	return p, nil
}
