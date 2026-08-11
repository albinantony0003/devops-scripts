#!/usr/bin/env bash
# ==============================================================================
# actions/restart.sh
# Action: restart-redpanda
# Restarts the Redpanda service on every node via SSH, then verifies it is
# active before moving on to the next node.
#
# Called by: redpanda-bootstrap.sh
# Expects globals:
#   INSTANCE_IPS  — space-separated private IPs
#   SSH_USER, SSH_OPTS (set in main script)
# ==============================================================================

action_restart() {
    local instance_ips="$1"

    log_step "Action: RESTART-REDPANDA — All Nodes"
    log_info "Target IPs: ${instance_ips}"

    if [[ -z "${instance_ips}" ]]; then
        log_error "No IPs provided. Cannot restart Redpanda."
        exit 1
    fi

    local pass=0
    local fail=0

    local restart_script='
set -euo pipefail
echo ">>> Restarting Redpanda service ..."
sudo systemctl restart redpanda

echo ">>> Waiting for Redpanda to become active ..."
for i in $(seq 1 12); do
    if systemctl is-active --quiet redpanda; then
        echo ">>> Redpanda is active (attempt ${i})."
        exit 0
    fi
    echo "    ... not active yet (attempt ${i}/12), retrying in 5s ..."
    sleep 5
done

echo "ERROR: Redpanda did not become active within 60 seconds."
systemctl status redpanda --no-pager || true
exit 1
'

    local pids=()
    local ips_array=()

    for ip in ${instance_ips}; do
        log_info "--- Starting Redpanda restart on: ${ip} (background) ---"
        
        # Run the SSH command in the background
        ssh ${SSH_OPTS} "${SSH_USER}@${ip}" "${restart_script}" &
        
        # Store PID and corresponding IP to evaluate results later
        pids+=($!)
        ips_array+=("$ip")
    done

    echo ""
    log_info "Waiting for all nodes to complete restart process..."

    # Wait for each background job and capture its exit status
    for i in "${!pids[@]}"; do
        if wait "${pids[$i]}"; then
            log_success "Redpanda restarted and active on ${ips_array[$i]}"
            (( pass++ )) || true
        else
            log_error "Redpanda restart failed or service did not become active on ${ips_array[$i]}"
            (( fail++ )) || true
        fi
    done

    echo ""
    log_step "Restart Summary"
    log_info "Nodes succeeded : ${pass}"
    log_info "Nodes failed    : ${fail}"

    if [[ "${fail}" -gt 0 ]]; then
        log_error "${fail} node(s) failed to restart Redpanda. Review logs above."
        exit 1
    else
        log_success "Redpanda restarted successfully on all ${pass} node(s)."
    fi
}
