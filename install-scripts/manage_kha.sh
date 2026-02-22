#!/usr/bin/env bash
#
# manage_kha.sh - Install or uninstall KEDA and KEDA HTTP Add-on (KHA)
#
# Usage:
#   ./manage_kha.sh install
#   ./manage_kha.sh uninstall
#
# Environment variables:
#   NAMESPACE     - Kubernetes namespace (default: autoscale-test)
#   KHA_VERSION   - KHA Helm chart version to install (default: 0.12.2)
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
NAMESPACE="${NAMESPACE:-autoscale-test}"
KHA_VERSION="${KHA_VERSION:-0.12.2}"

HELM_REPO_NAME="kedacore"
HELM_REPO_URL="https://kedacore.github.io/charts"

NODE_SELECTOR_KEY="gke-pool-type"
NODE_SELECTOR_VALUE="autoscale-test-control-plane"
TAINT_KEY="autoscale-test-control-plane"
TAINT_VALUE="true"
TAINT_EFFECT="NoSchedule"

INTERCEPTOR_MIN_REPLICA_COUNT=3
INTERCEPTOR_MAX_REPLICA_COUNT=3
SCALER_REPLICA_COUNT=1
OPERATOR_REPLICA_COUNT=1

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "===> $*"; }
error() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $0 {install|uninstall}

Manages the lifecycle of KEDA and KEDA HTTP Add-on (KHA).

Commands:
  install     Install latest KEDA and KHA ${KHA_VERSION} into the "${NAMESPACE}" namespace
  uninstall   Remove KHA and KEDA from the "${NAMESPACE}" namespace

Environment variables:
  NAMESPACE     Kubernetes namespace (default: autoscale-test)
  KHA_VERSION   KHA Helm chart version (default: 0.12.2)
EOF
    exit 1
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
install() {
    info "Adding Helm repository '${HELM_REPO_NAME}' (${HELM_REPO_URL})"
    helm repo add "${HELM_REPO_NAME}" "${HELM_REPO_URL}" 2>/dev/null || true
    helm repo update "${HELM_REPO_NAME}"

    # -- KEDA (latest) -------------------------------------------------------
    info "Installing KEDA (latest) into namespace '${NAMESPACE}'"
    helm install keda "${HELM_REPO_NAME}/keda" \
        --namespace "${NAMESPACE}" \
        --create-namespace \
        --wait \
        --timeout 5m \
        -f - <<EOF
nodeSelector:
  ${NODE_SELECTOR_KEY}: ${NODE_SELECTOR_VALUE}
tolerations:
  - key: "${TAINT_KEY}"
    operator: Equal
    value: "${TAINT_VALUE}"
    effect: ${TAINT_EFFECT}
EOF

    info "Waiting for KEDA operator rollout"
    kubectl rollout status deployment/keda-operator \
        -n "${NAMESPACE}" --timeout=120s

    # -- KHA (specific version) ----------------------------------------------
    info "Installing KHA v${KHA_VERSION} into namespace '${NAMESPACE}'"
    helm install keda-http-add-on "${HELM_REPO_NAME}/keda-add-ons-http" \
        --namespace "${NAMESPACE}" \
        --version "${KHA_VERSION}" \
        --wait \
        --timeout 5m \
        -f - <<EOF
operator:
  replicas: ${OPERATOR_REPLICA_COUNT}
  nodeSelector:
    ${NODE_SELECTOR_KEY}: ${NODE_SELECTOR_VALUE}
  tolerations:
    - key: "${TAINT_KEY}"
      operator: Equal
      value: "${TAINT_VALUE}"
      effect: ${TAINT_EFFECT}
  resources:
    limits: null
    requests:
      cpu: 250m
      memory: 20Mi
scaler:
  replicas: ${SCALER_REPLICA_COUNT}
  nodeSelector:
    ${NODE_SELECTOR_KEY}: ${NODE_SELECTOR_VALUE}
  tolerations:
    - key: "${TAINT_KEY}"
      operator: Equal
      value: "${TAINT_VALUE}"
      effect: ${TAINT_EFFECT}
  resources:
    limits: null
    requests:
      cpu: 250m
      memory: 20Mi
interceptor:
  replicas:
    min: ${INTERCEPTOR_MIN_REPLICA_COUNT}
    max: ${INTERCEPTOR_MAX_REPLICA_COUNT}
  nodeSelector:
    ${NODE_SELECTOR_KEY}: ${NODE_SELECTOR_VALUE}
  tolerations:
    - key: "${TAINT_KEY}"
      operator: Equal
      value: "${TAINT_VALUE}"
      effect: ${TAINT_EFFECT}
  resources:
    limits: null
    requests:
      cpu: 250m
      memory: 20Mi
EOF

    info "Waiting for KHA operator rollout"
    kubectl rollout status deployment/keda-add-ons-http-controller-manager \
        -n "${NAMESPACE}" --timeout=120s

    info "KEDA + KHA installation complete"
    echo
    helm list -n "${NAMESPACE}"
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
uninstall() {
    info "Uninstalling KHA from namespace '${NAMESPACE}'"
    helm uninstall keda-http-add-on -n "${NAMESPACE}" --wait 2>/dev/null || \
        echo "  (KHA release not found or already removed)"

    info "Uninstalling KEDA from namespace '${NAMESPACE}'"
    helm uninstall keda -n "${NAMESPACE}" --wait 2>/dev/null || \
        echo "  (KEDA release not found or already removed)"

    info "KEDA + KHA uninstallation complete"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "${1:-}" in
    install)   install ;;
    uninstall) uninstall ;;
    *)         usage ;;
esac
