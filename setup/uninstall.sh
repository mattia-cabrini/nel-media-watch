#!/bin/sh
# Copyright (c) 2026 Mattia Cabrini
# SPDX-License-Identifier: MIT

# ---------------------------------------------------------------------------
# uninstall.sh -- remove nel-media-watch (run as root).
#
# Backs up the whole current crontab to a timestamped file (its location
# is printed), then removes the crontab entry and the installed runtime
# scripts.  Configurations, cache and registries are deliberately left
# in place.
#
# Exit codes:
#     0   uninstalled
#     1   crontab backup could not be written
# ---------------------------------------------------------------------------

set -u

. "$(dirname -- "$0")/common.sh"

# Back up the crontab before touching it.  The backup lives next to the
# configurations, which uninstall never removes.
mkdir -p "$ETC_DIRECTORY"
CRONTAB_BACKUP="$ETC_DIRECTORY/$(timestamp)_crontab.bak"
: > "$CRONTAB_BACKUP" || exit 1

if crontab -l > "$CRONTAB_BACKUP" 2>/dev/null; then
    echo "==> Crontab backup written to $CRONTAB_BACKUP"
else
    rm -f "$CRONTAB_BACKUP"
    echo "==> No crontab present, nothing to back up"
fi

echo "==> Removing the crontab entry"
crontab -l 2>/dev/null | grep -v -F "$LIBEXEC_DIRECTORY/exec.sh" | crontab -

echo "==> Removing $LIBEXEC_DIRECTORY"
rm -rf "$LIBEXEC_DIRECTORY"

echo "==> Configurations, cache and registries were NOT touched."
