# HTTP Autoscaler Performance Testing

A test suite for benchmarking the data-plane overhead of HTTP autoscaling proxies on Kubernetes. It measures latency, throughput, error rates, and resource consumption across progressively increasing request rates for three configurations:

| Configuration | Autoscaler | Proxy in data path | Scale range |
|---|---|---|---|
| **Bare Service** (baseline) | None — fixed replicas | None | 50 (static) |
| **KEDA HTTP Add-on (KHA)** | KEDA + HTTPScaledObject | KHA Interceptor | 0 – 50 |
| **Knative Serving** | Knative Autoscaler (KPA) | Activator + Kourier | 0 – 50 |

## Repository structure

```
.
├── install-scripts/
│   ├── manage_kha.sh            # Install / uninstall KEDA + KHA
│   └── manage_knative.sh        # Install / uninstall Knative Serving + Kourier
├── test-bare-service/
│   ├── deployment.yaml          # nginx Deployment + Service (50 replicas)
│   └── test_bare_service.sh     # Load test: direct to Kubernetes Service
├── test-kha/
│   ├── deployment.yaml          # nginx Deployment + Service (0 replicas)
│   ├── httpso.yaml              # HTTPScaledObject (target 100 RPS/replica)
│   └── test_interceptor.sh      # Load test: through KHA interceptor proxy
└── test-knative/
    ├── ksvc.yaml                # Knative Service (target 100 RPS/replica)
    └── test_activator.sh        # Load test: through Kourier + Activator
```

## Prerequisites

- A Kubernetes cluster (tested on GKE) with dedicated node pools:
  - **Control-plane pool** — labeled `gke-pool-type=autoscale-test-control-plane` and tainted with `autoscale-test-control-plane=true:NoSchedule` for autoscaler components (KHA operator/scaler/interceptor, Knative Serving, Kourier).
  - **Workload pool** — labeled `gke-pool-type=autoscale-test` and tainted with `autoscale-test=true:NoSchedule` for the sample application and the load generator.
- `kubectl` configured and connected to the cluster
- `helm` (v3) for installing KEDA / KHA
- `jq` for parsing Fortio JSON results

## Quick start

### 1. Install autoscaler components

Install whichever autoscaler you want to test (or both):

```bash
# KEDA + KHA
./install-scripts/manage_kha.sh install

# Knative Serving + Kourier
./install-scripts/manage_knative.sh install
```

Both scripts accept environment variables for customization:

| Variable | Default | Description |
|---|---|---|
| `NAMESPACE` | `autoscale-test` | Target namespace (KHA only) |
| `KHA_VERSION` | `0.12.1` | KHA Helm chart version |
| `KNATIVE_VERSION` | *(auto-detect latest)* | Knative Serving version |

### 2. Run the tests

Each test script is self-contained — it deploys the sample workload, runs the load test, collects results, and cleans up afterwards.

```bash
# Baseline: bare Kubernetes Service (no autoscaler)
./test-bare-service/test_bare_service.sh

# KEDA HTTP Add-on interceptor proxy
./test-kha/test_interceptor.sh

# Knative Serving activator
./test-knative/test_activator.sh
```

#### Common options

All three test scripts support the same flags:

| Flag | Default | Description |
|---|---|---|
| `--duration SECS` | `60` | Duration of each RPS level |
| `--cooldown SECS` | `30` | Pause between RPS levels |
| `--results-dir DIR` | *(auto-generated timestamp)* | Custom output directory |
| `--no-cleanup` | *(off)* | Keep test resources after completion |

### 3. Uninstall

```bash
./install-scripts/manage_kha.sh uninstall
./install-scripts/manage_knative.sh uninstall
```

## Test methodology

1. **Deploy** the sample workload (nginx:alpine).
2. **Deploy** an in-cluster Fortio load-generator pod.
3. **Warm up** by sending low-rate traffic to prime connections and (for autoscaled tests) trigger scale-from-zero.
4. **Step through RPS levels**: 10, 50, 250, 1 000, 2 500, 5 000, 10 000, 25 000, 50 000, 100 000 — running each level for the configured duration with a cooldown in between.
5. **Collect** per-level results and a continuous resource-usage time series.
6. **Generate** a summary report (text + CSV).

### Metrics collected

| Metric | Source |
|---|---|
| Actual QPS achieved | Fortio JSON |
| Latency percentiles (p50, p75, p90, p95, p99, p99.9) | Fortio JSON |
| Total requests, successes, errors, error rate | Fortio JSON |
| CPU and memory per pod (5 s intervals) | `kubectl top` |
| Pod count snapshots per RPS level | `kubectl get pods` |
| Component logs (interceptor / activator) | `kubectl logs` |

## Results

Each test run writes its output to a timestamped directory under `results/` (git-ignored). A typical run produces:

```
results/
├── summary.txt              # Human-readable summary table
├── summary.csv              # Machine-readable summary
├── resource_metrics.csv     # Time-series pod resource usage
├── fortio_<RPS>rps.json     # Raw Fortio output per RPS level
├── fortio_<RPS>rps.txt      # Fortio stderr / progress per level
├── top_<RPS>rps.txt         # kubectl top snapshot per level
├── pods_<RPS>rps.txt        # kubectl get pods snapshot per level
├── interceptor_logs.txt     # KHA interceptor logs (KHA test only)
└── activator_logs.txt       # Knative activator logs (Knative test only)
```
