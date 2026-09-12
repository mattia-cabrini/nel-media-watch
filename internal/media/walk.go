// Copyright (c) 2026 Mattia Cabrini
// SPDX-License-Identifier: MIT

package media

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"

	"nel-media-watch/internal/identity"
)

// maximumPathBytes bounds one path on the wire: well above PATH_MAX,
// so that only a corrupted stream can hit it.
const maximumPathBytes = 64 * 1024

/* ----------------------------------------------------------------------------
 * The consumer side: listing a target from the coordinator
 * ---------------------------------------------------------------------------- */

// Listing streams the regular files of a directory tree.
type Listing struct {
	// Paths yields one absolute path per regular file, in lexical order
	// within each directory (the order WalkDir yields), and is closed
	// when the walk is over.
	Paths <-chan string

	command *exec.Cmd
	readErr error
}

// List starts walking a directory tree under the given identity.  The
// walk runs in a child process -- this same program, re-executed with
// the 'walk' subcommand -- because that is the only way to read the
// directories as RUN_AS (see package identity).  Paths travel
// NUL-terminated, so a file name containing a newline cannot split in
// two.
//
// Consume Paths to the end, then call Wait: a non-nil error means the
// walk did not complete -- the directory is missing, or not accessible
// as RUN_AS -- and the listing must not be trusted as a snapshot.
func List(directory string, as identity.Identity) (*Listing, error) {
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	command := exec.Command(executable, "walk", directory)
	as.Apply(command)
	// Whatever the walker complains about (an unreadable corner of the
	// tree) goes where cron's mail would carry it, as before.
	command.Stderr = os.Stderr
	output, err := command.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := command.Start(); err != nil {
		return nil, err
	}

	paths := make(chan string)
	listing := &Listing{Paths: paths, command: command}
	go func() {
		defer close(paths)
		scanner := bufio.NewScanner(output)
		scanner.Buffer(make([]byte, 0, 4096), maximumPathBytes)
		scanner.Split(scanNulTerminated)
		for scanner.Scan() {
			paths <- scanner.Text()
		}
		// A scanner that gave up (a token too long) must not leave the
		// child blocked on a full pipe: whatever is left is consumed.
		listing.readErr = scanner.Err()
		io.Copy(io.Discard, output)
	}()
	return listing, nil
}

// Wait reaps the walker.  It must be called once Paths is closed: the
// pipe is only fully read by then, and reaping earlier would close it
// under the reader.
func (l *Listing) Wait() error {
	if err := l.command.Wait(); err != nil {
		return err
	}
	return l.readErr
}

// scanNulTerminated is the bufio.SplitFunc for NUL-terminated records.
// A tail without its terminator can only be the end of a walker that
// died mid-write: it is dropped, and the walker's exit status tells the
// rest.
func scanNulTerminated(data []byte, atEOF bool) (advance int, token []byte, err error) {
	if index := bytes.IndexByte(data, 0); index >= 0 {
		return index + 1, data[:index], nil
	}
	if atEOF {
		return len(data), nil, nil
	}
	return 0, nil, nil
}

/* ----------------------------------------------------------------------------
 * The producer side: the 'walk' subcommand
 * ---------------------------------------------------------------------------- */

// WalkMain is the body of the 'walk' subcommand: it prints the absolute
// path of every regular file under the directory, NUL-terminated.  It
// runs with whatever identity the parent gave it, and that is the
// point: this is the process that can see the files.
//
// A subdirectory that cannot be read is reported and skipped -- one
// unreadable corner must not sink the snapshot of a whole target -- but
// a root directory that is missing, not a directory or not readable
// fails the walk: that is a broken target, not a corner, and an empty
// listing would empty its registry.  Symbolic links below the root are
// not followed, like find(1) without -L: a link to a file is not a
// file.  The root itself is resolved, see below.
func WalkMain(directory string, output io.Writer, diagnostics io.Writer) int {
	// The trailing separator matters.  WalkDir looks at its root with
	// Lstat, so a TARGET_DIRECTORY that is a symbolic link to a
	// directory would be "not a directory": zero files, exit 0, and an
	// emptied registry.  With the separator the kernel resolves the
	// link, exactly as os.Stat does below, and the paths emitted still
	// start with the directory as configured.
	root := filepath.Clean(directory) + string(filepath.Separator)
	info, err := os.Stat(root)
	if err != nil || !info.IsDir() {
		fmt.Fprintf(diagnostics, "walk: %s: not an accessible directory\n", directory)
		return 1
	}

	writer := bufio.NewWriter(output)
	walkErr := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			if path == root {
				return err
			}
			fmt.Fprintf(diagnostics, "walk: %v\n", err)
			return nil
		}
		if entry.Type().IsRegular() {
			writer.WriteString(path)
			writer.WriteByte(0)
		}
		return nil
	})
	if walkErr != nil {
		fmt.Fprintf(diagnostics, "walk: %v\n", walkErr)
		return 1
	}
	if err := writer.Flush(); err != nil {
		return 1
	}
	return 0
}
