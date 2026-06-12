#!/usr/bin/env bash
# ==============================================================================
# Script: maintenance_dev.sh
# Description: Toggles maintenance mode for a single dev application running
#              on a Dev Kubernetes cluster behind a CloudFront distribution.
# ==============================================================================
set -euo pipefail

# --- Configuration (Hardcoded Dev Settings) ---
ACTION="${ACTION:-}"
CLOUDFRONT_DISTRIBUTION_ID="E3ERCJKAXY7MTT"
ENV_VAR_NAME="POSTGRES_DB_URL"

# --- Dev Kubernetes Cluster Configuration ---
KUBEPATH="/opt/k8s-creds/dz-dev"
K8S_NAMESPACE="dz-development"
K8S_DEPLOYMENT_NAME="dz-admin-backend"

# --- Endpoints & Patterns ---
MAINTENANCE_PATH_PATTERN="*"
NORMAL_PATH_PATTERN="/disabled"
DB_READER_ENDPOINT="jdbc:postgresql://dev-rds-instance-1.cuom2a41sun8.us-east-1.rds.amazonaws.com:5432/postgres?ssl=true&sslmode=require"
DB_WRITER_ENDPOINT="jdbc:postgresql://dz-postgresrds:5432/postgres?ssl=true&sslmode=require"

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
echo -e "${BOLD}${CYAN}          K8S & CLOUDFRONT DEV MAINTENANCE ORCHESTRATOR           ${NC}"
echo -e "${BOLD}${CYAN}======================================================================${NC}"
echo -e "  Action Target:     ${BOLD}${ACTION}${NC}"
echo -e "  CloudFront ID:     ${BOLD}${CLOUDFRONT_DISTRIBUTION_ID}${NC}"
echo -e "  K8s Deployment:    ${BOLD}${K8S_DEPLOYMENT_NAME}${NC} , Namespace: ${BOLD}${K8S_NAMESPACE} ${NC}"
echo -e "  Database Var:      ${BOLD}${ENV_VAR_NAME}${NC}"
echo -e "${CYAN}----------------------------------------------------------------------${NC}"

# 2. Update AWS CloudFront Cache Behavior
log_step "Updating AWS CloudFront CDN (Dev)..."
log_info "Fetching current dev distribution configuration..."
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
log_success "Dev CloudFront distribution successfully deployed."

# 3. Update Kubernetes Deployment Environment Variable
log_step "Updating Kubernetes Resources (Dev)..."

log_info "Updating Dev deployment '${K8S_DEPLOYMENT_NAME}' variable '${ENV_VAR_NAME}' to '${TARGET_DB}'..."
kubectl set env deployment/"${K8S_DEPLOYMENT_NAME}" \
    --kubeconfig "$KUBEPATH" \
    -n "${K8S_NAMESPACE}" \
    -c "${K8S_DEPLOYMENT_NAME}" \
    "${ENV_VAR_NAME}"="${TARGET_DB}"

log_info "Monitoring Dev rollout status..."
kubectl rollout status deployment/"${K8S_DEPLOYMENT_NAME}" \
    --kubeconfig "$KUBEPATH" \
    -n "${K8S_NAMESPACE}"
log_success "Dev deployment rollout complete."

# 4. Create CloudFront Cache Invalidation
log_step "Purging Dev CDN Edge Caches..."
log_info "Submitting invalidation request for /*..."
aws cloudfront create-invalidation --distribution-id "${CLOUDFRONT_DISTRIBUTION_ID}" --paths "/*" > /dev/null
log_success "Dev edge cache invalidation submitted."

# --- Success Screen Banner ---
echo -e "\n${BOLD}${GREEN}======================================================================${NC}"
log_success "Dev Maintenance Mode successfully toggled to ${ACTION}!"
echo -e "${BOLD}${GREEN}======================================================================${NC}"
