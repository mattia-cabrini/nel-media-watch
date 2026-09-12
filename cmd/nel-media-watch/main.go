// Copyright (c) 2026 Mattia Cabrini
// SPDX-License-Identifier: MIT

// nel-media-watch -- periodic integrity surveillance of video files.
//
// Usage:
//
//	nel-media-watch run [target-name]
//	nel-media-watch walk <directory>
//
// 'run' is the cron entry point.  Without a target name every target in
// conf.d/ is processed, one after the other; with one, only that target
// is ('make run' uses this for manual, detached single-target runs).
// Both take the same global lock, so runs never overlap.
//
// 'walk' is an internal helper, not meant to be typed by hand: 'run'
// re-executes the program this way, under the target's RUN_AS identity,
// to list the files of a target with the credentials that can actually
// read them (see internal/media and internal/identity).
//
// Environment overrides (mainly for testing):
//
//	NEL_MEDIA_WATCH_CONF            global configuration path
//	NEL_MEDIA_WATCH_LOCK            lock file path
//	NEL_MEDIA_WATCH_JOBS            hashing runners (default: cores - 1)
//	NEL_MEDIA_WATCH_FFMPEG_THREADS  decoder threads (default: cores - 1)
//
// Exit codes:
//
//	0   run completed (or directory walked)
//	1   usage error, configuration or setup error, unknown target
//	75  lock already held (EX_TEMPFAIL): run skipped
package main

import (
	"fmt"
	"os"
	"runtime"
	"strconv"

	"nel-media-watch/internal/media"
	"nel-media-watch/internal/watch"
)

const (
	defaultConfPath = "/usr/local/etc/nel-media-watch/nel-media-watch.conf"
	defaultLockPath = "/var/run/nel-media-watch.lock"

	exitUsage = 1
)

func main() {
	extendPath()
	os.Exit(dispatch(os.Args[1:]))
}

// dispatch selects the subcommand and returns its exit code.  It is
// kept apart from main so that no code path calls os.Exit halfway
// through a run: that would skip every deferred cleanup up the stack,
// the release of the global lock included.
func dispatch(arguments []string) int {
	if len(arguments) == 0 {
		return usage()
	}
	switch arguments[0] {
	case "run":
		if len(arguments) > 2 {
			return usage()
		}
		only := ""
		if len(arguments) == 2 {
			only = arguments[1]
		}
		return watch.Run(settingsFromEnvironment(only))
	case "walk":
		if len(arguments) != 2 {
			return usage()
		}
		return media.WalkMain(arguments[1], os.Stdout, os.Stderr)
	}
	return usage()
}

func usage() int {
	fmt.Fprintln(os.Stderr, "usage: nel-media-watch run [target-name] | walk <directory>")
	return exitUsage
}

// extendPath makes the external tools reachable.  cron(8) gives crontab
// entries a bare PATH without /usr/local, which is where xxh128sum,
// ffmpeg and ffprobe live on FreeBSD.  Child processes inherit the
// extended value, so the tools resolve the same everywhere.
func extendPath() {
	os.Setenv("PATH", "/usr/local/sbin:/usr/local/bin:"+os.Getenv("PATH"))
}

// settingsFromEnvironment assembles the run settings: the defaults,
// overridden by the environment where a variable is set and sane.
func settingsFromEnvironment(only string) watch.Settings {
	return watch.Settings{
		ConfPath:       environmentString("NEL_MEDIA_WATCH_CONF", defaultConfPath),
		LockPath:       environmentString("NEL_MEDIA_WATCH_LOCK", defaultLockPath),
		Runners:        environmentPositiveInt("NEL_MEDIA_WATCH_JOBS", coresButOne()),
		DecoderThreads: environmentPositiveInt("NEL_MEDIA_WATCH_FFMPEG_THREADS", coresButOne()),
		Only:           only,
	}
}

// coresButOne is the project's parallelism rule: one core always stays
// free for the other services on the machine, never fewer than one
// worker.
func coresButOne() int {
	return max(1, runtime.NumCPU()-1)
}

func environmentString(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

// environmentPositiveInt reads an integer override.  Anything that is
// not a positive number -- unset, empty, garbage, zero -- yields the
// fallback: an override can tune the run, never disable a stage.
func environmentPositiveInt(name string, fallback int) int {
	value, err := strconv.Atoi(os.Getenv(name))
	if err != nil || value < 1 {
		return fallback
	}
	return value
}
