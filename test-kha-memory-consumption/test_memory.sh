#!/usr/bin/env bash
#
# test_memory.sh - KHA memory-consumption test
#
# Gradually deploys an increasing number of services (Deployment + Service +
# HTTPScaledObject) and measures memory (and CPU) of KHA components at each
# step.  No traffic is sent — the test isolates the overhead that each
# additional HTTPScaledObject adds to the control plane.
#
# Service counts are cumulative: at each level the script deploys just the
# delta, so resources accumulate across levels.
#
# Usage:
#   ./test_memory.sh [OPTIONS]
#
# Options:
#   --no-cleanup              Keep test resources after completion
#   --results-dir DIR         Custom results directory
#   --settle-time SECS        Wait after deploying before measuring (default: 30)
#   --samples N               Number of kubectl-top samples per level (default: 3)
#   --sample-interval SECS    Seconds between samples (default: 10)
#   --service-counts "1 10"   Space-separated cumulative counts (default: "1 10 25 50 100")
#
# Prerequisites:
#   - kubectl configured and connected to the cluster
#   - KHA already installed in the target namespace
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
NAMESPACE="autoscale-test"
NO_CLEANUP=false
RESULTS_DIR=""
SETTLE_TIME=30
SAMPLE_COUNT=3
SAMPLE_INTERVAL=10

SERVICE_COUNTS=(1 10 25 50 100)

NODE_SELECTOR_KEY="gke-pool-type"
NODE_SELECTOR_VALUE="autoscale-test"
TAINT_KEY="autoscale-test"
TAINT_VALUE="true"
TAINT_EFFECT="NoSchedule"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Tracks how many services are currently deployed (cumulative)
DEPLOYED_COUNT=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "===> $*"; }
warn()  { echo "WARN: $*" >&2; }
error() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: test_memory.sh [OPTIONS]

KHA memory-consumption test.

Options:
  --no-cleanup              Keep test resources after completion
  --results-dir DIR         Custom results directory
  --settle-time SECS        Wait after deploying before measuring (default: 30)
  --samples N               kubectl-top samples per level (default: 3)
  --sample-interval SECS    Seconds between samples (default: 10)
  --service-counts "1 10"   Cumulative service count levels (default: "1 10 25 50 100")

Examples:
  ./test_memory.sh --settle-time 60 --samples 5
  ./test_memory.sh --no-cleanup --service-counts "1 5 10 20 50 100 200"
EOF
    exit 0
}

service_name() {
    printf "mem-test-app-%03d" "$1"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-cleanup)        NO_CLEANUP=true; shift ;;
            --results-dir)       RESULTS_DIR="$2"; shift 2 ;;
            --settle-time)       SETTLE_TIME="$2"; shift 2 ;;
            --samples)           SAMPLE_COUNT="$2"; shift 2 ;;
            --sample-interval)   SAMPLE_INTERVAL="$2"; shift 2 ;;
            --service-counts)    read -ra SERVICE_COUNTS <<< "$2"; shift 2 ;;
            --help|-h)           usage ;;
            *)                   error "Unknown option: $1" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
check_prerequisites() {
    info "Checking prerequisites"
    command -v kubectl >/dev/null 2>&1 || error "kubectl is required but not installed"

    kubectl cluster-info >/dev/null 2>&1 || error "Cannot connect to Kubernetes cluster"

    kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || \
        error "Namespace '${NAMESPACE}' does not exist. Install KHA first."

    kubectl get deployment -n "${NAMESPACE}" -o name 2>/dev/null | grep -q "interceptor" || \
        error "KHA interceptor not found in '${NAMESPACE}'. Install KHA first."

    info "All prerequisites met"
}

# ---------------------------------------------------------------------------
# Deploy services from (prev_count+1) to target_count (cumulative)
# ---------------------------------------------------------------------------
deploy_services_delta() {
    local target_count=$1
    local start=$(( DEPLOYED_COUNT + 1 ))
    local delta=$(( target_count - DEPLOYED_COUNT ))

    if [[ ${delta} -le 0 ]]; then
        info "Already have ${DEPLOYED_COUNT} service(s), nothing to deploy"
        return
    fi

    info "Deploying services ${start}..${target_count} (${delta} new, ${target_count} total)"

    local manifest="${RESULTS_DIR}/manifests_${start}_to_${target_count}.yaml"
    : > "${manifest}"

    for i in $(seq "${start}" "${target_count}"); do
        local name
        name=$(service_name "${i}")
        sed "s/__NAME__/${name}/g" "${SCRIPT_DIR}/deployment.yaml" >> "${manifest}"
        echo "---" >> "${manifest}"
        sed "s/__NAME__/${name}/g" "${SCRIPT_DIR}/httpso.yaml" >> "${manifest}"
        if [[ ${i} -lt ${target_count} ]]; then
            echo "---" >> "${manifest}"
        fi
    done

    kubectl apply -f "${manifest}"
    DEPLOYED_COUNT=${target_count}

    info "Waiting for new deployments to become ready"
    local ready_count=0
    local timeout=300
    local deadline=$((SECONDS + timeout))
    while [[ ${SECONDS} -lt ${deadline} ]]; do
        ready_count=0
        for i in $(seq "${start}" "${target_count}"); do
            local name
            name=$(service_name "${i}")
            local ready
            ready=$(kubectl get deployment "${name}" -n "${NAMESPACE}" \
                -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            ready="${ready:-0}"
            if [[ "${ready}" -ge 1 ]]; then
                ready_count=$((ready_count + 1))
            fi
        done

        if [[ ${ready_count} -ge ${delta} ]]; then
            break
        fi
        sleep 5
    done

    info "${ready_count}/${delta} new deployments ready"

    local reconciled=0
    for i in $(seq "${start}" "${target_count}"); do
        local name
        name=$(service_name "${i}")
        if kubectl get httpscaledobject "${name}-httpso" -n "${NAMESPACE}" >/dev/null 2>&1; then
            reconciled=$((reconciled + 1))
        fi
    done
    info "${reconciled}/${delta} new HTTPScaledObjects reconciled"
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
# Take resource samples and write per-component breakdown
#
# Writes:
#   <level_dir>/top_sample_N.txt   — raw kubectl-top output per sample
#   <level_dir>/components.csv     — per-component averages
#
# Prints:  total_cpu_m total_mem_mi  (averaged across samples)
# ---------------------------------------------------------------------------
measure_resources() {
    local level_dir=$1

    info "Taking ${SAMPLE_COUNT} resource sample(s) (interval ${SAMPLE_INTERVAL}s)"

    # Accumulate per-component totals across samples to compute averages.
    # We use associative arrays keyed by a normalised component name.
    declare -A comp_cpu_sum comp_mem_sum comp_count

    for s in $(seq 1 "${SAMPLE_COUNT}"); do
        local raw="${level_dir}/top_sample_${s}.txt"
        kubectl top pod -n "${NAMESPACE}" --no-headers > "${raw}" 2>/dev/null || true

        while read -r pod cpu mem _rest; do
            local component=""
            case "${pod}" in
                *interceptor-proxy*)  component="interceptor-proxy" ;;
                *interceptor-admin*)  component="interceptor-admin" ;;
                *interceptor*)        component="interceptor" ;;
                *operator*)           component="operator" ;;
                *metrics*)            component="metrics-server" ;;
                *scaler*)             component="scaler" ;;
                *)                    continue ;;
            esac

            local cpu_m mem_mi
            cpu_m=$(parse_cpu_milli "${cpu}")
            mem_mi=$(parse_mem_mi "${mem}")

            comp_cpu_sum["${component}"]=$(( ${comp_cpu_sum["${component}"]:-0} + cpu_m ))
            comp_mem_sum["${component}"]=$(( ${comp_mem_sum["${component}"]:-0} + mem_mi ))
            comp_count["${component}"]=$(( ${comp_count["${component}"]:-0} + 1 ))
        done < "${raw}"

        if [[ ${s} -lt ${SAMPLE_COUNT} ]]; then
            sleep "${SAMPLE_INTERVAL}"
        fi
    done

    # Write per-component averages
    local comp_csv="${level_dir}/components.csv"
    echo "component,avg_cpu_m,avg_mem_mi,samples" > "${comp_csv}"

    local total_cpu=0 total_mem=0
    for comp in $(echo "${!comp_cpu_sum[@]}" | tr ' ' '\n' | sort); do
        local n=${comp_count["${comp}"]}
        local avg_cpu=$(( comp_cpu_sum["${comp}"] / n ))
        local avg_mem=$(( comp_mem_sum["${comp}"] / n ))
        echo "${comp},${avg_cpu},${avg_mem},${n}" >> "${comp_csv}"
        total_cpu=$(( total_cpu + avg_cpu ))
        total_mem=$(( total_mem + avg_mem ))
    done

    echo "${total_cpu} ${total_mem}"
}

# ---------------------------------------------------------------------------
# Generate per-level summary
# ---------------------------------------------------------------------------
generate_level_report() {
    local count=$1
    local level_dir=$2
    local total_cpu=$3
    local total_mem=$4

    local summary="${level_dir}/summary.txt"
    {
        echo "------------------------------------------------------------------------"
        echo "  Memory Level: ${count} HTTPScaledObject(s)"
        echo "------------------------------------------------------------------------"
        echo "Settle time:     ${SETTLE_TIME}s"
        echo "Samples:         ${SAMPLE_COUNT} (every ${SAMPLE_INTERVAL}s)"
        echo ""
        echo "KHA total CPU (m):   ${total_cpu}"
        echo "KHA total Mem (Mi):  ${total_mem}"
        echo ""
        echo "Per-component breakdown:"
        column -t -s',' "${level_dir}/components.csv" 2>/dev/null \
            || cat "${level_dir}/components.csv"
        echo "------------------------------------------------------------------------"
    } > "${summary}"

    cat "${summary}"

    echo "${count},${total_cpu},${total_mem}" >> "${RESULTS_DIR}/summary.csv"
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
        | grep -E 'interceptor|operator|metrics|scaler' || true)

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
# Cleanup all deployed services
# ---------------------------------------------------------------------------
cleanup_all_services() {
    info "Cleaning up all ${DEPLOYED_COUNT} service(s)"

    for f in "${RESULTS_DIR}"/manifests_*.yaml; do
        [[ -f "${f}" ]] || continue
        kubectl delete -f "${f}" --ignore-not-found --wait=false 2>/dev/null || true
    done

    sleep 15
    info "Cleanup complete"
}

# ---------------------------------------------------------------------------
# Generate final summary table
# ---------------------------------------------------------------------------
generate_final_summary() {
    local summary="${RESULTS_DIR}/summary.txt"
    info "Generating final summary"

    {
        echo "========================================================================"
        echo "  KHA Memory-Consumption Test Summary"
        echo "========================================================================"
        echo ""
        echo "Date:              $(date)"
        echo "Namespace:         ${NAMESPACE}"
        echo "Settle time:       ${SETTLE_TIME}s"
        echo "Samples/level:     ${SAMPLE_COUNT} (every ${SAMPLE_INTERVAL}s)"
        echo "Results:           ${RESULTS_DIR}"
        echo ""
        printf "%-12s  %-12s  %-12s\n" \
            "HTTPSOs" "KHA_CPU(m)" "KHA_Mem(Mi)"
        printf "%-12s  %-12s  %-12s\n" \
            "----------" "----------" "-----------"
    } > "${summary}"

    if [[ -f "${RESULTS_DIR}/summary.csv" ]]; then
        while IFS=',' read -r httpsos cpu mem; do
            printf "%-12s  %-12s  %-12s\n" \
                "${httpsos}" "${cpu}" "${mem}" >> "${summary}"
        done < "${RESULTS_DIR}/summary.csv"
    fi

    {
        echo ""
        echo "------------------------------------------------------------------------"
        echo "Per-level details:   ${RESULTS_DIR}/<N>-httpsos/"
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
        RESULTS_DIR="${SCRIPT_DIR}/results/memory-$(date +%Y%m%d-%H%M%S)"
    fi
    mkdir -p "${RESULTS_DIR}"
    info "Results will be saved to: ${RESULTS_DIR}"

    echo "httpsos,kha_cpu_m,kha_mem_mi" > "${RESULTS_DIR}/summary.csv"

    check_prerequisites

    # -- Baseline measurement (0 HTTPScaledObjects from this test) --
    info "========== Baseline (0 test HTTPScaledObjects) =========="
    local baseline_dir="${RESULTS_DIR}/0-httpsos"
    mkdir -p "${baseline_dir}"
    local base_cpu base_mem
    read -r base_cpu base_mem <<< "$(measure_resources "${baseline_dir}")"
    generate_level_report 0 "${baseline_dir}" "${base_cpu}" "${base_mem}"

    # -- Cumulative levels --
    for count in "${SERVICE_COUNTS[@]}"; do
        local level_dir="${RESULTS_DIR}/${count}-httpsos"
        mkdir -p "${level_dir}"

        info "========== Level: ${count} HTTPScaledObject(s) =========="

        deploy_services_delta "${count}"

        info "Letting KHA settle for ${SETTLE_TIME}s"
        sleep "${SETTLE_TIME}"

        local total_cpu total_mem
        read -r total_cpu total_mem <<< "$(measure_resources "${level_dir}")"
        collect_kha_logs "${level_dir}"
        generate_level_report "${count}" "${level_dir}" "${total_cpu}" "${total_mem}"
    done

    generate_final_summary

    if [[ "${NO_CLEANUP}" != "true" ]]; then
        cleanup_all_services
    fi

    info "All done! Results: ${RESULTS_DIR}"
}

main "$@"
