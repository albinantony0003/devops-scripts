#!/usr/bin/env bash
# ==============================================================================
# actions/start.sh
# Action: start
# Starts all EC2 instances belonging to the selected colour/cluster.
#
# Called by: redpanda-bootstrap.sh
# Expects globals: INSTANCE_IDS (space-separated EC2 instance IDs)
# ==============================================================================

action_start() {
    local instance_ids="$1"

    log_step "Action: START — EC2 Instances"
    log_info "Instance IDs : ${instance_ids}"

    if [[ -z "${instance_ids}" ]]; then
        log_error "No instance IDs provided. Cannot start instances."
        exit 1
    fi

    # Start each instance individually so we get per-instance feedback
    for instance in ${instance_ids}; do
        log_info "Starting instance: ${instance} ..."
        if aws ec2 start-instances --instance-ids "${instance}" --output text --query 'StartingInstances[0].CurrentState.Name'; then
            log_success "Start command accepted for ${instance}"
        else
            log_error "Failed to issue start command for ${instance}"
            exit 1
        fi
    done

    log_step "Waiting for all instances to reach 'running' state ..."
    if aws ec2 wait instance-running --instance-ids ${instance_ids}; then
        log_success "All instances are now running: ${instance_ids}"
    else
        log_error "Timed out waiting for instances to reach 'running' state."
        exit 1
    fi
}
