# Copyright (c) 2026 Mattia Cabrini
# SPDX-License-Identifier: MIT

# -----------------------------------------------------------------------------
# Makefile for nel-media-watch -- thin dispatcher.
#
# The runtime is one Go program (cmd/nel-media-watch, packages under
# internal/): 'make build' compiles it into bin/.  Everything about
# installation and management lives in setup/*.sh (plain POSIX sh,
# shared helpers in setup/common.sh).
#
# Run the management targets as root: they write under $(PREFIX) and
# edit root's crontab.  PREFIX (default /usr/local) is forwarded to the
# scripts through the environment.  The scripts are invoked via 'sh' so
# the repository files do not need the executable bit.
# -----------------------------------------------------------------------------

PREFIX ?= /usr/local
GO ?= go
BINARY = bin/nel-media-watch

.PHONY: help build install config unconfig reconfig run uninstall clean

help:
	@echo "nel-media-watch -- periodic video integrity surveillance"
	@echo ""
	@echo "Targets:"
	@echo "  make build      compile the runtime into $(BINARY) (needs the Go toolchain)"
	@echo ""
	@echo "Targets (run as root):"
	@echo "  make install    build, then install or update: binary, global configuration"
	@echo "                  (duty cycle included), cache directory and the daily crontab"
	@echo "                  entry; on re-install empty answers keep the current duty"
	@echo "                  cycle and schedule (no analysis is run).  Holds the run"
	@echo "                  lock: refuses to start during a run, blocks runs meanwhile"
	@echo "  make config     add a target configuration (conf.d/<name>.conf)"
	@echo "  make unconfig   list the target configurations and delete one by index"
	@echo "                  (the file is kept as a timestamped .conf.bak backup)"
	@echo "  make reconfig   edit a target configuration ('no change on empty')"
	@echo "  make run        build, then launch a detached run of one target"
	@echo "                  configuration via daemon(8): it completes even if this"
	@echo "                  shell terminates"
	@echo "  make uninstall  back up the crontab, then remove the cron entry and the"
	@echo "                  binary (configs/cache/registries kept)"
	@echo "  make clean      remove the build output"
	@echo ""
	@echo "Variables: PREFIX=$(PREFIX) GO=$(GO)"

# -buildvcs=false: 'make install' runs as root inside a checkout that
# usually belongs to somebody else, where git refuses to report the
# status ("dubious ownership") and the build would fail for it.  With
# -trimpath it also keeps the binary identical for identical sources,
# which is what 'make run' compares.
build:
	@$(GO) build -trimpath -buildvcs=false -o $(BINARY) ./cmd/nel-media-watch

install: build
	@PREFIX="$(PREFIX)" sh setup/install.sh

config:
	@PREFIX="$(PREFIX)" sh setup/config.sh

unconfig:
	@PREFIX="$(PREFIX)" sh setup/unconfig.sh

reconfig:
	@PREFIX="$(PREFIX)" sh setup/reconfig.sh

run: build
	@PREFIX="$(PREFIX)" sh setup/run.sh

uninstall:
	@PREFIX="$(PREFIX)" sh setup/uninstall.sh

clean:
	@rm -rf bin
