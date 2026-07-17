# Copyright (c) 2026 Mattia Cabrini
# SPDX-License-Identifier: MIT

# -----------------------------------------------------------------------------
# Makefile for nel-media-watch -- thin dispatcher.
#
# All the actual logic lives in setup/*.sh (plain POSIX sh, shared
# helpers in setup/common.sh); the runtime scripts live in libexec/.
#
# Run the targets as root: they write under $(PREFIX) and edit root's
# crontab.  PREFIX (default /usr/local) is forwarded to the scripts
# through the environment.  The scripts are invoked via 'sh' so the
# repository files do not need the executable bit.
# -----------------------------------------------------------------------------

PREFIX ?= /usr/local

.PHONY: help install config unconfig reconfig run uninstall

help:
	@echo "nel-media-watch -- periodic video integrity surveillance"
	@echo ""
	@echo "Targets (run as root):"
	@echo "  make install    install or update: scripts, global configuration, cache"
	@echo "                  directory and the daily crontab entry; on re-install empty"
	@echo "                  answers keep the current schedule (no analysis is run)"
	@echo "  make config     add a target configuration (conf.d/<name>.conf)"
	@echo "  make unconfig   list the target configurations and delete one by index"
	@echo "                  (the file is kept as a timestamped .conf.bak backup)"
	@echo "  make reconfig   edit a target configuration ('no change on empty')"
	@echo "  make run        launch a detached run of one target configuration, via"
	@echo "                  daemon(8): it completes even if this shell terminates"
	@echo "  make uninstall  back up the crontab, then remove the cron entry and the"
	@echo "                  scripts (configs/cache/registries kept)"
	@echo ""
	@echo "Variables: PREFIX=$(PREFIX)"

install:
	@PREFIX="$(PREFIX)" sh setup/install.sh

config:
	@PREFIX="$(PREFIX)" sh setup/config.sh

unconfig:
	@PREFIX="$(PREFIX)" sh setup/unconfig.sh

reconfig:
	@PREFIX="$(PREFIX)" sh setup/reconfig.sh

run:
	@PREFIX="$(PREFIX)" sh setup/run.sh

uninstall:
	@PREFIX="$(PREFIX)" sh setup/uninstall.sh
