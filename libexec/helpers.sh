# Copyright (c) 2026 Mattia Cabrini
# SPDX-License-Identifier: MIT

# ---------------------------------------------------------------------------
# helpers.sh -- shared helpers for the runtime scripts.
#
# Sourced (not executed) by the scripts in this directory; the callers
# run with 'set -u'.  Every function returns 0 on success and 1 on
# failure, and prints its result (when it has one) on stdout.
# ---------------------------------------------------------------------------

SYSLOG_TAG="nel-media-watch"

# Overridable from the environment (handy for testing).
NEL_MEDIA_WATCH_CONF="${NEL_MEDIA_WATCH_CONF:-/usr/local/etc/nel-media-watch/nel-media-watch.conf}"

# watch_log <message>: send one message to syslog with the tool's tag.
watch_log() {
    logger -t "$SYSLOG_TAG" "$@"
}

# hash_file <path>: print the xxh128 digest of the file content
# (32 lowercase hex characters).
hash_file() {
    _hash_output=$(xxh128sum "$1") || return 1
    printf '%s\n' "${_hash_output%% *}"
}

# ph_line <path>: print the PH line of the file -- its digest immediately
# followed by its absolute path ("HASH/absolute/path").  The path starts
# with '/', so plain concatenation yields the right format.
ph_line() {
    _digest=$(hash_file "$1") || return 1
    printf '%s%s\n' "$_digest" "$1"
}

# parse_ph_line <line>: split a PH line at its FIRST '/' into PH_HASH and
# PH_PATH.  Hex never contains '/', so the first '/' is unambiguously
# where the path begins.  Returns 1 on a line with no separator.
parse_ph_line() {
    case "$1" in
        */*) ;;
        *) return 1 ;;
    esac
    PH_HASH=${1%%/*}
    PH_PATH="/${1#*/}"
}

# shard_path <hash>: print the sharded cache path of a digest -- ten
# directory levels from its first ten characters (requires
# CACHE_DIRECTORY to be set), e.g.
#   9de3e55826... -> $CACHE_DIRECTORY/9/d/e/3/e/5/5/8/2/6/9de3e55826...
# (the sed expression appends a '/' after each character).
shard_path() {
    _shard=$(printf '%s\n' "$1" | cut -c 1-10 | sed 's|.|&/|g') || return 1
    printf '%s\n' "$CACHE_DIRECTORY/$_shard$1"
}

# load_cache_directory: make sure CACHE_DIRECTORY is set.  exec.sh
# exports it for the whole run; standalone invocations fall back to the
# global configuration.  Refuses an empty value: cache entries would end
# up sharded under '/'.
load_cache_directory() {
    if [ -z "${CACHE_DIRECTORY:-}" ]; then
        . "$NEL_MEDIA_WATCH_CONF"
    fi
    if [ -z "${CACHE_DIRECTORY:-}" ]; then
        echo "CACHE_DIRECTORY is not set" >&2
        return 1
    fi
}

# publish_file <temporary> <destination>: atomically install a file
# composed in /tmp at its final place, never writing in-place.  /tmp is
# usually a different filesystem, so the file is first copied NEXT TO
# the destination and only then renamed (a rename is atomic within one
# filesystem).  The temporary file is left for the caller's trap.
publish_file() {
    _destination_directory=$(dirname -- "$2")
    _staged="$_destination_directory/.stage.$(basename -- "$2").$$"

    mkdir -p "$_destination_directory" || return 1
    cp "$1" "$_staged" || return 1
    mv "$_staged" "$2" || { rm -f "$_staged"; return 1; }
}
