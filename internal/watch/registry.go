// Copyright (c) 2026 Mattia Cabrini
// SPDX-License-Identifier: MIT

package watch

import (
	"bytes"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"nel-media-watch/internal/atomicfile"
	"nel-media-watch/internal/config"
	"nel-media-watch/internal/verdict"
)

// registryMode: readable by everyone, like the cache.
const registryMode = 0o644

// registryHasEntries tells whether the registry currently records any
// file at all -- the guard against emptying it on a scan that found
// nothing (see processTarget).
func registryHasEntries(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Size() > 0
}

// writeRegistry records the state of every file of the snapshot, one
// line per file, OK included:
//
//	<relative-path> <TAB> <STATE> <TAB> <xxh128>
//
// sorted bytewise (the order LC_ALL=C sort gives), so that the
// comparison with the current registry is meaningful: identical bytes
// really mean "nothing changed", and the registry is REWRITTEN ONLY
// WHEN ITS CONTENT DIFFERS -- atomically, never in place.
//
// A file whose content has no verdict -- it vanished before the
// analysis -- is left out rather than guessed at.
func writeRegistry(target config.Target, snapshot []hashed, verdicts map[string]verdict.Verdict) error {
	lines := make([]string, 0, len(snapshot))
	for _, file := range snapshot {
		result, known := verdicts[file.digest]
		if !known {
			continue
		}
		relative, err := filepath.Rel(target.Directory, file.path)
		if err != nil {
			return err
		}
		lines = append(lines, relative+"\t"+string(result.State)+"\t"+file.digest+"\n")
	}
	sort.Strings(lines)
	content := []byte(strings.Join(lines, ""))

	current, err := os.ReadFile(target.Registry)
	if err == nil && bytes.Equal(current, content) {
		return nil
	}
	return atomicfile.Write(target.Registry, content, registryMode)
}
