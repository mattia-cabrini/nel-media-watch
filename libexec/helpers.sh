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

# Shared state of the duty cycle (see duty_cycle below): one line, the
# epoch at which work resumes -- in the past while working, in the future
# while a pause is in progress.  exec.sh resets it at the start of every
# run (the global lock guarantees one run at a time).  Overridable from
# the environment (handy for testing).
NEL_MEDIA_WATCH_DUTY="${NEL_MEDIA_WATCH_DUTY:-/var/run/nel-media-watch.duty}"

# In-flight markers: one empty file per worker that is reading media
# right now, named after its PID.  This is what tells "every worker has
# stopped" from "one is still decoding" (see duty_working and
# duty_park).  Derived from the state file, so a test override moves
# both.
NEL_MEDIA_WATCH_DUTY_WORKERS="$NEL_MEDIA_WATCH_DUTY.d"

# Ceiling of a single pause, in seconds -- the same one the install
# prompts impose on TIME_PAUSE.  A daily run must never sleep longer
# than a day, whatever the state file says: during a scan that file
# belongs to the target's RUN_AS user, and root's workers read it too.
DUTY_MAXIMUM_PAUSE=86400

# watch_log <message>: send one message to syslog with the tool's tag.
watch_log() {
    logger -t "$SYSLOG_TAG" "$@"
}

# run_as <user> <script> [argument]: run one of this tool's sh scripts
# as the given user.  'root' runs it directly; anyone else goes through
# su(1) -- sudo is not installed on the host, and root needs no password
# to su.  This is how NFS targets are read: root is squashed to nobody
# there, the configured RUN_AS user is not.
#
# '-m' keeps the environment and uses the CALLER's shell, so RUN_AS
# users without a login shell work too.  The script path and the
# optional argument travel through the ENVIRONMENT: the su command
# string is constant, no data is ever quoted into it, and it parses the
# same whether root's shell is sh or csh.
run_as() {
    _user="$1"
    shift

    if [ "$_user" = "root" ]; then
        sh "$@"
        return
    fi

    NEL_MEDIA_WATCH_COMMAND="$1"
    NEL_MEDIA_WATCH_ARGUMENT="${2:-}"
    export NEL_MEDIA_WATCH_COMMAND NEL_MEDIA_WATCH_ARGUMENT
    su -m "$_user" -c 'sh "$NEL_MEDIA_WATCH_COMMAND" "$NEL_MEDIA_WATCH_ARGUMENT"'
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

# is_seconds <value>: succeed when the value is a plain non-negative
# decimal integer.  Leading zeros are refused: sh arithmetic would read
# "010" as octal.
is_seconds() {
    case "$1" in
        ''|*[!0-9]*|0?*) return 1 ;;
    esac
}

# duty_working: mark this worker as busy with one unit of media I/O.
# Called right before the work starts; duty_cycle clears the mark when
# the unit is over.  A worker killed in between leaves a mark whose PID
# is dead, and the readers below reap it.  A failure is not fatal: at
# worst a pause cannot tell that this worker is still reading.
#
# The test is the one duty_cycle makes, and must stay that way: a mark
# laid down here is dropped there, so a configuration that enables one
# and not the other would leak one mark per file.
duty_working() {
    [ "${NEL_MEDIA_WATCH_TIME_UP:-0}" -gt 0 ] \
        && [ "${NEL_MEDIA_WATCH_TIME_PAUSE:-0}" -gt 0 ] || return 0
    true 2>/dev/null > "$NEL_MEDIA_WATCH_DUTY_WORKERS/$$"
    return 0
}

# duty_stopped: drop this worker's mark, its unit being over.  Always
# called AFTER the shared end has been pushed, never before: a parked
# worker that sees this mark gone must already be able to read that
# push, or it would resume while this worker is about to park.
duty_stopped() {
    rm -f "$NEL_MEDIA_WATCH_DUTY_WORKERS/$$" 2>/dev/null
    return 0
}

# duty_others_working: succeed while another worker still has a unit in
# flight.  A mark whose PID answers no signal belongs to a worker that
# died and is unlinked on sight, so a crash cannot hold a pause open for
# ever.  PID reuse can only make the answer too conservative, which
# duty_park's deadline bounds.
duty_others_working() {
    for _duty_mark in "$NEL_MEDIA_WATCH_DUTY_WORKERS"/*; do
        [ -e "$_duty_mark" ] || continue

        _duty_pid=${_duty_mark##*/}
        case "$_duty_pid" in
            ''|*[!0-9]*|0?*) continue ;;
        esac
        [ "$_duty_pid" -ne $$ ] || continue

        if kill -0 "$_duty_pid" 2>/dev/null; then
            return 0
        fi
        rm -f "$_duty_mark" 2>/dev/null
    done
    return 1
}

# duty_pushed_end: raise _park_until to the shared end when a worker
# that stopped after us has pushed it further.  Succeeds only when it
# really moved, so duty_park can tell "someone extended the pause" from
# "the pause is over".
duty_pushed_end() {
    _park_next=
    read -r _park_next 2>/dev/null < "$NEL_MEDIA_WATCH_DUTY"
    is_seconds "$_park_next" && [ "$_park_next" -gt "$_park_until" ] || return 1
    _park_until="$_park_next"
}

# duty_park <epoch to wake at>: stay parked until the pause is really
# over.  Two things can hold it: a straggler stopping after us pushes
# the shared epoch forward (so the state is read again after every
# sleep), and a worker still reading keeps the countdown from counting
# at all -- the quiet time is only quiet once everybody has stopped, so
# the loop polls the in-flight marks while one is still going.  It never
# parks longer than DUTY_MAXIMUM_PAUSE in total, whatever the state and
# the marks say.
duty_park() {
    _park_until="$1"
    _park_deadline=$(($(date +%s) + DUTY_MAXIMUM_PAUSE))

    while :; do
        duty_pushed_end
        [ "$_park_until" -le "$_park_deadline" ] || _park_until="$_park_deadline"

        _park_now=$(date +%s)
        if [ "$_park_until" -gt "$_park_now" ]; then
            sleep $((_park_until - _park_now))
            continue
        fi

        # The countdown is over.  Leave only once nobody is reading any
        # more -- and read the end one last time before doing so: a
        # worker pushes it BEFORE dropping its mark, so a mark already
        # gone means its push is visible here too.
        if duty_others_working; then
            [ "$_park_now" -lt "$_park_deadline" ] || return 0
            sleep 1
            continue
        fi
        duty_pushed_end || return 0
    done
}

# duty_cycle <epoch the unit started at>: checkpoint of the duty cycle
# that keeps the disks' temperature under control, called by every
# worker right after one unit of media I/O (a file hashed by scan.sh, a
# file analysed by check_media_state_c.sh).  Always returns 0.
#
# Reads NEL_MEDIA_WATCH_TIME_UP, NEL_MEDIA_WATCH_TIME_PAUSE and
# NEL_MEDIA_WATCH_START: TIME_UP and TIME_PAUSE of the global
# configuration plus the epoch of the run, validated and exported by
# exec.sh right after it resets the state.  Either time 0 disables the
# duty cycle.  Outside a run they are unset, so it stays off: sourcing
# the configuration alone (load_cache_directory) never enables it
# against a state left by an old run.
#
# Once TIME_UP seconds have passed since work resumed, the worker that
# notices it opens a pause and logs it; every other worker joins it
# (silently) as soon as it finishes its own file.  A file in flight is
# never interrupted: the granularity is one file.
#
# THE PAUSE ONLY RUNS WITH EVERY WORKER STOPPED.  The workers run in
# parallel (xargs -P) and each joins the pause at a different moment --
# in the analysis stage a straggler can still be decoding minutes after
# the pause opened, hammering the very disk that is supposed to be
# cooling down.  Two mechanisms keep the quiet time honest:
#
#   * every worker, as it stops, pushes the end of the pause to its own
#     arrival + its own pause length, never backward (the latest end
#     wins), so the countdown restarts at every arrival;
#   * a worker still reading blocks the countdown outright: it marks
#     itself in flight for the whole unit (duty_working), and duty_park
#     refuses to leave while any mark is alive.  The push alone would
#     not do -- a decode lasting longer than the pause would outlive it
#     and the others would resume with that disk still busy.
#
# So the pause length is counted from the moment the LAST worker stops.
# Arrivals are bounded by the number of workers -- a parked worker holds
# its xargs slot, so no new file can start meanwhile -- and the whole
# park is capped at DUTY_MAXIMUM_PAUSE.
#
# The pause lasts TIME_PAUSE seconds, stretched proportionally only when
# THIS file kept a disk busy for longer than TIME_UP on its own -- e.g.
# a file whose hash alone took 3 x TIME_UP earns a 3 x TIME_PAUSE pause.
# The wall clock since the last pause is what OPENS the pause, but it
# never stretches it: it also counts cache hits, waiting and the gaps
# between targets, during which the disks are nearly idle.
#
# The state is shared, and during a scan it belongs to an unprivileged
# user: a value outside [run start, now + DUTY_MAXIMUM_PAUSE] is refused
# and the window restarted, and no pause may ever exceed that ceiling.
# Without both, a bogus state could put root's workers to sleep for
# years while they hold the global lock.
duty_cycle() {
    _time_up="${NEL_MEDIA_WATCH_TIME_UP:-0}"
    _time_pause="${NEL_MEDIA_WATCH_TIME_PAUSE:-0}"
    [ "$_time_up" -gt 0 ] && [ "$_time_pause" -gt 0 ] || return 0

    _started="${1:-}"
    _run_start="${NEL_MEDIA_WATCH_START:-0}"

    # Lock-free fast path, and the only exit that takes no lock: the
    # state is plausible, no pause is open and the work window is not
    # over -- by far the common case.  Anything else, joining an open
    # pause included, has to write the state and goes through the lock.
    # Only writers hold it, so this read may catch the file
    # half-rewritten: an implausible value falls through as well.
    _now=$(date +%s)
    _resume=
    read -r _resume 2>/dev/null < "$NEL_MEDIA_WATCH_DUTY"
    if is_seconds "$_resume" && [ "$_resume" -ge "$_run_start" ] \
        && [ "$_resume" -le $((_now + DUTY_MAXIMUM_PAUSE)) ] \
        && [ "$_now" -ge "$_resume" ] \
        && [ $((_now - _resume)) -lt "$_time_up" ]; then
        duty_stopped
        return 0
    fi

    # A pause is open, the work window is over, or the state is not
    # plausible: decide again on fresh data under lockf(1), so that
    # workers racing here do not open -- and log -- the same pause
    # twice, and so that two arrivals cannot push the end at once.  The
    # decision prints "start <seconds> <processing> <until>", "join
    # <until>", "blind <seconds>", "reset <refused state>" or nothing.
    # A lock not obtained within a minute skips this checkpoint.  '-k'
    # keeps the state file: lockf would otherwise unlink it.
    _decision=$(lockf -k -t 60 "$NEL_MEDIA_WATCH_DUTY" sh -c '
        state=$1 time_up=$2 time_pause=$3 run_start=$4 maximum=$5 started=$6
        now=$(date +%s)

        # write_state <epoch>: record the new state, and read it back to
        # be sure it landed -- a full filesystem truncates it to nothing
        # without necessarily failing the write.
        write_state() {
            printf "%s\n" "$1" 2>/dev/null > "$state" || return 1
            written=
            read -r written 2>/dev/null < "$state"
            [ "$written" = "$1" ]
        }

        resume=
        read -r resume < "$state"
        case "$resume" in
            ""|*[!0-9]*|0?*) resume=0 ;;
        esac

        # Refuse an implausible state instead of sleeping on it.
        if [ "$resume" -lt "$run_start" ] || [ "$resume" -gt $((now + maximum)) ]; then
            write_state "$now" && echo "reset $resume" || echo "blind $time_pause"
            exit 0
        fi

        # The pause this worker is entitled to now that it has stopped,
        # stretched on the time ITS file took, never on the wall clock.
        case "$started" in
            ""|*[!0-9]*|0?*) started=$now ;;
        esac
        unit=$((now - started))
        [ "$unit" -gt "$time_up" ] || unit=$time_up
        seconds=$((time_pause * unit / time_up))
        [ "$seconds" -le "$maximum" ] || seconds=$maximum
        pause_end=$((now + seconds))

        # This unit was already running when the current end was set, so
        # it kept a disk busy through that pause and the pause did not
        # count.  Push the end forward -- never backward -- so the quiet
        # time restarts from the moment this worker stops.  The test is
        # on the unit start, not on "now": a decode outlasting the whole
        # pause has to restart it too, not sail past an expired end.
        if [ "$started" -lt "$resume" ]; then
            [ "$pause_end" -gt "$resume" ] || pause_end=$resume
            write_state "$pause_end" && echo "join $pause_end" || echo "blind $seconds"
            exit 0
        fi

        processing=$((now - resume))
        [ "$processing" -ge "$time_up" ] || exit 0

        write_state "$pause_end" \
            && echo "start $seconds $processing $pause_end" \
            || echo "blind $seconds"
    ' duty-cycle "$NEL_MEDIA_WATCH_DUTY" "$_time_up" "$_time_pause" \
        "$_run_start" "$DUTY_MAXIMUM_PAUSE" "$_started") || _decision=

    # Whatever this worker pushed is recorded by now: only here may its
    # mark go, never before (see duty_stopped).
    duty_stopped

    # Word splitting of the decision is intended.
    set -- $_decision
    case "${1:-}" in
        start)
            watch_log "Duty cycle: pausing for ${2}s once every worker has stopped, after ${3}s of processing"
            duty_park "$4"
            ;;
        join)
            duty_park "$2"
            ;;
        blind)
            # The pause is taken anyway: the disks come first, and every
            # worker pausing on its own is still better than a run that
            # silently stops throttling.  One line per file at worst,
            # each of them followed by the pause itself.
            watch_log "Duty cycle: '$NEL_MEDIA_WATCH_DUTY' could not be written, pausing for ${2}s unrecorded"
            sleep "$2"
            ;;
        reset)
            watch_log "Duty cycle: implausible state '${2}' in '$NEL_MEDIA_WATCH_DUTY' refused, work window restarted"
            ;;
    esac
    return 0
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
