// Copyright (c) 2026 Mattia Cabrini
// SPDX-License-Identifier: MIT

// Package duty implements the duty cycle that keeps the disks'
// temperature under control: after TIME_UP of processing, the program
// rests for TIME_PAUSE.
//
// The cycle belongs to the coordinator, the single goroutine that hands
// out work.  It looks at the cycle BETWEEN units of work, never inside
// one (a file being hashed or decoded is never interrupted), and only
// when nothing is in flight: during the snapshot it first waits for
// every runner to finish its file.  So when a pause starts the disks
// are really idle, and the pause is measured from that moment.
//
// The length of a pause is proportional to the processing that earned
// it:
//
//	TIME_PAUSE * processing / TIME_UP
//
// where processing is the time since the previous pause ended, measured
// once everything has stopped.  Normally that is just over TIME_UP and
// the pause is about TIME_PAUSE; when a single file kept a disk busy
// for, say, three times TIME_UP, the processing is three times TIME_UP
// and so is the pause.  The ratio of rest to work is therefore the one
// the configuration says, however uneven the files are.
package duty

import (
	"time"

	"nel-media-watch/internal/journal"
)

// Cycle is the duty cycle of one run.
type Cycle struct {
	up        time.Duration
	pause     time.Duration
	resumedAt time.Time
	journal   *journal.Journal
}

// New starts a cycle: the first work window opens now.  Either duration
// being zero disables it, and every method becomes a no-op.
func New(up, pause time.Duration, journal *journal.Journal) *Cycle {
	return &Cycle{up: up, pause: pause, resumedAt: time.Now(), journal: journal}
}

func (c *Cycle) enabled() bool {
	return c.up > 0 && c.pause > 0
}

// Due tells whether the current work window is over.  The caller then
// stops handing out work, waits for what is in flight, and calls Rest.
func (c *Cycle) Due() bool {
	return c.enabled() && time.Since(c.resumedAt) >= c.up
}

// Rest takes the pause the processing so far has earned, logs it and
// opens the next work window.  It is meant to follow Due, with nothing
// in flight; should it be called earlier, the pause is still never
// shorter than TIME_PAUSE.
func (c *Cycle) Rest() {
	if !c.enabled() {
		return
	}
	processing := time.Since(c.resumedAt)
	if processing < c.up {
		processing = c.up
	}
	length := time.Duration(float64(c.pause) * float64(processing) / float64(c.up))

	c.journal.Printf("Duty cycle: pausing for %ds after %ds of processing",
		wholeSeconds(length), wholeSeconds(processing))
	time.Sleep(length)
	c.resumedAt = time.Now()
}

func wholeSeconds(duration time.Duration) int {
	return int(duration.Round(time.Second) / time.Second)
}
