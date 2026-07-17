#!/bin/sh
# Copyright (c) 2026 Mattia Cabrini
# SPDX-License-Identifier: MIT

# ---------------------------------------------------------------------------
# check_media_state_c.sh -- cached state of ONE media file.
#
# Wrapper around check_media_state.sh going through the content cache, so
# the expensive full decode is paid at most once per distinct content.
#
# Usage:   check_media_state_c.sh 'HASH/absolute/path'
#
# The argument is one "PH" line (see helpers.sh).  The hash is computed
# once, upstream, by exec.sh: this script never re-hashes anything.
#
# Cache HIT  -> read STATE from the entry, print it, done (no analysis).
# Cache MISS -> analyse, create the cache entry atomically, log the new
#               fingerprint via syslog, print the state.
#
# A cache entry is an IMMUTABLE sourceable snippet:
#
#     STATE="OK|Degraded|Corrupted"
#     INTEGRITY="<percentage of the declared duration actually decoded>"
#     REASON="<why Corrupted/Degraded; empty when OK>"
#     # /absolute/path/of/the/first/file/with/this/content
#
# Stdout:  OK | Degraded | Corrupted
#
# Exit codes:
#     0   a state was determined and printed
#     1   usage, configuration or cache-write error (no state printed)
# ---------------------------------------------------------------------------

set -u

SELF_DIRECTORY=$(cd -- "$(dirname -- "$0")" && pwd) || exit 1
. "$SELF_DIRECTORY/helpers.sh"

# --- Argument: one PH line -----------------------------------------------------

parse_ph_line "${1:-}" || {
    echo "usage: $0 'HASH/absolute/path'" >&2
    exit 1
}

load_cache_directory || exit 1

CACHE_FILE=$(shard_path "$PH_HASH") || exit 1

# --- Cache HIT: the entry is a sourceable snippet that sets STATE ----------------

if [ -f "$CACHE_FILE" ]; then
    . "$CACHE_FILE"
    printf '%s\n' "$STATE"
    exit 0
fi

# --- Cache MISS: analyse, then publish the entry ---------------------------------

# The analyzer prints one line: STATE <TAB> INTEGRITY <TAB> REASON.
#
# It runs as the target's RUN_AS user (exported by exec.sh): on NFS
# targets root is squashed to nobody and could not read the file.  This
# script itself stays root, because the CACHE IS ALWAYS WRITTEN AS ROOT,
# no matter what RUN_AS says.
ANALYSIS=$(run_as "${NEL_MEDIA_WATCH_RUN_AS:-root}" \
    "$SELF_DIRECTORY/check_media_state.sh" "$PH_PATH") || exit 1

TAB=$(printf '\t')
STATE=${ANALYSIS%%"$TAB"*}
REST=${ANALYSIS#*"$TAB"}
INTEGRITY=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}

TEMPORARY=$(mktemp "${TMPDIR:-/tmp}/nel-media-watch.fp.XXXXXX") || exit 1
trap 'rm -f "$TEMPORARY"' EXIT

{
    printf 'STATE="%s"\n' "$STATE"
    printf 'INTEGRITY="%s"\n' "$INTEGRITY"
    printf 'REASON="%s"\n' "$REASON"
    printf '# %s\n' "$PH_PATH"
} > "$TEMPORARY"

publish_file "$TEMPORARY" "$CACHE_FILE" || exit 1

# Logged on cache miss only -- one line per new fingerprint, never on
# hits.  This single message also covers the alert for new
# DEGRADED/CORRUPTED content (no separate alert, it would be redundant).
STATE_UPPER=$(printf '%s' "$STATE" | tr '[:lower:]' '[:upper:]')
watch_log "New fingerprint in watch's cache for xxh128 $PH_HASH. State is $STATE_UPPER"

printf '%s\n' "$STATE"
exit 0
