#!/usr/bin/env bash
# ==============================================================================
# actions/disk-mount-tune.sh
# Action: disk-mount-tune
# Copies the disk-mounting-tune script to every node and executes it remotely
# (requires root/sudo on the target — the script manages NVMe mount + XFS format
#  + Redpanda tuning via rpk).
#
# Called by: redpanda-bootstrap.sh
# Expects globals:
#   INSTANCE_IPS  — space-separated private IPs
#   SSH_USER, SSH_OPTS, SCP_OPTS (set in main script)
#   SCRIPT_DIR    — absolute path to the redpanda-bootstrap repo root
# ==============================================================================

action_disk_mount_tune() {
    local instance_ips="$1"

    log_step "Action: DISK-MOUNT-TUNE — All Nodes"
    log_info "Target IPs: ${instance_ips}"

    if [[ -z "${instance_ips}" ]]; then
        log_error "No IPs provided. Cannot run disk-mount-tune."
        exit 1
    fi

    local remote_script='
set -euo pipefail
exec > >(tee  /var/log/redpanda-userdata.log) 2>&1
echo "================= redpanda instance-store init: $(date -u) ================="

echo "=== Scanning for NVMe instance storage devices... ==="
DEVICE=$(nvme list | awk '\''/Instance Storage/ {print $1; exit}'\'')

if [ -z "${DEVICE:-}" ]; then
    echo "    --- ERROR: no instance store NVMe device found ---" >&2
    exit 1
fi
echo "=== Using device: $DEVICE ==="

echo "=== Creating target directory for Redpanda storage (/mnt/vectorized)... ==="
mkdir -p /mnt/vectorized

echo "=== Checking if filesystem exists on $DEVICE... ==="
if ! blkid "$DEVICE" >/dev/null 2>&1; then
    echo "    --- No filesystem found on $DEVICE, formatting as XFS ---"
    echo "    --- Formatting $DEVICE as XFS... ---"
    mkfs.xfs -f "$DEVICE"
else
    echo "    --- $DEVICE already has a filesystem, skipping mkfs (data preserved) ---"
fi

echo "=== Checking if /mnt/vectorized is already mounted... ==="
if mountpoint -q /mnt/vectorized; then
    echo "    --- /mnt/vectorized is already mounted, skipping mount. ---"
else
    echo "    --- Mounting $DEVICE to /mnt/vectorized... ---"
    mount "$DEVICE" /mnt/vectorized
fi

echo "=== Verifying that the mount succeeded... ==="
if ! mountpoint -q /mnt/vectorized; then
    echo "    --- ERROR: mount failed, aborting before touching redpanda ---" >&2
    exit 1
fi

echo "=== Setting ownership of /mnt/vectorized to the redpanda user... ==="
chown -R redpanda:redpanda /mnt/vectorized

echo "===  Redpanda Cluster Configuration tuning ==="
rpk redpanda mode prod

rpk redpanda tune all -r /mnt/vectorized

systemctl start redpanda
'

    local pass=0
    local fail=0

    local pids=()
    local ips=()

    for ip in ${instance_ips}; do
        echo ""
        log_info "--- Processing node: ${ip} (background) ---"
        log_info "Executing disk-mount-tune on ${ip} ..."

        # ── Execute inline script on remote node (requires sudo) ──────────────
        (
            if echo "${remote_script}" | ssh ${SSH_OPTS} "${SSH_USER}@${ip}" "sudo bash"; then
                exit 0
            else
                exit 1
            fi
        ) &
        pids+=($!)
        ips+=("${ip}")
    done

    # Wait for any remaining background jobs
    for i in "${!pids[@]}"; do
        if wait "${pids[$i]}"; then
            log_success "disk-mount-tune completed successfully on ${ips[$i]}"
            (( pass++ )) || true
        else
            log_error "disk-mount-tune failed on ${ips[$i]}"
            (( fail++ )) || true
        fi
    done

    echo ""
    log_step "Disk-Mount-Tune Summary"
    log_info "Nodes succeeded : ${pass}"
    log_info "Nodes failed    : ${fail}"

    if [[ "${fail}" -gt 0 ]]; then
        log_error "${fail} node(s) failed disk-mount-tune. Review logs above."
        exit 1
    else
        log_success "disk-mount-tune completed on all ${pass} node(s)."
    fi
}
