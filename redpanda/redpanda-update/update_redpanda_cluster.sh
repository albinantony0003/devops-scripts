#!/bin/bash

# Redpanda Cluster Update Script
#
# Fetches node IPs automatically from the S3 inventory based on COLOUR and
# CLUSTER_NAME — no manual IP passing required.
#
# Required environment variables (set as Jenkins parameters):
#   COLOUR       - "green" or "blue"
#   CLUSTER_NAME - "core", "ingest", or "analytics"
#
# Optional environment variables:
#   SSH_USER     - SSH username (default: ubuntu)
#   S3_BUCKET    - S3 bucket name for inventory (default: redpanda-config)
#
# S3 inventory layout expected:
#   s3://<S3_BUCKET>/<colour>/<cluster>/inventory.txt
#
# inventory.txt format (one entry per line):
#   <instance-id>  <private-ip>
#   e.g.  i-0abc123def456789a  10.0.1.25

set -e
set -o pipefail

# Configuration
SSH_USER=${SSH_USER:-"ubuntu"}        # Default SSH user, can be overridden
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
S3_BUCKET="${S3_BUCKET:-dz-sandbox-redpanda-config}"

# Attempt to use tput for bold text, fallback to empty if not fully supported
# Redirect stderr to /dev/null to avoid "No value for $TERM" errors
if command -v tput >/dev/null 2>&1 && tput bold >/dev/null 2>&1; then
    BOLD=$(tput bold 2>/dev/null)
    RESET=$(tput sgr0 2>/dev/null)
else
    BOLD=""
    RESET=""
fi

# --- Helper Functions ---

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

run_remote() {
    local ip=$1
    local cmd=$2
    ssh $SSH_OPTS "$SSH_USER@$ip" "sudo sh -c '$cmd'" >&2
}

run_remote_output() {
    local ip=$1
    local cmd=$2
    ssh $SSH_OPTS "$SSH_USER@$ip" "sudo sh -c '$cmd'"
}

# --- Core Logic Functions ---

check_ssh_connectivity() {
    local ip=$1
    log "Checking connectivity to ${BOLD}$ip${RESET}..."
    # ssh -q exits with 0 on success, non-zero on failure
    if ! ssh $SSH_OPTS -q "$SSH_USER@$ip" exit; then
        log "[ERROR] Cannot connect to ${BOLD}$ip${RESET} via SSH. Aborting."
        return 1
    fi
}

check_for_updates() {
    local ip=$1
    log "Checking for updates on ${BOLD}$ip${RESET}..."
    
    # Update apt cache first
    run_remote "$ip" "apt-get update > /dev/null 2>&1 || true"
    
    local update_check
    update_check=$(run_remote_output "$ip" "apt list --upgradable 2>/dev/null | grep redpanda || true")

    if [[ -z "$update_check" ]]; then
        return 1 # No updates
    else
        echo "$update_check"
        return 0 # Update available
    fi
}

get_node_details() {
    local ip=$1
    log "Fetching Node ID and Current Version..."

    # Try retrieving ID from cluster status (Text parsing based on user output)
    local cluster_status_text
    cluster_status_text=$(run_remote_output "$ip" "rpk cluster status 2>/dev/null || true")
    
    # Parse text output:
    # Look for the line where the 2nd column (HOST) matches the IP.
    # Print the 1st column (ID).
    NODE_ID=$(echo "$cluster_status_text" | awk -v ip="$ip" '$2 == ip {print $1}')

    # Remove trailing '*' if present (indicates leader)
    NODE_ID=${NODE_ID%\*}

    PRE_VERSION=$(run_remote_output "$ip" "rpk version")
    
    log "Node ID: $NODE_ID"
    log "Current Version: $PRE_VERSION"

    if [[ -z "$NODE_ID" ]]; then
        log "Error: Could not retrieve Node ID for ${BOLD}$ip${RESET}. Aborting."
        return 1
    fi
}


check_and_unhold_package() {
    local ip=$1
    log "Checking if redpanda is held..."
    WAS_HELD=false
    local hold_status
    hold_status=$(run_remote_output "$ip" "apt-mark showhold redpanda")
    
    if [[ "$hold_status" == *"redpanda"* ]]; then
        log "Package is held. Unholding..."
        WAS_HELD=true
        run_remote "$ip" "apt-mark unhold redpanda"
    else
        log "Package is not held."
    fi
}

enable_maintenance() {
    local ip=$1
    local node_id=$2
    log "Enabling maintenance mode for Node $node_id..."
    run_remote "$ip" "rpk cluster maintenance enable $node_id --wait"
}

backup_config() {
    local ip=$1
    log "Backing up configuration..."
    run_remote "$ip" "cp /etc/redpanda/redpanda.yaml /etc/redpanda/redpanda.yaml.bak.$(date +%F_%T)"
}

perform_system_update() {
    local ip=$1
    log "Performing system update (keeping config)..."
    run_remote "$ip" "DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -o Dpkg::Options::='--force-confold' > /dev/null"
}

reboot_node() {
    local ip=$1
    log "Rebooting node..."
    run_remote "$ip" "reboot" || true
}

wait_for_node() {
    local ip=$1
    log "Waiting for node to come back online..."
    
    sleep 10
    local max_retries=30
    local count=0
    while ! ssh $SSH_OPTS -q "$SSH_USER@$ip" exit; do
        sleep 10
        count=$((count+1))
        if [ $count -ge $max_retries ]; then
            log "Error: Timed out waiting for ${BOLD}$ip${RESET} to come back online."
            exit 1
        fi
        echo -n "."
    done
    echo ""
    log "Node is back online."
}

disable_maintenance() {
    local ip=$1
    local node_id=$2
    log "Disabling maintenance mode for Node $node_id..."
    run_remote "$ip" "rpk cluster maintenance disable $node_id"
}

restore_hold() {
    local ip=$1
    if [ "$WAS_HELD" = "true" ]; then
        log "Re-holding redpanda package..."
        run_remote "$ip" "apt-mark hold redpanda"
    fi
}

verify_update() {
    local ip=$1
    log "Verifying update..."
    local post_version
    post_version=$(run_remote_output "$ip" "rpk version")
    
    log "--------------------------------------------------"
    log "Update Complete for ${BOLD}$ip${RESET}"
    log "Pre-update Version: $PRE_VERSION"
    log "Post-update Version: $post_version"
    log "--------------------------------------------------"
}

# --- Main Execution ---

# ---------------------------------------------------------------------------
# Validate required Jenkins parameters
# ---------------------------------------------------------------------------
COLOUR="${COLOUR:-}"
CLUSTER_NAME="${CLUSTER_NAME:-}"

if [ -z "$COLOUR" ]; then
    log "[ERROR] COLOUR is required. Set it to 'green' or 'blue'."
    exit 1
fi

if [ -z "$CLUSTER_NAME" ]; then
    log "[ERROR] CLUSTER_NAME is required. Set it to 'core', 'ingest', or 'analytics'."
    exit 1
fi

# Normalize to lowercase
COLOUR=$(echo "$COLOUR" | tr '[:upper:]' '[:lower:]' | xargs)
CLUSTER_NAME=$(echo "$CLUSTER_NAME" | tr '[:upper:]' '[:lower:]' | xargs)

# ---------------------------------------------------------------------------
# Fetch node IPs from S3 inventory
# ---------------------------------------------------------------------------
fetch_ips_from_s3() {
    local colour="$1"
    local cluster="$2"
    local s3_path="s3://${S3_BUCKET}/${colour}/${cluster}/inventory.txt"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    log "Fetching inventory from S3: ${s3_path}"

    if ! aws s3 cp "${s3_path}" "${tmp_dir}/inventory.txt" --quiet; then
        log "[ERROR] Failed to download inventory from ${s3_path}"
        rm -rf "${tmp_dir}"
        exit 1
    fi

    # Parse column 2 (private IPs) from inventory.txt, space-separated
    local ips
    ips=$(tr -d '\r' < "${tmp_dir}/inventory.txt" | awk '{print $2}' | tr '\n' ' ' | xargs)
    rm -rf "${tmp_dir}"

    if [ -z "$ips" ]; then
        log "[ERROR] No IPs found in inventory at ${s3_path}"
        exit 1
    fi

    echo "$ips"
}

IPS=$(fetch_ips_from_s3 "$COLOUR" "$CLUSTER_NAME")
log "Resolved node IPs for ${COLOUR}/${CLUSTER_NAME}: ${IPS}"

# Initialize status arrays
UPDATED_NODES=()
SKIPPED_NODES=()


for IP in $IPS; do
    log "=================================================="
    log "Starting update process for node: ${BOLD}$IP${RESET}"
    log "=================================================="

    # 1. Check Connectivity
    if ! check_ssh_connectivity "$IP"; then
        exit 1
    fi

    # 2. Check Update
    if ! update_info=$(check_for_updates "$IP"); then
         log "No Redpanda updates available for ${BOLD}$IP${RESET}. Skipping..."
         SKIPPED_NODES+=("$IP")
         continue
    fi
    log "Update available: $update_info"

    # 2. Get Details
    if ! get_node_details "$IP"; then
        log "[ERROR] Failed to get details execution for node: $IP"
        exit 1
    fi
    
    # 3. Check/Unhold
    check_and_unhold_package "$IP"

    # 4. Enable Maintenance
    enable_maintenance "$IP" "$NODE_ID"

    # 5. Backup
    backup_config "$IP"

    # 6. Update
    perform_system_update "$IP"

    # 7. Reboot
    reboot_node "$IP"
    wait_for_node "$IP"

    # 8. Disable Maintenance
    disable_maintenance "$IP" "$NODE_ID"

    # 9. Restore Hold
    restore_hold "$IP"

    # 10. Verify
    verify_update "$IP"
    UPDATED_NODES+=("$IP")

done

log ""
log "=================================================="
log "Update Summary"
log "=================================================="

if [ ${#UPDATED_NODES[@]} -gt 0 ]; then
    log "Updated Nodes:"
    for node in "${UPDATED_NODES[@]}"; do
        log "  - ${BOLD}$node${RESET}"
    done
else
    log "Updated Nodes: None"
fi

if [ ${#SKIPPED_NODES[@]} -gt 0 ]; then
    log "Skipped Nodes (No updates necessary):"
    for node in "${SKIPPED_NODES[@]}"; do
        log "  - ${BOLD}$node${RESET}"
    done
fi
log "=================================================="
