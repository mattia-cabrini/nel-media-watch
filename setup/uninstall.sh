#!/bin/sh
# Copyright (c) 2026 Mattia Cabrini
# SPDX-License-Identifier: MIT

# ---------------------------------------------------------------------------
# uninstall.sh -- remove nel-media-watch (run as root).
#
# Backs up the whole current crontab to a timestamped file (its location
# is printed), then removes the crontab entry and the installed runtime
# binary.  Configurations, cache and registries are deliberately left
# in place.  Like the installation, it runs under the runtime's global
# lock (see hold_run_lock in common.sh): a run in progress is never
# pulled from under its feet.
#
# Exit codes:
#     0   uninstalled
#     1   crontab backup could not be written
#     75  a run is in progress: nothing was touched, retry later
# ---------------------------------------------------------------------------

set -u

. "$(dirname -- "$0")/common.sh"

hold_run_lock

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
crontab -l 2>/dev/null | grep -v -F "$LIBEXEC_DIRECTORY/" | crontab -

echo "==> Removing $LIBEXEC_DIRECTORY"
rm -rf "$LIBEXEC_DIRECTORY"

echo "==> Configurations, cache and registries were NOT touched."
