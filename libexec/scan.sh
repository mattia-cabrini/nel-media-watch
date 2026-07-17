#!/bin/sh
# Copyright (c) 2026 Mattia Cabrini
# SPDX-License-Identifier: MIT

# ---------------------------------------------------------------------------
# scan.sh -- list and hash the files of ONE target, emitting PH lines.
#
# Runs entirely under the identity of its invoker: exec.sh executes it
# through run_as (su(1), see helpers.sh) when the target configures a
# RUN_AS user, so NFS targets where root is squashed to nobody are read
# with the right identity.  That is also why the parameters arrive via
# ENVIRONMENT and not as arguments: the su command string stays constant
# and no data ever needs to be quoted into it.
#
# Environment (set by exec.sh):
#     NEL_MEDIA_WATCH_SCAN_TARGET      directory to scan, recursively
#     NEL_MEDIA_WATCH_SCAN_FILTER      extended regex selecting the files
#     NEL_MEDIA_WATCH_SCAN_GREP_FLAGS  -E (sensitive) or -Ei (insensitive)
#     NEL_MEDIA_WATCH_JOBS             parallel hashing workers
#
# Stdout: one PH line per file ("HASH/absolute/path", see helpers.sh).
#
# Exit codes:
#     0   scan completed (possibly with zero matching files)
#     1   missing parameters, or target directory not accessible
# ---------------------------------------------------------------------------

set -u

SELF_DIRECTORY=$(cd -- "$(dirname -- "$0")" && pwd) || exit 1
. "$SELF_DIRECTORY/helpers.sh"

TARGET="${NEL_MEDIA_WATCH_SCAN_TARGET:-}"
FILTER="${NEL_MEDIA_WATCH_SCAN_FILTER:-}"
GREP_FLAGS="${NEL_MEDIA_WATCH_SCAN_GREP_FLAGS:--E}"
JOBS="${NEL_MEDIA_WATCH_JOBS:-1}"

if [ -z "$TARGET" ] || [ -z "$FILTER" ]; then
    echo "$0: NEL_MEDIA_WATCH_SCAN_TARGET and NEL_MEDIA_WATCH_SCAN_FILTER must be set" >&2
    exit 1
fi

# Validated HERE, with the identity that actually reads the files: root
# may not even be able to see a directory that the RUN_AS user can.
if [ ! -d "$TARGET" ]; then
    echo "$0: '$TARGET' does not exist or is not a directory" >&2
    exit 1
fi

# Pipeline notes:
#   * find -type f: FILTER selects among files (a directory has no
#     content to hash);
#   * tr + xargs -0 keep paths with spaces intact;
#   * each worker sources helpers.sh (argument 1) and emits the PH line
#     of one file (argument 2).  Each line is one short write, hence
#     atomic even with parallel workers.  A file vanishing between find
#     and hash is simply dropped from the snapshot.
find "$TARGET" -type f \
    | LC_ALL=C grep $GREP_FLAGS -- "$FILTER" \
    | tr '\n' '\0' \
    | xargs -0 -n 1 -P "$JOBS" \
        sh -c '. "$1" || exit 1; ph_line "$2" || exit 0' \
        ph-worker "$SELF_DIRECTORY/helpers.sh"
