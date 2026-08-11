#!/usr/bin/env bash
# ==============================================================================
# actions/stop.sh
# Action: stop
# Sequence:
#   1. Traffic guard check (placeholder — set GREEN_TRAFFIC / BLUE_TRAFFIC env vars)
#   2. SSH to first node → run topic backup script
#   3. aws s3 sync backup output to Jenkins workspace
#   4. Stop all EC2 instances and wait for 'stopped' state
#
# Called by: redpanda-bootstrap.sh
# Expects globals:
#   INSTANCE_IDS   — space-separated EC2 instance IDs
#   FIRST_IP       — IP of the first/primary node (for topic backup SSH)
#   COLOUR         — used by traffic guard
#   SSH_USER, SSH_PORT, SSH_OPTS  (set in main script)
#   GREEN_TRAFFIC, BLUE_TRAFFIC   (Jenkins env vars, placeholder)
#   BACKUP_S3_BUCKET              (optional, defaults to s3://redpanda-config)
# ==============================================================================

action_stop() {
    local instance_ids="$1"
    local first_ip="$2"

    log_step "Action: STOP — Traffic Guard Check"

    # -------------------------------------------------------------------------
    # Traffic guard: refuse to stop instances if the selected colour side
    # still has live traffic.
    # Set GREEN_TRAFFIC=0 / BLUE_TRAFFIC=0 in Jenkins when traffic is drained.
    # -------------------------------------------------------------------------
    local traffic_value
    case "${COLOUR,,}" in
        green) traffic_value="${GREEN_TRAFFIC:-PLACEHOLDER}" ;;
        blue)  traffic_value="${BLUE_TRAFFIC:-PLACEHOLDER}"  ;;
    esac

    if [[ "${traffic_value}" == "PLACEHOLDER" ]]; then
        log_warn "Traffic variable for '${COLOUR^^}' is not configured."
        log_warn "Set GREEN_TRAFFIC or BLUE_TRAFFIC in Jenkins environment."
        log_warn "Proceeding without traffic guard (PLACEHOLDER mode)."
    elif [[ "${traffic_value}" -ne 0 ]]; then
        log_error "Active traffic detected on ${COLOUR^^} side (traffic = ${traffic_value})."
        log_error "Drain traffic from the ${COLOUR^^} side before stopping instances."
        exit 1
    else
        log_success "Traffic check passed (${COLOUR^^} traffic = ${traffic_value}). Safe to stop."
    fi

    # -------------------------------------------------------------------------
    # Step 1: SSH to first node and run topic backup
    # -------------------------------------------------------------------------
    log_step "Step 1: Topic Backup — SSH to ${first_ip}"

    if [[ -z "${first_ip}" ]]; then
        log_error "No IP available for topic backup. Cannot proceed."
        exit 1
    fi

    local remote_backup_script='
set -euo pipefail
BACKUP_DIR="/tmp/redpanda-topic-backup"
mkdir -p "${BACKUP_DIR}"
cd "${BACKUP_DIR}"

RED="\033[0;31m"
GREEN="\033[0;32m"
BLUE="\033[0;34m"
RESET="\033[0m"

echo -e "${BLUE}Generating List of Topics and Partition Count...${RESET}"
rpk topic list | awk '\''NR>1 {print $2}'\'' > partition.txt
rpk topic list | awk '\''NR>1 {print $1}'\'' > topic.txt
echo -e "${GREEN}List generated.${RESET}"

echo "BACKUP_DIR=${BACKUP_DIR}"
'

    log_info "Running topic backup on ${first_ip} ..."
    local backup_output
    if backup_output=$(ssh ${SSH_OPTS} "${SSH_USER}@${first_ip}" "${remote_backup_script}" 2>&1); then
        log_success "Topic backup completed on ${first_ip}"
        log_info "${backup_output}"
    else
        log_error "Topic backup script failed on ${first_ip}"
        exit 1
    fi

    # -------------------------------------------------------------------------
    # Step 2: Sync backup output from node to Jenkins workspace / S3
    # -------------------------------------------------------------------------
    log_step "Step 2: Sync Backup Output"

    local backup_s3_dest="${BACKUP_S3_BUCKET:-s3://redpanda-config}"
    local backup_local_dir="${WORKSPACE:-/tmp}/redpanda-backup-${COLOUR}-${CLUSTER_NAME}"

    log_info "Copying backup files from ${first_ip} to Jenkins workspace ..."
    # Extract the remote backup dir path from output
    local remote_dir
    remote_dir=$(echo "${backup_output}" | grep '^BACKUP_DIR=' | cut -d= -f2 || echo "/tmp/redpanda-topic-backup")

    mkdir -p "${backup_local_dir}"
    if scp ${SCP_OPTS} -r "${SSH_USER}@${first_ip}:${remote_dir}/*" "${backup_local_dir}/"; then
        log_success "Backup files copied to ${backup_local_dir}"
    else
        log_warn "SCP of backup files failed — continuing with stop (backup may be incomplete)."
    fi

    if [[ -n "${backup_s3_dest}" ]]; then
        log_info "Syncing backup to S3: ${backup_s3_dest}/${COLOUR}/${CLUSTER_NAME}/ ..."
        if aws s3 sync "${backup_local_dir}/" "${backup_s3_dest}/${COLOUR}/${CLUSTER_NAME}/"; then
            log_success "Backup synced to S3."
        else
            log_warn "S3 sync failed — backup remains locally at ${backup_local_dir}"
        fi
    else
        log_warn "BACKUP_S3_BUCKET not set. Skipping S3 sync. Files are in: ${backup_local_dir}"
    fi

    # -------------------------------------------------------------------------
    # Step 3: Stop all EC2 instances
    # -------------------------------------------------------------------------
    log_step "Step 3: Stopping EC2 Instances"
    log_info "Instance IDs: ${instance_ids}"

    for instance in ${instance_ids}; do
        log_info "Stopping instance: ${instance} ..."
        if aws ec2 stop-instances --instance-ids "${instance}" --output text --query 'StoppingInstances[0].CurrentState.Name'; then
            log_success "Stop command accepted for ${instance}"
        else
            log_error "Failed to issue stop command for ${instance}"
            exit 1
        fi
    done

    log_step "Waiting for all instances to reach 'stopped' state ..."
    if aws ec2 wait instance-stopped --instance-ids ${instance_ids}; then
        log_success "All instances are now stopped: ${instance_ids}"
    else
        log_error "Timed out waiting for instances to reach 'stopped' state."
        exit 1
    fi
}
