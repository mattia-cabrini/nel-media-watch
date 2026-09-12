#!/bin/sh
# Copyright (c) 2026 Mattia Cabrini
# SPDX-License-Identifier: MIT

# ---------------------------------------------------------------------------
# install.sh -- install or update nel-media-watch (run as root).
#
# Installs the runtime binary (built by 'make build') and the default
# global configuration, creates the cache directory and conf.d/, asks
# for the duty cycle (TIME_UP, TIME_PAUSE -- written into the global
# configuration) and the daily execution time, and installs the crontab
# entry.  Installation ONLY: no analysis is run -- the first run happens
# at the scheduled time.
#
# Re-running it IS the update path: the binary is refreshed, an existing
# global configuration is kept (only its TIME_UP/TIME_PAUSE lines are
# rewritten, added if missing), the target configurations in conf.d/
# are not touched, and every prompt proposes the current value in "no
# change on empty" mode (reconfig style), so updating is just 'make
# install' plus four empty answers.  A machine still running the shell
# version of the tool is updated the same way: its scripts, its crontab
# entry and the state of its duty cycle are cleared here.
#
# The whole installation runs under the runtime's global lock (see
# hold_run_lock in common.sh): it refuses to start while a run is in
# progress, and no run can start while it is going on.
#
# Exit codes:
#     0   installed (or updated)
#     1   binary not built, input stream closed, broken global
#         configuration, or global configuration update failed
#     75  a run is in progress: nothing was touched, retry later
# ---------------------------------------------------------------------------

set -u

. "$(dirname -- "$0")/common.sh"

# Nothing below may overlap a run -- a binary replaced under a running
# program, a crontab entry swapped halfway -- and no run may start
# meanwhile: from here to the end the runtime's own lock is held.
hold_run_lock

# prompt_number <prompt> <maximum> <current>: ask for an integer in
# [0, maximum], left in NUMBER_ANSWER.  With a <current> value an empty
# answer keeps it ("no change on empty", reconfig style); without one,
# an answer is required.  Typed answers lose their leading zeros: sh
# arithmetic would read "010" as octal.
prompt_number() {
    while :; do
        if [ -n "$3" ]; then
            printf '%s (0-%d) [%s]: ' "$1" "$2" "$3"
        else
            printf '%s (0-%d): ' "$1" "$2"
        fi
        read -r NUMBER_ANSWER || exit 1
        if [ -z "$NUMBER_ANSWER" ]; then
            if [ -n "$3" ]; then
                NUMBER_ANSWER="$3"
                return
            fi
            echo "  A value is required."
            continue
        fi
        case "$NUMBER_ANSWER" in
            *[!0-9]*) ;;
            *)
                NUMBER_ANSWER=${NUMBER_ANSWER#"${NUMBER_ANSWER%%[!0]*}"}
                NUMBER_ANSWER=${NUMBER_ANSWER:-0}
                [ "$NUMBER_ANSWER" -le "$2" ] && return
                ;;
        esac
        echo "  Invalid value, try again."
    done
}

umask 022

if [ ! -f "$SOURCE_DIRECTORY/$BUILT_BINARY" ]; then
    echo "ERROR: $BUILT_BINARY not found: run 'make build' first" >&2
    exit 1
fi

echo "==> Installing $RUNTIME_BINARY into $LIBEXEC_DIRECTORY"
mkdir -p "$LIBEXEC_DIRECTORY" "$ETC_DIRECTORY" "$CONF_D_DIRECTORY"
install -m 0755 "$SOURCE_DIRECTORY/$BUILT_BINARY" "$INSTALLED_BINARY"

# The shell runtime this binary replaced: an update from that version
# would leave its scripts behind, next to a binary that never uses them,
# and the state of its duty cycle next to the lock file (it was
# nel-media-watch.duty, plus a .duty.d/ of markers).  Nothing of it is
# in use -- the lock held here guarantees no run of it is going on.
rm -f "$LIBEXEC_DIRECTORY"/*.sh
rm -rf "${LOCK_FILE%.lock}.duty" "${LOCK_FILE%.lock}.duty.d"

if [ ! -f "$GLOBAL_CONF" ]; then
    echo "==> Installing default global configuration $GLOBAL_CONF"
    install -m 0644 "$SOURCE_DIRECTORY/nel-media-watch.conf.default" "$GLOBAL_CONF"
else
    echo "==> Keeping existing global configuration $GLOBAL_CONF"
fi

CACHE_DIRECTORY=; TIME_UP=; TIME_PAUSE=
. "$GLOBAL_CONF"
if [ -z "$CACHE_DIRECTORY" ]; then
    echo "ERROR: CACHE_DIRECTORY is not set in $GLOBAL_CONF" >&2
    exit 1
fi
echo "==> Creating cache directory $CACHE_DIRECTORY"
mkdir -p "$CACHE_DIRECTORY"

# Duty cycle: on an update an empty answer keeps the current values.  A
# configuration written before the duty cycle existed has none, and a
# hand-edited value that is not a plain integer (the program would
# refuse it) is dropped: in both cases an answer is required.
case "$TIME_UP" in
    *[!0-9]*|0?*) TIME_UP= ;;
esac
case "$TIME_PAUSE" in
    *[!0-9]*|0?*) TIME_PAUSE= ;;
esac

echo "Duty cycle, to keep the disks' temperature under control: after TIME_UP"
echo "seconds of processing, pause for TIME_PAUSE seconds (0 disables it)."
prompt_number 'TIME_UP, seconds of processing between pauses' 86400 "$TIME_UP"
TIME_UP="$NUMBER_ANSWER"
prompt_number 'TIME_PAUSE, seconds of each pause' 86400 "$TIME_PAUSE"
TIME_PAUSE="$NUMBER_ANSWER"

# Lines already in the global configuration are replaced in place, the
# missing ones appended (with a comment when it predates the duty
# cycle); everything else is kept verbatim.  The new content is composed
# next to the file and renamed over it -- atomic -- only when it differs.
UPDATED_CONF=$(mktemp "$ETC_DIRECTORY/.nel-media-watch.conf.XXXXXX") || exit 1
awk -v time_up="$TIME_UP" -v time_pause="$TIME_PAUSE" '
    /^TIME_UP=/    { print "TIME_UP=" time_up;       has_up = 1;    next }
    /^TIME_PAUSE=/ { print "TIME_PAUSE=" time_pause; has_pause = 1; next }
    { print }
    END {
        if (!has_up && !has_pause) {
            print ""
            print "# Duty cycle, to keep the disk temperature under control: after"
            print "# TIME_UP seconds of processing, pause for TIME_PAUSE seconds."
            print "# Plain integers, in seconds; 0 in either one disables it."
        }
        if (!has_up)    print "TIME_UP=" time_up
        if (!has_pause) print "TIME_PAUSE=" time_pause
    }' "$GLOBAL_CONF" > "$UPDATED_CONF" || { rm -f "$UPDATED_CONF"; exit 1; }

if cmp -s "$UPDATED_CONF" "$GLOBAL_CONF"; then
    rm -f "$UPDATED_CONF"
else
    echo "==> Writing the duty cycle into $GLOBAL_CONF"
    chmod 0644 "$UPDATED_CONF" && mv "$UPDATED_CONF" "$GLOBAL_CONF" \
        || { rm -f "$UPDATED_CONF"; exit 1; }
fi

# Current schedule from the already-installed crontab entry, if any: on
# an update an empty answer keeps it (reconfig style).  Any line
# launching something under our libexec directory counts, so that the
# entry of the old shell runtime (exec.sh) is recognised and replaced.
CURRENT_MINUTE=; CURRENT_HOUR=
EXISTING_CRON_ENTRY=$(crontab -l 2>/dev/null | grep -F "$LIBEXEC_DIRECTORY/" | head -n 1)
if [ -n "$EXISTING_CRON_ENTRY" ]; then
    # Pathname expansion is off meanwhile: the '*' fields of the entry
    # must split into words, not into the file names of this directory.
    set -f
    set -- $EXISTING_CRON_ENTRY
    set +f
    if [ $# -ge 2 ]; then
        CURRENT_MINUTE="$1"
        CURRENT_HOUR="$2"
    fi
    # A hand-edited entry (e.g. '@daily') yields non-numeric fields:
    # fall back to asking from scratch.
    case "$CURRENT_MINUTE$CURRENT_HOUR" in
        *[!0-9]*) CURRENT_MINUTE=; CURRENT_HOUR= ;;
    esac
fi

prompt_number 'Hour of the daily run' 23 "$CURRENT_HOUR"
RUN_HOUR="$NUMBER_ANSWER"
prompt_number 'Minute of the daily run' 59 "$CURRENT_MINUTE"
RUN_MINUTE="$NUMBER_ANSWER"

# Idempotent crontab refresh: any previous line launching our runtime
# is filtered out before appending the new one.
echo "==> Installing the daily crontab entry ($RUN_HOUR:$RUN_MINUTE)"
{
    crontab -l 2>/dev/null | grep -v -F "$LIBEXEC_DIRECTORY/"
    printf '%s %s * * * %s run\n' "$RUN_MINUTE" "$RUN_HOUR" "$INSTALLED_BINARY"
} | crontab -

echo "==> Done. No analysis was run: the first run happens at the scheduled time."
