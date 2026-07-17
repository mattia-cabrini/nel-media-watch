# Copyright (c) 2026 Mattia Cabrini
# SPDX-License-Identifier: MIT

# ---------------------------------------------------------------------------
# common.sh -- shared paths and helpers for the setup scripts.
#
# Sourced (not executed) by every script in setup/; the callers run with
# 'set -u'.  Everything interactive lives here so that config.sh and
# reconfig.sh share the exact same prompts and validations.
#
# The prompt_* functions implement both modes with one rule:
#   * variable empty (config)   -> an answer is required;
#   * variable set   (reconfig) -> an empty answer keeps the current value.
#
# Values are stored single-quoted in the .conf files, so every prompt
# refuses input containing a single quote.
# ---------------------------------------------------------------------------

PREFIX="${PREFIX:-/usr/local}"
LIBEXEC_DIRECTORY="$PREFIX/libexec/nel-media-watch"
ETC_DIRECTORY="$PREFIX/etc/nel-media-watch"
CONF_D_DIRECTORY="$ETC_DIRECTORY/conf.d"
GLOBAL_CONF="$ETC_DIRECTORY/nel-media-watch.conf"

RUNTIME_SCRIPTS="helpers.sh exec.sh exec_check.sh exec_dir.sh check_media_state.sh check_media_state_c.sh"

# timestamp: print the current time as {yyyymmdd}h{HHMMSS}; used to name
# backup files.
timestamp() {
    date +%Y%m%dh%H%M%S
}

# --- Listing and selection -----------------------------------------------

# Print the numbered list of local configurations; sets CONFIGURATION_COUNT.
list_configurations() {
    CONFIGURATION_COUNT=0
    for _conf_file in "$CONF_D_DIRECTORY"/*.conf; do
        [ -e "$_conf_file" ] || continue
        CONFIGURATION_COUNT=$((CONFIGURATION_COUNT + 1))
        printf '%3d) %s\n' "$CONFIGURATION_COUNT" "$(basename -- "$_conf_file")"
    done
}

# Ask for an index ($1 = verb shown in the prompt) and set
# SELECTED_CONFIGURATION.  The shell expands the glob in sorted order, so
# the numbering here matches the one printed by list_configurations.
select_configuration() {
    while :; do
        printf 'Index of the configuration to %s [1-%d]: ' "$1" "$CONFIGURATION_COUNT"
        read -r _index || exit 1
        case "$_index" in
            ''|*[!0-9]*) ;;
            *) [ "$_index" -ge 1 ] && [ "$_index" -le "$CONFIGURATION_COUNT" ] && break ;;
        esac
        echo "  Invalid index."
    done

    _i=0
    for _conf_file in "$CONF_D_DIRECTORY"/*.conf; do
        [ -e "$_conf_file" ] || continue
        _i=$((_i + 1))
        [ "$_i" -eq "$_index" ] && SELECTED_CONFIGURATION="$_conf_file"
    done
}

# --- Parameter prompts -----------------------------------------------------

prompt_target_directory() {
    while :; do
        if [ -n "$TARGET_DIRECTORY" ]; then
            printf 'TARGET_DIRECTORY [%s]: ' "$TARGET_DIRECTORY"
        else
            printf 'TARGET_DIRECTORY (absolute path of the directory to scan): '
        fi
        read -r _answer || exit 1
        if [ -z "$_answer" ]; then
            [ -n "$TARGET_DIRECTORY" ] && return
            echo "  A value is required."
            continue
        fi
        case "$_answer" in
            *"'"*) echo "  Single quotes are not allowed."; continue ;;
            /*) ;;
            *)  echo "  Must be an absolute path."; continue ;;
        esac
        if [ -d "$_answer" ]; then
            TARGET_DIRECTORY="$_answer"
            return
        fi
        echo "  Does not exist or is not a directory."
    done
}

prompt_filter() {
    while :; do
        if [ -n "$FILTER" ]; then
            printf 'FILTER [%s]: ' "$FILTER"
        else
            printf 'FILTER (extended regex for grep, selects the files to scan): '
        fi
        read -r _answer || exit 1
        if [ -z "$_answer" ]; then
            [ -n "$FILTER" ] && return
            echo "  A value is required."
            continue
        fi
        case "$_answer" in
            *"'"*) echo "  Single quotes are not allowed."; continue ;;
        esac
        # A broken pattern makes grep exit 2; 0 and 1 both mean "valid".
        printf '' | grep -E -- "$_answer" >/dev/null 2>&1
        if [ $? -le 1 ]; then
            FILTER="$_answer"
            return
        fi
        echo "  Not a valid extended regular expression."
    done
}

prompt_case() {
    while :; do
        if [ -n "$CASE" ]; then
            echo "CASE (current: $CASE):"
        else
            echo "CASE:"
        fi
        echo "  1) sensitive"
        echo "  2) insensitive"
        if [ -n "$CASE" ]; then
            printf 'Choice [1-2, empty keeps current]: '
        else
            printf 'Choice [1-2]: '
        fi
        read -r _answer || exit 1
        case "$_answer" in
            '') [ -n "$CASE" ] && return ;;
            1)  CASE="sensitive";   return ;;
            2)  CASE="insensitive"; return ;;
        esac
        echo "  Invalid choice."
    done
}

prompt_registry() {
    while :; do
        if [ -n "$REGISTRY" ]; then
            printf 'REGISTRY [%s]: ' "$REGISTRY"
        else
            printf 'REGISTRY (absolute path of the registry file): '
        fi
        read -r _answer || exit 1
        if [ -z "$_answer" ]; then
            [ -n "$REGISTRY" ] && return
            echo "  A value is required."
            continue
        fi
        case "$_answer" in
            *"'"*) echo "  Single quotes are not allowed."; continue ;;
            /*) ;;
            *)  echo "  Must be an absolute path."; continue ;;
        esac
        _registry_directory=$(dirname -- "$_answer")
        if [ -d "$_registry_directory" ] && [ -w "$_registry_directory" ]; then
            REGISTRY="$_answer"
            return
        fi
        echo "  Parent directory must exist and be writable."
    done
}

# Ask the four parameters in order (used by config.sh and reconfig.sh).
prompt_all_parameters() {
    prompt_target_directory
    prompt_filter
    prompt_case
    prompt_registry
}

# Write the four variables to the configuration file $1.
write_configuration() {
    {
        echo "# nel-media-watch local (per-target) configuration."
        printf "TARGET_DIRECTORY='%s'\n" "$TARGET_DIRECTORY"
        printf "FILTER='%s'\n" "$FILTER"
        printf "CASE='%s'\n" "$CASE"
        printf "REGISTRY='%s'\n" "$REGISTRY"
    } > "$1"
    echo "==> Wrote $1"
}
