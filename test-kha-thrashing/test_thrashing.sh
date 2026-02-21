#!/usr/bin/env bash
#
# test_thrashing.sh - KHA scaling thrashing test
#
# Sends steady traffic at several RPS levels to a single service and monitors
# the replica count over time.  For each level the script records:
#   - expected vs actual replica count
#   - min / max / avg replicas during the observation window
#   - number of scale events (thrashing)
#   - percentage of time spent at the expected replica count (accuracy)
#   - time to first reach the expected count
#
# Usage:
#   ./test_thrashing.sh [OPTIONS]
#
# Options:
#   --no-cleanup              Keep test resources after completion
#   --results-dir DIR         Custom results directory
#   --ramp-up SECS            Ramp-up allowance before observing (default: 120)
#   --observation SECS        Observation window per level (default: 180)
#   --poll-interval SECS      Replica polling interval (default: 5)
#   --cooldown SECS           Cooldown between levels (default: 60)
#   --target-value N          HTTPSO requestRate target (default: 100)
#   --rps-levels "100 200"    Space-separated RPS levels (default: "50 100 200 300 500 1000")
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
NO_CLEANUP=false
RESULTS_DIR=""

TARGET_VALUE=100
MIN_REPLICAS=1
MAX_REPLICAS=20

RAMP_UP=120
OBSERVATION=180
POLL_INTERVAL=5
COOLDOWN=60

RPS_LEVELS=(50 100 200 300 500 1000)

DEPLOYMENT_NAME="scaling-test-app"
TARGET_HOST="scaling-test-app.local"

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

FORTIO_PID=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "===> $*"; }
warn()  { echo "WARN: $*" >&2; }
error() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: test_thrashing.sh [OPTIONS]

KHA scaling thrashing test.

Options:
  --no-cleanup              Keep test resources after completion
  --results-dir DIR         Custom results directory
  --ramp-up SECS            Ramp-up allowance before observing (default: 120)
  --observation SECS        Observation window per level (default: 180)
  --poll-interval SECS      Replica polling interval (default: 5)
  --cooldown SECS           Cooldown between levels (default: 60)
  --target-value N          HTTPSO requestRate target (default: 100)
  --rps-levels "100 200"    Space-separated RPS levels (default: "50 100 200 300 500 1000")

Examples:
  ./test_thrashing.sh --observation 300 --cooldown 90
  ./test_thrashing.sh --target-value 50 --rps-levels "25 50 100 250 500"
EOF
    exit 0
}

cleanup_on_exit() {
    if [[ -n "${FORTIO_PID}" ]]; then
        kill "${FORTIO_PID}" 2>/dev/null || true
        wait "${FORTIO_PID}" 2>/dev/null || true
    fi
}
trap cleanup_on_exit EXIT

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-cleanup)      NO_CLEANUP=true; shift ;;
            --results-dir)     RESULTS_DIR="$2"; shift 2 ;;
            --ramp-up)         RAMP_UP="$2"; shift 2 ;;
            --observation)     OBSERVATION="$2"; shift 2 ;;
            --poll-interval)   POLL_INTERVAL="$2"; shift 2 ;;
            --cooldown)        COOLDOWN="$2"; shift 2 ;;
            --target-value)    TARGET_VALUE="$2"; shift 2 ;;
            --rps-levels)      read -ra RPS_LEVELS <<< "$2"; shift 2 ;;
            --help|-h)         usage ;;
            *)                 error "Unknown option: $1" ;;
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
    command -v awk     >/dev/null 2>&1 || error "awk is required but not installed"

    kubectl cluster-info >/dev/null 2>&1 || error "Cannot connect to Kubernetes cluster"

    kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || \
        error "Namespace '${NAMESPACE}' does not exist. Install KHA first."

    kubectl get deployment -n "${NAMESPACE}" -o name 2>/dev/null | grep -q "interceptor" || \
        error "KHA interceptor not found in '${NAMESPACE}'. Install KHA first."

    info "All prerequisites met"
}

# ---------------------------------------------------------------------------
# Deploy workload (single Deployment + Service + HTTPScaledObject)
# ---------------------------------------------------------------------------
deploy_workload() {
    info "Deploying scaling-test-app workload"
    kubectl apply -f "${SCRIPT_DIR}/deployment.yaml"
    kubectl apply -f "${SCRIPT_DIR}/httpso.yaml"

    info "Waiting for deployment to be ready"
    kubectl rollout status deployment "${DEPLOYMENT_NAME}" \
        -n "${NAMESPACE}" --timeout=120s

    info "Waiting for HTTPScaledObject to be reconciled"
    sleep 10
    kubectl get httpscaledobject "${DEPLOYMENT_NAME}-httpso" -n "${NAMESPACE}" >/dev/null 2>&1 || \
        error "HTTPScaledObject was not created"

    info "Workload deployed"
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
# Compute expected replicas for a given RPS: ceil(rps / target), clamped
# ---------------------------------------------------------------------------
expected_replicas() {
    local rps=$1
    local exp=$(( (rps + TARGET_VALUE - 1) / TARGET_VALUE ))
    [[ ${exp} -lt ${MIN_REPLICAS} ]] && exp=${MIN_REPLICAS}
    [[ ${exp} -gt ${MAX_REPLICAS} ]] && exp=${MAX_REPLICAS}
    echo "${exp}"
}

# ---------------------------------------------------------------------------
# Compute concurrent connections for a given RPS
# ---------------------------------------------------------------------------
calculate_connections() {
    local rps=$1
    local c=$((rps / 10))
    [[ ${c} -lt 4 ]]   && c=4
    [[ ${c} -gt 128 ]] && c=128
    echo "${c}"
}

# ---------------------------------------------------------------------------
# Parse CPU/Memory from kubectl-top notation
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

aggregate_kha_resources() {
    local top_file=$1
    local total_cpu=0 total_mem=0

    if [[ ! -f "${top_file}" ]]; then
        echo "0 0"
        return
    fi

    while read -r pod cpu mem _rest; do
        case "${pod}" in
            *interceptor*|*operator*|*metrics*|*scaler*)
                total_cpu=$(( total_cpu + $(parse_cpu_milli "${cpu}") ))
                total_mem=$(( total_mem + $(parse_mem_mi "${mem}") ))
                ;;
        esac
    done < "${top_file}"

    echo "${total_cpu} ${total_mem}"
}

# ---------------------------------------------------------------------------
# Reset deployment to MIN_REPLICAS and wait for it to stabilise
# ---------------------------------------------------------------------------
reset_replicas() {
    info "Resetting deployment to ${MIN_REPLICAS} replica(s)"
    kubectl scale deployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" \
        --replicas="${MIN_REPLICAS}"

    local deadline=$((SECONDS + 120))
    while [[ ${SECONDS} -lt ${deadline} ]]; do
        local ready
        ready=$(kubectl get deployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        ready="${ready:-0}"
        if [[ "${ready}" -eq ${MIN_REPLICAS} ]]; then
            info "Deployment at ${MIN_REPLICAS} ready replica(s)"
            return 0
        fi
        sleep 5
    done
    warn "Deployment did not fully reset within timeout"
}

# ---------------------------------------------------------------------------
# Run a single RPS level: send traffic + poll replicas simultaneously
# ---------------------------------------------------------------------------
run_level() {
    local rps=$1
    local level_dir=$2
    local total_duration=$(( RAMP_UP + OBSERVATION ))
    local connections
    connections=$(calculate_connections "${rps}")
    local expected
    expected=$(expected_replicas "${rps}")

    info "[RPS=${rps}] Expected replicas: ${expected}, ramp-up: ${RAMP_UP}s, observation: ${OBSERVATION}s"

    # -- Replica time-series CSV --
    local replica_csv="${level_dir}/replicas.csv"
    echo "elapsed_s,ready_replicas,spec_replicas" > "${replica_csv}"

    # -- Start fortio in background --
    local json_file="${level_dir}/fortio.json"
    local txt_file="${level_dir}/fortio.txt"

    kubectl exec load-generator -n "${NAMESPACE}" -- \
        fortio load \
        -qps "${rps}" \
        -t "${total_duration}s" \
        -c "${connections}" \
        -p "50,75,90,95,99,99.9" \
        -json /dev/stdout \
        -H "Host: ${TARGET_HOST}" \
        -allow-initial-errors \
        "${TARGET_URL}" > "${json_file}" 2> "${txt_file}" &
    FORTIO_PID=$!

    # -- Poll replica count while traffic is running --
    local start_time=${SECONDS}
    while [[ $(( SECONDS - start_time )) -lt ${total_duration} ]]; do
        local elapsed=$(( SECONDS - start_time ))
        local ready spec
        ready=$(kubectl get deployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        spec=$(kubectl get deployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" \
            -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
        ready="${ready:-0}"
        spec="${spec:-0}"
        echo "${elapsed},${ready},${spec}" >> "${replica_csv}"
        sleep "${POLL_INTERVAL}"
    done

    # -- Wait for fortio --
    wait "${FORTIO_PID}" || true
    FORTIO_PID=""

    # -- Resource snapshot --
    kubectl top pod -n "${NAMESPACE}" --no-headers \
        > "${level_dir}/top_pods.txt" 2>/dev/null || true

    info "[RPS=${rps}] Traffic stopped"
}

# ---------------------------------------------------------------------------
# Analyse replica time-series for a single level
#
# Outputs (space-separated):
#   time_to_expected  obs_samples  avg_replicas  min_replicas  max_replicas
#   scale_events  accuracy_pct
# ---------------------------------------------------------------------------
analyse_replicas() {
    local replica_csv=$1
    local expected=$2

    awk -F',' -v ramp="${RAMP_UP}" -v expected="${expected}" '
    NR == 1 { next }
    {
        elapsed = $1 + 0
        ready   = $2 + 0

        if (!first_reached && ready == expected) {
            first_reached = elapsed
        }

        if (elapsed >= ramp) {
            n++
            sum += ready
            if (n == 1 || ready < mn) mn = ready
            if (n == 1 || ready > mx) mx = ready
            if (ready == expected) hit++
            if (n > 1 && ready != prev) events++
            prev = ready
        }
    }
    END {
        fr  = first_reached ? first_reached : "N/A"
        avg = (n > 0) ? sum / n : 0
        acc = (n > 0) ? hit * 100 / n : 0
        if (!mn) mn = 0
        if (!mx) mx = 0
        printf "%s %d %.1f %d %d %d %.1f\n", fr, n+0, avg, mn, mx, events+0, acc
    }' "${replica_csv}"
}

# ---------------------------------------------------------------------------
# Generate per-level report
# ---------------------------------------------------------------------------
generate_level_report() {
    local rps=$1
    local level_dir=$2

    local expected
    expected=$(expected_replicas "${rps}")

    local stats
    stats=$(analyse_replicas "${level_dir}/replicas.csv" "${expected}")

    local time_to_exp obs_samples avg_rep min_rep max_rep scale_events accuracy
    read -r time_to_exp obs_samples avg_rep min_rep max_rep scale_events accuracy <<< "${stats}"

    # KHA resources
    local kha_cpu=0 kha_mem=0
    if [[ -f "${level_dir}/top_pods.txt" ]]; then
        read -r kha_cpu kha_mem <<< "$(aggregate_kha_resources "${level_dir}/top_pods.txt")"
    fi

    # Fortio summary
    local actual_rps total_reqs error_pct
    actual_rps="N/A"; total_reqs="0"; error_pct="N/A"
    local json="${level_dir}/fortio.json"
    if [[ -f "${json}" && -s "${json}" ]]; then
        actual_rps=$(jq -r '.ActualQPS | . * 100 | round / 100' "${json}" 2>/dev/null || echo "N/A")
        total_reqs=$(jq -r '.DurationHistogram.Count // 0' "${json}" 2>/dev/null || echo "0")
        local errs
        errs=$(jq -r '[.RetCodes | to_entries[] | select(.key != "200") | .value] | add // 0' \
            "${json}" 2>/dev/null || echo "0")
        if [[ "${total_reqs}" -gt 0 ]] 2>/dev/null; then
            error_pct=$(awk "BEGIN {printf \"%.2f\", ${errs} * 100 / ${total_reqs}}")
        else
            error_pct="N/A"
        fi
    fi

    local summary="${level_dir}/summary.txt"
    cat > "${summary}" <<EOF
------------------------------------------------------------------------
  Autoscaling Level: ${rps} RPS  (target ${TARGET_VALUE} RPS/replica)
------------------------------------------------------------------------
Expected replicas:     ${expected}
Actual RPS:            ${actual_rps}
Total requests:        ${total_reqs}
Error rate:            ${error_pct}%

Ramp-up window:        ${RAMP_UP}s
Observation window:    ${OBSERVATION}s  (${obs_samples} samples)

Time to expected:      ${time_to_exp}s
Avg replicas (obs):    ${avg_rep}
Min replicas (obs):    ${min_rep}
Max replicas (obs):    ${max_rep}
Scale events (obs):    ${scale_events}
Accuracy (obs):        ${accuracy}%

KHA CPU (m):           ${kha_cpu}
KHA Memory (Mi):       ${kha_mem}
------------------------------------------------------------------------
EOF
    cat "${summary}"

    # Append to global CSV
    echo "${rps},${expected},${actual_rps},${total_reqs},${error_pct},${time_to_exp},${avg_rep},${min_rep},${max_rep},${scale_events},${accuracy},${kha_cpu},${kha_mem}" \
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
# Generate final summary table
# ---------------------------------------------------------------------------
generate_final_summary() {
    local summary="${RESULTS_DIR}/summary.txt"
    info "Generating final summary"

    {
        echo "========================================================================"
        echo "  KHA Scaling Thrashing Test Summary"
        echo "========================================================================"
        echo ""
        echo "Date:            $(date)"
        echo "Namespace:       ${NAMESPACE}"
        echo "Target value:    ${TARGET_VALUE} RPS/replica"
        echo "Min replicas:    ${MIN_REPLICAS}"
        echo "Max replicas:    ${MAX_REPLICAS}"
        echo "Ramp-up:         ${RAMP_UP}s"
        echo "Observation:     ${OBSERVATION}s"
        echo "Poll interval:   ${POLL_INTERVAL}s"
        echo "Cooldown:        ${COOLDOWN}s"
        echo "Results:         ${RESULTS_DIR}"
        echo ""
        printf "%-8s  %-8s  %-10s  %-10s  %-7s  %-10s  %-8s  %-5s  %-5s  %-8s  %-10s  %-8s  %-8s\n" \
            "RPS" "Expect" "ActualRPS" "TotalReqs" "Err%" \
            "TimeToExp" "AvgRepl" "Min" "Max" "ScaleEvt" "Accuracy%" \
            "CPU(m)" "Mem(Mi)"
        printf "%-8s  %-8s  %-10s  %-10s  %-7s  %-10s  %-8s  %-5s  %-5s  %-8s  %-10s  %-8s  %-8s\n" \
            "------" "------" "--------" "--------" "-----" \
            "--------" "------" "---" "---" "------" "--------" \
            "------" "-------"
    } > "${summary}"

    if [[ -f "${RESULTS_DIR}/summary.csv" ]]; then
        while IFS=',' read -r rps expected actual_rps total_reqs err_pct \
                               time_exp avg_rep min_rep max_rep scale_evt \
                               accuracy cpu mem; do
            printf "%-8s  %-8s  %-10s  %-10s  %-7s  %-10s  %-8s  %-5s  %-5s  %-8s  %-10s  %-8s  %-8s\n" \
                "${rps}" "${expected}" "${actual_rps}" "${total_reqs}" "${err_pct}" \
                "${time_exp}" "${avg_rep}" "${min_rep}" "${max_rep}" "${scale_evt}" \
                "${accuracy}" "${cpu}" "${mem}" >> "${summary}"
        done < "${RESULTS_DIR}/summary.csv"
    fi

    {
        echo ""
        echo "------------------------------------------------------------------------"
        echo "Per-level details:   ${RESULTS_DIR}/<RPS>rps/"
        echo "Global CSV:          ${RESULTS_DIR}/summary.csv"
        echo ""
        echo "Columns:"
        echo "  TimeToExp  - seconds until ready replicas first reached the expected count"
        echo "  AvgRepl    - average ready replicas during the observation window"
        echo "  ScaleEvt   - number of replica-count changes during observation (thrashing)"
        echo "  Accuracy%  - % of observation samples at the expected replica count"
        echo "========================================================================"
    } >> "${summary}"

    echo ""
    cat "${summary}"
    echo ""
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
    info "Cleaning up test resources"
    kubectl delete pod load-generator -n "${NAMESPACE}" \
        --ignore-not-found --wait 2>/dev/null || true
    kubectl delete -f "${SCRIPT_DIR}/httpso.yaml"      --ignore-not-found 2>/dev/null || true
    kubectl delete -f "${SCRIPT_DIR}/deployment.yaml"   --ignore-not-found 2>/dev/null || true
    info "Cleanup complete"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    if [[ -z "${RESULTS_DIR}" ]]; then
        RESULTS_DIR="${SCRIPT_DIR}/results/thrashing-$(date +%Y%m%d-%H%M%S)"
    fi
    mkdir -p "${RESULTS_DIR}"
    info "Results will be saved to: ${RESULTS_DIR}"

    echo "rps,expected,actual_rps,total_reqs,error_pct,time_to_expected_s,avg_replicas,min_replicas,max_replicas,scale_events,accuracy_pct,kha_cpu_m,kha_mem_mi" \
        > "${RESULTS_DIR}/summary.csv"

    check_prerequisites
    deploy_workload
    deploy_load_generator

    for idx in "${!RPS_LEVELS[@]}"; do
        local rps="${RPS_LEVELS[${idx}]}"
        local level_dir="${RESULTS_DIR}/${rps}rps"
        mkdir -p "${level_dir}"

        info "========== Level: ${rps} RPS =========="

        reset_replicas

        # Brief settle after reset so KEDA's rate window clears
        info "Settling for 30s after reset"
        sleep 30

        run_level "${rps}" "${level_dir}"
        collect_kha_logs "${level_dir}"
        generate_level_report "${rps}" "${level_dir}"

        # Cooldown between levels (skip after the last one)
        if [[ ${idx} -lt $(( ${#RPS_LEVELS[@]} - 1 )) ]]; then
            info "Cooling down for ${COOLDOWN}s"
            sleep "${COOLDOWN}"
        fi
    done

    generate_final_summary

    if [[ "${NO_CLEANUP}" != "true" ]]; then
        cleanup
    else
        info "Skipping cleanup (--no-cleanup specified)"
    fi

    info "All done! Results: ${RESULTS_DIR}"
}

main "$@"
