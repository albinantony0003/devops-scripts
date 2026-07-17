#!/usr/bin/env bash
# ==============================================================================
# lib/inventory.sh
# S3 inventory fetcher and parser helpers.
#
# S3 layout expected:
#   s3://redpanda-config/<colour>/<cluster>/inventory.txt
#   s3://redpanda-config/<colour>/<cluster>/partition.txt
#   s3://redpanda-config/<colour>/<cluster>/topic.txt
#
# inventory.txt format (one entry per line):
#   <instance-id>  <private-ip>
#   e.g.  i-0abc123def456789a  10.0.1.25
#
# Source this file and call fetch_inventory first, then use the get_* helpers.
#   source "$(dirname "$0")/../lib/inventory.sh"
# ==============================================================================

readonly S3_BUCKET="redpanda-config"

# Temporary directory where inventory files are downloaded for this run.
INVENTORY_DIR=""

# ---------------------------------------------------------------------------
# fetch_inventory COLOUR CLUSTER_NAME
#   Downloads the three inventory files from S3 into a temp directory.
#   Sets the global INVENTORY_DIR variable.
# ---------------------------------------------------------------------------
fetch_inventory() {
    local colour="$1"
    local cluster="$2"

    INVENTORY_DIR=$(mktemp -d /tmp/redpanda-inventory-XXXXXX)
    local s3_prefix="s3://${S3_BUCKET}/${colour}/${cluster}"

    log_step "Fetching inventory from S3"
    log_info "Source : ${s3_prefix}/"
    log_info "Dest   : ${INVENTORY_DIR}/"

    for file in inventory.txt partition.txt topic.txt; do
        log_info "Downloading ${file} ..."
        if aws s3 cp "${s3_prefix}/${file}" "${INVENTORY_DIR}/${file}" --quiet; then
            log_success "Downloaded ${file}"
        else
            log_error "Failed to download '${file}' from ${s3_prefix}/${file}"
            exit 1
        fi
    done

    log_success "Inventory fetch complete."
}

# ---------------------------------------------------------------------------
# get_instance_ids
#   Reads column 1 of inventory.txt and returns space-separated instance IDs.
# ---------------------------------------------------------------------------
get_instance_ids() {
    _require_inventory
    tr -d '\r' < "${INVENTORY_DIR}/inventory.txt" | awk '{print $1}' | tr '\n' ' ' | xargs
}

# ---------------------------------------------------------------------------
# get_instance_ips
#   Reads column 2 of inventory.txt and returns space-separated private IPs.
# ---------------------------------------------------------------------------
get_instance_ips() {
    _require_inventory
    tr -d '\r' < "${INVENTORY_DIR}/inventory.txt" | awk '{print $2}' | tr '\n' ' ' | xargs
}

# ---------------------------------------------------------------------------
# get_first_ip
#   Returns the IP of the first instance in inventory.txt.
#   Used by actions that only need to operate on a single representative node
#   (e.g. config-update).
# ---------------------------------------------------------------------------
get_first_ip() {
    _require_inventory
    tr -d '\r' < "${INVENTORY_DIR}/inventory.txt" | awk 'NR==1{print $2}'
}

# ---------------------------------------------------------------------------
# get_topics
#   Returns all topic names from topic.txt (one per line → space-separated).
# ---------------------------------------------------------------------------
get_topics() {
    _require_inventory
    tr -d '\r' < "${INVENTORY_DIR}/topic.txt" | tr '\n' ' ' | xargs
}

# ---------------------------------------------------------------------------
# get_partitions
#   Returns all partition counts from partition.txt (one per line → space-sep).
# ---------------------------------------------------------------------------
get_partitions() {
    _require_inventory
    tr -d '\r' < "${INVENTORY_DIR}/partition.txt" | tr '\n' ' ' | xargs
}

# ---------------------------------------------------------------------------
# cleanup_inventory
#   Removes the temp directory created by fetch_inventory.
#   Register with: trap cleanup_inventory EXIT
# ---------------------------------------------------------------------------
cleanup_inventory() {
    if [[ -n "${INVENTORY_DIR:-}" && -d "${INVENTORY_DIR}" ]]; then
        rm -rf "${INVENTORY_DIR}"
    fi
}

# ---------------------------------------------------------------------------
# Internal guard — ensures fetch_inventory was called first.
# ---------------------------------------------------------------------------
_require_inventory() {
    if [[ -z "${INVENTORY_DIR:-}" || ! -d "${INVENTORY_DIR}" ]]; then
        log_error "Inventory not loaded. Call fetch_inventory before using get_* helpers."
        exit 1
    fi
}
