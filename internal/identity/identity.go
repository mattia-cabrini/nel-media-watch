// Copyright (c) 2026 Mattia Cabrini
// SPDX-License-Identifier: MIT

// Package identity is how media reads get the right credentials.
//
// Every operation that READS the media -- listing the target, hashing,
// probing and decoding -- runs under the target's RUN_AS user, because
// on NFS targets exported with root squash the root user is mapped to
// nobody and could not open the files.  Everything that WRITES -- cache
// entries and registries -- always runs as root, whatever RUN_AS says.
//
// A Go process cannot change identity for a single goroutine, so the
// identity is applied to the child processes that do the reading
// (xxh128sum, ffprobe, ffmpeg, and the program itself re-executed to
// walk a directory): the kernel switches each of them to the user's
// uid, gid and supplementary groups right after the fork.  No su(1), no
// sudo, nothing quoted into a shell command line.
package identity

import (
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"strconv"
	"syscall"
)

// Identity is a user the media reads run as.
type Identity struct {
	name string
	// credential is nil for the program's own identity: nothing to
	// switch.
	credential *syscall.Credential
}

// Lookup resolves a RUN_AS user name.  "root" is the program's own
// identity (config.LoadTarget already turned an absent RUN_AS into
// it).  Any other name needs the program to be root, since only root
// can become somebody else.
func Lookup(name string) (Identity, error) {
	if name == "root" {
		return Identity{name: "root"}, nil
	}
	account, err := user.Lookup(name)
	if err != nil {
		return Identity{}, fmt.Errorf("unknown user '%s'", name)
	}
	if os.Geteuid() != 0 {
		return Identity{}, fmt.Errorf("reading media as '%s' requires root", name)
	}
	credential, err := credentialOf(account)
	if err != nil {
		return Identity{}, fmt.Errorf("user '%s': %w", name, err)
	}
	return Identity{name: name, credential: credential}, nil
}

// Name is the user name, for the log.
func (id Identity) Name() string {
	return id.name
}

// Apply makes a command run under this identity.  It is meant for a
// command fresh out of exec.Command, before it starts.
func (id Identity) Apply(command *exec.Cmd) {
	if id.credential == nil {
		return
	}
	command.SysProcAttr = &syscall.SysProcAttr{Credential: id.credential}
}

// credentialOf turns an account into what the kernel needs: numeric
// uid, gid and supplementary groups.  The supplementary groups matter
// on NFS, where a tree is often readable by a group rather than by its
// owner; should they fail to resolve, the primary group alone is still
// a valid identity, just a poorer one.
func credentialOf(account *user.User) (*syscall.Credential, error) {
	uid, err := parseID(account.Uid)
	if err != nil {
		return nil, err
	}
	gid, err := parseID(account.Gid)
	if err != nil {
		return nil, err
	}

	ids, err := account.GroupIds()
	if err != nil {
		ids = []string{account.Gid}
	}
	groups := make([]uint32, 0, len(ids))
	for _, id := range ids {
		group, err := parseID(id)
		if err != nil {
			return nil, err
		}
		groups = append(groups, group)
	}
	return &syscall.Credential{Uid: uid, Gid: gid, Groups: groups}, nil
}

func parseID(text string) (uint32, error) {
	id, err := strconv.ParseUint(text, 10, 32)
	if err != nil {
		return 0, fmt.Errorf("malformed id '%s'", text)
	}
	return uint32(id), nil
}
