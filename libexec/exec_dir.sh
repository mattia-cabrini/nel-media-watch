#!/bin/sh
# Copyright (c) 2026 Mattia Cabrini
# SPDX-License-Identifier: MIT

# ---------------------------------------------------------------------------
# exec_dir.sh -- build (or refresh) the state REGISTRY of one target.
#
# Usage:   exec_dir.sh <target-directory> <registry-path> < ph-lines
#
# Reads the target's PH lines from STDIN.  For every line the state is
# read through check_media_state_c.sh -- always a cache hit at this
# stage, because exec.sh already ran the general batch over the whole
# snapshot: this pass only reads states and formats the registry.
#
# Registry format, one line per file (OK included):
#
#     <relative-path> <TAB> <STATE> <TAB> <xxh128>
#
# sorted by relative path with LC_ALL=C.  The deterministic order makes
# the byte-by-byte comparison below meaningful: identical bytes really
# means "nothing changed", so the registry is REWRITTEN ONLY WHEN ITS
# CONTENT DIFFERS -- and the replacement is atomic (see publish_file in
# helpers.sh), never in-place.
#
# Exit codes:
#     0   registry up to date (rewritten, or already identical)
#     1   usage error or write failure
# ---------------------------------------------------------------------------

set -u

SELF_DIRECTORY=$(cd -- "$(dirname -- "$0")" && pwd) || exit 1
. "$SELF_DIRECTORY/helpers.sh"

TARGET_DIRECTORY="${1:-}"
REGISTRY="${2:-}"

if [ -z "$TARGET_DIRECTORY" ] || [ -z "$REGISTRY" ]; then
    echo "usage: $0 <target-directory> <registry-path> < ph-lines" >&2
    exit 1
fi

TEMPORARY=$(mktemp "${TMPDIR:-/tmp}/nel-media-watch.reg.XXXXXX") || exit 1
trap 'rm -f "$TEMPORARY"' EXIT

# One registry line per PH line; the loop writes to stdout, which goes
# through the deterministic sort before touching the disk.  A malformed
# line, or one whose state cannot be determined (the child already
# reported the reason on stderr), is skipped rather than sinking the
# whole registry.
while IFS= read -r PH_LINE; do
    [ -n "$PH_LINE" ] || continue
    parse_ph_line "$PH_LINE" || continue

    # stdin of the child comes from /dev/null so nothing down the chain
    # can ever steal PH lines from this loop's own stdin.
    STATE=$("$SELF_DIRECTORY/check_media_state_c.sh" "$PH_LINE" < /dev/null) || continue

    # Relative path = absolute path minus the target prefix (and minus a
    # possible leftover leading slash).
    RELATIVE_PATH=${PH_PATH#"$TARGET_DIRECTORY"}
    RELATIVE_PATH=${RELATIVE_PATH#/}

    printf '%s\t%s\t%s\n' "$RELATIVE_PATH" "$STATE" "$PH_HASH"
done | LC_ALL=C sort > "$TEMPORARY"

# Identical content: leave the registry completely untouched.
if [ -f "$REGISTRY" ] && cmp -s "$TEMPORARY" "$REGISTRY"; then
    exit 0
fi

publish_file "$TEMPORARY" "$REGISTRY" || exit 1
exit 0
