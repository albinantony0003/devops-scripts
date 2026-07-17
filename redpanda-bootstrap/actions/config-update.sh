#!/usr/bin/env bash
# ==============================================================================
# actions/config-update.sh
# Action: config-update
# Applies Redpanda cluster configuration and recreates topics on a single
# representative node (first IP in the inventory).
#
# Sequence:
#   1. SCP topic.txt and partition.txt from the downloaded inventory to the node
#   2. SSH: apply rpk cluster config settings
#   3. SSH: create __consumer_offsets topic (idempotent)
#   4. SSH: recreate all application topics from topic.txt / partition.txt
#
# Called by: redpanda-bootstrap.sh
# Expects globals:
#   FIRST_IP      — IP of the single target node
#   SSH_USER, SSH_OPTS, SCP_OPTS (set in main script)
#   INVENTORY_DIR — path to downloaded inventory files (set by inventory.sh)
# ==============================================================================

# Partition count for __consumer_offsets — cluster-specific defaults.
# Override via Jenkins env vars: CORE_PARTITIONS, INGEST_PARTITIONS, ANALYTICS_PARTITIONS
CORE_PARTITIONS="${CORE_PARTITIONS:-77}"
INGEST_PARTITIONS="${INGEST_PARTITIONS:-55}"
ANALYTICS_PARTITIONS="${ANALYTICS_PARTITIONS:-16}"

action_config_update() {
    local first_ip="$1"

    log_step "Action: CONFIG-UPDATE — Single Node (${first_ip})"

    if [[ -z "${first_ip}" ]]; then
        log_error "No target IP available for config-update."
        exit 1
    fi

    # Resolve __consumer_offsets partition count from cluster name
    local partitions
    case "${CLUSTER_NAME,,}" in
        core)      partitions="${CORE_PARTITIONS}"      ;;
        ingest)    partitions="${INGEST_PARTITIONS}"    ;;
        analytics) partitions="${ANALYTICS_PARTITIONS}" ;;
        *)
            log_error "Unknown CLUSTER_NAME '${CLUSTER_NAME}' — cannot resolve partition count."
            exit 1
            ;;
    esac

    log_info "Target node       : ${first_ip}"
    log_info "Cluster           : ${CLUSTER_NAME}"
    log_info "Offset partitions : ${partitions}"

    # ── Step 1: SCP inventory files to node ───────────────────────────────────
    log_step "Step 1: Copy topic/partition files to ${first_ip}"

    local topic_file="${INVENTORY_DIR}/topic.txt"
    local partition_file="${INVENTORY_DIR}/partition.txt"

    if [[ ! -f "${topic_file}" || ! -f "${partition_file}" ]]; then
        log_error "topic.txt or partition.txt missing from inventory dir: ${INVENTORY_DIR}"
        exit 1
    fi

    log_info "Copying topic.txt and partition.txt to ${first_ip}:/tmp/ ..."
    if scp ${SCP_OPTS} "${topic_file}" "${partition_file}" "${SSH_USER}@${first_ip}:/tmp/"; then
        log_success "Files copied successfully."
    else
        log_error "Failed to SCP files to ${first_ip}."
        exit 1
    fi

    # ── Step 2: Apply rpk cluster config settings ──────────────────────────────
    log_step "Step 2: Apply Redpanda cluster configuration on ${first_ip}"

    local config_script='
set -euo pipefail
echo ">>> Applying Redpanda cluster configuration ..."
rpk cluster config set auto_create_topics_enabled true
rpk cluster config set enable_idempotence false
rpk cluster config set default_topic_replications 3
rpk cluster config set default_topic_partitions 3
rpk cluster config set delete_retention_ms 259200000
rpk cluster config set log_segment_ms 259200000
rpk cluster config set enable_rack_awareness true
echo ">>> Cluster configuration applied."
'
    if ssh ${SSH_OPTS} "${SSH_USER}@${first_ip}" "${config_script}"; then
        log_success "Cluster config applied on ${first_ip}."
    else
        log_error "Failed to apply cluster config on ${first_ip}."
        exit 1
    fi

    # ── Step 3: Create __consumer_offsets topic ────────────────────────────────
    log_step "Step 3: Create '__consumer_offsets' topic (${partitions} partitions)"

    local create_offsets_cmd="rpk topic create __consumer_offsets \
--partitions ${partitions} \
--replicas 3 \
--topic-config cleanup.policy=compact \
--topic-config retention.ms=1728000000 \
--topic-config segment.ms=1728000000"

    log_info "Running: ${create_offsets_cmd}"
    if ssh ${SSH_OPTS} "${SSH_USER}@${first_ip}" "${create_offsets_cmd}"; then
        log_success "'__consumer_offsets' topic configured."
    else
        log_warn "'__consumer_offsets' creation returned non-zero (topic may already exist — continuing)."
    fi

    # ── Step 4: Recreate application topics from inventory files ───────────────
    log_step "Step 4: Recreate application topics from inventory"

    local recreate_script='
set -euo pipefail
cd /tmp

if [[ ! -f topic.txt || ! -f partition.txt ]]; then
    echo "ERROR: topic.txt or partition.txt missing from /tmp"
    exit 1
fi

mapfile -t topics     < topic.txt
mapfile -t partitions < partition.txt

if [[ ${#topics[@]} -ne ${#partitions[@]} ]]; then
    echo "ERROR: topic count (${#topics[@]}) != partition count (${#partitions[@]})"
    exit 1
fi

echo ">>> Recreating ${#topics[@]} topics ..."
for i in "${!topics[@]}"; do
    topic=$(echo "${topics[$i]}"     | tr -d "\r\n " )
    parts=$(echo "${partitions[$i]}" | tr -d "\r\n " )
    if [[ -n "$topic" && -n "$parts" ]]; then
        echo "  Creating: ${topic}  (partitions=${parts})"
        rpk topic create "${topic}" --partitions "${parts}" || true
    fi
done
echo ">>> Topics recreated."

# Cleanup uploaded files
rm -f /tmp/topic.txt /tmp/partition.txt
'
    if ssh ${SSH_OPTS} "${SSH_USER}@${first_ip}" "${recreate_script}"; then
        log_success "All topics recreated on ${first_ip}."
    else
        log_error "Topic recreation failed on ${first_ip}."
        exit 1
    fi
}
