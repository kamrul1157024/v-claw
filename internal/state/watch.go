package state

import (
	"context"
	"path/filepath"
	"time"

	"github.com/fsnotify/fsnotify"
)

// Watch calls fn with the current valid state whenever the file changes, and at least
// once per tick.
//
// It watches the directory rather than the file, because Save renames a temp file into
// place and a file watch would follow the replaced inode. The tick is a safety net: a
// missed event would leave the daemon acting on stale state with nothing on screen to
// show it.
func Watch(ctx context.Context, path string, tick time.Duration, fn func(State, error)) error {
	w, err := fsnotify.NewWatcher()
	if err != nil {
		return err
	}
	defer w.Close()

	if err := w.Add(filepath.Dir(path)); err != nil {
		return err
	}

	emit := func() { fn(Load(path)) }
	emit()

	t := time.NewTicker(tick)
	defer t.Stop()

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case ev, ok := <-w.Events:
			if !ok {
				return nil
			}
			if filepath.Clean(ev.Name) == filepath.Clean(path) {
				emit()
			}
		case <-w.Errors:
			// A watcher error must not stop the loop. The ticker keeps the daemon
			// correct until the watcher recovers.
		case <-t.C:
			emit()
		}
	}
}
