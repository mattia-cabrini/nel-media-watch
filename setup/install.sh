#!/bin/sh
# Copyright (c) 2026 Mattia Cabrini
# SPDX-License-Identifier: MIT

# ---------------------------------------------------------------------------
# install.sh -- install or update nel-media-watch (run as root).
#
# Installs the runtime scripts and the default global configuration,
# creates the cache directory and conf.d/, asks for the daily execution
# time and installs the crontab entry.  Installation ONLY: no analysis
# is run -- the first run happens at the scheduled time.
#
# Re-running it IS the update path: scripts are refreshed, an existing
# global configuration is kept, and the schedule prompts propose the
# current crontab values in "no change on empty" mode (reconfig style),
# so updating is just 'make install' plus two empty answers.
#
# Exit codes:
#     0   installed (or updated)
#     1   input stream closed, or broken global configuration
# ---------------------------------------------------------------------------

set -u

. "$(dirname -- "$0")/common.sh"

# Repo layout: setup/ and libexec/ are siblings of the repository root.
SOURCE_DIRECTORY=$(cd -- "$(dirname -- "$0")/.." && pwd) || exit 1

# prompt_number <prompt> <maximum> <current>: ask for an integer in
# [0, maximum], left in NUMBER_ANSWER.  With a <current> value an empty
# answer keeps it ("no change on empty", reconfig style); without one,
# an answer is required.
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
            *) [ "$NUMBER_ANSWER" -le "$2" ] && return ;;
        esac
        echo "  Invalid value, try again."
    done
}

umask 022

echo "==> Installing scripts into $LIBEXEC_DIRECTORY"
mkdir -p "$LIBEXEC_DIRECTORY" "$ETC_DIRECTORY" "$CONF_D_DIRECTORY"
for SCRIPT_NAME in $RUNTIME_SCRIPTS; do
    install -m 0755 "$SOURCE_DIRECTORY/libexec/$SCRIPT_NAME" "$LIBEXEC_DIRECTORY/$SCRIPT_NAME"
done

if [ ! -f "$GLOBAL_CONF" ]; then
    echo "==> Installing default global configuration $GLOBAL_CONF"
    install -m 0644 "$SOURCE_DIRECTORY/nel-media-watch.conf.default" "$GLOBAL_CONF"
else
    echo "==> Keeping existing global configuration $GLOBAL_CONF"
fi

CACHE_DIRECTORY=
. "$GLOBAL_CONF"
if [ -z "$CACHE_DIRECTORY" ]; then
    echo "ERROR: CACHE_DIRECTORY is not set in $GLOBAL_CONF" >&2
    exit 1
fi
echo "==> Creating cache directory $CACHE_DIRECTORY"
mkdir -p "$CACHE_DIRECTORY"

# Current schedule from the already-installed crontab entry, if any: on
# an update an empty answer keeps it (reconfig style).
CURRENT_MINUTE=; CURRENT_HOUR=
EXISTING_CRON_ENTRY=$(crontab -l 2>/dev/null | grep -F "$LIBEXEC_DIRECTORY/exec.sh" | head -n 1)
if [ -n "$EXISTING_CRON_ENTRY" ]; then
    set -- $EXISTING_CRON_ENTRY
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

# Idempotent crontab refresh: any previous line launching our exec.sh is
# filtered out before appending the new one.
echo "==> Installing the daily crontab entry ($RUN_HOUR:$RUN_MINUTE)"
{
    crontab -l 2>/dev/null | grep -v -F "$LIBEXEC_DIRECTORY/exec.sh"
    printf '%s %s * * * %s\n' "$RUN_MINUTE" "$RUN_HOUR" "$LIBEXEC_DIRECTORY/exec.sh"
} | crontab -

echo "==> Done. No analysis was run: the first run happens at the scheduled time."
