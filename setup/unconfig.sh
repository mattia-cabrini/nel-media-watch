#!/bin/sh
# Copyright (c) 2026 Mattia Cabrini
# SPDX-License-Identifier: MIT

# ---------------------------------------------------------------------------
# unconfig.sh -- delete a target configuration (run as root).
#
# Lists the configurations, selects one by numeric index and, after
# confirmation, moves it aside as a timestamped backup:
#
#     conf.d/{yyyymmdd}h{HHMMSS}_<name>.conf.bak
#
# The '.conf.bak' suffix keeps the backup out of the tool's reach (only
# '*.conf' files are ever loaded).  The global configuration is never
# touched.
#
# Exit codes:
#     0   configuration removed, aborted by the user, or nothing to remove
#     1   input stream closed, or backup move failed
# ---------------------------------------------------------------------------

set -u

. "$(dirname -- "$0")/common.sh"

list_configurations
if [ "$CONFIGURATION_COUNT" -eq 0 ]; then
    echo "No configurations present in $CONF_D_DIRECTORY."
    exit 0
fi
select_configuration "delete"

printf 'Delete %s? [y/N]: ' "$SELECTED_CONFIGURATION"
read -r CONFIRM_ANSWER || exit 1
case "$CONFIRM_ANSWER" in
    y|Y)
        CONFIGURATION_NAME=$(basename -- "$SELECTED_CONFIGURATION" .conf)
        BACKUP_FILE="$CONF_D_DIRECTORY/$(timestamp)_$CONFIGURATION_NAME.conf.bak"
        mv "$SELECTED_CONFIGURATION" "$BACKUP_FILE" || exit 1
        echo "==> Removed $SELECTED_CONFIGURATION"
        echo "==> Backup kept at $BACKUP_FILE"
        ;;
    *)
        echo "==> Aborted, nothing deleted."
        ;;
esac
