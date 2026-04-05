#!/usr/bin/env bash
# =============================================================================
# wait-for-rollout.sh — Monitor Argo Rollout canary progress
#
# Usage:
#   ./scripts/wait-for-rollout.sh \
#     --name api-service \
#     --namespace api-service \
#     --context prod-cluster \
#     --timeout 1800
#
# Exits 0 on successful promotion, 1 on abort/degraded
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

log()  { echo -e "${GREEN}[✔]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✘]${NC} $*" >&2; exit 1; }
info() { echo -e "${CYAN}[→]${NC} $*"; }

ROLLOUT_NAME=""
NAMESPACE=""
KUBE_CONTEXT=""
TIMEOUT=1800
POLL_INTERVAL=15

while [[ $# -gt 0 ]]; do
  case $1 in
    --name)      ROLLOUT_NAME="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2";    shift 2 ;;
    --context)   KUBE_CONTEXT="$2"; shift 2 ;;
    --timeout)   TIMEOUT="$2";      shift 2 ;;
    *) err "Unknown argument: $1" ;;
  esac
done

[[ -z "$ROLLOUT_NAME" ]] && err "--name is required"
[[ -z "$NAMESPACE" ]]    && err "--namespace is required"
[[ -z "$KUBE_CONTEXT" ]] && err "--context is required"

kubectl config use-context "$KUBE_CONTEXT"

DEADLINE=$(( $(date +%s) + TIMEOUT ))

info "Monitoring Argo Rollout '$ROLLOUT_NAME' in '$NAMESPACE'..."
info "Timeout: ${TIMEOUT}s ($(( TIMEOUT / 60 )) minutes)"
echo ""

PREV_STEP=""

while true; do
  NOW=$(date +%s)
  if (( NOW > DEADLINE )); then
    err "Timeout after ${TIMEOUT}s — rollout did not complete"
  fi

  # Get rollout status
  STATUS=$(kubectl get rollout "$ROLLOUT_NAME" \
    -n "$NAMESPACE" \
    -o json 2>/dev/null) || {
    warn "Could not fetch rollout — retrying..."
    sleep "$POLL_INTERVAL"
    continue
  }

  PHASE=$(echo "$STATUS"           | jq -r '.status.phase // "Unknown"')
  CANARY_WEIGHT=$(echo "$STATUS"   | jq -r '.status.canary.weights.canary.weight // 0')
  STABLE_WEIGHT=$(echo "$STATUS"   | jq -r '.status.canary.weights.stable.weight // 100')
  CURRENT_STEP=$(echo "$STATUS"    | jq -r '.status.currentStepIndex // 0')
  TOTAL_STEPS=$(echo "$STATUS"     | jq -r '(.spec.strategy.canary.steps | length) // 0')
  READY=$(echo "$STATUS"           | jq -r '.status.readyReplicas // 0')
  DESIRED=$(echo "$STATUS"         | jq -r '.spec.replicas // 0')
  MESSAGE=$(echo "$STATUS"         | jq -r '.status.conditions[-1].message // ""')

  # Print update only when step changes
  STEP_KEY="${PHASE}-${CURRENT_STEP}-${CANARY_WEIGHT}"
  if [[ "$STEP_KEY" != "$PREV_STEP" ]]; then
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    info "Phase:        ${PHASE}"
    info "Step:         ${CURRENT_STEP} / ${TOTAL_STEPS}"
    info "Traffic:      canary=${CANARY_WEIGHT}%  stable=${STABLE_WEIGHT}%"
    info "Replicas:     ${READY} / ${DESIRED} ready"
    [[ -n "$MESSAGE" ]] && info "Message:      $MESSAGE"
    PREV_STEP="$STEP_KEY"
  fi

  case "$PHASE" in
    Healthy)
      echo ""
      log "Rollout COMPLETE — canary fully promoted to stable"
      log "All ${READY} replicas healthy"
      exit 0
      ;;

    Degraded)
      echo ""
      err "Rollout DEGRADED — check 'kubectl argo rollouts get rollout $ROLLOUT_NAME -n $NAMESPACE'"
      ;;

    Aborted)
      echo ""
      err "Rollout ABORTED — automatic rollback triggered by failed analysis"
      ;;

    Paused)
      info "  Rollout paused (manual step or analysis window) — watching..."
      ;;

    Progressing)
      REMAINING=$(( DEADLINE - NOW ))
      info "  Progressing... (${REMAINING}s remaining)"
      ;;
  esac

  sleep "$POLL_INTERVAL"
done
