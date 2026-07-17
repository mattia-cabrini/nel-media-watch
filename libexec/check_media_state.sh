#!/bin/sh
# Copyright (c) 2026 Mattia Cabrini
# SPDX-License-Identifier: MIT

# ---------------------------------------------------------------------------
# check_media_state.sh -- FULL integrity analysis of ONE media file.
#
# The only script that actually decodes media; it knows nothing about the
# cache (that is check_media_state_c.sh's job).
#
# Usage:   check_media_state.sh /absolute/path/to/file
#
# Stdout, one line, tab-separated:
#
#     STATE <TAB> INTEGRITY <TAB> REASON
#
#     STATE      OK | Degraded | Corrupted
#     INTEGRITY  percentage of the declared duration actually decoded
#                ("0.0" when the decode could not even start)
#     REASON     why the file is Corrupted or Degraded; empty when OK
#
# Exit codes:
#     0   a state was determined and printed ("Corrupted" is a
#         SUCCESSFUL analysis of a broken file)
#     1   usage or internal error (no state printed)
#
# Method (specification, section 8):
#   8.1 pre-check with ffprobe (openability, duration, size);
#   8.2 full software decode of every frame (ffmpeg -f null -);
#   8.3 duration coverage against the container duration (anti-truncation);
#   8.4 classification.
#
# Forbidden by the specification: -xerror, -err_detect +explode, hardware
# acceleration, *_cuvid / *_v4l2m2m decoders, -c copy.
# ---------------------------------------------------------------------------

set -u

MINIMUM_SIZE_BYTES=102400        # below 100 KB it cannot be a sane clip
MINIMUM_DURATION_SECONDS=0.5     # shorter or absent duration => Corrupted
MINIMUM_COVERAGE_PERCENT=98      # decoded/declared duration threshold

# The batch runs (cores - 1) files in parallel (see exec.sh), so each
# single decode stays single-threaded: total footprint = cores - 1.
FFMPEG_DECODE_THREADS="${NEL_MEDIA_WATCH_FFMPEG_THREADS:-1}"

MEDIA_FILE="${1:-}"
if [ -z "$MEDIA_FILE" ]; then
    echo "usage: $0 /absolute/path/to/media-file" >&2
    exit 1
fi

# finish <state> <integrity> <reason>: print the analysis line and leave
# with "state determined".
finish() {
    printf '%s\t%s\t%s\n' "$1" "$2" "$3"
    exit 0
}

# --- 8.1  Pre-check ----------------------------------------------------------

# Vanished or unreadable = not openable = Corrupted.
[ -f "$MEDIA_FILE" ] && [ -r "$MEDIA_FILE" ] \
    || finish "Corrupted" "0.0" "file is missing or unreadable"

# Declared container duration; ffprobe failing to open it => Corrupted.
DURATION=$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$MEDIA_FILE" 2>/dev/null) \
    || finish "Corrupted" "0.0" "ffprobe cannot open the file"

# Float comparison delegated to awk (POSIX sh has integer math only).
# A missing duration ("" or "N/A") coerces to 0 and fails the check too.
awk -v d="$DURATION" -v m="$MINIMUM_DURATION_SECONDS" \
    'BEGIN { exit (d + 0 >= m) ? 0 : 1 }' \
    || finish "Corrupted" "0.0" \
        "declared duration '$DURATION' below minimum ${MINIMUM_DURATION_SECONDS}s"

SIZE_BYTES=$(wc -c < "$MEDIA_FILE" | tr -d '[:space:]')
[ "$SIZE_BYTES" -ge "$MINIMUM_SIZE_BYTES" ] \
    || finish "Corrupted" "0.0" "size $SIZE_BYTES bytes below minimum $MINIMUM_SIZE_BYTES"

# --- 8.2  Full decode ----------------------------------------------------------

ERROR_LOG=$(mktemp "${TMPDIR:-/tmp}/nel-media-watch.err.XXXXXX") || exit 1
PROGRESS_LOG=$(mktemp "${TMPDIR:-/tmp}/nel-media-watch.prg.XXXXXX") || { rm -f "$ERROR_LOG"; exit 1; }
trap 'rm -f "$ERROR_LOG" "$PROGRESS_LOG"' EXIT

# -f null -       decode every frame, discard the output;
# -map 0:v/0:a?   video always, audio if present -- the data/bin_data
#                 telemetry stream of dashcam .ts files is never mapped,
#                 so it cannot influence the verdict;
# -progress FILE  with -v error ffmpeg prints no stats, so the decoded
#                 duration for the coverage check is read from this
#                 machine-readable file (which also keeps ERROR_LOG
#                 free of non-error noise).
ffmpeg -nostdin -hide_banner -v error \
    -threads "$FFMPEG_DECODE_THREADS" \
    -err_detect +crccheck+bitstream+buffer \
    -progress "$PROGRESS_LOG" \
    -i "$MEDIA_FILE" -map "0:v" -map "0:a?" \
    -f null - 2> "$ERROR_LOG"
FFMPEG_STATUS=$?

# --- 8.3  Duration coverage -----------------------------------------------------

# Last out_time_us value = how far the decode actually got (microseconds).
DECODED_US=$(awk -F= \
    '$1 == "out_time_us" && $2 ~ /^[0-9]+$/ { t = $2 } END { print t + 0 }' \
    "$PROGRESS_LOG")

# us / 1e6 / duration * 100  ==  us / 10000 / duration
COVERAGE=$(awk -v us="$DECODED_US" -v d="$DURATION" \
    'BEGIN { printf "%.1f", (d + 0 > 0) ? us / 10000 / d : 0 }')

# Non-blank decoder error lines (grep -c prints the count either way).
ERROR_LINES=$(grep -c '[^[:space:]]' "$ERROR_LOG")

# --- 8.4  Classification ---------------------------------------------------------

# ffmpeg gave up before the end of the file.
[ "$FFMPEG_STATUS" -eq 0 ] \
    || finish "Corrupted" "$COVERAGE" "decode stopped before EOF (ffmpeg exit $FFMPEG_STATUS)"

# Decoded less than the declared duration: truncated => Corrupted, even
# with few errors.
awk -v c="$COVERAGE" -v m="$MINIMUM_COVERAGE_PERCENT" \
    'BEGIN { exit (c + 0 >= m) ? 0 : 1 }' \
    || finish "Corrupted" "$COVERAGE" "stops@${COVERAGE}%"

# Full coverage but decode errors along the way: playable yet damaged.
[ "$ERROR_LINES" -eq 0 ] \
    || finish "Degraded" "$COVERAGE" "$ERROR_LINES decoder error line(s)"

finish "OK" "$COVERAGE" ""
