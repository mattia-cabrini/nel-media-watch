// Copyright (c) 2026 Mattia Cabrini
// SPDX-License-Identifier: MIT

// Package verdict is the outcome of the integrity analysis of one media
// content: the vocabulary shared by the analyzer that produces it, the
// cache that remembers it and the registry that reports it.
package verdict

import "strings"

// State is the classification of a content.
type State string

const (
	// OK: full coverage, zero decoder errors.
	OK State = "OK"
	// Degraded: full coverage but at least one decoder error line --
	// playable, yet damaged.
	Degraded State = "Degraded"
	// Corrupted: not openable, too short or too small to be a sane
	// clip, decode aborted, or truncated.
	Corrupted State = "Corrupted"
)

// Known tells whether the state is one of the three the tool produces
// -- what a cache entry read back from disk has to prove before it is
// trusted.
func (s State) Known() bool {
	switch s {
	case OK, Degraded, Corrupted:
		return true
	}
	return false
}

// Upper is the state as the log lines spell it ("State is DEGRADED").
func (s State) Upper() string {
	return strings.ToUpper(string(s))
}

// Verdict is the full outcome of one analysis.
type Verdict struct {
	State State
	// Integrity is the percentage of the declared duration that was
	// actually decoded; 0 when the decode could not even start.
	Integrity float64
	// Reason says why the content is Corrupted or Degraded; empty when
	// OK.
	Reason string
}
