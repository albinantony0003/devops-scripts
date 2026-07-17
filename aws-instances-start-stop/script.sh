#!/bin/bash
# =============================================================================
# AWS EC2 Instance Start/Stop Script
# Intended to be triggered by a Jenkins job with the following parameters:
#   ACTION        - "start" or "stop"
#   COLOUR        - "green" or "blue"   (Production environment colour)
#   CLUSTER_NAME  - "core", "ingest", "analytics", or "all"
#   GREEN_TRAFFIC - Current traffic count/metric on the Green side (integer)
#   BLUE_TRAFFIC  - Current traffic count/metric on the Blue side  (integer)
#
# Colour determines which set of instance IDs to operate on.
# Each colour maintains its own separate group of instances.
# Before stopping instances the script checks whether the selected
# colour still has live traffic; if so it aborts to prevent data loss.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Instance ID Groups — GREEN environment
# -----------------------------------------------------------------------------
GREEN_CORE_INSTANCES="i-0green111 i-0green222 i-0green333"
GREEN_INGEST_INSTANCES="i-0green444 i-0green555 i-0green666"
GREEN_ANALYTICS_INSTANCES="i-0green777 i-0green888 i-0green999"
GREEN_ALL_INSTANCES="$GREEN_CORE_INSTANCES $GREEN_INGEST_INSTANCES $GREEN_ANALYTICS_INSTANCES"

# -----------------------------------------------------------------------------
# Instance ID Groups — BLUE environment
# -----------------------------------------------------------------------------
BLUE_CORE_INSTANCES="i-0blue1111 i-0blue2222 i-0blue3333"
BLUE_INGEST_INSTANCES="i-0blue4444 i-0blue5555 i-0blue6666"
BLUE_ANALYTICS_INSTANCES="i-0blue7777 i-0blue8888 i-0blue9999"
BLUE_ALL_INSTANCES="$BLUE_CORE_INSTANCES $BLUE_INGEST_INSTANCES $BLUE_ANALYTICS_INSTANCES"

# -----------------------------------------------------------------------------
# Validate required Jenkins parameters
# -----------------------------------------------------------------------------
: "${ACTION:?ERROR: Jenkins parameter ACTION is not set. Use 'start' or 'stop'.}"
: "${COLOUR:?ERROR: Jenkins parameter COLOUR is not set. Use 'green' or 'blue'.}"
: "${CLUSTER_NAME:?ERROR: Jenkins parameter CLUSTER_NAME is not set. Use 'core', 'ingest', 'analytics', or 'all'.}"
: "${GREEN_TRAFFIC:?ERROR: Jenkins parameter GREEN_TRAFFIC is not set. Provide current traffic count for the Green side.}"
: "${BLUE_TRAFFIC:?ERROR: Jenkins parameter BLUE_TRAFFIC is not set. Provide current traffic count for the Blue side.}"

# -----------------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------------
start_instances() {
    local instance_ids="$1"
    echo ">>> Starting instances: $instance_ids"
    for instance in $instance_ids; do
        echo "  Starting $instance ..."
        aws ec2 start-instances --instance-ids "$instance"
    done
    echo ">>> Waiting for instances to reach 'running' state ..."
    aws ec2 wait instance-running --instance-ids $instance_ids
    echo ">>> All instances are now running."
}

stop_instances() {
    local instance_ids="$1"

    # -------------------------------------------------------------------------
    # Traffic guard: refuse to stop instances if the selected colour side
    # still has live traffic.
    # -------------------------------------------------------------------------
    local traffic_value
    case "${COLOUR,,}" in
        green) traffic_value="$GREEN_TRAFFIC" ;;
        blue)  traffic_value="$BLUE_TRAFFIC"  ;;
    esac

    if [[ "$traffic_value" -ne 0 ]]; then
        echo "ERROR: Detected active traffic on the ${COLOUR^^} side (traffic = $traffic_value)."
        echo "       Stopping instances while traffic is live is not allowed."
        echo "       Please drain traffic from the ${COLOUR^^} side before stopping."
        exit 1
    fi

    echo ">>> Traffic check passed (${COLOUR^^} traffic = $traffic_value). Proceeding with stop."
    echo ">>> Stopping instances: $instance_ids"
    for instance in $instance_ids; do
        echo "  Stopping $instance ..."
        aws ec2 stop-instances --instance-ids "$instance"
    done
    echo ">>> Waiting for instances to reach 'stopped' state ..."
    aws ec2 wait instance-stopped --instance-ids $instance_ids
    echo ">>> All instances are now stopped."
}

perform_action() {
    local instance_ids="$1"
    case "$ACTION" in
        start)
            start_instances "$instance_ids"
            ;;
        stop)
            stop_instances "$instance_ids"
            ;;
        *)
            echo "ERROR: Invalid ACTION '$ACTION'. Use 'start' or 'stop'."
            exit 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Resolve instance IDs based on COLOUR + CLUSTER_NAME
# -----------------------------------------------------------------------------
echo "=== AWS EC2 Instance Manager ==="
echo "ACTION        : $ACTION"
echo "COLOUR        : $COLOUR"
echo "CLUSTER_NAME  : $CLUSTER_NAME"
echo "GREEN_TRAFFIC : $GREEN_TRAFFIC"
echo "BLUE_TRAFFIC  : $BLUE_TRAFFIC"
echo "================================"

# Select the correct instance group for the chosen colour
case "${COLOUR,,}" in   # lowercase comparison
    green)
        case "${CLUSTER_NAME,,}" in
            core)
                perform_action "$GREEN_CORE_INSTANCES"
                ;;
            ingest)
                perform_action "$GREEN_INGEST_INSTANCES"
                ;;
            analytics)
                perform_action "$GREEN_ANALYTICS_INSTANCES"
                ;;
            all)
                perform_action "$GREEN_ALL_INSTANCES"
                ;;
            *)
                echo "ERROR: Invalid CLUSTER_NAME '$CLUSTER_NAME'. Use 'core', 'ingest', 'analytics', or 'all'."
                exit 1
                ;;
        esac
        ;;
    blue)
        case "${CLUSTER_NAME,,}" in
            core)
                perform_action "$BLUE_CORE_INSTANCES"
                ;;
            ingest)
                perform_action "$BLUE_INGEST_INSTANCES"
                ;;
            analytics)
                perform_action "$BLUE_ANALYTICS_INSTANCES"
                ;;
            all)
                perform_action "$BLUE_ALL_INSTANCES"
                ;;
            *)
                echo "ERROR: Invalid CLUSTER_NAME '$CLUSTER_NAME'. Use 'core', 'ingest', 'analytics', or 'all'."
                exit 1
                ;;
        esac
        ;;
    *)
        echo "ERROR: Invalid COLOUR '$COLOUR'. Use 'green' or 'blue'."
        exit 1
        ;;
esac

echo "=== Done ==="