#!/usr/bin/env bash
#
# test_cold_start.sh - KHA cold-start performance test
#
# For each service-count level (1, 10, 25, 50, 100) the script:
#   1. Deploys N services (Deployment + Service + HTTPScaledObject) at 0 replicas.
#   2. Verifies every deployment has 0 ready replicas.
#   3. Simultaneously sends 15 RPS per service through the KHA interceptor proxy.
#   4. Collects per-service error rates, latency, and KHA resource consumption.
#
# Usage:
#   ./test_cold_start.sh [OPTIONS]
#
# Options:
#   --no-cleanup              Keep test resources after completion
#   --results-dir DIR         Custom results directory
#   --duration SECS           Load duration per level (default: 60)
#   --cooldown SECS           Cooldown between levels (default: 60)
#   --rps-per-service N       RPS to send per service (default: 15)
#   --service-counts "1 10"   Space-separated list of counts (default: "1 10 25 50 100")
#
# Prerequisites:
#   - kubectl configured and connected to the cluster
#   - jq installed
#   - KHA already installed in the target namespace
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
NAMESPACE="autoscale-test"
DURATION=60
COOLDOWN=60
NO_CLEANUP=false
RESULTS_DIR=""
RPS_PER_SERVICE=15
CONNECTIONS_PER_SERVICE=4
SCALE_DOWN_TIMEOUT=180

SERVICE_COUNTS=(1 10 25 50 100)

INTERCEPTOR_SVC="keda-add-ons-http-interceptor-proxy"
INTERCEPTOR_PORT=8080
TARGET_URL="http://${INTERCEPTOR_SVC}:${INTERCEPTOR_PORT}/"

FORTIO_IMAGE="fortio/fortio:latest"

NODE_SELECTOR_KEY="gke-pool-type"
NODE_SELECTOR_VALUE="autoscale-test"
TAINT_KEY="autoscale-test"
TAINT_VALUE="true"
TAINT_EFFECT="NoSchedule"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Background PIDs
MONITOR_PID=""
LOAD_PIDS=()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "===> $*"; }
warn()  { echo "WARN: $*" >&2; }
error() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: test_cold_start.sh [OPTIONS]

KHA cold-start performance test.

Options:
  --no-cleanup              Keep test resources after completion
  --results-dir DIR         Custom results directory
  --duration SECS           Load duration per level (default: 60)
  --cooldown SECS           Cooldown between levels (default: 60)
  --rps-per-service N       RPS per service (default: 15)
  --service-counts "1 10"   Space-separated service count levels (default: "1 10 25 50 100")

Examples:
  ./test_cold_start.sh --duration 30 --cooldown 30
  ./test_cold_start.sh --no-cleanup --service-counts "1 5 10"
EOF
    exit 0
}

cleanup_on_exit() {
    if [[ -n "${MONITOR_PID}" ]]; then
        kill "${MONITOR_PID}" 2>/dev/null || true
        wait "${MONITOR_PID}" 2>/dev/null || true
    fi
    for pid in "${LOAD_PIDS[@]+"${LOAD_PIDS[@]}"}"; do
        kill "${pid}" 2>/dev/null || true
    done
}
trap cleanup_on_exit EXIT

service_name() {
    printf "cold-start-app-%03d" "$1"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-cleanup)       NO_CLEANUP=true; shift ;;
            --results-dir)      RESULTS_DIR="$2"; shift 2 ;;
            --duration)         DURATION="$2"; shift 2 ;;
            --cooldown)         COOLDOWN="$2"; shift 2 ;;
            --rps-per-service)  RPS_PER_SERVICE="$2"; shift 2 ;;
            --service-counts)   read -ra SERVICE_COUNTS <<< "$2"; shift 2 ;;
            --help|-h)          usage ;;
            *)                  error "Unknown option: $1" ;;
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

    kubectl cluster-info >/dev/null 2>&1 || error "Cannot connect to Kubernetes cluster"

    kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || \
        error "Namespace '${NAMESPACE}' does not exist. Install KHA first."

    kubectl get deployment -n "${NAMESPACE}" -o name 2>/dev/null | grep -q "interceptor" || \
        error "KHA interceptor not found in '${NAMESPACE}'. Install KHA first."

    info "All prerequisites met"
}

# ---------------------------------------------------------------------------
# Deploy N services from templates (batched into a single kubectl apply)
# ---------------------------------------------------------------------------
deploy_services() {
    local count=$1
    local manifest="${RESULTS_DIR}/manifests_${count}.yaml"
    info "Deploying ${count} service(s)"

    : > "${manifest}"
    for i in $(seq 1 "${count}"); do
        local name
        name=$(service_name "${i}")
        sed "s/__NAME__/${name}/g" "${SCRIPT_DIR}/deployment.yaml" >> "${manifest}"
        echo "---" >> "${manifest}"
        sed "s/__NAME__/${name}/g" "${SCRIPT_DIR}/httpso.yaml" >> "${manifest}"
        if [[ ${i} -lt ${count} ]]; then
            echo "---" >> "${manifest}"
        fi
    done

    kubectl apply -f "${manifest}"

    info "Waiting for HTTPScaledObjects to be reconciled"
    sleep 10

    local reconciled=0
    for i in $(seq 1 "${count}"); do
        local name
        name=$(service_name "${i}")
        if kubectl get httpscaledobject "${name}-httpso" -n "${NAMESPACE}" >/dev/null 2>&1; then
            reconciled=$((reconciled + 1))
        fi
    done
    info "${reconciled}/${count} HTTPScaledObjects reconciled"
}

# ---------------------------------------------------------------------------
# Ensure every deployment is at 0 ready replicas
# ---------------------------------------------------------------------------
ensure_zero_replicas() {
    local count=$1
    info "Scaling all ${count} deployment(s) to 0 replicas"

    for i in $(seq 1 "${count}"); do
        local name
        name=$(service_name "${i}")
        kubectl scale deployment "${name}" -n "${NAMESPACE}" --replicas=0 2>/dev/null || true
    done

    info "Waiting for all deployments to reach 0 ready replicas (timeout ${SCALE_DOWN_TIMEOUT}s)"
    local deadline=$((SECONDS + SCALE_DOWN_TIMEOUT))
    while [[ ${SECONDS} -lt ${deadline} ]]; do
        local all_zero=true
        for i in $(seq 1 "${count}"); do
            local name
            name=$(service_name "${i}")
            local ready
            ready=$(kubectl get deployment "${name}" -n "${NAMESPACE}" \
                -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            ready="${ready:-0}"
            if [[ "${ready}" != "0" && "${ready}" != "" ]]; then
                all_zero=false
                break
            fi
        done

        if [[ "${all_zero}" == "true" ]]; then
            info "All deployments confirmed at 0 replicas"
            return 0
        fi
        sleep 5
    done

    error "Timed out waiting for deployments to scale to zero"
}

# ---------------------------------------------------------------------------
# Deploy load generator pod (fortio)
# ---------------------------------------------------------------------------
deploy_load_generator() {
    info "Deploying load generator pod (fortio)"

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
# Resource monitor (background, writes CSV)
# ---------------------------------------------------------------------------
start_resource_monitor() {
    local csv="$1"
    info "Starting resource monitor -> ${csv}"
    echo "timestamp,pod,cpu,memory" > "${csv}"

    (
        while true; do
            local ts
            ts=$(date +%s)
            kubectl top pod -n "${NAMESPACE}" --no-headers 2>/dev/null | \
                while IFS= read -r line; do
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
# Run cold-start load test for N services (parallel fortio instances)
# ---------------------------------------------------------------------------
run_cold_start_test() {
    local count=$1
    local level_dir=$2

    info "Sending ${RPS_PER_SERVICE} RPS to each of ${count} service(s) for ${DURATION}s"

    echo "MARKER,${count},START,$(date +%s)" >> "${level_dir}/resource_metrics.csv"

    LOAD_PIDS=()
    for i in $(seq 1 "${count}"); do
        local name
        name=$(service_name "${i}")
        local host="${name}.local"
        local json_file="${level_dir}/fortio_${name}.json"
        local txt_file="${level_dir}/fortio_${name}.txt"

        kubectl exec load-generator -n "${NAMESPACE}" -- \
            fortio load \
            -qps "${RPS_PER_SERVICE}" \
            -t "${DURATION}s" \
            -c "${CONNECTIONS_PER_SERVICE}" \
            -p "50,75,90,95,99,99.9" \
            -json /dev/stdout \
            -H "Host: ${host}" \
            -allow-initial-errors \
            "${TARGET_URL}" > "${json_file}" 2> "${txt_file}" &
        LOAD_PIDS+=($!)
    done

    info "Waiting for all ${count} load generator(s) to finish"
    local exec_failures=0
    for pid in "${LOAD_PIDS[@]}"; do
        wait "${pid}" || exec_failures=$((exec_failures + 1))
    done
    LOAD_PIDS=()

    echo "MARKER,${count},END,$(date +%s)" >> "${level_dir}/resource_metrics.csv"

    if [[ ${exec_failures} -gt 0 ]]; then
        warn "${exec_failures} fortio process(es) exited with errors"
    fi

    # Snapshot pod state right after the load
    kubectl top pod -n "${NAMESPACE}" --no-headers \
        > "${level_dir}/top_pods.txt" 2>/dev/null || true
    kubectl get pods -n "${NAMESPACE}" --no-headers \
        > "${level_dir}/pods.txt" 2>/dev/null || true

    info "Load test complete for ${count} service(s)"
}

# ---------------------------------------------------------------------------
# Parse CPU from kubectl-top notation (e.g. "5m" -> 5, "1" -> 1000)
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
# Aggregate KHA component resources from a kubectl-top snapshot
# Returns: total_cpu_m total_mem_mi
# ---------------------------------------------------------------------------
aggregate_kha_resources() {
    local top_file=$1
    local total_cpu=0 total_mem=0

    if [[ ! -f "${top_file}" ]]; then
        echo "0 0"
        return
    fi

    while read -r pod cpu mem _rest; do
        case "${pod}" in
            *interceptor*|*operator*|*metrics*)
                total_cpu=$(( total_cpu + $(parse_cpu_milli "${cpu}") ))
                total_mem=$(( total_mem + $(parse_mem_mi "${mem}") ))
                ;;
        esac
    done < "${top_file}"

    echo "${total_cpu} ${total_mem}"
}

# ---------------------------------------------------------------------------
# Get a latency percentile from fortio JSON (returns ms)
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
# Generate per-level report, append a row to the global summary CSV
# ---------------------------------------------------------------------------
generate_level_report() {
    local count=$1
    local level_dir=$2

    info "Generating report for ${count} service(s)"

    # -- Per-service detail CSV --
    local detail_csv="${level_dir}/per_service.csv"
    echo "service,total_reqs,success,errors,error_pct,p50_ms,p90_ms,p99_ms" > "${detail_csv}"

    local total_requests=0
    local total_success=0
    local total_errors=0
    local failed_services=0
    local healthy_services=0

    for i in $(seq 1 "${count}"); do
        local name
        name=$(service_name "${i}")
        local json="${level_dir}/fortio_${name}.json"

        if [[ ! -f "${json}" || ! -s "${json}" ]]; then
            echo "${name},0,0,0,100.00,N/A,N/A,N/A" >> "${detail_csv}"
            failed_services=$((failed_services + 1))
            continue
        fi

        local reqs ok errs err_pct
        reqs=$(jq -r '.DurationHistogram.Count // 0' "${json}" 2>/dev/null || echo "0")
        ok=$(jq -r '.RetCodes["200"] // 0' "${json}" 2>/dev/null || echo "0")
        errs=$(jq -r '[.RetCodes | to_entries[] | select(.key != "200") | .value] | add // 0' \
            "${json}" 2>/dev/null || echo "0")

        if [[ "${reqs}" -gt 0 ]] 2>/dev/null; then
            err_pct=$(awk "BEGIN {printf \"%.2f\", ${errs} * 100 / ${reqs}}")
        else
            err_pct="100.00"
        fi

        local p50 p90 p99
        p50=$(get_percentile "${json}" "50")
        p90=$(get_percentile "${json}" "90")
        p99=$(get_percentile "${json}" "99")

        for var in p50 p90 p99; do
            local val="${!var}"
            if [[ "${val}" != "N/A" ]]; then
                printf -v "${var}" "%.2f" "${val}" 2>/dev/null || true
            fi
        done

        echo "${name},${reqs},${ok},${errs},${err_pct},${p50},${p90},${p99}" >> "${detail_csv}"

        total_requests=$((total_requests + reqs))
        total_success=$((total_success + ok))
        total_errors=$((total_errors + errs))

        if [[ "${ok}" -eq 0 ]]; then
            failed_services=$((failed_services + 1))
        elif (( $(awk "BEGIN {print (${err_pct} < 5) ? 1 : 0}") )); then
            healthy_services=$((healthy_services + 1))
        fi
    done

    local overall_err_pct="0.00"
    if [[ "${total_requests}" -gt 0 ]]; then
        overall_err_pct=$(awk "BEGIN {printf \"%.2f\", ${total_errors} * 100 / ${total_requests}}")
    fi

    # -- KHA resource snapshot --
    local top_file="${level_dir}/top_pods.txt"
    local kha_cpu=0 kha_mem=0
    if [[ -f "${top_file}" ]]; then
        read -r kha_cpu kha_mem <<< "$(aggregate_kha_resources "${top_file}")"
    fi

    # -- App pod count --
    local app_pods=0
    if [[ -f "${level_dir}/pods.txt" ]]; then
        app_pods=$(grep -c "cold-start-app" "${level_dir}/pods.txt" 2>/dev/null || echo "0")
    fi

    # -- Level summary text --
    local summary="${level_dir}/summary.txt"
    cat > "${summary}" <<EOF
------------------------------------------------------------------------
  Cold-Start Level: ${count} service(s)
------------------------------------------------------------------------
Target RPS/service:  ${RPS_PER_SERVICE}
Total target RPS:    $((count * RPS_PER_SERVICE))
Duration:            ${DURATION}s

Total requests:      ${total_requests}
Successful:          ${total_success}
Errors:              ${total_errors}
Error rate:          ${overall_err_pct}%

Failed services:     ${failed_services} / ${count}  (0 successful responses)
Healthy services:    ${healthy_services} / ${count}  (<5% error rate)
App pods running:    ${app_pods}

KHA CPU (m):         ${kha_cpu}
KHA Memory (Mi):     ${kha_mem}
------------------------------------------------------------------------
EOF
    cat "${summary}"

    # -- Append row to global summary CSV --
    echo "${count},${total_requests},${total_success},${total_errors},${overall_err_pct},${failed_services},${healthy_services},${app_pods},${kha_cpu},${kha_mem}" \
        >> "${RESULTS_DIR}/summary.csv"
}

# ---------------------------------------------------------------------------
# Collect KHA component logs
# ---------------------------------------------------------------------------
collect_kha_logs() {
    local level_dir=$1
    local log_file="${level_dir}/kha_logs.txt"
    info "Collecting KHA component logs"
    : > "${log_file}"

    local pods
    pods=$(kubectl get pods -n "${NAMESPACE}" -o name 2>/dev/null \
        | grep -E 'interceptor|operator|metrics' || true)

    if [[ -z "${pods}" ]]; then
        echo "(no KHA pods found)" > "${log_file}"
        return
    fi

    for pod in ${pods}; do
        {
            echo "======== $(basename "${pod}") ========"
            kubectl logs -n "${NAMESPACE}" "${pod}" --tail=2000 2>/dev/null \
                || echo "(failed to retrieve logs)"
            echo ""
        } >> "${log_file}"
    done
}

# ---------------------------------------------------------------------------
# Cleanup services for a given level
# ---------------------------------------------------------------------------
cleanup_services() {
    local count=$1
    info "Cleaning up ${count} service(s)"

    local manifest="${RESULTS_DIR}/manifests_${count}.yaml"
    if [[ -f "${manifest}" ]]; then
        kubectl delete -f "${manifest}" --ignore-not-found --wait=false 2>/dev/null || true
    fi

    # Wait briefly for resources to disappear
    sleep 10
    info "Cleanup complete for ${count} service(s)"
}

# ---------------------------------------------------------------------------
# Generate final summary across all levels
# ---------------------------------------------------------------------------
generate_final_summary() {
    local summary="${RESULTS_DIR}/summary.txt"
    info "Generating final summary"

    {
        echo "========================================================================"
        echo "  KHA Cold-Start Performance Test Summary"
        echo "========================================================================"
        echo ""
        echo "Date:             $(date)"
        echo "Namespace:        ${NAMESPACE}"
        echo "Duration/level:   ${DURATION}s"
        echo "Cooldown:         ${COOLDOWN}s"
        echo "RPS/service:      ${RPS_PER_SERVICE}"
        echo "Connections/svc:  ${CONNECTIONS_PER_SERVICE}"
        echo "Results:          ${RESULTS_DIR}"
        echo ""
        printf "%-8s  %-10s  %-10s  %-10s  %-8s  %-10s  %-10s  %-8s  %-10s  %-10s\n" \
            "Svcs" "TotalReqs" "Success" "Errors" "Err%" \
            "FailedSvc" "HealthySvc" "AppPods" "CPU(m)" "Mem(Mi)"
        printf "%-8s  %-10s  %-10s  %-10s  %-8s  %-10s  %-10s  %-8s  %-10s  %-10s\n" \
            "------" "--------" "-------" "------" "------" \
            "---------" "----------" "-------" "------" "-------"
    } > "${summary}"

    if [[ -f "${RESULTS_DIR}/summary.csv" ]]; then
        while IFS=',' read -r svcs total_reqs success errors err_pct failed healthy app_pods cpu mem; do
            printf "%-8s  %-10s  %-10s  %-10s  %-8s  %-10s  %-10s  %-8s  %-10s  %-10s\n" \
                "${svcs}" "${total_reqs}" "${success}" "${errors}" "${err_pct}" \
                "${failed}" "${healthy}" "${app_pods}" "${cpu}" "${mem}" \
                >> "${summary}"
        done < "${RESULTS_DIR}/summary.csv"
    fi

    {
        echo ""
        echo "------------------------------------------------------------------------"
        echo "Per-level details:   ${RESULTS_DIR}/<N>-services/"
        echo "Global CSV:          ${RESULTS_DIR}/summary.csv"
        echo "========================================================================"
    } >> "${summary}"

    echo ""
    cat "${summary}"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    if [[ -z "${RESULTS_DIR}" ]]; then
        RESULTS_DIR="${SCRIPT_DIR}/results/cold-start-$(date +%Y%m%d-%H%M%S)"
    fi
    mkdir -p "${RESULTS_DIR}"
    info "Results will be saved to: ${RESULTS_DIR}"

    # CSV header
    echo "services,total_reqs,success,errors,error_pct,failed_svcs,healthy_svcs,app_pods,kha_cpu_m,kha_mem_mi" \
        > "${RESULTS_DIR}/summary.csv"

    check_prerequisites
    deploy_load_generator

    for idx in "${!SERVICE_COUNTS[@]}"; do
        local count="${SERVICE_COUNTS[${idx}]}"
        local level_dir="${RESULTS_DIR}/${count}-services"
        mkdir -p "${level_dir}"

        info "========== Level: ${count} service(s) =========="

        deploy_services "${count}"
        ensure_zero_replicas "${count}"

        start_resource_monitor "${level_dir}/resource_metrics.csv"

        run_cold_start_test "${count}" "${level_dir}"

        stop_resource_monitor
        collect_kha_logs "${level_dir}"
        generate_level_report "${count}" "${level_dir}"

        if [[ "${NO_CLEANUP}" != "true" ]]; then
            cleanup_services "${count}"
        fi

        # Cooldown between levels (skip after the last one)
        if [[ ${idx} -lt $(( ${#SERVICE_COUNTS[@]} - 1 )) ]]; then
            info "Cooling down for ${COOLDOWN}s"
            sleep "${COOLDOWN}"
        fi
    done

    generate_final_summary

    # Clean up load generator
    if [[ "${NO_CLEANUP}" != "true" ]]; then
        info "Cleaning up load generator"
        kubectl delete pod load-generator -n "${NAMESPACE}" \
            --ignore-not-found --wait 2>/dev/null || true
    fi

    info "All done! Results: ${RESULTS_DIR}"
}

main "$@"
