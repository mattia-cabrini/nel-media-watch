// Copyright (c) 2026 Mattia Cabrini
// SPDX-License-Identifier: MIT

// Package config reads the configuration files.
//
// They are written by the setup scripts (setup/*.sh, plain POSIX shell)
// and must stay sourceable by them, so their syntax is the one of shell
// assignments:
//
//	# a comment
//	CACHE_DIRECTORY="/var/db/nel-media-watch/cache"
//	TARGET_DIRECTORY='/media/videos'
//	TIME_UP=600
//
// Only this subset is understood -- one assignment per line, a value
// that is bare, single-quoted or double-quoted, no expansions, no
// escapes -- and it is exactly the subset the setup scripts produce.
//
// Two kinds of files exist.  The GLOBAL one (nel-media-watch.conf)
// holds what is common to the whole run: the cache directory and the
// duty cycle.  The LOCAL ones (conf.d/<name>.conf) describe one target
// each: adding a target is creating a file there, removing it is
// deleting that file.
package config

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

/* ----------------------------------------------------------------------------
 * Global configuration
 * ---------------------------------------------------------------------------- */

// Global is the configuration shared by every target of a run.
type Global struct {
	// CacheDirectory is the root of the content cache (see package
	// cache).
	CacheDirectory string
	// TimeUp and TimePause define the duty cycle (see package duty):
	// after TimeUp of processing the program rests for TimePause.
	// Either one being zero disables it.
	TimeUp    time.Duration
	TimePause time.Duration
}

// LoadGlobal reads and validates the global configuration file.
func LoadGlobal(path string) (Global, error) {
	values, err := parseFile(path)
	if err != nil {
		return Global{}, err
	}

	global := Global{CacheDirectory: values["CACHE_DIRECTORY"]}
	// An empty cache directory would shard the entries under '/':
	// refuse rather than guess.
	if global.CacheDirectory == "" {
		return Global{}, fmt.Errorf("%s: CACHE_DIRECTORY is not set", path)
	}
	if global.TimeUp, err = seconds(values, "TIME_UP"); err != nil {
		return Global{}, fmt.Errorf("%s: %w", path, err)
	}
	if global.TimePause, err = seconds(values, "TIME_PAUSE"); err != nil {
		return Global{}, fmt.Errorf("%s: %w", path, err)
	}
	return global, nil
}

// seconds reads a duration written as a plain number of seconds.  A
// missing key is zero -- configurations written before the duty cycle
// existed have none -- but a present, malformed one is an error: a run
// silently ignoring the duty cycle it was given would defeat its
// purpose.
func seconds(values map[string]string, key string) (time.Duration, error) {
	raw := values[key]
	if raw == "" {
		return 0, nil
	}
	amount, err := strconv.Atoi(raw)
	if err != nil || amount < 0 {
		return 0, fmt.Errorf("%s: %q is not a non-negative integer", key, raw)
	}
	return time.Duration(amount) * time.Second, nil
}

/* ----------------------------------------------------------------------------
 * Target configurations
 * ---------------------------------------------------------------------------- */

// Target is the configuration of one watched directory tree.
type Target struct {
	// Name is the configuration file name without its .conf suffix; it
	// is how the target is called in the log and on the command line.
	Name string
	// Directory is the absolute path of the tree to watch.
	Directory string
	// Pattern selects the files to watch, matched against their
	// absolute path: FILTER, case-insensitive when CASE says so.
	Pattern *regexp.Regexp
	// Registry is the absolute path of the file recording the state of
	// every watched file.
	Registry string
	// RunAs is the user that reads the media of this target (see
	// package identity); "root" when the configuration names none.
	RunAs string
}

// ConfDir is where the local configurations live: conf.d/ next to the
// global file.
func ConfDir(globalPath string) string {
	return filepath.Join(filepath.Dir(globalPath), "conf.d")
}

// TargetFiles lists the local configuration files, sorted by name --
// the order targets are processed in.  A missing conf.d/ is simply an
// empty list: no targets, nothing to do.
func TargetFiles(confDir string) ([]string, error) {
	entries, err := os.ReadDir(confDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}

	var files []string
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".conf") {
			continue
		}
		files = append(files, filepath.Join(confDir, entry.Name()))
	}
	return files, nil
}

// TargetName is the name of the target described by a configuration
// file.
func TargetName(file string) string {
	return strings.TrimSuffix(filepath.Base(file), ".conf")
}

// LoadTarget reads and validates one local configuration file.
func LoadTarget(path string) (Target, error) {
	values, err := parseFile(path)
	if err != nil {
		return Target{}, err
	}
	for _, key := range []string{"TARGET_DIRECTORY", "FILTER", "REGISTRY"} {
		if values[key] == "" {
			return Target{}, fmt.Errorf("%s: %s is not set", path, key)
		}
	}

	// FILTER is validated by the setup scripts with grep -E, and the
	// extended regular expressions one writes to pick file names --
	// '\.(mp4|mkv)$', '[[:digit:]]+' -- read the same in Go's syntax;
	// back-references are the one thing neither accepts.  The (?i) flag
	// is what grep -Ei used to provide.
	expression := values["FILTER"]
	switch values["CASE"] {
	case "insensitive":
		expression = "(?i)" + expression
	case "", "sensitive":
	default:
		return Target{}, fmt.Errorf("%s: CASE must be 'sensitive' or 'insensitive'", path)
	}
	pattern, err := regexp.Compile(expression)
	if err != nil {
		return Target{}, fmt.Errorf("%s: FILTER: %w", path, err)
	}

	target := Target{
		Name:      TargetName(path),
		Directory: values["TARGET_DIRECTORY"],
		Pattern:   pattern,
		Registry:  values["REGISTRY"],
		RunAs:     values["RUN_AS"],
	}
	// RUN_AS defaults to root for configurations written before it
	// existed.
	if target.RunAs == "" {
		target.RunAs = "root"
	}
	return target, nil
}

/* ----------------------------------------------------------------------------
 * Shell assignment parsing
 * ---------------------------------------------------------------------------- */

// parseFile reads a file of shell assignments.
func parseFile(path string) (map[string]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	values, err := ParseAssignments(file)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return values, nil
}

// ParseAssignments reads KEY=value lines into a map.  Blank lines and
// comments are skipped; a line that is anything else is an error, since
// a file this tool cannot read in full is a file it does not
// understand.  Later assignments of the same key win, as they would in
// the shell.
func ParseAssignments(reader io.Reader) (map[string]string, error) {
	values := make(map[string]string)
	scanner := bufio.NewScanner(reader)
	for number := 1; scanner.Scan(); number++ {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, raw, found := strings.Cut(line, "=")
		if !found || !namePattern.MatchString(key) {
			return nil, fmt.Errorf("line %d: not a KEY=value assignment", number)
		}
		value, err := unquote(raw)
		if err != nil {
			return nil, fmt.Errorf("line %d: %w", number, err)
		}
		values[key] = value
	}
	return values, scanner.Err()
}

// namePattern is what the shell accepts as a variable name.
var namePattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// unquote strips the shell quoting of a value.  A quoted value runs up
// to the matching quote, whatever follows (the setup scripts write
// nothing after it); a bare value ends at the first blank, so that a
// trailing comment does not become part of it.
func unquote(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" || raw[0] == '#' {
		return "", nil
	}
	quote := raw[0]
	if quote != '\'' && quote != '"' {
		return strings.Fields(raw)[0], nil
	}
	end := strings.IndexByte(raw[1:], quote)
	if end < 0 {
		return "", fmt.Errorf("unterminated quote")
	}
	return raw[1 : 1+end], nil
}
