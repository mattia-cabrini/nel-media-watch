// Copyright (c) 2026 Mattia Cabrini
// SPDX-License-Identifier: MIT

package watch

import (
	"errors"
	"os"
	"syscall"
)

// errBusy reports a lock held by another run.
var errBusy = errors.New("another run is in progress")

// lock is the global run lock.  It is an flock(2) on a file, tied to a
// file descriptor the kernel releases when the process dies -- hard
// power loss included.  No stale lock can exist, so no cleanup logic
// exists either; the lock file itself stays around between runs.
type lock struct {
	file *os.File
}

// acquire takes the lock without waiting: a run that finds it busy is
// simply skipped, since the next scheduled one will come.
func acquire(path string) (*lock, error) {
	file, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o644)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		file.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, errBusy
		}
		return nil, err
	}
	return &lock{file: file}, nil
}

// release lets the next run in.  Closing the descriptor is what
// releases an flock.
func (l *lock) release() {
	l.file.Close()
}
