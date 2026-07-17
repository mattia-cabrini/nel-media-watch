#!/bin/sh
# Copyright (c) 2026 Mattia Cabrini
# SPDX-License-Identifier: MIT

# ---------------------------------------------------------------------------
# run.sh -- launch a detached run of ONE target configuration (run as root).
#
# Lists the configurations, selects one by numeric index and starts the
# INSTALLED exec.sh on that target through daemon(8): the job is fully
# detached from this session, so it runs to completion even if the shell
# (or the SSH connection) terminates.  Progress goes to syslog as usual.
#
# The job takes the same global lock as the nightly cron run: if another
# run is already in progress it logs "Execution aborted" and exits.
#
# Exit codes:
#     0   job launched (or nothing to run)
#     1   input stream closed, tool not installed or outdated, or
#         daemon(8) failed
# ---------------------------------------------------------------------------

set -u

. "$(dirname -- "$0")/common.sh"

if [ ! -x "$LIBEXEC_DIRECTORY/exec.sh" ]; then
    echo "ERROR: $LIBEXEC_DIRECTORY/exec.sh not found: run 'make install' first" >&2
    exit 1
fi

# The detached job runs the INSTALLED runtime: refuse to launch it when
# it differs from the repository, otherwise the job would silently run
# outdated code.
SOURCE_DIRECTORY=$(cd -- "$(dirname -- "$0")/.." && pwd) || exit 1
for SCRIPT_NAME in $RUNTIME_SCRIPTS; do
    if ! cmp -s "$SOURCE_DIRECTORY/libexec/$SCRIPT_NAME" "$LIBEXEC_DIRECTORY/$SCRIPT_NAME"; then
        echo "ERROR: installed '$SCRIPT_NAME' differs from the repository: run 'make install' first" >&2
        exit 1
    fi
done

list_configurations
if [ "$CONFIGURATION_COUNT" -eq 0 ]; then
    echo "No configurations present in $CONF_D_DIRECTORY."
    exit 0
fi
select_configuration "run"

TARGET_NAME=$(basename -- "$SELECTED_CONFIGURATION" .conf)

# daemon(8) double-forks and detaches the job from this session;
# -c moves it to / (never keeps a mount point busy) and -f sends its
# stdio to /dev/null (everything of interest goes to syslog anyway).
daemon -c -f "$LIBEXEC_DIRECTORY/exec.sh" "$TARGET_NAME" || exit 1

echo "==> Detached run launched for target '$TARGET_NAME'."
echo "==> Follow it with: grep nel-media-watch /var/log/messages"
echo "==> (If another run is already in progress, the job logs an abort and exits.)"
