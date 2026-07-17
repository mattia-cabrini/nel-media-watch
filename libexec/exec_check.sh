#!/bin/sh
# Copyright (c) 2026 Mattia Cabrini
# SPDX-License-Identifier: MIT

# ---------------------------------------------------------------------------
# exec_check.sh -- run the cached check over a whole batch of PH lines.
#
# Usage:   exec_check.sh < ph-file
#
# Reads PH lines ("HASH/absolute/path") from stdin and feeds each one to
# check_media_state_c.sh.  exec.sh uses it for the single cross-target
# "general" pass: afterwards every hash of the snapshot has a cache
# entry, so the registry pass never re-analyses anything.
#
# Concurrency: by explicit project decision the batch is processed by
# (available cores - 1) parallel workers, superseding the strictly
# sequential rule of the original specification.  exec.sh computes and
# exports the count; each worker decodes single-threaded, so the total
# footprint stays at "cores - 1".
#
# The list is newline-delimited (paths must not contain newlines, an
# assumption of the whole find|grep scan); it is converted to
# NUL-delimited so that xargs preserves spaces in paths.
#
# Exit codes:
#     0   every line was processed
#     >0  at least one invocation failed (status forwarded from xargs)
# ---------------------------------------------------------------------------

set -u

SELF_DIRECTORY=$(cd -- "$(dirname -- "$0")" && pwd) || exit 1

tr '\n' '\0' | xargs -0 -n 1 -P "${NEL_MEDIA_WATCH_JOBS:-1}" \
    "$SELF_DIRECTORY/check_media_state_c.sh"
