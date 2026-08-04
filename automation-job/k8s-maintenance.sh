#!/bin/bash
# k8s-maintenance.sh
# Jenkins job helper script for Kubernetes deployment and HPA maintenance operations.

set -euo pipefail

# ==========================================
# Parameter Definition & Defaults
# ==========================================
ACTION="${ACTION:-}"
COLOR="${COLOR:-}"
DRY_RUN="${DRY_RUN:-false}"
NAMESPACE="${NAMESPACE:-}"

# --- Blue Kubernetes Cluster Configuration ---
KUBEPATH_BLUE="/opt/k8s-creds/EKS-Production-Blue"
KUBEPATH_GREEN="/opt/k8s-creds/EKS-Production-Green"
# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Define Usage
usage() {
    echo "Usage: $0"
    echo "Required Environment Variables or Parameters:"
    echo "  ACTION                 : HPA_AND_ENV_UPDATE | RUN_AUTOMATION_SCRIPT | REVERT_HPA_AND_ENV"
    echo "  COLOR                  : blue | green"
    echo "Optional Environment Variables:"
    echo "  DRY_RUN                : true | false (default: false)"
    echo "  NAMESPACE              : Kubernetes namespace (defaults dynamically based on COLOR)"
    exit 1
}

# Validate inputs
if [[ -z "$ACTION" ]] || [[ -z "$COLOR" ]]; then
    echo "ERROR: ACTION and COLOR parameters must be set." >&2
    usage
fi

if [[ "$COLOR" != "blue" ]] && [[ "$COLOR" != "green" ]]; then
    echo "ERROR: COLOR must be 'blue' or 'green'." >&2
    usage
fi

# Determine namespace based on color if not explicitly overridden
if [[ -z "$NAMESPACE" ]]; then
    if [[ "$COLOR" == "blue" ]]; then
        NAMESPACE="dz-production-blue"
    elif [[ "$COLOR" == "green" ]]; then
        NAMESPACE="dz-production-green"
    fi
fi

# Define Deployment and HPA names dynamically
EVENT_NORMALIZER_DEP="dz-event-normalizer-${COLOR}"
LOG_NORMALIZER_DEP="dz-log-normalizer-${COLOR}"

# Determine kubeconfig path based on color
if [[ "$COLOR" == "blue" ]]; then
    KUBECONFIG_PATH="$KUBEPATH_BLUE"
elif [[ "$COLOR" == "green" ]]; then
    KUBECONFIG_PATH="$KUBEPATH_GREEN"
fi

# Kubeconfig is explicitly appended to kubectl commands for visibility in logs

echo "=================================================="
echo " Starting Kubernetes Maintenance Job"
echo " Time      : $(date)"
echo " Action    : ${ACTION}"
echo " Color     : ${COLOR}"
echo " Namespace : ${NAMESPACE}"
echo " Dry Run   : ${DRY_RUN}"
echo " kubeconfig path: ${KUBECONFIG_PATH}"
echo "=================================================="

# ==========================================
# Helper Functions
# ==========================================

# Run commands with dry-run support
run_cmd() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] Would execute: $*"
    else
        echo "Executing: $*"
        "$@"
    fi
}

# Logging helper
log() {
    echo -e "\n[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

# ==========================================
# Stage 1: Validation
# ==========================================
stage_validation() {
    log "=== Stage 1: Validation & Current State ==="

    # Check for kubectl installation
    if ! command -v kubectl &> /dev/null; then
        echo "ERROR: kubectl command-line tool not found." >&2
        exit 1
    fi

    echo "Retrieving current cluster configurations..."
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] Simulating retrieval of current resource states."
    else
        echo "--- Current HPAs ---"
        kubectl --kubeconfig="${KUBECONFIG_PATH}" get hpa "$EVENT_NORMALIZER_DEP-hpa" "$LOG_NORMALIZER_DEP-hpa" -n "$NAMESPACE" || echo "Warning: HPAs unavailable."
        
        echo -e "\n--- Current Env Vars for $EVENT_NORMALIZER_DEP ---"
        kubectl --kubeconfig="${KUBECONFIG_PATH}" describe deployment "$EVENT_NORMALIZER_DEP" -n "$NAMESPACE"  | grep -E 'FIRST_PASS_MESSAGE_TTL_MS|SEMANTIC_MESSAGE_DEDUPE_TTL_MS' || echo "Warning: Env vars unavailable."
        
    fi

    echo "Validation completed successfully."
}

# ==========================================
# Stage 3: Verification
# ==========================================
stage_verification() {
    log "=== Stage 3: Verification ==="
    
    echo "Verifying Deployment Environment Variables:"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] Skipping actual resource state retrieval."
    else
        echo "--- event-normalizer Env Vars ---"
        kubectl --kubeconfig="${KUBECONFIG_PATH}" describe deployment "$EVENT_NORMALIZER_DEP" -n "$NAMESPACE"  | grep -E 'FIRST_PASS_MESSAGE_TTL_MS|SEMANTIC_MESSAGE_DEDUPE_TTL_MS' || echo "No env vars found or deployment unavailable."
        echo -e "\n--- HPAs ---"
        kubectl --kubeconfig="${KUBECONFIG_PATH}" get hpa "$EVENT_NORMALIZER_DEP-hpa" "$LOG_NORMALIZER_DEP-hpa" -n "$NAMESPACE" || echo "HPAs unavailable."
    fi
}

# ==========================================
# Stage 2: Operations
# ==========================================
action_hpa_and_env_update() {
    log "=== Stage 2: Update HPAs & Env Vars ==="

    # 1. Update HPAs to minReplicas=1, maxReplicas=1
    log "Patching HPA '$EVENT_NORMALIZER_DEP-hpa' to minReplicas=1, maxReplicas=1..."
    run_cmd kubectl --kubeconfig="${KUBECONFIG_PATH}" patch hpa "$EVENT_NORMALIZER_DEP-hpa" -n "$NAMESPACE" --type='json' -p='[{"op": "replace", "path": "/spec/minReplicas", "value": 1}, {"op": "replace", "path": "/spec/maxReplicas", "value": 1}]'

    log "Patching HPA '$LOG_NORMALIZER_DEP-hpa' to minReplicas=1, maxReplicas=1..."
    run_cmd kubectl --kubeconfig="${KUBECONFIG_PATH}" patch hpa "$LOG_NORMALIZER_DEP-hpa" -n "$NAMESPACE" --type='json' -p='[{"op": "replace", "path": "/spec/minReplicas", "value": 1}, {"op": "replace", "path": "/spec/maxReplicas", "value": 1}]'

    # 2. Patch env vars for event-normalizer deployment
    log "Patching Env Variables for '$EVENT_NORMALIZER_DEP'..."
    run_cmd kubectl --kubeconfig="${KUBECONFIG_PATH}" set env deployment/"$EVENT_NORMALIZER_DEP" -n "$NAMESPACE" -c "$EVENT_NORMALIZER_DEP" \
        FIRST_PASS_MESSAGE_TTL_MS=200000 \
        SEMANTIC_MESSAGE_DEDUPE_TTL_MS=200000
}

action_run_automation_script() {
    log "=== Stage 2: Run Automation Script ==="

    local qa_script="${SCRIPT_DIR}/qa-automation.sh"
    if [[ ! -f "$qa_script" ]]; then
        echo "ERROR: QA Automation script not found at '$qa_script'." >&2
        exit 1
    fi

    log "Executing automation script: $qa_script"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] Would run bash '$qa_script'"
    else
        # Run and display logs in real-time
        bash "$qa_script"
    fi
}

action_revert_hpa_and_env() {
    log "=== Stage 2: Revert HPAs & Env Vars ==="

    # 1. Revert environment variables for event-normalizer deployment
    log "Reverting Env Variables for '$EVENT_NORMALIZER_DEP'..."
    run_cmd kubectl --kubeconfig="${KUBECONFIG_PATH}" set env deployment/"$EVENT_NORMALIZER_DEP" -n "$NAMESPACE" -c "$EVENT_NORMALIZER_DEP" \
        FIRST_PASS_MESSAGE_TTL_MS=300000 \
        SEMANTIC_MESSAGE_DEDUPE_TTL_MS=1000

    # 2. Restore HPAs
    # event-normalizer: minReplicas=10, maxReplicas=120
    log "Restoring HPA '$EVENT_NORMALIZER_DEP' to minReplicas=10, maxReplicas=120..."
    run_cmd kubectl --kubeconfig="${KUBECONFIG_PATH}" patch hpa "$EVENT_NORMALIZER_DEP" -n "$NAMESPACE" --type='json' -p='[{"op": "replace", "path": "/spec/minReplicas", "value": 10}, {"op": "replace", "path": "/spec/maxReplicas", "value": 120}]'

    # log-normalizer: minReplicas=2, maxReplicas=120
    log "Restoring HPA '$LOG_NORMALIZER_DEP' to minReplicas=2, maxReplicas=120..."
    run_cmd kubectl --kubeconfig="${KUBECONFIG_PATH}" patch hpa "$LOG_NORMALIZER_DEP" -n "$NAMESPACE" --type='json' -p='[{"op": "replace", "path": "/spec/minReplicas", "value": 2}, {"op": "replace", "path": "/spec/maxReplicas", "value": 120}]'
}

# ==========================================
# Main Execution Flow
# ==========================================
stage_validation

case "$ACTION" in
    HPA_AND_ENV_UPDATE)
        action_hpa_and_env_update
        stage_verification
        ;;
    RUN_AUTOMATION_SCRIPT)
        action_run_automation_script
        ;;
    REVERT_HPA_AND_ENV)
        action_revert_hpa_and_env
        stage_verification
        ;;
    *)
        echo "ERROR: Unknown ACTION '$ACTION'." >&2
        usage
        ;;
esac

log "Kubernetes Maintenance Job finished successfully."
