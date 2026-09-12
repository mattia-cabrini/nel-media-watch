// Copyright (c) 2026 Mattia Cabrini
// SPDX-License-Identifier: MIT

package watch

import (
	"sync"

	"nel-media-watch/internal/duty"
	"nel-media-watch/internal/media"
)

// stopToken is what a runner receives, in place of a path, when there
// is nothing left to do: the coordinator hands one to each runner once
// the last path is out, and a runner returns on it.  It cannot clash
// with a path -- runners only ever receive regular files, and "///" is
// not one.
const stopToken = "///"

// hashed is one file of a snapshot: where it is, and what its content
// is.
type hashed struct {
	path   string
	digest string
}

// hashing is what a runner reports back for one path.
type hashing struct {
	hashed
	err error
}

// coordinator drives the snapshot of one target.
//
// The shape is the classic one: N runners pull paths from a shared
// channel and push results on another; the coordinator feeds the first
// and drains the second.  Two details are the whole point of it:
//
//   - the coordinator is the ONLY goroutine that looks at the duty
//     cycle.  When a pause is due it stops feeding, waits until nothing
//     is in flight -- so that the pause really starts with every runner
//     idle -- and only then rests.  While it rests nobody is fed, and
//     the walker upstream stalls on its full pipe: the whole target
//     goes quiet;
//   - feeding and draining are one select, so that a runner blocked on
//     delivering a result can never deadlock a coordinator blocked on
//     delivering a path.
type coordinator struct {
	// runners is how many paths are hashed at once; never below one, or
	// nobody would ever take a path.
	runners int
	// digest hashes one file; the coordinator does not care how.
	digest func(path string) (string, error)
	// refused is told about every file the hasher ran on but turned
	// down, so that nothing leaves the registry unannounced.
	refused func(err error)
	// cycle is the duty cycle to honour.
	cycle *duty.Cycle
}

// hash digests every path of the stream and returns the snapshot, in
// completion order.  A file the hasher ran on but could not read --
// vanished between the listing and the hash, or unreadable as RUN_AS
// -- is left out, as it would have been from any snapshot taken a
// moment later, and reported through refused.  The error, when not
// nil, is a failure of the machinery itself: the hasher could not run
// at all.  The snapshot is then not to be trusted, since every file
// would be "left out".
func (c *coordinator) hash(paths <-chan string) ([]hashed, error) {
	jobs := make(chan string)
	results := make(chan hashing)
	var crew sync.WaitGroup
	for count := 0; count < c.runners; count++ {
		crew.Add(1)
		go c.runner(jobs, results, &crew)
	}

	var snapshot []hashed
	var failure error
	inflight := 0

	// collect takes one result in, telling a file the hasher turned
	// down (see media.Refusal) from a hasher that did not run.
	collect := func(result hashing) {
		inflight--
		switch {
		case result.err == nil:
			snapshot = append(snapshot, result.hashed)
		case media.Refusal(result.err):
			c.refused(result.err)
		case failure == nil:
			failure = result.err
		}
	}
	// hand delivers one job to whichever runner is free, collecting
	// results meanwhile so that busy runners can always unload.
	hand := func(job string) {
		for {
			select {
			case jobs <- job:
				return
			case result := <-results:
				collect(result)
			}
		}
	}

	for path := range paths {
		if c.cycle.Due() {
			// Nothing may be in flight when the pause starts: every
			// result still owed is collected first.
			for inflight > 0 {
				collect(<-results)
			}
			c.cycle.Rest()
		}
		hand(path)
		inflight++
	}
	// A runner takes the stop token only once its last result has been
	// delivered, and hand returns only once a runner has taken it: after
	// this loop nothing is in flight any more, and the crew is merely
	// reaped.
	for count := 0; count < c.runners; count++ {
		hand(stopToken)
	}
	crew.Wait()
	return snapshot, failure
}

// runner is one hashing worker: it takes a path, hashes it, reports,
// and goes back for more until it receives the stop token.
func (c *coordinator) runner(jobs <-chan string, results chan<- hashing, crew *sync.WaitGroup) {
	defer crew.Done()
	for {
		path := <-jobs
		if path == stopToken {
			return
		}
		digest, err := c.digest(path)
		results <- hashing{hashed: hashed{path: path, digest: digest}, err: err}
	}
}
