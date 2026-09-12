// Copyright (c) 2026 Mattia Cabrini
// SPDX-License-Identifier: MIT

// Package media is everything that touches the media files themselves:
// listing them, hashing their content, analysing their integrity.  All
// of it runs under the target's RUN_AS identity (see package identity)
// and none of it writes anything.
package media

import (
	"errors"
	"fmt"
	"os/exec"
	"regexp"
	"strings"

	"nel-media-watch/internal/identity"
)

// digestPattern is what an xxh128 digest looks like: thirty-two
// lowercase hexadecimal characters.
var digestPattern = regexp.MustCompile(`^[0-9a-f]{32}$`)

// Digest returns the xxh128 digest of the file content: the key of the
// content cache.
//
// The digest is computed by xxh128sum(1) rather than in-process, for
// two reasons.  The cache is keyed by these digests and its existing
// entries were produced by xxh128sum, so any implementation had better
// yield byte-identical digests, which the tool itself is the only one
// to guarantee.  And a child process can run under the RUN_AS identity,
// which a goroutine cannot.
//
// An error that is a Refusal means the tool ran and could not read the
// file (vanished, unreadable); any other error means it could not run.
func Digest(path string, as identity.Identity) (string, error) {
	command := exec.Command("xxh128sum", path)
	as.Apply(command)

	output, err := command.Output()
	if err != nil {
		return "", describeFailure(path, err)
	}
	// The output line is "<digest>  <path>".  Since 0.8.2 xxhsum escapes
	// a name containing '\', '\n' or '\r' the way md5sum does: the whole
	// line then starts with a backslash, which is no part of the digest.
	line := strings.TrimPrefix(string(output), "\\")
	digest, _, _ := strings.Cut(line, " ")
	if !digestPattern.MatchString(digest) {
		return "", fmt.Errorf("xxh128sum %s: unexpected output %q", path, output)
	}
	return digest, nil
}

// describeFailure wraps a failed run of xxh128sum.  A refusal keeps its
// *exec.ExitError -- that is what Refusal looks for -- and gains the
// tool's own words, which say why: "No such file or directory",
// "Permission denied".
func describeFailure(path string, err error) error {
	var refused *exec.ExitError
	if errors.As(err, &refused) && len(refused.Stderr) > 0 {
		err = fmt.Errorf("%w (%s)", err, strings.TrimSpace(string(refused.Stderr)))
	}
	return fmt.Errorf("xxh128sum %s: %w", path, err)
}
