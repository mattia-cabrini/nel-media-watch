// Copyright (c) 2026 Mattia Cabrini
// SPDX-License-Identifier: MIT

// Package watch is the orchestration: the run as a whole, and the three
// stages every target goes through, one target after the other.
//
// Flow of a run:
//
//  0. take the global lock; if busy, log and leave at once;
//  1. load the global configuration (cache directory, duty cycle);
//  2. for every target, in name order:
//     SNAPSHOT  list its files and hash them -- a coordinator hands the
//     paths to N hashing runners (coordinator.go); lists and
//     hashes are frozen here for the rest of the target;
//     ANALYSE   for every content never seen before, the coordinator
//     itself launches ffprobe/ffmpeg, one file at a time, and
//     caches the verdict (target.go);
//     REGISTRY  write the state of every file, atomically and only
//     if it changed (registry.go);
//  3. log the total duration.
//
// Targets are strictly sequential.  The cache is global, so a content
// shared by two targets is analysed by the first and found in the cache
// by the second.  The duty cycle is one for the whole run as well: its
// clock does not restart between targets.
//
// Identity model (NFS root-squash support): every operation that READS
// the media runs as the target's RUN_AS user, through child processes
// carrying its credentials (see package identity).  Everything that
// WRITES -- cache entries and registries -- runs as root, no matter
// what RUN_AS says.
package watch

import (
	"errors"
	"fmt"
	"time"

	"nel-media-watch/internal/cache"
	"nel-media-watch/internal/config"
	"nel-media-watch/internal/duty"
	"nel-media-watch/internal/journal"
)

// Settings is what the command line and the environment decide.
type Settings struct {
	ConfPath string
	LockPath string
	// Runners is how many files are hashed at once.
	Runners int
	// DecoderThreads is what each ffmpeg gets; decodes run one at a
	// time, so this is the whole decoding footprint.
	DecoderThreads int
	// Only names the single target to process; empty means all of
	// them.
	Only string
}

// Exit codes of a run.
const (
	exitOK       = 0
	exitFailure  = 1
	exitTempFail = 75 // EX_TEMPFAIL: the lock is held by another run
)

// Run is the whole job, from the lock to the final duration line.  It
// returns the process exit code rather than exiting, so that every
// deferred release happens.
func Run(settings Settings) int {
	logbook := journal.Open()
	defer logbook.Close()

	held, err := acquire(settings.LockPath)
	if errors.Is(err, errBusy) {
		logbook.Printf("Execution aborted: another run is in progress")
		return exitTempFail
	}
	if err != nil {
		logbook.Printf("Lock '%s': %v: aborting", settings.LockPath, err)
		return exitFailure
	}
	defer held.release()

	started := time.Now()
	logbook.Printf("Execution started")

	global, err := config.LoadGlobal(settings.ConfPath)
	if err != nil {
		logbook.Printf("Global configuration: %v: aborting", err)
		return exitFailure
	}
	store := cache.New(global, logbook)
	if err := store.Prepare(); err != nil {
		logbook.Printf("Cache directory '%s': %v: aborting", global.CacheDirectory, err)
		return exitFailure
	}

	files, err := config.TargetFiles(config.ConfDir(settings.ConfPath))
	if err != nil {
		logbook.Printf("Target configurations: %v: aborting", err)
		return exitFailure
	}
	if settings.Only != "" {
		files = selectOnly(files, settings.Only)
		if len(files) == 0 {
			logbook.Printf("Unknown target '%s': aborting", settings.Only)
			return exitFailure
		}
	}

	current := &run{
		settings: settings,
		store:    store,
		cycle:    duty.New(global.TimeUp, global.TimePause, logbook),
		journal:  logbook,
	}
	for _, file := range files {
		current.processTarget(file)
	}

	logbook.Printf("Execution finished in %s", formatDuration(time.Since(started)))
	return exitOK
}

// selectOnly keeps the configuration file of the named target, if any.
func selectOnly(files []string, name string) []string {
	for _, file := range files {
		if config.TargetName(file) == name {
			return []string{file}
		}
	}
	return nil
}

// formatDuration renders <H>h<MM>'<SS>'' -- hours unpadded, minutes and
// seconds two digits -- the format the final log line has always had.
func formatDuration(elapsed time.Duration) string {
	seconds := int(elapsed / time.Second)
	return fmt.Sprintf("%dh%02d'%02d''", seconds/3600, seconds%3600/60, seconds%60)
}
