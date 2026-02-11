#!/usr/bin/env bash
#
# test_activator.sh - Knative Serving Activator performance test suite
#
# Deploys a sample nginx Knative Service, then runs fortio load tests
# at increasing RPS levels through the Knative networking stack
# (Kourier gateway + Activator). Collects latency percentiles, throughput,
# error rates, and activator resource consumption.
#
# Usage:
#   ./scripts/test_activator.sh [OPTIONS]
#
# Options:
#   --no-cleanup          Keep test resources after completion
#   --results-dir DIR     Custom results directory (default: auto-generated)
#   --duration SECS       Duration per RPS level (default: 60)
#   --cooldown SECS       Cooldown between levels (default: 30)
#
# Prerequisites:
#   - kubectl configured and connected to the cluster
#   - jq installed
#   - Knative Serving already installed (via manage_knative.sh install)
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
NAMESPACE="autoscale-test"
KNATIVE_NAMESPACE="knative-serving"
KOURIER_NAMESPACE="kourier-system"
DURATION=60
COOLDOWN=30
WARMUP_DURATION=15
NO_CLEANUP=false
RESULTS_DIR=""

# RPS levels to test (ascending)
RPS_LEVELS=(10 50 250 1000 2500 5000 10000 25000 50000 100000)

# Target service configuration
# Traffic path: fortio -> Kourier internal gateway -> Activator -> App pods
GATEWAY_SVC="kourier-internal.${KOURIER_NAMESPACE}"
GATEWAY_PORT=80
TARGET_HOST="sample-app.${NAMESPACE}.svc.cluster.local"
TARGET_URL="http://${GATEWAY_SVC}:${GATEWAY_PORT}/"

# Load generator image
FORTIO_IMAGE="fortio/fortio:latest"

# Node placement (matching ksvc.yaml)
NODE_SELECTOR_KEY="gke-pool-type"
NODE_SELECTOR_VALUE="autoscale-test"
TAINT_KEY="autoscale-test"
TAINT_VALUE="true"
TAINT_EFFECT="NoSchedule"

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
TEST_KNATIVE_DIR="${PROJECT_DIR}/test-knative"

# Background process PIDs (set during run)
MONITOR_PID=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "===> $*"; }
warn()  { echo "WARN: $*" >&2; }
error() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: test_activator.sh [OPTIONS]

Knative Serving Activator performance test suite.

Options:
  --no-cleanup          Keep test resources after completion
  --results-dir DIR     Custom results directory
  --duration SECS       Duration per RPS level (default: 60)
  --cooldown SECS       Cooldown between levels (default: 30)

Examples:
  ./scripts/test_activator.sh --duration 30 --cooldown 15
  ./scripts/test_activator.sh --no-cleanup --results-dir ./my-results
EOF
    exit 0
}

cleanup_on_exit() {
    if [[ -n "${MONITOR_PID}" ]]; then
        kill "${MONITOR_PID}" 2>/dev/null || true
        wait "${MONITOR_PID}" 2>/dev/null || true
    fi
}
trap cleanup_on_exit EXIT

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-cleanup)    NO_CLEANUP=true; shift ;;
            --results-dir)   RESULTS_DIR="$2"; shift 2 ;;
            --duration)      DURATION="$2"; shift 2 ;;
            --cooldown)      COOLDOWN="$2"; shift 2 ;;
            --help|-h)       usage ;;
            *)               error "Unknown option: $1" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
check_prerequisites() {
    info "Checking prerequisites"
    command -v kubectl >/dev/null 2>&1 || error "kubectl is required but not installed"
    command -v jq      >/dev/null 2>&1 || error "jq is required but not installed"

    # Verify cluster connectivity
    kubectl cluster-info >/dev/null 2>&1 || error "Cannot connect to Kubernetes cluster"

    # Verify Knative Serving is installed
    kubectl get namespace "${KNATIVE_NAMESPACE}" >/dev/null 2>&1 || \
        error "Namespace '${KNATIVE_NAMESPACE}' does not exist. Install Knative Serving first."

    # Verify activator is running
    kubectl get deployment activator -n "${KNATIVE_NAMESPACE}" >/dev/null 2>&1 || \
        error "Knative activator not found in '${KNATIVE_NAMESPACE}'. Install Knative Serving first."

    # Verify Kourier networking layer is installed
    kubectl get namespace "${KOURIER_NAMESPACE}" >/dev/null 2>&1 || \
        error "Namespace '${KOURIER_NAMESPACE}' does not exist. Install Kourier first."

    # Verify Kourier internal gateway service exists
    kubectl get service kourier-internal -n "${KOURIER_NAMESPACE}" >/dev/null 2>&1 || \
        error "Kourier internal gateway service not found in '${KOURIER_NAMESPACE}'."

    info "All prerequisites met"
}

# ---------------------------------------------------------------------------
# Deploy sample workload (Knative Service)
# ---------------------------------------------------------------------------
deploy_workload() {
    info "Deploying sample workload (Knative Service)"

    # Ensure workload namespace exists
    kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

    kubectl apply -f "${TEST_KNATIVE_DIR}/ksvc.yaml"

    info "Waiting for Knative Service to be ready"
    kubectl wait ksvc/sample-app -n "${NAMESPACE}" \
        --for=condition=Ready --timeout=120s

    info "Sample workload deployed"
}

# ---------------------------------------------------------------------------
# Deploy load generator pod
# ---------------------------------------------------------------------------
deploy_load_generator() {
    info "Deploying load generator pod (fortio)"

    # Remove stale pod if present
    kubectl delete pod load-generator -n "${NAMESPACE}" \
        --ignore-not-found --wait 2>/dev/null || true

    kubectl run load-generator \
        --image="${FORTIO_IMAGE}" \
        --namespace="${NAMESPACE}" \
        --restart=Never \
        --overrides="$(cat <<EOFOVERRIDE
{
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
EOFOVERRIDE
        )" \
        --command -- fortio server -http-port 0 -grpc-port 0 -redirect-port 0

    info "Waiting for load generator pod to be ready"
    kubectl wait --for=condition=ready pod/load-generator \
        -n "${NAMESPACE}" --timeout=120s

    info "Load generator pod ready"
}

# ---------------------------------------------------------------------------
# Warmup: trigger scale-from-zero, wait for backend pods
# ---------------------------------------------------------------------------
warmup() {
    info "Warming up: sending requests to trigger scale-from-zero"

    kubectl exec load-generator -n "${NAMESPACE}" -- \
        fortio load \
        -qps 5 \
        -t "${WARMUP_DURATION}s" \
        -c 2 \
        -H "Host: ${TARGET_HOST}" \
        -allow-initial-errors \
        "${TARGET_URL}" >/dev/null 2>&1 || true

    info "Waiting for sample-app to have running pods"
    local retries=0
    local max_retries=60
    while [[ ${retries} -lt ${max_retries} ]]; do
        local ready
        ready=$(kubectl get pods -n "${NAMESPACE}" \
            -l serving.knative.dev/service=sample-app \
            --field-selector=status.phase=Running \
            --no-headers 2>/dev/null | wc -l | tr -d ' ')
        ready="${ready:-0}"
        if [[ ${ready} -gt 0 ]]; then
            info "sample-app has ${ready} running pod(s)"
            break
        fi
        retries=$((retries + 1))
        sleep 5
    done

    if [[ ${retries} -ge ${max_retries} ]]; then
        error "sample-app failed to scale up within timeout"
    fi

    sleep 5
    info "Warmup complete"
}

# ---------------------------------------------------------------------------
# Resource monitor (runs in background for the entire test)
# ---------------------------------------------------------------------------
start_resource_monitor() {
    local csv="${RESULTS_DIR}/resource_metrics.csv"
    info "Starting resource monitor -> ${csv}"
    echo "timestamp,namespace,pod,cpu,memory" > "${csv}"

    (
        while true; do
            local ts
            ts=$(date +%s)

            # Monitor all pods in the workload namespace (app pods + load generator)
            kubectl top pod -n "${NAMESPACE}" --no-headers 2>/dev/null | \
                while IFS= read -r line; do
                    echo "${ts},${NAMESPACE},$(echo "${line}" | awk '{print $1","$2","$3}')" >> "${csv}"
                done

            # Monitor activator pods in the Knative Serving namespace
            kubectl top pod -n "${KNATIVE_NAMESPACE}" -l app=activator --no-headers 2>/dev/null | \
                while IFS= read -r line; do
                    echo "${ts},${KNATIVE_NAMESPACE},$(echo "${line}" | awk '{print $1","$2","$3}')" >> "${csv}"
                done

            sleep 5
        done
    ) &
    MONITOR_PID=$!
}

stop_resource_monitor() {
    if [[ -n "${MONITOR_PID}" ]]; then
        info "Stopping resource monitor"
        kill "${MONITOR_PID}" 2>/dev/null || true
        wait "${MONITOR_PID}" 2>/dev/null || true
        MONITOR_PID=""
    fi
}

# ---------------------------------------------------------------------------
# Calculate concurrent connections for a given RPS
# ---------------------------------------------------------------------------
calculate_connections() {
    local rps=$1
    local c=$((rps / 10))
    [[ ${c} -lt 4 ]]   && c=4
    [[ ${c} -gt 128 ]] && c=128
    echo "${c}"
}

# ---------------------------------------------------------------------------
# Run a single load test at a given RPS
# ---------------------------------------------------------------------------
run_load_test() {
    local rps=$1
    local connections
    connections=$(calculate_connections "${rps}")
    local fortio_txt="${RESULTS_DIR}/fortio_${rps}rps.txt"
    local local_json="${RESULTS_DIR}/fortio_${rps}rps.json"

    info "[RPS=${rps}] Starting load test (${DURATION}s, ${connections} connections)"

    # Phase marker for resource correlation
    echo "MARKER,${rps},START,$(date +%s)" >> "${RESULTS_DIR}/resource_metrics.csv"

    # Run fortio — JSON is written to /dev/stdout inside the container and
    # streamed back via kubectl exec (avoids kubectl cp which requires tar in
    # the container image).  Human-readable progress goes to stderr → text file.
    kubectl exec load-generator -n "${NAMESPACE}" -- \
        fortio load \
        -qps "${rps}" \
        -t "${DURATION}s" \
        -c "${connections}" \
        -p "50,75,90,95,99,99.9" \
        -json /dev/stdout \
        -H "Host: ${TARGET_HOST}" \
        "${TARGET_URL}" > "${local_json}" 2> "${fortio_txt}" || true

    # Phase marker
    echo "MARKER,${rps},END,$(date +%s)" >> "${RESULTS_DIR}/resource_metrics.csv"

    # Snapshot of pod resource usage right after the load
    # Capture both app namespace and activator namespace
    kubectl top pod -n "${NAMESPACE}" --no-headers \
        > "${RESULTS_DIR}/top_${rps}rps.txt" 2>/dev/null || true
    kubectl top pod -n "${KNATIVE_NAMESPACE}" -l app=activator --no-headers \
        >> "${RESULTS_DIR}/top_${rps}rps.txt" 2>/dev/null || true

    kubectl get pods -n "${NAMESPACE}" --no-headers \
        > "${RESULTS_DIR}/pods_${rps}rps.txt" 2>/dev/null || true

    info "[RPS=${rps}] Complete"
}

# ---------------------------------------------------------------------------
# Extract a latency percentile from fortio JSON (returns value in ms)
# ---------------------------------------------------------------------------
get_percentile() {
    local json_file=$1
    local pct=$2
    jq -r --arg p "${pct}" \
        '(.DurationHistogram.Percentiles // [])[]
         | select(.Percentile == ($p | tonumber))
         | .Value * 1000' \
        "${json_file}" 2>/dev/null || echo "N/A"
}

# ---------------------------------------------------------------------------
# Parse CPU from kubectl-top notation (e.g. "5m" -> 5, "1" -> 1000)
# Returns integer millicores; "0" on failure.
# ---------------------------------------------------------------------------
parse_cpu_milli() {
    local v="$1"
    if [[ "${v}" =~ ^([0-9]+)m$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "${v}" =~ ^([0-9]+)$ ]]; then
        echo "$(( BASH_REMATCH[1] * 1000 ))"
    else
        echo "0"
    fi
}

# ---------------------------------------------------------------------------
# Parse memory from kubectl-top notation (e.g. "64Mi" -> 64)
# Returns integer MiB; "0" on failure.
# ---------------------------------------------------------------------------
parse_mem_mi() {
    local v="$1"
    if [[ "${v}" =~ ^([0-9]+)Mi$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "${v}" =~ ^([0-9]+)Ki$ ]]; then
        echo "$(( BASH_REMATCH[1] / 1024 ))"
    elif [[ "${v}" =~ ^([0-9]+)Gi$ ]]; then
        echo "$(( BASH_REMATCH[1] * 1024 ))"
    else
        echo "0"
    fi
}

# ---------------------------------------------------------------------------
# Aggregate activator resource usage from a kubectl-top snapshot file
# Returns: total_cpu_m  total_mem_mi  pod_count
# ---------------------------------------------------------------------------
aggregate_activator_resources() {
    local top_file=$1
    local total_cpu=0 total_mem=0 count=0

    if [[ ! -f "${top_file}" ]]; then
        echo "0 0 0"
        return
    fi

    while read -r pod cpu mem _rest; do
        [[ "${pod}" == *activator* ]] || continue
        total_cpu=$(( total_cpu + $(parse_cpu_milli "${cpu}") ))
        total_mem=$(( total_mem + $(parse_mem_mi "${mem}") ))
        count=$(( count + 1 ))
    done < "${top_file}"

    echo "${total_cpu} ${total_mem} ${count}"
}

# ---------------------------------------------------------------------------
# Generate summary report
# ---------------------------------------------------------------------------
generate_report() {
    local summary="${RESULTS_DIR}/summary.txt"
    local summary_csv="${RESULTS_DIR}/summary.csv"
    info "Generating summary report"

    # ---- CSV header ----
    echo "target_rps,actual_rps,total_reqs,success,errors,error_pct,p50_ms,p75_ms,p90_ms,p95_ms,p99_ms,p999_ms,actv_cpu_m,actv_mem_mi,actv_pods,app_pods" \
        > "${summary_csv}"

    # ---- Text header ----
    {
        echo "========================================================================"
        echo "  Knative Serving Activator Performance Test Summary"
        echo "========================================================================"
        echo ""
        echo "Date:       $(date)"
        echo "Namespace:  ${NAMESPACE}"
        echo "Duration:   ${DURATION}s per level"
        echo "Cooldown:   ${COOLDOWN}s between levels"
        echo "Target:     ${TARGET_URL}"
        echo "Host:       ${TARGET_HOST}"
        echo "Results:    ${RESULTS_DIR}"
        echo ""
        printf "%-10s  %-10s  %-8s  %-8s  %-7s  %-8s  %-8s  %-8s  %-8s  %-8s  %-10s  %-10s  %-6s  %-6s\n" \
            "Tgt_RPS" "Act_RPS" "Total" "OK" "Err%" \
            "p50ms" "p90ms" "p95ms" "p99ms" "p999ms" \
            "CPU(m)" "Mem(Mi)" "ActPod" "AppPod"
        printf "%-10s  %-10s  %-8s  %-8s  %-7s  %-8s  %-8s  %-8s  %-8s  %-8s  %-10s  %-10s  %-6s  %-6s\n" \
            "-------" "-------" "------" "------" "-----" \
            "------" "------" "------" "------" "------" \
            "------" "-------" "------" "------"
    } > "${summary}"

    # ---- Per-level results ----
    for rps in "${RPS_LEVELS[@]}"; do
        local json="${RESULTS_DIR}/fortio_${rps}rps.json"
        local top_file="${RESULTS_DIR}/top_${rps}rps.txt"
        local pods_file="${RESULTS_DIR}/pods_${rps}rps.txt"

        if [[ ! -f "${json}" ]]; then
            warn "No results for ${rps} RPS (skipping)"
            continue
        fi

        # -- Fortio metrics --
        local actual_qps total_requests success errors error_pct

        actual_qps=$(jq -r '.ActualQPS | . * 100 | round / 100' "${json}" 2>/dev/null || echo "N/A")
        total_requests=$(jq -r '.DurationHistogram.Count' "${json}" 2>/dev/null || echo "0")
        success=$(jq -r '.RetCodes["200"] // 0' "${json}" 2>/dev/null || echo "0")
        errors=$(jq -r '[.RetCodes | to_entries[] | select(.key != "200") | .value] | add // 0' \
            "${json}" 2>/dev/null || echo "0")

        if [[ "${total_requests}" -gt 0 ]] 2>/dev/null; then
            error_pct=$(awk "BEGIN {printf \"%.2f\", ${errors} * 100 / ${total_requests}}")
        else
            error_pct="N/A"
        fi

        # -- Latency percentiles (ms, 2 decimal places) --
        local p50 p75 p90 p95 p99 p999
        p50=$(get_percentile  "${json}" "50")
        p75=$(get_percentile  "${json}" "75")
        p90=$(get_percentile  "${json}" "90")
        p95=$(get_percentile  "${json}" "95")
        p99=$(get_percentile  "${json}" "99")
        p999=$(get_percentile "${json}" "99.9")

        # Format to 2 decimals
        for var in p50 p75 p90 p95 p99 p999; do
            local val="${!var}"
            if [[ "${val}" != "N/A" ]]; then
                printf -v "${var}" "%.2f" "${val}" 2>/dev/null || true
            fi
        done

        # -- Activator resources --
        local res
        res=$(aggregate_activator_resources "${top_file}")
        local actv_cpu actv_mem actv_pods
        read -r actv_cpu actv_mem actv_pods <<< "${res}"

        # -- Sample-app pod count --
        local app_pods=0
        if [[ -f "${pods_file}" ]]; then
            app_pods=$(grep -c "sample-app" "${pods_file}" 2>/dev/null || echo "0")
        fi

        # -- Write text row --
        printf "%-10s  %-10s  %-8s  %-8s  %-7s  %-8s  %-8s  %-8s  %-8s  %-8s  %-10s  %-10s  %-6s  %-6s\n" \
            "${rps}" "${actual_qps}" "${total_requests}" "${success}" "${error_pct}" \
            "${p50}" "${p90}" "${p95}" "${p99}" "${p999}" \
            "${actv_cpu}" "${actv_mem}" "${actv_pods}" "${app_pods}" \
            >> "${summary}"

        # -- Write CSV row --
        echo "${rps},${actual_qps},${total_requests},${success},${errors},${error_pct},${p50},${p75},${p90},${p95},${p99},${p999},${actv_cpu},${actv_mem},${actv_pods},${app_pods}" \
            >> "${summary_csv}"
    done

    # ---- Footer ----
    {
        echo ""
        echo "------------------------------------------------------------------------"
        echo "Detailed fortio JSON:  ${RESULTS_DIR}/fortio_*rps.json"
        echo "Resource time-series:  ${RESULTS_DIR}/resource_metrics.csv"
        echo "Activator logs:        ${RESULTS_DIR}/activator_logs.txt"
        echo "========================================================================"
    } >> "${summary}"

    echo ""
    cat "${summary}"
    echo ""
}

# ---------------------------------------------------------------------------
# Collect activator logs (tail of each pod)
# ---------------------------------------------------------------------------
collect_logs() {
    info "Collecting activator logs"
    local log_file="${RESULTS_DIR}/activator_logs.txt"
    : > "${log_file}"

    local pods
    pods=$(kubectl get pods -n "${KNATIVE_NAMESPACE}" -l app=activator -o name 2>/dev/null || true)

    if [[ -z "${pods}" ]]; then
        echo "(no activator pods found)" > "${log_file}"
        return
    fi

    for pod in ${pods}; do
        {
            echo "======== $(basename "${pod}") ========"
            kubectl logs -n "${KNATIVE_NAMESPACE}" "${pod}" --tail=2000 2>/dev/null || echo "(failed to retrieve logs)"
            echo ""
        } >> "${log_file}"
    done
}

# ---------------------------------------------------------------------------
# Cleanup test resources
# ---------------------------------------------------------------------------
cleanup() {
    info "Cleaning up test resources"
    kubectl delete pod load-generator -n "${NAMESPACE}" \
        --ignore-not-found --wait 2>/dev/null || true
    kubectl delete -f "${TEST_KNATIVE_DIR}/ksvc.yaml" --ignore-not-found 2>/dev/null || true
    info "Cleanup complete"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    # Setup results directory
    if [[ -z "${RESULTS_DIR}" ]]; then
        RESULTS_DIR="${TEST_KNATIVE_DIR}/results/activator-$(date +%Y%m%d-%H%M%S)"
    fi
    mkdir -p "${RESULTS_DIR}"
    info "Results will be saved to: ${RESULTS_DIR}"

    check_prerequisites
    deploy_workload
    deploy_load_generator
    warmup

    start_resource_monitor

    for i in "${!RPS_LEVELS[@]}"; do
        run_load_test "${RPS_LEVELS[${i}]}"
        # Cooldown between levels (skip after the last one)
        if [[ ${i} -lt $(( ${#RPS_LEVELS[@]} - 1 )) ]]; then
            info "Cooling down for ${COOLDOWN}s"
            sleep "${COOLDOWN}"
        fi
    done

    stop_resource_monitor
    collect_logs
    generate_report

    if [[ "${NO_CLEANUP}" == "true" ]]; then
        info "Skipping cleanup (--no-cleanup specified)"
    else
        cleanup
    fi

    info "All done! Results: ${RESULTS_DIR}"
}

main "$@"
