#!/bin/sh
# Copyright (c) 2026 Mattia Cabrini
# SPDX-License-Identifier: MIT

# ---------------------------------------------------------------------------
# config.sh -- interactively add a target configuration (run as root).
#
# Asks for the file name and the four parameters (TARGET_DIRECTORY,
# FILTER, CASE as a 1/2 menu, REGISTRY), validates them, and writes
# conf.d/<name>.conf.  The prompts and validations are shared with
# reconfig.sh (see common.sh).
#
# Exit codes:
#     0   configuration written
#     1   input stream closed
# ---------------------------------------------------------------------------

set -u

. "$(dirname -- "$0")/common.sh"

mkdir -p "$CONF_D_DIRECTORY"
echo "== nel-media-watch: add a target configuration =="

while :; do
    printf 'Configuration file name (will become conf.d/<name>.conf): '
    read -r CONFIGURATION_NAME || exit 1
    case "$CONFIGURATION_NAME" in
        ''|*/*|*' '*|*"'"*)
            echo "  Invalid name: non-empty, no spaces, no slashes, no single quotes."
            continue
            ;;
    esac
    if [ -e "$CONF_D_DIRECTORY/$CONFIGURATION_NAME.conf" ]; then
        echo "  '$CONFIGURATION_NAME.conf' already exists: use 'make reconfig' to change it."
        continue
    fi
    break
done

# Empty starting values: every prompt requires an explicit answer.
TARGET_DIRECTORY=; FILTER=; CASE=; REGISTRY=
prompt_all_parameters

write_configuration "$CONF_D_DIRECTORY/$CONFIGURATION_NAME.conf"
