#!/usr/bin/env bash
# =============================================================================
# wait-for-argocd.sh — Poll ArgoCD until app is Synced + Healthy
#
# Usage:
#   ./scripts/wait-for-argocd.sh \
#     --app api-service-dev \
#     --timeout 300 \
#     --argocd-url https://argocd.internal.example.com \
#     --auth-token $ARGOCD_AUTH_TOKEN
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✔]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✘]${NC} $*" >&2; exit 1; }
info() { echo -e "${CYAN}[→]${NC} $*"; }

APP_NAME=""
TIMEOUT=300
ARGOCD_URL=""
AUTH_TOKEN=""
POLL_INTERVAL=10

while [[ $# -gt 0 ]]; do
  case $1 in
    --app)         APP_NAME="$2";    shift 2 ;;
    --timeout)     TIMEOUT="$2";     shift 2 ;;
    --argocd-url)  ARGOCD_URL="$2";  shift 2 ;;
    --auth-token)  AUTH_TOKEN="$2";  shift 2 ;;
    --interval)    POLL_INTERVAL="$2"; shift 2 ;;
    *) err "Unknown argument: $1" ;;
  esac
done

[[ -z "$APP_NAME" ]]    && err "--app is required"
[[ -z "$ARGOCD_URL" ]]  && err "--argocd-url is required"
[[ -z "$AUTH_TOKEN" ]]  && err "--auth-token is required"

DEADLINE=$(( $(date +%s) + TIMEOUT ))

info "Waiting for ArgoCD app '$APP_NAME' to be Synced + Healthy (timeout: ${TIMEOUT}s)..."

while true; do
  NOW=$(date +%s)
  if (( NOW > DEADLINE )); then
    err "Timeout after ${TIMEOUT}s waiting for '$APP_NAME'"
  fi

  # Query the ArgoCD API
  RESPONSE=$(curl -sf \
    -H "Authorization: Bearer ${AUTH_TOKEN}" \
    "${ARGOCD_URL}/api/v1/applications/${APP_NAME}" \
    2>/dev/null) || {
    warn "Failed to reach ArgoCD API — retrying..."
    sleep "$POLL_INTERVAL"
    continue
  }

  SYNC_STATUS=$(echo "$RESPONSE"   | jq -r '.status.sync.status   // "Unknown"')
  HEALTH_STATUS=$(echo "$RESPONSE" | jq -r '.status.health.status // "Unknown"')
  OPERATION=$(echo "$RESPONSE"     | jq -r '.status.operationState.phase // "None"')

  info "  sync=${SYNC_STATUS}  health=${HEALTH_STATUS}  operation=${OPERATION}"

  # Check for terminal failure states
  if [[ "$OPERATION" == "Failed" || "$OPERATION" == "Error" ]]; then
    MESSAGE=$(echo "$RESPONSE" | jq -r '.status.operationState.message // "No message"')
    err "ArgoCD sync FAILED for '$APP_NAME': $MESSAGE"
  fi

  # Success condition
  if [[ "$SYNC_STATUS" == "Synced" && "$HEALTH_STATUS" == "Healthy" ]]; then
    REVISION=$(echo "$RESPONSE" | jq -r '.status.sync.revision // "unknown"')
    log "App '$APP_NAME' is Synced + Healthy at revision: ${REVISION:0:8}"
    exit 0
  fi

  REMAINING=$(( DEADLINE - NOW ))
  info "  Waiting... (${REMAINING}s remaining)"
  sleep "$POLL_INTERVAL"
done
