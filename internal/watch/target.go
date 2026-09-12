// Copyright (c) 2026 Mattia Cabrini
// SPDX-License-Identifier: MIT

package watch

import (
	"fmt"
	"regexp"

	"nel-media-watch/internal/cache"
	"nel-media-watch/internal/config"
	"nel-media-watch/internal/duty"
	"nel-media-watch/internal/identity"
	"nel-media-watch/internal/journal"
	"nel-media-watch/internal/media"
	"nel-media-watch/internal/verdict"
)

// run holds what every target of one run shares.
type run struct {
	settings Settings
	store    *cache.Cache
	cycle    *duty.Cycle
	journal  *journal.Journal
}

// processTarget takes one target through its three stages.  Any failure
// of the machinery -- a configuration that does not load, a user that
// does not exist, a walk or a tool that cannot run, a cache that cannot
// be read or written -- is logged and the target skipped, its registry
// left untouched: a registry emptied or thinned by a breakdown would
// read as "all those files are gone", the one lie this tool must never
// tell.  Only a file the tools ran on and turned down leaves the
// registry, and it does so with a log line of its own.
func (r *run) processTarget(confFile string) {
	target, err := config.LoadTarget(confFile)
	if err != nil {
		r.journal.Printf("Target '%s': invalid configuration (%v), target skipped",
			config.TargetName(confFile), err)
		return
	}
	as, err := identity.Lookup(target.RunAs)
	if err != nil {
		r.journal.Printf("Target '%s': %v, target skipped", target.Name, err)
		return
	}

	snapshot, err := r.snapshot(target, as)
	if err != nil {
		r.journal.Printf("Target '%s': scan as '%s' failed (%v), target skipped",
			target.Name, as.Name(), err)
		return
	}
	// A scan that found nothing where the registry says there was
	// plenty is far more likely a mount that is not there, a link gone
	// stale or a filter that no longer matches than a tree really
	// emptied: the disappearance is not recorded.  A tree emptied on
	// purpose is acknowledged by deleting its registry by hand.
	if len(snapshot) == 0 && registryHasEntries(target.Registry) {
		r.journal.Printf("Target '%s': the scan found no file while the registry is not empty, target skipped",
			target.Name)
		return
	}
	verdicts, err := r.analyse(target, as, snapshot)
	if err != nil {
		r.journal.Printf("Target '%s': analysis failed (%v), target skipped", target.Name, err)
		return
	}
	if err := writeRegistry(target, snapshot, verdicts); err != nil {
		r.journal.Printf("Target '%s': registry build failed (%v)", target.Name, err)
	}
}

/* ----------------------------------------------------------------------------
 * Stage 1: snapshot
 * ---------------------------------------------------------------------------- */

// snapshot lists the files of the target and hashes the ones the filter
// selects.  Lists and digests are frozen here and used unchanged for
// the rest of the target's processing, so that the analysis and the
// registry describe one consistent moment.
func (r *run) snapshot(target config.Target, as identity.Identity) ([]hashed, error) {
	listing, err := media.List(target.Directory, as)
	if err != nil {
		return nil, err
	}

	hasher := coordinator{
		runners: r.settings.Runners,
		digest: func(path string) (string, error) {
			return media.Digest(path, as)
		},
		refused: func(err error) {
			r.journal.Printf("Target '%s': not hashed (%v), file left out of the registry",
				target.Name, err)
		},
		cycle: r.cycle,
	}
	files, hashErr := hasher.hash(selectMatching(listing.Paths, target.Pattern))
	// The listing is fully consumed by now, whatever the hashing did:
	// the walker can be reaped, and its verdict comes first -- a walk
	// that failed makes the whole listing untrustworthy.
	if err := listing.Wait(); err != nil {
		return nil, err
	}
	return files, hashErr
}

// selectMatching forwards the paths the filter accepts.  The filter is
// matched against the absolute path, as grep -E did on find's output.
func selectMatching(paths <-chan string, pattern *regexp.Regexp) <-chan string {
	selected := make(chan string)
	go func() {
		defer close(selected)
		for path := range paths {
			if pattern.MatchString(path) {
				selected <- path
			}
		}
	}()
	return selected
}

/* ----------------------------------------------------------------------------
 * Stage 2: analysis
 * ---------------------------------------------------------------------------- */

// analyse makes sure every distinct content of the snapshot has a
// verdict, and returns the verdicts by digest.  A content already in
// the cache costs a read; a content never seen before is analysed by
// the coordinator itself -- ffprobe, then a full ffmpeg decode -- one
// file at a time, pausing whenever the duty cycle says so, and its
// verdict is cached before anything else happens, so that a run
// interrupted halfway keeps what it paid for.
//
// The snapshot is de-duplicated by digest: the same content under
// several paths is analysed once, and a content whose analysis was
// refused (the file vanished meanwhile) is not retried on its other
// paths.  A refusal (see media.Refusal) costs that file its registry
// line, with a log line; anything else that goes wrong is a breakdown
// that would cost every file the same way, and is returned as an error
// instead.
func (r *run) analyse(target config.Target, as identity.Identity, snapshot []hashed) (map[string]verdict.Verdict, error) {
	analyzer := media.Analyzer{Threads: r.settings.DecoderThreads, As: as}
	verdicts := make(map[string]verdict.Verdict)
	attempted := make(map[string]bool)

	for _, file := range snapshot {
		if attempted[file.digest] {
			continue
		}
		attempted[file.digest] = true

		known, found, err := r.store.Lookup(file.digest)
		if err != nil {
			return nil, fmt.Errorf("cache lookup for xxh128 %s: %w", file.digest, err)
		}
		if found {
			verdicts[file.digest] = known
			continue
		}

		// The coordinator is the only worker here, and its last decode
		// is over: a pause due now starts with nothing in flight.
		if r.cycle.Due() {
			r.cycle.Rest()
		}
		result, err := analyzer.Analyze(file.path)
		if media.Refusal(err) {
			r.journal.Printf("Target '%s': '%s' not analysed (%v), file left out of the registry",
				target.Name, file.path, err)
			continue
		}
		if err != nil {
			return nil, err
		}
		if err := r.store.Store(file.digest, result, file.path); err != nil {
			return nil, fmt.Errorf("cache write for xxh128 %s: %w", file.digest, err)
		}
		// Logged on cache miss only -- one line per new fingerprint,
		// never on hits.  This single message also covers the alert for
		// new DEGRADED/CORRUPTED content: a separate one would be
		// redundant.
		r.journal.Printf("New fingerprint in watch's cache for xxh128 %s. State is %s",
			file.digest, result.State.Upper())
		verdicts[file.digest] = result
	}
	return verdicts, nil
}
