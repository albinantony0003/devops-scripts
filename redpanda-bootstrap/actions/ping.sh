#!/usr/bin/env bash
# ==============================================================================
# actions/ping.sh
# Action: ping
# Checks SSH connectivity (and optionally ICMP reachability) to every node
# in the cluster inventory.
#
# Called by: redpanda-bootstrap.sh
# Expects globals:
#   INSTANCE_IPS  — space-separated private IPs
#   SSH_USER, SSH_OPTS (set in main script)
# ==============================================================================

action_ping() {
    local instance_ips="$1"

    log_step "Action: PING — Connectivity Check"
    log_info "Target IPs: ${instance_ips}"

    if [[ -z "${instance_ips}" ]]; then
        log_error "No IPs provided. Cannot run ping."
        exit 1
    fi

    local pass=0
    local fail=0
    local results=()

    for ip in ${instance_ips}; do
        echo ""
        log_info "--- Checking node: ${ip} ---"

        # ── 1. ICMP ping (3 packets, 5-second timeout) ──────────────────────
        if ping -c 3 -W 5 "${ip}" > /dev/null 2>&1; then
            log_success "[${ip}] ICMP ping: REACHABLE"
            icmp_status="PASS"
        else
            log_warn    "[${ip}] ICMP ping: UNREACHABLE (may be filtered by security group)"
            icmp_status="FAIL"
        fi

        # ── 2. SSH connectivity check (banner grab, no command executed) ─────
        if ssh ${SSH_OPTS} \
               -o ConnectTimeout=10 \
               -o BatchMode=yes \
               "${SSH_USER}@${ip}" "echo SSH_OK" 2>/dev/null | grep -q "SSH_OK"; then
            log_success "[${ip}] SSH connectivity: OK"
            ssh_status="PASS"
            (( pass++ )) || true
        else
            log_error   "[${ip}] SSH connectivity: FAILED"
            ssh_status="FAIL"
            (( fail++ )) || true
        fi

        results+=("${ip}  ICMP=${icmp_status}  SSH=${ssh_status}")
    done

    # ── Summary table ─────────────────────────────────────────────────────────
    echo ""
    log_step "Ping Summary"
    printf "  %-20s %-12s %-10s\n" "IP" "ICMP" "SSH"
    printf "  %-20s %-12s %-10s\n" "--------------------" "------------" "----------"
    for row in "${results[@]}"; do
        # re-parse for formatted output
        r_ip=$(echo "$row"   | awk '{print $1}')
        r_icmp=$(echo "$row" | grep -oP 'ICMP=\K\S+')
        r_ssh=$(echo "$row"  | grep -oP 'SSH=\K\S+')
        printf "  %-20s %-12s %-10s\n" "${r_ip}" "${r_icmp}" "${r_ssh}"
    done
    echo ""

    if [[ "${fail}" -gt 0 ]]; then
        log_error "${fail} node(s) failed SSH connectivity check."
        exit 1
    else
        log_success "All ${pass} node(s) are reachable via SSH."
    fi
}
