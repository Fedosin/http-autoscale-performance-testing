#!/usr/bin/env bash
#
# test_interceptor.sh - KHA Interceptor performance test suite
#
# Deploys a sample nginx app + HTTPScaledObject, then runs fortio load tests
# at increasing RPS levels through the KHA interceptor proxy. Collects latency
# percentiles, throughput, error rates, and interceptor resource consumption.
#
# Usage:
#   ./scripts/test_interceptor.sh [OPTIONS]
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
#   - KHA already installed in the target namespace (via manage_kha.sh install)
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
NAMESPACE="autoscale-test"
DURATION=60
COOLDOWN=30
WARMUP_DURATION=15
NO_CLEANUP=false
RESULTS_DIR=""

# RPS levels to test (ascending)
RPS_LEVELS=(10 50 250 1000 2500 5000 10000 25000 50000 100000)

# Target service configuration
INTERCEPTOR_SVC="keda-add-ons-http-interceptor-proxy"
INTERCEPTOR_PORT=8080
TARGET_HOST="sample-app.local"
TARGET_URL="http://${INTERCEPTOR_SVC}:${INTERCEPTOR_PORT}/"

# Load generator image
FORTIO_IMAGE="fortio/fortio:latest"

# Node placement (matching deployment.yaml)
NODE_SELECTOR_KEY="gke-pool-type"
NODE_SELECTOR_VALUE="autoscale-test"
TAINT_KEY="autoscale-test"
TAINT_VALUE="true"
TAINT_EFFECT="NoSchedule"

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
TEST_KHA_DIR="${PROJECT_DIR}/test-kha-throughput"

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
Usage: test_interceptor.sh [OPTIONS]

KHA Interceptor performance test suite.

Options:
  --no-cleanup          Keep test resources after completion
  --results-dir DIR     Custom results directory
  --duration SECS       Duration per RPS level (default: 60)
  --cooldown SECS       Cooldown between levels (default: 30)

Examples:
  ./scripts/test_interceptor.sh --duration 30 --cooldown 15
  ./scripts/test_interceptor.sh --no-cleanup --results-dir ./my-results
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

    # Verify namespace exists
    kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || \
        error "Namespace '${NAMESPACE}' does not exist. Install KHA first."

    # Verify interceptor is running
    kubectl get deployment -n "${NAMESPACE}" -o name 2>/dev/null | grep -q "interceptor" || \
        error "KHA interceptor not found in '${NAMESPACE}'. Install KHA first."

    info "All prerequisites met"
}

# ---------------------------------------------------------------------------
# Deploy sample workload
# ---------------------------------------------------------------------------
deploy_workload() {
    info "Deploying sample workload (nginx + HTTPScaledObject)"
    kubectl apply -f "${TEST_KHA_DIR}/deployment.yaml"
    kubectl apply -f "${TEST_KHA_DIR}/httpso.yaml"

    info "Waiting for HTTPScaledObject to be reconciled"
    sleep 5

    kubectl get httpscaledobject -n "${NAMESPACE}" sample-app-httpso >/dev/null 2>&1 || \
        error "HTTPScaledObject 'sample-app-httpso' was not created"

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

    info "Waiting for sample-app to have ready replicas"
    local retries=0
    local max_retries=60
    while [[ ${retries} -lt ${max_retries} ]]; do
        local ready
        ready=$(kubectl get deployment sample-app -n "${NAMESPACE}" \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        ready="${ready:-0}"
        if [[ ${ready} -gt 0 ]]; then
            info "sample-app has ${ready} ready replica(s)"
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
    echo "timestamp,pod,cpu,memory" > "${csv}"

    (
        while true; do
            local ts
            ts=$(date +%s)
            kubectl top pod -n "${NAMESPACE}" --no-headers 2>/dev/null | \
                while IFS= read -r line; do
                    # Collapse whitespace into commas: POD,CPU,MEM
                    echo "${ts},$(echo "${line}" | awk '{print $1","$2","$3}')" >> "${csv}"
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
    kubectl top pod -n "${NAMESPACE}" --no-headers \
        > "${RESULTS_DIR}/top_${rps}rps.txt" 2>/dev/null || true
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
# Aggregate interceptor resource usage from a kubectl-top snapshot file
# Returns: total_cpu_m  total_mem_mi  pod_count
# ---------------------------------------------------------------------------
aggregate_interceptor_resources() {
    local top_file=$1
    local total_cpu=0 total_mem=0 count=0

    if [[ ! -f "${top_file}" ]]; then
        echo "0 0 0"
        return
    fi

    while read -r pod cpu mem _rest; do
        [[ "${pod}" == *interceptor* ]] || continue
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
    echo "target_rps,actual_rps,total_reqs,success,errors,error_pct,p50_ms,p75_ms,p90_ms,p95_ms,p99_ms,p999_ms,intcpt_cpu_m,intcpt_mem_mi,intcpt_pods,app_pods" \
        > "${summary_csv}"

    # ---- Text header ----
    {
        echo "========================================================================"
        echo "  KHA Interceptor Performance Test Summary"
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
            "CPU(m)" "Mem(Mi)" "IntPod" "AppPod"
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

        # -- Interceptor resources --
        local res
        res=$(aggregate_interceptor_resources "${top_file}")
        local intcpt_cpu intcpt_mem intcpt_pods
        read -r intcpt_cpu intcpt_mem intcpt_pods <<< "${res}"

        # -- Sample-app pod count --
        local app_pods=0
        if [[ -f "${pods_file}" ]]; then
            app_pods=$(grep -c "sample-app" "${pods_file}" 2>/dev/null || echo "0")
        fi

        # -- Write text row --
        printf "%-10s  %-10s  %-8s  %-8s  %-7s  %-8s  %-8s  %-8s  %-8s  %-8s  %-10s  %-10s  %-6s  %-6s\n" \
            "${rps}" "${actual_qps}" "${total_requests}" "${success}" "${error_pct}" \
            "${p50}" "${p90}" "${p95}" "${p99}" "${p999}" \
            "${intcpt_cpu}" "${intcpt_mem}" "${intcpt_pods}" "${app_pods}" \
            >> "${summary}"

        # -- Write CSV row --
        echo "${rps},${actual_qps},${total_requests},${success},${errors},${error_pct},${p50},${p75},${p90},${p95},${p99},${p999},${intcpt_cpu},${intcpt_mem},${intcpt_pods},${app_pods}" \
            >> "${summary_csv}"
    done

    # ---- Footer ----
    {
        echo ""
        echo "------------------------------------------------------------------------"
        echo "Detailed fortio JSON:  ${RESULTS_DIR}/fortio_*rps.json"
        echo "Resource time-series:  ${RESULTS_DIR}/resource_metrics.csv"
        echo "Interceptor logs:      ${RESULTS_DIR}/interceptor_logs.txt"
        echo "========================================================================"
    } >> "${summary}"

    echo ""
    cat "${summary}"
    echo ""
}

# ---------------------------------------------------------------------------
# Collect interceptor logs (tail of each pod)
# ---------------------------------------------------------------------------
collect_logs() {
    info "Collecting interceptor logs"
    local log_file="${RESULTS_DIR}/interceptor_logs.txt"
    : > "${log_file}"

    local pods
    pods=$(kubectl get pods -n "${NAMESPACE}" -o name 2>/dev/null | grep interceptor || true)

    if [[ -z "${pods}" ]]; then
        echo "(no interceptor pods found)" > "${log_file}"
        return
    fi

    for pod in ${pods}; do
        {
            echo "======== $(basename "${pod}") ========"
            kubectl logs -n "${NAMESPACE}" "${pod}" --tail=2000 2>/dev/null || echo "(failed to retrieve logs)"
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
    kubectl delete -f "${TEST_KHA_DIR}/httpso.yaml"  --ignore-not-found 2>/dev/null || true
    kubectl delete -f "${TEST_KHA_DIR}/deployment.yaml" --ignore-not-found 2>/dev/null || true
    info "Cleanup complete"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    # Setup results directory
    if [[ -z "${RESULTS_DIR}" ]]; then
        RESULTS_DIR="${TEST_KHA_DIR}/results/interceptor-$(date +%Y%m%d-%H%M%S)"
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
