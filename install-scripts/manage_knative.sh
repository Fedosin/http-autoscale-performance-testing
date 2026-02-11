#!/usr/bin/env bash
#
# manage_knative.sh - Install or uninstall Knative Serving with Kourier networking
#
# Usage:
#   ./manage_knative.sh install
#   ./manage_knative.sh uninstall
#
# Environment variables:
#   KNATIVE_VERSION - Knative version to install (default: auto-detect latest stable)
#
# Note: Knative Serving is installed in the standard "knative-serving" namespace
# and Kourier in "kourier-system". These namespaces are hardcoded in the upstream
# YAML manifests. Deployments are patched post-install to honour the required
# node selector and taint toleration for the dedicated node pool.
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
KNATIVE_NAMESPACE="knative-serving"
KOURIER_NAMESPACE="kourier-system"

NODE_SELECTOR_KEY="gke-pool-type"
NODE_SELECTOR_VALUE="autoscale-test-control-plane"
TAINT_KEY="autoscale-test-control-plane"
TAINT_VALUE="true"
TAINT_EFFECT="NoSchedule"

SERVING_BASE_URL="https://github.com/knative/serving/releases/download"
KOURIER_BASE_URL="https://github.com/knative-extensions/net-kourier/releases/download"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "===> $*"; }
error() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $0 {install|uninstall}

Manages the lifecycle of Knative Serving (with Kourier networking layer).

Commands:
  install     Install latest stable Knative Serving
  uninstall   Remove Knative Serving and Kourier

Environment variables:
  KNATIVE_VERSION   Knative version to install (default: auto-detect latest stable)

Note: Components are installed in their standard namespaces:
  - Knative Serving  -> ${KNATIVE_NAMESPACE}
  - Kourier           -> ${KOURIER_NAMESPACE}
EOF
    exit 1
}

# ---------------------------------------------------------------------------
# Resolve the latest stable Knative Serving version from GitHub
# ---------------------------------------------------------------------------
get_latest_knative_version() {
    local tag
    tag=$(curl -sI "https://github.com/knative/serving/releases/latest" \
        | grep -i '^location:' \
        | sed -E 's|.*/knative-v([0-9]+\.[0-9]+\.[0-9]+).*|\1|' \
        | tr -d '[:space:]')

    if [[ -z "${tag}" ]]; then
        error "Failed to detect the latest Knative Serving release. Set KNATIVE_VERSION manually."
    fi
    echo "${tag}"
}

# ---------------------------------------------------------------------------
# Patch all Deployments in a namespace with nodeSelector + tolerations
# ---------------------------------------------------------------------------
patch_deployments() {
    local ns="$1"

    info "Patching deployments in namespace '${ns}' with nodeSelector and tolerations"

    local deployments
    deployments=$(kubectl get deployments -n "${ns}" -o name 2>/dev/null || true)

    if [[ -z "${deployments}" ]]; then
        echo "  (no deployments found in ${ns})"
        return
    fi

    local patch
    patch=$(cat <<EOF
{
  "spec": {
    "template": {
      "spec": {
        "nodeSelector": {
          "${NODE_SELECTOR_KEY}": "${NODE_SELECTOR_VALUE}"
        },
        "tolerations": [
          {
            "key": "${TAINT_KEY}",
            "operator": "Equal",
            "value": "${TAINT_VALUE}",
            "effect": "${TAINT_EFFECT}"
          }
        ]
      }
    }
  }
}
EOF
    )

    for deploy in ${deployments}; do
        echo "  Patching ${deploy}"
        kubectl patch "${deploy}" -n "${ns}" --type=strategic -p "${patch}"
    done
}

# ---------------------------------------------------------------------------
# Remove resource limits (cpu & memory) from all containers in a namespace
# ---------------------------------------------------------------------------
remove_resource_limits() {
    local ns="$1"

    info "Removing resource limits from deployments in namespace '${ns}'"

    local deployments
    deployments=$(kubectl get deployments -n "${ns}" -o name 2>/dev/null || true)

    if [[ -z "${deployments}" ]]; then
        echo "  (no deployments found in ${ns})"
        return
    fi

    for deploy in ${deployments}; do
        # Get container names to determine count
        local names
        names=$(kubectl get "${deploy}" -n "${ns}" \
            -o jsonpath='{.spec.template.spec.containers[*].name}')

        local patch_ops=""
        local i=0
        for name in ${names}; do
            local limits
            limits=$(kubectl get "${deploy}" -n "${ns}" \
                -o jsonpath="{.spec.template.spec.containers[${i}].resources.limits}")
            if [[ -n "${limits}" && "${limits}" != "{}" ]]; then
                [[ -n "${patch_ops}" ]] && patch_ops+=","
                patch_ops+="{\"op\":\"remove\",\"path\":\"/spec/template/spec/containers/${i}/resources/limits\"}"
            fi
            i=$((i + 1))
        done

        if [[ -n "${patch_ops}" ]]; then
            echo "  Removing resource limits from ${deploy}"
            kubectl patch "${deploy}" -n "${ns}" --type=json -p "[${patch_ops}]"
        else
            echo "  No resource limits found in ${deploy}"
        fi
    done
}

# ---------------------------------------------------------------------------
# Wait for all Deployments in a namespace to roll out
# ---------------------------------------------------------------------------
wait_for_deployments() {
    local ns="$1"

    local deployments
    deployments=$(kubectl get deployments -n "${ns}" -o name 2>/dev/null || true)

    for deploy in ${deployments}; do
        info "Waiting for ${deploy} in '${ns}'"
        kubectl rollout status "${deploy}" -n "${ns}" --timeout=120s
    done
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
install() {
    local version="${KNATIVE_VERSION:-}"
    if [[ -z "${version}" ]]; then
        info "Detecting latest stable Knative Serving version"
        version=$(get_latest_knative_version)
    fi
    info "Using Knative Serving version: v${version}"

    local serving_url="${SERVING_BASE_URL}/knative-v${version}"
    local kourier_url="${KOURIER_BASE_URL}/knative-v${version}"

    # -- CRDs ----------------------------------------------------------------
    info "Installing Knative Serving CRDs"
    kubectl apply -f "${serving_url}/serving-crds.yaml"
    kubectl wait --for=condition=Established --all crd --timeout=60s

    # -- Serving core --------------------------------------------------------
    info "Installing Knative Serving core components"
    kubectl apply -f "${serving_url}/serving-core.yaml"

    # -- Kourier networking --------------------------------------------------
    info "Installing Kourier networking layer"
    kubectl apply -f "${kourier_url}/kourier.yaml"

    # Configure Knative to use Kourier as the default ingress
    info "Configuring Knative to use Kourier ingress"
    kubectl patch configmap/config-network \
        --namespace "${KNATIVE_NAMESPACE}" \
        --type merge \
        --patch '{"data":{"ingress-class":"kourier.ingress.networking.knative.dev"}}'

    # Enable PodSpec features so Knative Services can use nodeSelector/tolerations
    info "Enabling PodSpec feature flags (nodeSelector, tolerations)"
    kubectl patch configmap/config-features \
        --namespace "${KNATIVE_NAMESPACE}" \
        --type merge \
        --patch '{"data":{"kubernetes.podspec-nodeselector":"enabled","kubernetes.podspec-tolerations":"enabled"}}'

    # -- Node placement ------------------------------------------------------
    patch_deployments "${KNATIVE_NAMESPACE}"
    patch_deployments "${KOURIER_NAMESPACE}"

    # -- Remove resource limits -----------------------------------------------
    remove_resource_limits "${KNATIVE_NAMESPACE}"
    remove_resource_limits "${KOURIER_NAMESPACE}"

    # -- Wait for rollouts ---------------------------------------------------
    wait_for_deployments "${KNATIVE_NAMESPACE}"
    wait_for_deployments "${KOURIER_NAMESPACE}"

    info "Knative Serving installation complete (v${version})"
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
uninstall() {
    local version="${KNATIVE_VERSION:-}"
    if [[ -z "${version}" ]]; then
        info "Detecting latest stable Knative Serving version (for manifest URLs)"
        version=$(get_latest_knative_version)
    fi
    info "Using Knative Serving version for uninstall manifests: v${version}"

    local serving_url="${SERVING_BASE_URL}/knative-v${version}"
    local kourier_url="${KOURIER_BASE_URL}/knative-v${version}"

    info "Removing Kourier networking layer"
    kubectl delete -f "${kourier_url}/kourier.yaml" --ignore-not-found 2>/dev/null || true

    info "Removing Knative Serving core components"
    kubectl delete -f "${serving_url}/serving-core.yaml" --ignore-not-found 2>/dev/null || true

    info "Removing Knative Serving CRDs"
    kubectl delete -f "${serving_url}/serving-crds.yaml" --ignore-not-found 2>/dev/null || true

    info "Knative Serving uninstallation complete"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "${1:-}" in
    install)   install ;;
    uninstall) uninstall ;;
    *)         usage ;;
esac
