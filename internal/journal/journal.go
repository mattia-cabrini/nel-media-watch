// Copyright (c) 2026 Mattia Cabrini
// SPDX-License-Identifier: MIT

// Package journal is the voice of a run.  Everything the tool has to
// say goes to syslog under one fixed tag, so that a single
//
//	grep nel-media-watch /var/log/messages
//
// tells the whole story of a run: start, pauses, new fingerprints,
// skipped targets and files, duration.  There is no other channel meant
// for a human, on purpose: the tool runs from cron, where stdout is
// nobody's screen.  Stderr remains what cron mails to root -- the
// walker's complaints about unreadable corners go there, and so do
// these lines as a last resort, should syslog itself be out of reach.
package journal

import (
	"fmt"
	"log/syslog"
	"os"
)

// tag is the syslog tag of every line the tool writes.
const tag = "nel-media-watch"

// Journal writes lines to syslog, or to stderr when syslog is out of
// reach.
type Journal struct {
	writer *syslog.Writer
}

// Open connects to the local syslog daemon.  When it cannot be reached
// the journal degrades to stderr instead of failing the run: a
// surveillance job that refused to run because it could not talk would
// leave the disks unwatched for the sake of a log line.
func Open() *Journal {
	// NOTICE is the priority logger(1) uses by default, and the one the
	// stock syslog.conf of FreeBSD routes to /var/log/messages; INFO
	// would be dropped there.
	writer, err := syslog.New(syslog.LOG_NOTICE|syslog.LOG_USER, tag)
	if err != nil {
		return &Journal{}
	}
	return &Journal{writer: writer}
}

// Printf records one line, formatted like fmt.Printf.
func (j *Journal) Printf(format string, arguments ...any) {
	line := fmt.Sprintf(format, arguments...)
	if j.writer != nil && j.writer.Notice(line) == nil {
		return
	}
	fmt.Fprintf(os.Stderr, "%s: %s\n", tag, line)
}

// Close releases the syslog connection.
func (j *Journal) Close() {
	if j.writer != nil {
		j.writer.Close()
	}
}
