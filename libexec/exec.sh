#!/bin/sh
# Copyright (c) 2026 Mattia Cabrini
# SPDX-License-Identifier: MIT

# ---------------------------------------------------------------------------
# exec.sh -- orchestrator and cron entry point of nel-media-watch.
#
# Usage:   exec.sh [target-name]
#
# Without argument every target in conf.d/ is processed (the daily cron
# mode).  With an argument only conf.d/<target-name>.conf is processed:
# 'make run' uses this for manual, detached single-target runs.  Both
# modes take the SAME global lock, so runs can never overlap.
#
# Flow of a run:
#   0. take the global lock (lockf); if busy, log and leave at once;
#   1. load the global configuration (CACHE_DIRECTORY);
#   2. SNAPSHOT: per target, scan.sh lists and hashes the files
#      (find | grep FILTER | xxh128sum) into one "PH" file per target.
#      Lists and hashes are crystallised here and used unchanged for
#      the whole run;
#   3. per target: feed its PH lines, de-duplicated by hash, to
#      exec_check.sh (content never seen before is analysed and
#      cached), then let exec_dir.sh build the registry (pure cache
#      reads).  Content shared across targets is analysed only once:
#      the first batch caches it, the later ones hit the cache;
#   4. log the total duration.
#
# Identity model (NFS root-squash support): every operation that READS
# the media files -- the scan and the ffprobe/ffmpeg analysis -- runs as
# the target's RUN_AS user through run_as/su(1) (sudo is not installed).
# Everything that WRITES -- cache entries and registries -- always runs
# as root, no matter what RUN_AS says.
#
# Locking: lockf(1) ties the lock to a file descriptor, which the kernel
# releases when the process dies -- hard power loss included.  No stale
# locks can exist, so no cleanup logic exists either.
#
# Concurrency: by explicit project decision the heavy stages (hashing
# and the analysis batches) use (available cores - 1) parallel workers,
# superseding the strictly sequential rule of the original
# specification.  Each ffmpeg decode is single-threaded (see
# check_media_state.sh), so one core is always left free for the other
# services on the machine.
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

# cron(8) gives crontab entries a bare PATH without /usr/local, where
# xxh128sum, ffmpeg and ffprobe live: make them always reachable.
PATH="/usr/local/sbin:/usr/local/bin:$PATH"
export PATH

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

# Optional single-target mode (see Usage above).
ONLY_TARGET="${1:-}"
if [ -n "$ONLY_TARGET" ] && [ ! -f "$CONF_D_DIRECTORY/$ONLY_TARGET.conf" ]; then
    watch_log "Unknown target '$ONLY_TARGET': aborting"
    exit 1
fi

# Parallel workers = available cores - 1, never below 1.
CPU_COUNT=$(sysctl -n hw.ncpu 2>/dev/null || echo 2)
NEL_MEDIA_WATCH_JOBS="${NEL_MEDIA_WATCH_JOBS:-$((CPU_COUNT - 1))}"
[ "$NEL_MEDIA_WATCH_JOBS" -ge 1 ] || NEL_MEDIA_WATCH_JOBS=1
export NEL_MEDIA_WATCH_JOBS

# Scratch area holding the PH snapshot of this run.
WORK_DIRECTORY=$(mktemp -d "${TMPDIR:-/tmp}/nel-media-watch.XXXXXX") || exit 1
trap 'rm -rf "$WORK_DIRECTORY"' EXIT

# --- 2. Snapshot: list and hash every target (as its RUN_AS user) ----------------

for LOCAL_CONF in "$CONF_D_DIRECTORY"/*.conf; do
    [ -e "$LOCAL_CONF" ] || continue
    TARGET_NAME=$(basename -- "$LOCAL_CONF" .conf)

    # In single-target mode every other configuration is skipped (and
    # phase 3 skips them too, since they get no PH file here).
    [ -z "$ONLY_TARGET" ] || [ "$TARGET_NAME" = "$ONLY_TARGET" ] || continue

    # Reset, then source: values cannot leak between targets.  RUN_AS
    # defaults to root for configurations written before it existed.
    TARGET_DIRECTORY=; FILTER=; CASE=; REGISTRY=; RUN_AS=
    . "$LOCAL_CONF"
    [ -n "$RUN_AS" ] || RUN_AS=root

    # CASE selects the grep flavour (kept as a single token on purpose).
    case "$CASE" in
        insensitive) GREP_FLAGS=-Ei ;;
        *)           GREP_FLAGS=-E  ;;
    esac

    # scan.sh takes its parameters from the environment so that the su
    # command string inside run_as stays constant (see helpers.sh).
    NEL_MEDIA_WATCH_SCAN_TARGET="$TARGET_DIRECTORY"
    NEL_MEDIA_WATCH_SCAN_FILTER="$FILTER"
    NEL_MEDIA_WATCH_SCAN_GREP_FLAGS="$GREP_FLAGS"
    export NEL_MEDIA_WATCH_SCAN_TARGET NEL_MEDIA_WATCH_SCAN_FILTER NEL_MEDIA_WATCH_SCAN_GREP_FLAGS

    # Target PH files are named "ph.<target>": the PH file stays owned
    # by root (the redirection happens here), only the scan runs as
    # RUN_AS.  The scan validates the target directory itself, with the
    # identity that actually reads it; on failure the PH file is removed
    # so phase 3 skips this target instead of emptying its registry.
    TARGET_PH_FILE="$WORK_DIRECTORY/ph.$TARGET_NAME"

    if ! run_as "$RUN_AS" "$SELF_DIRECTORY/scan.sh" > "$TARGET_PH_FILE"; then
        rm -f "$TARGET_PH_FILE"
        watch_log "Target '$TARGET_NAME': scan as '$RUN_AS' failed, target skipped"
        continue
    fi
done

# --- 3. Per target: analyse new content, then build the registry -----------------

for LOCAL_CONF in "$CONF_D_DIRECTORY"/*.conf; do
    [ -e "$LOCAL_CONF" ] || continue
    TARGET_NAME=$(basename -- "$LOCAL_CONF" .conf)
    TARGET_PH_FILE="$WORK_DIRECTORY/ph.$TARGET_NAME"

    # No PH file = target skipped during the snapshot.
    [ -f "$TARGET_PH_FILE" ] || continue

    TARGET_DIRECTORY=; FILTER=; CASE=; REGISTRY=; RUN_AS=
    . "$LOCAL_CONF"
    [ -n "$RUN_AS" ] || RUN_AS=root

    # check_media_state_c.sh runs the analyzer as this user (reads the
    # media), while itself staying root (writes the cache).
    NEL_MEDIA_WATCH_RUN_AS="$RUN_AS"
    export NEL_MEDIA_WATCH_RUN_AS

    # Analyse and cache every content of this target never seen before.
    # De-duplicated by hash (the first 32 characters) so the same
    # content, present under several paths, is not analysed twice
    # concurrently.  After this batch every hash of the target has a
    # cache entry: the registry pass below finds only cache hits.
    if [ -s "$TARGET_PH_FILE" ]; then
        awk '!seen[substr($0, 1, 32)]++' "$TARGET_PH_FILE" \
            | "$SELF_DIRECTORY/exec_check.sh" > /dev/null
    fi

    # Registry written as root, no matter what RUN_AS says.
    "$SELF_DIRECTORY/exec_dir.sh" "$TARGET_DIRECTORY" "$REGISTRY" < "$TARGET_PH_FILE" \
        || watch_log "Target '$TARGET_NAME': registry build failed"
done

# --- 4. Duration: <H>h<MM>'<SS>'' (hours unpadded, minutes/seconds two digits) -------

ELAPSED=$(($(date +%s) - START_EPOCH))
watch_log "$(printf "Execution finished in %dh%02d'%02d''" \
    $((ELAPSED / 3600)) $((ELAPSED % 3600 / 60)) $((ELAPSED % 60)))"

exit 0
