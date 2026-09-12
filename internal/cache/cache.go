// Copyright (c) 2026 Mattia Cabrini
// SPDX-License-Identifier: MIT

// Package cache is the memory of the tool: the content-addressed store
// that lets the expensive full decode be paid AT MOST ONCE per distinct
// content, even when a file is renamed, moved or copied to another
// target.
//
// One entry per xxh128 digest, sharded over ten directory levels taken
// from its first ten characters, so that no directory ever holds more
// than sixteen children:
//
//	<CACHE_DIRECTORY>/9/d/e/3/e/5/5/8/2/6/9de3e55826ad412c3a9d9fd22da014fb
//
// An entry is a small sourceable snippet -- the format the shell
// version of this tool used, kept so that an existing cache stays valid
// and readable by a human with cat:
//
//	STATE="Degraded"
//	INTEGRITY="99.4"
//	REASON="3 decoder error line(s)"
//	# /absolute/path/of/the/first/file/with/this/content
//
// Entries are written once and never rewritten, with one exception: an
// entry that yields no state (emptied or filled with garbage, e.g. by a
// power loss on a filesystem that reordered the writes) is unusable.
// It is reported as a miss and replaced by the next analysis, instead
// of pinning that content out of every registry for ever.
//
// The functions here know the global configuration, so that a caller
// only ever says WHAT it wants to remember or recall, never WHERE or
// HOW.  Writes are atomic (see package atomicfile) and always happen as
// root, whatever RUN_AS the target has: the cache belongs to the tool,
// not to the users that read the media.
package cache

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"nel-media-watch/internal/atomicfile"
	"nel-media-watch/internal/config"
	"nel-media-watch/internal/journal"
	"nel-media-watch/internal/verdict"
)

const (
	// shardLevels is how many leading characters of a digest become
	// directory levels.
	shardLevels = 10
	// entryMode makes entries world-readable.  Nothing but root ever
	// reads or writes the cache; the mode simply keeps it inspectable
	// with cat by anybody, as the shell version left it.
	entryMode = 0o644
)

// Cache is the content cache of one global configuration.
type Cache struct {
	directory string
	journal   *journal.Journal
}

// New binds the cache to the global configuration.  Nothing is touched
// on disk until Prepare.
func New(global config.Global, journal *journal.Journal) *Cache {
	return &Cache{directory: global.CacheDirectory, journal: journal}
}

// Prepare makes sure the cache root exists.
func (c *Cache) Prepare() error {
	return os.MkdirAll(c.directory, 0o755)
}

// entryPath is where the entry of a digest lives: the root, one
// directory per leading character, then the digest itself.  A digest
// is the thirty-two characters media.Digest validated, well beyond the
// ten used here.
func (c *Cache) entryPath(digest string) string {
	elements := make([]string, 0, shardLevels+2)
	elements = append(elements, c.directory)
	for position := 0; position < shardLevels; position++ {
		elements = append(elements, digest[position:position+1])
	}
	elements = append(elements, digest)
	return filepath.Join(elements...)
}

// Lookup recalls the verdict of a content.  A missing entry is a plain
// miss; an unusable one is a miss as well, and is logged, since the
// analysis it triggers will replace it.  Only a failure to READ the
// entry is an error.
func (c *Cache) Lookup(digest string) (verdict.Verdict, bool, error) {
	file, err := os.Open(c.entryPath(digest))
	if errors.Is(err, fs.ErrNotExist) {
		return verdict.Verdict{}, false, nil
	}
	if err != nil {
		return verdict.Verdict{}, false, err
	}
	defer file.Close()

	result, usable := parseEntry(file)
	if !usable {
		c.journal.Printf("Unusable cache entry for xxh128 %s: re-analysing", digest)
		return verdict.Verdict{}, false, nil
	}
	return result, true, nil
}

// Store remembers the verdict of a content, along with the path of the
// file that produced it -- the first path ever seen with this content,
// kept as a comment for whoever reads the cache by hand.
func (c *Cache) Store(digest string, result verdict.Verdict, path string) error {
	return atomicfile.Write(c.entryPath(digest), formatEntry(result, path), entryMode)
}

// parseEntry reads an entry back.  The state is the one thing that has
// to be there and be valid; INTEGRITY and REASON are informational, and
// a damaged one must not cost a re-analysis.
func parseEntry(reader io.Reader) (verdict.Verdict, bool) {
	values, err := config.ParseAssignments(reader)
	if err != nil {
		return verdict.Verdict{}, false
	}
	state := verdict.State(values["STATE"])
	if !state.Known() {
		return verdict.Verdict{}, false
	}
	integrity, _ := strconv.ParseFloat(values["INTEGRITY"], 64)
	return verdict.Verdict{State: state, Integrity: integrity, Reason: values["REASON"]}, true
}

// formatEntry renders an entry in the sourceable format described in
// the package comment.
func formatEntry(result verdict.Verdict, path string) []byte {
	return fmt.Appendf(nil, "STATE=\"%s\"\nINTEGRITY=\"%.1f\"\nREASON=\"%s\"\n# %s\n",
		result.State, result.Integrity, quotable(result.Reason), singleLine(path))
}

// singleLine keeps a value from breaking the line structure of an
// entry: a newline would start a line the parser cannot read.  No path
// or reason is expected to contain one, but the file format must not
// depend on that.
func singleLine(text string) string {
	return strings.NewReplacer("\n", " ", "\r", " ").Replace(text)
}

// quotable additionally keeps a value inside its double quotes, which
// a double quote in the text would close early.
func quotable(text string) string {
	return strings.ReplaceAll(singleLine(text), "\"", "'")
}
