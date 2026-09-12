// Copyright (c) 2026 Mattia Cabrini
// SPDX-License-Identifier: MIT

// Package atomicfile writes files that are never seen half-written.
// Cache entries and registries go through it: a reader of either must
// find the previous content or the new one, never a mix and never an
// empty file.
package atomicfile

import (
	"os"
	"path/filepath"
)

// Write installs content at path atomically.  The content is composed
// in a staging file NEXT TO the destination -- a rename is atomic only
// within one filesystem, and /tmp is usually another one -- flushed to
// disk, and only then renamed over the destination.  The fsync before
// the rename is what makes a power loss harmless: the name never exists
// without its content, so a crash cannot leave an empty file behind.
//
// The staging file is removed on any failure; after a successful rename
// it no longer exists under its staging name, and the deferred removal
// simply finds nothing.
func Write(path string, content []byte, mode os.FileMode) error {
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return err
	}
	staging, err := os.CreateTemp(directory, ".stage."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	defer os.Remove(staging.Name())

	if err := fill(staging, content, mode); err != nil {
		return err
	}
	return os.Rename(staging.Name(), path)
}

// fill writes the content, forces it to disk, sets the final mode and
// closes the file, in this order; whatever fails, the file ends up
// closed.
func fill(file *os.File, content []byte, mode os.FileMode) error {
	defer file.Close()

	if _, err := file.Write(content); err != nil {
		return err
	}
	if err := file.Sync(); err != nil {
		return err
	}
	// CreateTemp opens the file with mode 0600: the destination's own
	// mode is applied here, once the content is complete.
	return file.Chmod(mode)
}
