#!/usr/bin/env bash
# ==============================================================================
# lib/logging.sh
# Shared ANSI colour palette and log-helper functions.
# Source this file at the top of any script that needs formatted output:
#   source "$(dirname "$0")/../lib/logging.sh"
# ==============================================================================

# --- Colour Palette ---
ESC=$(printf '\033')
RED="${ESC}[31m"
GREEN_CLR="${ESC}[32m"
YELLOW="${ESC}[33m"
BLUE_CLR="${ESC}[34m"
MAGENTA="${ESC}[35m"
CYAN="${ESC}[36m"
BOLD="${ESC}[1m"
NC="${ESC}[0m" # No Colour / Reset

# --- Icons ---
INFO_ICON="➜"
SUCCESS_ICON="✔"
WARNING_ICON="⚠"
ERROR_ICON="✖"
STEP_ICON="❖"

# --- Log Functions ---
log_step()    { printf "\n%s%s %s%s\n" "${MAGENTA}" "${STEP_ICON}" "$1" "${NC}"; }
log_info()    { printf "%s%s %s%s\n" "${BLUE_CLR}" "${INFO_ICON}" "$1" "${NC}"; }
log_success() { printf "%s%s %s%s\n" "${GREEN_CLR}" "${SUCCESS_ICON}" "$1" "${NC}"; }
log_warn()    { printf "%s%s %s%s\n" "${YELLOW}" "${WARNING_ICON}" "$1" "${NC}"; }
log_error()   { printf "%s%s %s%s\n" "${RED}" "${ERROR_ICON}" "$1" "${NC}" >&2; }

# --- Banner helpers ---
print_header() {
    local title="${1:-REDPANDA BOOTSTRAP ORCHESTRATOR}"
    local width=70
    local pad=$(( (width - ${#title}) / 2 ))
    printf "%s%s%s\n" "${CYAN}" "$(printf '=%.0s' $(seq 1 $width))" "${NC}"
    printf "%s%s%s%s\n" "${CYAN}" "$(printf ' %.0s' $(seq 1 $pad))" "${title}" "${NC}"
    printf "%s%s%s\n" "${CYAN}" "$(printf '=%.0s' $(seq 1 $width))" "${NC}"
}

print_divider() {
    printf "%s%s%s\n" "${CYAN}" "$(printf -- '-%.0s' $(seq 1 70))" "${NC}"
}

print_footer() {
    local msg="${1:-Execution completed successfully.}"
    printf "\n%s%s%s\n" "${GREEN_CLR}" "$(printf '=%.0s' $(seq 1 70))" "${NC}"
    log_success "$msg"
    printf "%s%s%s\n" "${GREEN_CLR}" "$(printf '=%.0s' $(seq 1 70))" "${NC}"
}
