#!/usr/bin/env bash
# ==============================================================================
# Script: maintenance.sh
# Description: Toggles maintenance mode for two applications running on Blue/Green
#              Kubernetes clusters behind an AWS CloudFront distribution.
# ==============================================================================
set -euo pipefail

# --- Configuration (Hardcoded Settings) ---
ACTION="${ACTION:-}"
CLOUDFRONT_DISTRIBUTION_ID="E1234567890ABC"
ENV_VAR_NAME="DATABASE_URL"
NOTIFY_TEAM="${NOTIFY_TEAM:-false}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"


# --- Blue Kubernetes Cluster Configuration ---
KUBEPATH_BLUE="blue-cluster-context"
K8S_NAMESPACE_BLUE="production"
K8S_DEPLOYMENT_BLUE_NAME="my-app-deployment"

# --- Green Kubernetes Cluster Configuration ---
KUBEPATH_GREEN="green-cluster-context"
K8S_NAMESPACE_GREEN="production"
K8S_DEPLOYMENT_GREEN_NAME="my-other-app-deployment"

# --- Endpoints & Patterns ---
MAINTENANCE_PATH_PATTERN="*"
NORMAL_PATH_PATTERN="/down"
DB_READER_ENDPOINT="jdbc:postgresql://reader:5432/postgres?ssl=true&sslmode=require"
DB_WRITER_ENDPOINT="jdbc:postgresql://writer:5432/postgres?ssl=true&sslmode=require"

# --- Modern Styling System (ANSI Colors) ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Indicators & Icons
INFO_ICON="${BLUE}➜${NC}"
SUCCESS_ICON="${GREEN}✔${NC}"
WARNING_ICON="${YELLOW}⚠${NC}"
ERROR_ICON="${RED}✖${NC}"
STEP_ICON="${MAGENTA}❖${NC}"

log_step()    { echo -e "\n${STEP_ICON}  ${BOLD}${MAGENTA}$1${NC}"; }
log_info()    { echo -e "  ${INFO_ICON}  $1"; }
log_success() { echo -e "  ${SUCCESS_ICON}  ${GREEN}$1${NC}"; }
log_warn()    { echo -e "  ${WARNING_ICON}  ${YELLOW}$1${NC}"; }
log_error()   { echo -e "  ${ERROR_ICON}  ${RED}${BOLD}$1${NC}" >&2; }

# 1. Validation
if [[ -z "${ACTION}" || -z "${CLOUDFRONT_DISTRIBUTION_ID}" ]]; then
    log_error "ACTION and CLOUDFRONT_DISTRIBUTION_ID are required."
    exit 1
fi

ACTION=$(echo "${ACTION}" | tr '[:lower:]' '[:upper:]')
if [[ "${ACTION}" != "ENABLE" && "${ACTION}" != "DISABLE" ]]; then
    log_error "ACTION must be either ENABLE or DISABLE."
    exit 1
fi

# Set targets based on selected ACTION
if [ "${ACTION}" = "ENABLE" ]; then
    TARGET_PATTERN="${MAINTENANCE_PATH_PATTERN}"
    TARGET_DB="${DB_READER_ENDPOINT}"
else
    TARGET_PATTERN="${NORMAL_PATH_PATTERN}"
    TARGET_DB="${DB_WRITER_ENDPOINT}"
fi

# Ensure clean up of temporary JSON files on exit
cleanup() {
    rm -f config.json dist-config.json modified-config.json
}
trap cleanup EXIT

# --- Start Screen Header ---
echo -e "${BOLD}${CYAN}======================================================================${NC}"
echo -e "${BOLD}${CYAN}          K8S & CLOUDFRONT MAINTENANCE MODE ORCHESTRATOR               ${NC}"
echo -e "${BOLD}${CYAN}======================================================================${NC}"
echo -e "  Action Target:     ${BOLD}${ACTION}${NC}"
echo -e "  CloudFront ID:     ${BOLD}${CLOUDFRONT_DISTRIBUTION_ID}${NC}"
echo -e "  Blue Deployment:   ${BOLD}${K8S_DEPLOYMENT_BLUE_NAME}${NC} , Namespace: ${BOLD}${K8S_NAMESPACE_BLUE}${NC}"
echo -e "  Green Deployment:  ${BOLD}${K8S_DEPLOYMENT_GREEN_NAME}${NC} , Namespace: ${BOLD}${K8S_NAMESPACE_GREEN}${NC}"
echo -e "  Database Var:      ${BOLD}${ENV_VAR_NAME}${NC}"
echo -e "${CYAN}----------------------------------------------------------------------${NC}"

# 2. Update AWS CloudFront Cache Behavior
log_step "Updating AWS CloudFront CDN..."
log_info "Fetching current distribution configuration..."
aws cloudfront get-distribution-config --id "${CLOUDFRONT_DISTRIBUTION_ID}" > config.json
ETAG=$(jq -r '.ETag' config.json)
jq '.DistributionConfig' config.json > dist-config.json

if [ "$(jq '.CacheBehaviors.Quantity' dist-config.json)" -eq 0 ]; then
    log_error "No custom cache behaviors found in CloudFront configuration. A precedence 0 behavior is required."
    exit 1
fi

log_info "Modifying path pattern in cache behavior precedence 0 to: '${TARGET_PATTERN}'"
jq ".CacheBehaviors.Items[0].PathPattern = \"${TARGET_PATTERN}\"" dist-config.json > modified-config.json

aws cloudfront update-distribution \
    --id "${CLOUDFRONT_DISTRIBUTION_ID}" \
    --if-match "${ETAG}" \
    --distribution-config file://modified-config.json > /dev/null

log_info "Waiting for CloudFront deployment to finish (this may take a few minutes)..."
aws cloudfront wait distribution-deployed --id "${CLOUDFRONT_DISTRIBUTION_ID}"
log_success "CloudFront distribution successfully deployed."

# 3. Update Kubernetes Deployment Environment Variable
log_step "Updating Kubernetes Resources..."

# --- Update Blue Cluster ---
log_info "Updating Blue Cluster: deployment '${K8S_DEPLOYMENT_BLUE_NAME}' variable '${ENV_VAR_NAME}' to '${TARGET_DB}'..."
kubectl set env deployment/"${K8S_DEPLOYMENT_BLUE_NAME}" \
    --kubeconfig="${KUBEPATH_BLUE}" \
    -n "${K8S_NAMESPACE_BLUE}" \
    -c "${K8S_DEPLOYMENT_BLUE_NAME}" \
    "${ENV_VAR_NAME}"="${TARGET_DB}"

log_info "Monitoring Blue Cluster rollout status..."
kubectl rollout status deployment/"${K8S_DEPLOYMENT_BLUE_NAME}" \
    --kubeconfig="${KUBEPATH_BLUE}" \
    -n "${K8S_NAMESPACE_BLUE}"
log_success "Blue cluster deployment rollout complete."

# --- Update Green Cluster ---
log_info "Updating Green Cluster: deployment '${K8S_DEPLOYMENT_GREEN_NAME}' variable '${ENV_VAR_NAME}' to '${TARGET_DB}'..."
kubectl set env deployment/"${K8S_DEPLOYMENT_GREEN_NAME}" \
    --kubeconfig="${KUBEPATH_GREEN}" \
    -n "${K8S_NAMESPACE_GREEN}" \
    -c "${K8S_DEPLOYMENT_GREEN_NAME}" \
    "${ENV_VAR_NAME}"="${TARGET_DB}"

log_info "Monitoring Green Cluster rollout status..."
kubectl rollout status deployment/"${K8S_DEPLOYMENT_GREEN_NAME}" \
    --kubeconfig="${KUBEPATH_GREEN}" \
    -n "${K8S_NAMESPACE_GREEN}"
log_success "Green cluster deployment rollout complete."

# 4. Create CloudFront Cache Invalidation
log_step "Purging CDN Edge Caches..."
log_info "Submitting invalidation request for /*..."
aws cloudfront create-invalidation --distribution-id "${CLOUDFRONT_DISTRIBUTION_ID}" --paths "/*" > /dev/null
log_success "Edge cache invalidation submitted."

# --- Success Screen Banner ---
echo -e "\n${BOLD}${GREEN}======================================================================${NC}"
log_success "Maintenance Mode successfully toggled to ${ACTION}!"
echo -e "${BOLD}${GREEN}======================================================================${NC}"

# --- SUCCESSFUL EXECUTION SLACK NOTIFICATION ---
if [ "${NOTIFY_TEAM}" = "TRUE" ]; then
    if [ -z "${SLACK_WEBHOOK_URL}" ]; then
        log_warn "Slack notification is enabled, but SLACK_WEBHOOK_URL is not configured."
    else
        log_info "Sending execution notification to Slack..."
        if [ "${ACTION}" = "ENABLE" ]; then
            TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S %Z")
            MESSAGE="*📢 Release Alert* : *🚀Production release initiated at \`${TIMESTAMP}\`* | 🚧 Admin Frontend is now in *Maintenance Mode* 🔒"
        elif [ "${ACTION}" = "DISABLE" ]; then
            TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S %Z")
            MESSAGE="*📢 Release Alert* : ✅ *Traffic switch completed successfully!* 🔓 Admin Frontend is back online 🟢 at \`${TIMESTAMP}\`."
        fi

        # Safely construct JSON payload using jq and send to Slack
        PAYLOAD=$(jq -n --arg msg "$MESSAGE" '{text: $msg}')
        if curl -s -f -X POST -H 'Content-type: application/json' \
          --data "$PAYLOAD" \
          "$SLACK_WEBHOOK_URL" > /dev/null; then
            log_success "Slack notification sent successfully."
        else
            log_warn "Failed to send Slack notification."
        fi
    fi
else
    log_info "Slack notification skipped because NOTIFY_TEAM is not set to true."
fi
