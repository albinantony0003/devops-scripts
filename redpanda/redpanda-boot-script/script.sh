#!/usr/bin/env bash
# ==============================================================================
# Script: script.sh
# Description: Bootstraps Redpanda topics and configurations for a chosen cluster
#              (core, ingest, analytics) from a Jenkins job.
#
# Jenkins Parameters:
#   COLOUR       - "green" or "blue"  (Production environment colour)
#   CLUSTER_NAME - "core", "ingest", or "analytics"
#
# The COLOUR determines which set of node IPs and config directories to use.
# Config files are expected under: <colour>/<cluster>/
#   e.g.  green/core/topic_names.txt
#         blue/analytics/partition_counts.txt
# ==============================================================================
set -euo pipefail

# --- Configuration (Hardcoded defaults, can be overridden by environment variables) ---
CLUSTER_NAME="${1:-${CLUSTER_NAME:-}}"
COLOUR="${COLOUR:-}"
SSH_USER="${SSH_USER:-ubuntu}"
SSH_PORT="${SSH_PORT:-22}"

# ---------------------------------------------------------------------------
# Cluster nodes IPs/Hostnames — GREEN environment
# ---------------------------------------------------------------------------
GREEN_CORE_NODE="${GREEN_CORE_NODE:-}"
GREEN_INGEST_NODE="${GREEN_INGEST_NODE:-}"
GREEN_ANALYTICS_NODE="${GREEN_ANALYTICS_NODE:-}"

# ---------------------------------------------------------------------------
# Cluster nodes IPs/Hostnames — BLUE environment
# ---------------------------------------------------------------------------
BLUE_CORE_NODE="${BLUE_CORE_NODE:-}"
BLUE_INGEST_NODE="${BLUE_INGEST_NODE:-}"
BLUE_ANALYTICS_NODE="${BLUE_ANALYTICS_NODE:-}"

# ---------------------------------------------------------------------------
# Partitions for __consumer_offsets — common across all colours
# ---------------------------------------------------------------------------
CORE_PARTITIONS="${CORE_PARTITIONS:-77}"
INGEST_PARTITIONS="${INGEST_PARTITIONS:-55}"
ANALYTICS_PARTITIONS="${ANALYTICS_PARTITIONS:-16}"

# --- Modern Styling System (ANSI Colors) ---
RED='\033[0;31m'
GREEN_CLR='\033[0;32m'
YELLOW='\033[0;33m'
BLUE_CLR='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Indicators & Icons
INFO_ICON="${BLUE_CLR}➜${NC}"
SUCCESS_ICON="${GREEN_CLR}✔${NC}"
WARNING_ICON="${YELLOW}⚠${NC}"
ERROR_ICON="${RED}✖${NC}"
STEP_ICON="${MAGENTA}❖${NC}"

log_step()    { echo -e "\n${STEP_ICON}  ${BOLD}${MAGENTA}$1${NC}"; }
log_info()    { echo -e "  ${INFO_ICON}  $1"; }
log_success() { echo -e "  ${SUCCESS_ICON}  ${GREEN_CLR}$1${NC}"; }
log_warn()    { echo -e "  ${WARNING_ICON}  ${YELLOW}$1${NC}"; }
log_error()   { echo -e "  ${ERROR_ICON}  ${RED}${BOLD}$1${NC}" >&2; }

# --- Header Display ---
echo -e "${BOLD}${CYAN}======================================================================${NC}"
echo -e "${BOLD}${CYAN}               REDPANDA CLUSTER BOOTSTRAP ORCHESTRATOR                ${NC}"
echo -e "${BOLD}${CYAN}======================================================================${NC}"

# ---------------------------------------------------------------------------
# Validate required parameters
# ---------------------------------------------------------------------------
if [ -z "${COLOUR}" ]; then
    log_error "COLOUR is required. Set the environment variable to 'green' or 'blue'."
    exit 1
fi

if [ -z "${CLUSTER_NAME}" ]; then
    log_error "CLUSTER_NAME is required. Provide it as the first argument or set the environment variable."
    echo -e "Usage: $0 <core|ingest|analytics>\n"
    exit 1
fi

# Standardize to lowercase and strip leading/trailing whitespace
COLOUR=$(echo "$COLOUR" | tr '[:upper:]' '[:lower:]' | xargs)
CLUSTER_NAME=$(echo "$CLUSTER_NAME" | tr '[:upper:]' '[:lower:]' | xargs)

# ---------------------------------------------------------------------------
# Resolve NODE_HOST based on COLOUR + CLUSTER_NAME
# (PARTITIONS are common across colours — resolved from CLUSTER_NAME only)
# ---------------------------------------------------------------------------
case "$COLOUR" in
    green)
        case "$CLUSTER_NAME" in
            core)      NODE_HOST="${GREEN_CORE_NODE}"      ;;
            ingest)    NODE_HOST="${GREEN_INGEST_NODE}"    ;;
            analytics) NODE_HOST="${GREEN_ANALYTICS_NODE}" ;;
            *)
                log_error "Invalid CLUSTER_NAME: '${CLUSTER_NAME}'. Must be one of: core, ingest, analytics"
                exit 1
                ;;
        esac
        ;;
    blue)
        case "$CLUSTER_NAME" in
            core)      NODE_HOST="${BLUE_CORE_NODE}"      ;;
            ingest)    NODE_HOST="${BLUE_INGEST_NODE}"    ;;
            analytics) NODE_HOST="${BLUE_ANALYTICS_NODE}" ;;
            *)
                log_error "Invalid CLUSTER_NAME: '${CLUSTER_NAME}'. Must be one of: core, ingest, analytics"
                exit 1
                ;;
        esac
        ;;
    *)
        log_error "Invalid COLOUR: '${COLOUR}'. Must be 'green' or 'blue'."
        exit 1
        ;;
esac

# Resolve PARTITIONS from CLUSTER_NAME — shared across all colours
case "$CLUSTER_NAME" in
    core)      PARTITIONS="${CORE_PARTITIONS}"      ;;
    ingest)    PARTITIONS="${INGEST_PARTITIONS}"    ;;
    analytics) PARTITIONS="${ANALYTICS_PARTITIONS}" ;;
esac

# Config directory follows the pattern: <colour>/<cluster>
CONFIG_DIR="${COLOUR}/${CLUSTER_NAME}"

# Validate target host
if [ -z "$NODE_HOST" ]; then
    log_error "Node host/IP for '${COLOUR}/${CLUSTER_NAME}' is not defined."
    log_info "Please configure the corresponding environment variable (e.g. GREEN_CORE_NODE, BLUE_INGEST_NODE, ...)."
    exit 1
fi

echo -e "  Colour Selection:   ${BOLD}${COLOUR}${NC}"
echo -e "  Cluster Selection:  ${BOLD}${CLUSTER_NAME}${NC}"
echo -e "  Target Host:        ${BOLD}${NODE_HOST}${NC}"
echo -e "  Offset Partitions:  ${BOLD}${PARTITIONS}${NC}"
echo -e "  Config Directory:   ${BOLD}${CONFIG_DIR}${NC}"
echo -e "  SSH User:           ${BOLD}${SSH_USER}${NC}"
echo -e "${CYAN}----------------------------------------------------------------------${NC}"

# Setup SSH/SCP options
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p ${SSH_PORT}"
SCP_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P ${SSH_PORT}"

# Step 1: Switch to the colour/cluster config directory
log_step "Step 1: Switch to '${CONFIG_DIR}' directory"
if [ ! -d "${CONFIG_DIR}" ]; then
    log_warn "Directory '${CONFIG_DIR}' does not exist. Creating it..."
    mkdir -p "${CONFIG_DIR}"
fi
log_info "Changing directory to '$(pwd)/${CONFIG_DIR}'"
cd "${CONFIG_DIR}"

# Step 2: Placeholder step
log_step "Step 2: No operation defined"
log_info "Skipping..."

# Step 3: SCP the partition and topic list text files to node
log_step "Step 3: SCP the partition and topic list text files to node"
if [[ ! -f topic_names.txt || ! -f partition_counts.txt ]]; then
    log_error "Required files 'topic_names.txt' or 'partition_counts.txt' missing in $(pwd)."
    exit 1
fi

log_info "Copying files to ${SSH_USER}@${NODE_HOST}:/tmp/..."
if scp $SCP_OPTS topic_names.txt partition_counts.txt "${SSH_USER}@${NODE_HOST}:/tmp/"; then
    log_success "Files successfully copied."
else
    log_error "Failed to copy files to remote node."
    exit 1
fi

# Step 4: SSH to node and create __consumer_offsets topic
log_step "Step 4: SSH to node and create '__consumer_offsets' topic"
log_info "Creating __consumer_offsets topic with ${PARTITIONS} partitions on ${NODE_HOST}..."

# Execute topic creation command on remote node
CREATE_CMD="rpk topic create __consumer_offsets --partitions ${PARTITIONS} --replicas 3 --topic-config cleanup.policy=compact --topic-config retention.ms=1728000000 --topic-config segment.ms=1728000000"

log_info "Executing remote command: $CREATE_CMD"
if ssh $SSH_OPTS "${SSH_USER}@${NODE_HOST}" "$CREATE_CMD"; then
    log_success "Topic '__consumer_offsets' successfully configured."
else
    log_warn "Topic '__consumer_offsets' creation command completed with warning/error (it may already exist)."
fi

# Step 5: Based on copied files recreate topics
log_step "Step 5: Based on copied files recreate topics"
log_info "Running remote script to recreate topics..."

REMOTE_SCRIPT='
RED="\033[0;31m"
GREEN="\033[0;32m"
BLUE="\033[0;34m"
RESET="\033[0m"

cd /tmp || {
    echo -e "${RED}Error: Could not switch to /tmp directory.${RESET}"
    exit 1
}

recreate_topics() {
    if [[ ! -f topic_names.txt || ! -f partition_counts.txt ]]; then
        echo -e "${RED}Error: Topic name or partition count file missing.${RESET}"
        return
    fi

    mapfile -t topics < topic_names.txt
    mapfile -t partitions < partition_counts.txt

    if [[ ${#topics[@]} -ne ${#partitions[@]} ]]; then
        echo -e "${RED}Error: Number of topics and partition counts do not match.${RESET}"
        exit 1
    fi

    echo -e "${BLUE}Recreating Topics...${RESET}"
    for i in "${!topics[@]}"; do
        # Trim carriage returns if files were uploaded from Windows environment
        topic=$(echo "${topics[$i]}" | tr -d "\r")
        partition=$(echo "${partitions[$i]}" | tr -d "\r")
        
        if [[ -n "$topic" && -n "$partition" ]]; then
            rpk topic create "$topic" -p "$partition"
        fi
    done
    echo -e "${GREEN}Topics recreated.${RESET}"
}

recreate_topics
'

if ssh $SSH_OPTS "${SSH_USER}@${NODE_HOST}" "$REMOTE_SCRIPT"; then
    log_success "All topics successfully recreated."
else
    log_error "Failed to complete topic recreation on remote host."
    exit 1
fi

echo -e "\n${BOLD}${GREEN_CLR}======================================================================${NC}"
log_success "Bootstrap execution completed successfully for ${COLOUR}/${CLUSTER_NAME} cluster!"
echo -e "${BOLD}${GREEN_CLR}======================================================================${NC}"
