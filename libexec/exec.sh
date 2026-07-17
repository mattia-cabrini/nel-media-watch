#!/bin/sh
# Copyright (c) 2026 Mattia Cabrini
# SPDX-License-Identifier: MIT

# ---------------------------------------------------------------------------
# exec.sh -- orchestrator and cron entry point of nel-media-watch.
#
# Flow of a run:
#   0. take the global lock (lockf); if busy, log and leave at once;
#   1. load the global configuration (CACHE_DIRECTORY);
#   2. SNAPSHOT: per target, list the files (find | grep FILTER) and hash
#      each one with xxh128sum, producing one "PH" file per target plus a
#      general one with everything.  Lists and hashes are crystallised
#      here and used unchanged for the whole run;
#   3. GENERAL PASS: feed the general PH file, de-duplicated by hash, to
#      exec_check.sh -- every content never seen before is analysed and
#      cached in this single batch;
#   4. REGISTRIES: per target, exec_dir.sh builds the registry from the
#      target's PH lines on stdin (pure cache reads, nothing re-analysed);
#   5. log the total duration.
#
# The PH line format and the shared helpers live in helpers.sh.
#
# Locking: lockf(1) ties the lock to a file descriptor, which the kernel
# releases when the process dies -- hard power loss included.  No stale
# locks can exist, so no cleanup logic exists either.
#
# Concurrency: by explicit project decision the heavy stages (hashing and
# the general analysis batch) use (available cores - 1) parallel workers,
# superseding the strictly sequential rule of the original specification.
# Each ffmpeg decode is single-threaded (see check_media_state.sh), so
# one core is always left free for the other services on the machine.
#
# Paths are assumed not to contain newlines (the scan is line-oriented).
#
# Exit codes:
#     0   run completed
#     1   configuration or setup error
#     75  lock already held (EX_TEMPFAIL from lockf): run skipped
# ---------------------------------------------------------------------------

set -u

SELF_DIRECTORY=$(cd -- "$(dirname -- "$0")" && pwd) || exit 1
. "$SELF_DIRECTORY/helpers.sh"

# Overridable from the environment (handy for testing).
LOCK_FILE="${NEL_MEDIA_WATCH_LOCK:-/var/run/nel-media-watch.lock}"

# --- 0. Global lock ------------------------------------------------------------
# On first entry the script re-executes itself under lockf; the child
# sees the marker variable and skips this block.  '-t 0' = do not wait:
# when the lock is busy lockf exits 75 and this run is simply skipped.
# '-k' keeps the lock file around, avoiding unlink races between runs.

if [ -z "${NEL_MEDIA_WATCH_LOCK_HELD:-}" ]; then
    export NEL_MEDIA_WATCH_LOCK_HELD=1

    lockf -t 0 -k "$LOCK_FILE" "$0" "$@"
    STATUS=$?

    [ "$STATUS" -eq 75 ] \
        && watch_log "Execution aborted: another run is in progress"
    exit "$STATUS"
fi

START_EPOCH=$(date +%s)
watch_log "Execution started"

# --- 1. Global configuration -----------------------------------------------------

if [ ! -r "$NEL_MEDIA_WATCH_CONF" ]; then
    watch_log "Global configuration '$NEL_MEDIA_WATCH_CONF' unreadable: aborting"
    exit 1
fi

CACHE_DIRECTORY=
. "$NEL_MEDIA_WATCH_CONF"

# An empty CACHE_DIRECTORY would shard cache entries under '/': refuse.
if [ -z "$CACHE_DIRECTORY" ]; then
    watch_log "CACHE_DIRECTORY not set in '$NEL_MEDIA_WATCH_CONF': aborting"
    exit 1
fi

# Children read the cache location from the environment.
export CACHE_DIRECTORY
mkdir -p "$CACHE_DIRECTORY" || exit 1

# The local configurations live in conf.d/ next to the global file.
CONF_D_DIRECTORY=$(dirname -- "$NEL_MEDIA_WATCH_CONF")/conf.d

# Parallel workers = available cores - 1, never below 1.
CPU_COUNT=$(sysctl -n hw.ncpu 2>/dev/null || echo 2)
NEL_MEDIA_WATCH_JOBS="${NEL_MEDIA_WATCH_JOBS:-$((CPU_COUNT - 1))}"
[ "$NEL_MEDIA_WATCH_JOBS" -ge 1 ] || NEL_MEDIA_WATCH_JOBS=1
export NEL_MEDIA_WATCH_JOBS

# Scratch area holding the PH snapshot of this run.
WORK_DIRECTORY=$(mktemp -d "${TMPDIR:-/tmp}/nel-media-watch.XXXXXX") || exit 1
trap 'rm -rf "$WORK_DIRECTORY"' EXIT

# Target PH files are named "ph.<target>", so the general file can never
# collide with a target name.
GENERAL_PH_FILE="$WORK_DIRECTORY/general"
: > "$GENERAL_PH_FILE"

# --- 2. Snapshot: list and hash every target ---------------------------------------

for LOCAL_CONF in "$CONF_D_DIRECTORY"/*.conf; do
    [ -e "$LOCAL_CONF" ] || continue
    TARGET_NAME=$(basename -- "$LOCAL_CONF" .conf)

    # Reset, then source: values cannot leak between targets.
    TARGET_DIRECTORY=; FILTER=; CASE=; REGISTRY=
    . "$LOCAL_CONF"

    # A target that vanished is logged and skipped, never fatal.
    if [ ! -d "$TARGET_DIRECTORY" ]; then
        watch_log "Target '$TARGET_NAME': '$TARGET_DIRECTORY' is not a directory, target skipped"
        continue
    fi

    # CASE selects the grep flavour (kept as a single token on purpose).
    case "$CASE" in
        insensitive) GREP_FLAGS=-Ei ;;
        *)           GREP_FLAGS=-E  ;;
    esac

    # Pipeline notes:
    #   * find -type f: FILTER selects among files (a directory has no
    #     content to hash);
    #   * tr + xargs -0 keep paths with spaces intact;
    #   * each worker sources helpers.sh (argument 1) and emits the PH
    #     line of one file (argument 2).  Each line is one short write,
    #     hence atomic even with parallel workers.  A file vanishing
    #     between find and hash is simply dropped from the snapshot.
    TARGET_PH_FILE="$WORK_DIRECTORY/ph.$TARGET_NAME"

    find "$TARGET_DIRECTORY" -type f \
        | LC_ALL=C grep $GREP_FLAGS -- "$FILTER" \
        | tr '\n' '\0' \
        | xargs -0 -n 1 -P "$NEL_MEDIA_WATCH_JOBS" \
            sh -c '. "$1" || exit 1; ph_line "$2" || exit 0' \
            ph-worker "$SELF_DIRECTORY/helpers.sh" \
        > "$TARGET_PH_FILE"

    cat "$TARGET_PH_FILE" >> "$GENERAL_PH_FILE"
done

# --- 3. General pass: analyse and cache every new content ---------------------------
# De-duplicated by hash (the first 32 characters) so the same content,
# present under several paths, is analysed once.  After this batch every
# hash of the snapshot has a cache entry: step 4 finds only cache hits.

if [ -s "$GENERAL_PH_FILE" ]; then
    awk '!seen[substr($0, 1, 32)]++' "$GENERAL_PH_FILE" \
        | "$SELF_DIRECTORY/exec_check.sh" > /dev/null
fi

# --- 4. Per-target registries --------------------------------------------------------

for LOCAL_CONF in "$CONF_D_DIRECTORY"/*.conf; do
    [ -e "$LOCAL_CONF" ] || continue
    TARGET_NAME=$(basename -- "$LOCAL_CONF" .conf)
    TARGET_PH_FILE="$WORK_DIRECTORY/ph.$TARGET_NAME"

    # No PH file = target skipped during the snapshot.
    [ -f "$TARGET_PH_FILE" ] || continue

    TARGET_DIRECTORY=; FILTER=; CASE=; REGISTRY=
    . "$LOCAL_CONF"

    "$SELF_DIRECTORY/exec_dir.sh" "$TARGET_DIRECTORY" "$REGISTRY" < "$TARGET_PH_FILE" \
        || watch_log "Target '$TARGET_NAME': registry build failed"
done

# --- 5. Duration: <H>h<MM>'<SS>'' (hours unpadded, minutes/seconds two digits) -------

ELAPSED=$(($(date +%s) - START_EPOCH))
watch_log "$(printf "Execution finished in %dh%02d'%02d''" \
    $((ELAPSED / 3600)) $((ELAPSED % 3600 / 60)) $((ELAPSED % 60)))"

exit 0
