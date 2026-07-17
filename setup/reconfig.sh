#!/bin/sh
# Copyright (c) 2026 Mattia Cabrini
# SPDX-License-Identifier: MIT

# ---------------------------------------------------------------------------
# reconfig.sh -- edit an existing target configuration (run as root).
#
# Lists the configurations, selects one by numeric index, then re-asks
# the four parameters in "no change on empty" mode: the current value is
# shown in [brackets] and an empty answer keeps it.  Only NEW values are
# validated.  The prompts and validations are shared with config.sh
# (see common.sh).
#
# Exit codes:
#     0   configuration rewritten (or nothing to edit)
#     1   input stream closed
# ---------------------------------------------------------------------------

set -u

. "$(dirname -- "$0")/common.sh"

list_configurations
if [ "$CONFIGURATION_COUNT" -eq 0 ]; then
    echo "No configurations present in $CONF_D_DIRECTORY."
    exit 0
fi
select_configuration "edit"

# Current values as starting point: every prompt keeps them on empty input.
TARGET_DIRECTORY=; FILTER=; CASE=; REGISTRY=
. "$SELECTED_CONFIGURATION"

echo "Editing $SELECTED_CONFIGURATION (an empty answer keeps the current value)."
prompt_all_parameters

write_configuration "$SELECTED_CONFIGURATION"
