#!/usr/bin/env bash
# ==============================================================================
# redpanda-bootstrap.sh
# Main orchestrator for Redpanda cluster lifecycle operations.
#
# Usage (Jenkins — pass as environment variables or positional args):
#   COLOUR=blue CLUSTER_NAME=core ACTION=start       bash redpanda-bootstrap.sh
#   COLOUR=blue CLUSTER_NAME=core ACTION=ping        bash redpanda-bootstrap.sh
#   COLOUR=blue CLUSTER_NAME=core ACTION=disk-mount-tune bash redpanda-bootstrap.sh
#   COLOUR=blue CLUSTER_NAME=core ACTION=config-update   bash redpanda-bootstrap.sh
#   COLOUR=blue CLUSTER_NAME=core ACTION=restart-redpanda bash redpanda-bootstrap.sh
#   COLOUR=blue CLUSTER_NAME=core ACTION=stop        bash redpanda-bootstrap.sh
#
# Parameters (env vars, Jenkins params, or positional args):
#   COLOUR       - "blue" | "green"
#   CLUSTER_NAME - "core" | "ingest" | "analytics"
#   ACTION       - one of: start | stop | ping | disk-mount-tune |
#                          config-update | restart-redpanda
#
# Optional env vars:
#   SSH_USER          - SSH login user (default: ubuntu)
#   SSH_PORT          - SSH port       (default: 22)
#   BACKUP_S3_BUCKET  - S3 URI for syncing topic backups (stop action)
#   GREEN_TRAFFIC     - Traffic level on green side (0 = safe to stop)
#   BLUE_TRAFFIC      - Traffic level on blue side  (0 = safe to stop)
#   CORE_PARTITIONS   - __consumer_offsets partitions for core cluster   (default: 77)
#   INGEST_PARTITIONS - __consumer_offsets partitions for ingest cluster  (default: 55)
#   ANALYTICS_PARTITIONS - for analytics cluster (default: 16)
# ==============================================================================
set -euo pipefail

# ── Resolve the repo root (works regardless of the CWD Jenkins uses) ──────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

# ── Source shared libraries ────────────────────────────────────────────────────
# shellcheck source=lib/logging.sh
source "${SCRIPT_DIR}/lib/logging.sh"
# shellcheck source=lib/inventory.sh
source "${SCRIPT_DIR}/lib/inventory.sh"

# ── Source all action modules ──────────────────────────────────────────────────
# shellcheck source=actions/start.sh
source "${SCRIPT_DIR}/actions/start.sh"
# shellcheck source=actions/stop.sh
source "${SCRIPT_DIR}/actions/stop.sh"
# shellcheck source=actions/ping.sh
source "${SCRIPT_DIR}/actions/ping.sh"
# shellcheck source=actions/disk-mount-tune.sh
source "${SCRIPT_DIR}/actions/disk-mount-tune.sh"
# shellcheck source=actions/config-update.sh
source "${SCRIPT_DIR}/actions/config-update.sh"
# shellcheck source=actions/restart.sh
source "${SCRIPT_DIR}/actions/restart.sh"

# ── Ensure inventory temp dir is cleaned up on exit ───────────────────────────
trap cleanup_inventory EXIT

# ==============================================================================
# 1. PARAMETER RESOLUTION
#    Accept Jenkins env vars (primary) or positional args (fallback).
# ==============================================================================
COLOUR="${COLOUR:-${1:-}}"
CLUSTER_NAME="${CLUSTER_NAME:-${2:-}}"
ACTION="${ACTION:-${3:-}}"

# Normalise: lowercase + strip surrounding whitespace
COLOUR=$(echo "${COLOUR}"       | tr '[:upper:]' '[:lower:]' | xargs)
CLUSTER_NAME=$(echo "${CLUSTER_NAME}" | tr '[:upper:]' '[:lower:]' | xargs)
ACTION=$(echo "${ACTION}"       | tr '[:upper:]' '[:lower:]' | xargs)

# Export so action scripts can read them directly if needed
export COLOUR CLUSTER_NAME ACTION

# SSH configuration
SSH_USER="${SSH_USER:-ubuntu}"
SSH_PORT="${SSH_PORT:-22}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p ${SSH_PORT}"
SCP_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P ${SSH_PORT}"
export SSH_USER SSH_PORT SSH_OPTS SCP_OPTS

# ==============================================================================
# 2. BANNER
# ==============================================================================
print_header "REDPANDA BOOTSTRAP ORCHESTRATOR"
printf "  Colour       : %s%s%s\n" "${BOLD}" "${COLOUR}" "${NC}"
printf "  Cluster Name : %s%s%s\n" "${BOLD}" "${CLUSTER_NAME}" "${NC}"
printf "  Action       : %s%s%s\n" "${BOLD}" "${ACTION}" "${NC}"
printf "  SSH User     : %s%s%s\n" "${BOLD}" "${SSH_USER}" "${NC}"
print_divider

# ==============================================================================
# 3. PARAMETER VALIDATION
# ==============================================================================
log_step "Validating parameters"

# Validate COLOUR
case "${COLOUR}" in
    blue|green) log_success "COLOUR: ${COLOUR}" ;;
    "")
        log_error "COLOUR is required. Set it to 'blue' or 'green'."
        exit 1
        ;;
    *)
        log_error "Invalid COLOUR: '${COLOUR}'. Must be 'blue' or 'green'."
        exit 1
        ;;
esac

# Validate CLUSTER_NAME
case "${CLUSTER_NAME}" in
    core|ingest|analytics) log_success "CLUSTER_NAME: ${CLUSTER_NAME}" ;;
    "")
        log_error "CLUSTER_NAME is required. Set it to 'core', 'ingest', or 'analytics'."
        exit 1
        ;;
    *)
        log_error "Invalid CLUSTER_NAME: '${CLUSTER_NAME}'. Must be 'core', 'ingest', or 'analytics'."
        exit 1
        ;;
esac

# Validate ACTION
valid_actions=("start" "stop" "ping" "disk-mount-tune" "config-update" "restart-redpanda")
action_valid=false
for a in "${valid_actions[@]}"; do
    [[ "${ACTION}" == "${a}" ]] && action_valid=true && break
done

if [[ "${action_valid}" == "false" ]]; then
    if [[ -z "${ACTION}" ]]; then
        log_error "ACTION is required."
    else
        log_error "Invalid ACTION: '${ACTION}'."
    fi
    echo -e "  Valid actions: ${valid_actions[*]}"
    exit 1
fi
log_success "ACTION: ${ACTION}"

# ==============================================================================
# 4. FETCH INVENTORY FROM S3
#    Downloads inventory.txt, topic.txt, partition.txt into $INVENTORY_DIR
# ==============================================================================
fetch_inventory "${COLOUR}" "${CLUSTER_NAME}"

# Parse inventory into usable variables
INSTANCE_IDS=$(get_instance_ids)
INSTANCE_IPS=$(get_instance_ips)
FIRST_IP=$(get_first_ip)

export INSTANCE_IDS INSTANCE_IPS FIRST_IP INVENTORY_DIR

printf "\n"
log_step "Inventory Loaded"
printf "  Instance IDs : %s%s%s\n" "${BOLD}" "${INSTANCE_IDS}" "${NC}"
printf "  Instance IPs : %s%s%s\n" "${BOLD}" "${INSTANCE_IPS}" "${NC}"
printf "  First IP     : %s%s%s\n" "${BOLD}" "${FIRST_IP}" "${NC}"
print_divider

# ==============================================================================
# 5. ACTION DISPATCH
# ==============================================================================
log_step "Dispatching action: ${ACTION^^}"

case "${ACTION}" in

    # ── start ─────────────────────────────────────────────────────────────────
    # Uses: instance IDs (EC2 API)
    start)
        action_start "${INSTANCE_IDS}"
        ;;

    # ── stop ──────────────────────────────────────────────────────────────────
    # Uses: all instance IDs (EC2 API) + first IP (SSH topic backup)
    stop)
        action_stop "${INSTANCE_IDS}" "${FIRST_IP}"
        ;;

    # ── ping ──────────────────────────────────────────────────────────────────
    # Uses: all instance IPs (ICMP + SSH connectivity)
    ping)
        action_ping "${INSTANCE_IPS}"
        ;;

    # ── disk-mount-tune ───────────────────────────────────────────────────────
    # Uses: all instance IPs (SSH to run disk/tune script)
    disk-mount-tune)
        action_disk_mount_tune "${INSTANCE_IPS}"
        ;;

    # ── config-update ─────────────────────────────────────────────────────────
    # Uses: first instance IP only (SSH cluster config + topic creation)
    config-update)
        action_config_update "${FIRST_IP}"
        ;;

    # ── restart-redpanda ──────────────────────────────────────────────────────
    # Uses: all instance IPs (SSH systemctl restart)
    restart-redpanda)
        action_restart "${INSTANCE_IPS}"
        ;;

esac

# ==============================================================================
# 6. SUCCESS FOOTER
# ==============================================================================
print_footer "Bootstrap action '${ACTION}' completed for ${COLOUR}/${CLUSTER_NAME}."
