#!/bin/bash
# =============================================================================
# 05_cluster_startup.sh
# Scenario 5: Cluster Startup Time Measurement
# =============================================================================

source "$(dirname "$0")/00_common.sh"

# Failsafe: ensure RESULTS_DIR is set absolutely
if [ -z "$RESULTS_DIR" ] || [ "$RESULTS_DIR" == "/results" ]; then
    RESULTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/results"
fi
mkdir -p "$RESULTS_DIR"

# =============================================================================
# CONFIGURATION
# =============================================================================

REPETITIONS=10
BETWEEN_RUNS_WAIT=60

# =============================================================================
# MILESTONE DETECTION FUNCTIONS — all log to stderr, only echo numbers to stdout
# =============================================================================

sanitize_number() {
    local val="$1"
    val=$(echo "$val" | grep -oE '^[0-9]+$' | tail -1)
    [ -z "$val" ] && val="-1"
    echo "$val"
}

wait_for_api_server() {
    local timeout=300
    local start
    start=$(now)
    echo "[INFO] $(date '+%H:%M:%S') Waiting for k3s API server..." >&2

    while true; do
        if kubectl get nodes >/dev/null 2>&1; then
            local elapsed=$(($(now) - start))
            echo "[INFO] $(date '+%H:%M:%S') API server ready after ${elapsed}s" >&2
            echo "$elapsed"
            return 0
        fi
        if [ $(($(now) - start)) -gt "$timeout" ]; then
            echo "[ERROR] Timeout waiting for API server" >&2
            echo "-1"
            return 1
        fi
        sleep 2
    done
}

wait_for_all_nodes() {
    local timeout=300
    local start
    start=$(now)
    echo "[INFO] $(date '+%H:%M:%S') Waiting for all 3 nodes to be Ready..." >&2

    while true; do
        local ready_count
        ready_count=$(kubectl get nodes --no-headers 2>/dev/null | grep " Ready" | wc -l) || ready_count=0
        if [ "$ready_count" -ge 3 ]; then
            local elapsed=$(($(now) - start))
            echo "[INFO] $(date '+%H:%M:%S') All 3 nodes Ready after ${elapsed}s" >&2
            echo "$elapsed"
            return 0
        fi
        if [ $(($(now) - start)) -gt "$timeout" ]; then
            echo "[ERROR] Timeout waiting for all nodes" >&2
            echo "-1"
            return 1
        fi
        sleep 5
    done
}

wait_for_longhorn() {
    local timeout=300
    local start
    start=$(now)
    echo "[INFO] $(date '+%H:%M:%S') Waiting for Longhorn storage to be healthy..." >&2

    while true; do
        local healthy_nodes
        healthy_nodes=$(kubectl get nodes.longhorn.io -n longhorn-system \
            --no-headers 2>/dev/null | grep "True" | wc -l) || healthy_nodes=0
        if [ "$healthy_nodes" -ge 3 ]; then
            local elapsed=$(($(now) - start))
            echo "[INFO] $(date '+%H:%M:%S') Longhorn healthy after ${elapsed}s" >&2
            echo "$elapsed"
            return 0
        fi
        if [ $(($(now) - start)) -gt "$timeout" ]; then
            echo "[WARN] Timeout waiting for Longhorn" >&2
            echo "-1"
            return 1
        fi
        sleep 5
    done
}

wait_for_prometheus() {
    local timeout=300
    local start
    start=$(now)
    echo "[INFO] $(date '+%H:%M:%S') Waiting for Prometheus..." >&2

    while true; do
        if curl -sf "${PROMETHEUS_URL}/-/healthy" >/dev/null 2>&1; then
            local elapsed=$(($(now) - start))
            echo "[INFO] $(date '+%H:%M:%S') Prometheus ready after ${elapsed}s" >&2
            echo "$elapsed"
            return 0
        fi
        if [ $(($(now) - start)) -gt "$timeout" ]; then
            echo "[WARN] Timeout waiting for Prometheus" >&2
            echo "-1"
            return 1
        fi
        sleep 5
    done
}

wait_for_grafana() {
    local timeout=300
    local start
    start=$(now)
    echo "[INFO] $(date '+%H:%M:%S') Waiting for Grafana..." >&2

    while true; do
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout 2 "http://${MASTER_IP}:32000" 2>/dev/null) || http_code="000"
        if [ "$http_code" == "200" ] || [ "$http_code" == "302" ]; then
            local elapsed=$(($(now) - start))
            echo "[INFO] $(date '+%H:%M:%S') Grafana ready after ${elapsed}s" >&2
            echo "$elapsed"
            return 0
        fi
        if [ $(($(now) - start)) -gt "$timeout" ]; then
            echo "[WARN] Timeout waiting for Grafana" >&2
            echo "-1"
            return 1
        fi
        sleep 5
    done
}

wait_for_vms() {
    local timeout=600
    local start
    start=$(now)
    echo "[INFO] $(date '+%H:%M:%S') Waiting for both VMs to be Running..." >&2

    while true; do
        local running_count
        running_count=$(kubectl get vmi --no-headers 2>/dev/null | grep "Running" | wc -l) || running_count=0
        if [ "$running_count" -ge 2 ]; then
            local elapsed=$(($(now) - start))
            echo "[INFO] $(date '+%H:%M:%S') Both VMs Running after ${elapsed}s" >&2
            echo "$elapsed"
            return 0
        fi
        if [ $(($(now) - start)) -gt "$timeout" ]; then
            echo "[WARN] Timeout waiting for VMs" >&2
            echo "-1"
            return 1
        fi
        sleep 10
    done
}

wait_for_vm_http() {
    local timeout=180
    local start
    start=$(now)
    echo "[INFO] $(date '+%H:%M:%S') Waiting for VM HTTP endpoints..." >&2

    while true; do
        local code1 code2
        code1=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "$VM1_HTTP" 2>/dev/null) || code1="000"
        code2=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "$VM2_HTTP" 2>/dev/null) || code2="000"

        if [ "$code1" == "200" ] && [ "$code2" == "200" ]; then
            local elapsed=$(($(now) - start))
            echo "[INFO] $(date '+%H:%M:%S') Both VM HTTP endpoints ready after ${elapsed}s" >&2
            echo "$elapsed"
            return 0
        fi
        if [ $(($(now) - start)) -gt "$timeout" ]; then
            echo "[WARN] Timeout waiting for VM HTTP" >&2
            echo "-1"
            return 1
        fi
        sleep 5
    done
}

# =============================================================================
# SINGLE STARTUP RUN
# =============================================================================

run_startup() {
    local run_number=$1
    local results_dir=$2

    log_step "Run $run_number / $REPETITIONS"

    # Prompt user to power off cluster
    echo ""
    echo ""
    log_warn "============================================"
    log_warn " STEP 1 OF 2 — POWER OFF"
    log_warn " Run shutdown script: bash shutdown-cluster.sh"
    log_warn " Then physically power off all 3 Pis"
    log_warn ""
    log_warn " Press ENTER once all nodes are powered OFF"
    log_warn "============================================"
    echo ""
    read -r

    log_info "Waiting 10s before next prompt..."
    sleep 10

    # Prompt user to power on
    echo ""
    echo ""
    log_warn "============================================"
    log_warn " STEP 2 OF 2 — POWER ON"
    log_warn ""
    log_warn " 1. Power on k3s-master FIRST"
    log_warn " 2. Press ENTER immediately after (timer starts)"
    log_warn " 3. Then 20-30 seconds later, power on BOTH workers"
    log_warn ""
    log_warn " Press ENTER right after powering on master."
    log_warn "============================================"
    echo ""
    read -r

    # Record power-on time
    local t_power_on
    t_power_on=$(now)
    log_info "Timer started at $(now_human)"

    # Start pod count tracker — direct background spawn, not $()
    local pod_tracker_pid_file="/tmp/cs5_pod_tracker_${run_number}.tmp"
    local pod_csv="$results_dir/pod_count_run${run_number}.csv"
    (
        echo "timestamp,datetime,total_pods,running_pods,pending_pods" > "$pod_csv"
        local start
        start=$(now)
        while [ $(($(now) - start)) -lt 1200 ]; do
            local ts
            ts=$(now)
            local dt
            dt=$(now_human)
            local total running pending
            total=$(kubectl get pods -A --no-headers 2>/dev/null | wc -l) || total=0
            running=$(kubectl get pods -A --no-headers 2>/dev/null | grep "Running" | wc -l) || running=0
            pending=$(kubectl get pods -A --no-headers 2>/dev/null | grep "Pending" | wc -l) || pending=0
            echo "$ts,$dt,$total,$running,$pending" >> "$pod_csv"
            sleep 10
        done
    ) &
    echo $! > "$pod_tracker_pid_file"
    local pod_tracker_pid
    pod_tracker_pid=$(cat "$pod_tracker_pid_file")
    log_info "Pod tracker started (PID: $pod_tracker_pid)"

    # All milestone captures use temp files to avoid subshell issues
    local tmp="/tmp/cs5_milestone_${run_number}.tmp"

    echo "-1" > "$tmp"; wait_for_api_server > "$tmp" || true
    local t_api; t_api=$(now)
    record_timing "$results_dir" "run${run_number}_api_server_ready" $((t_api - t_power_on)) || true

    echo "-1" > "$tmp"; wait_for_all_nodes > "$tmp" || true
    local t_nodes; t_nodes=$(now)
    record_timing "$results_dir" "run${run_number}_all_nodes_ready" $((t_nodes - t_power_on)) || true

    echo "-1" > "$tmp"; wait_for_longhorn > "$tmp" || true
    local t_longhorn; t_longhorn=$(now)
    record_timing "$results_dir" "run${run_number}_longhorn_healthy" $((t_longhorn - t_power_on)) || true

    echo "-1" > "$tmp"; wait_for_prometheus > "$tmp" || true
    local t_prom; t_prom=$(now)
    record_timing "$results_dir" "run${run_number}_prometheus_ready" $((t_prom - t_power_on)) || true

    echo "-1" > "$tmp"; wait_for_grafana > "$tmp" || true
    local t_grafana; t_grafana=$(now)
    record_timing "$results_dir" "run${run_number}_grafana_ready" $((t_grafana - t_power_on)) || true

    echo "-1" > "$tmp"; wait_for_vms > "$tmp" || true
    local t_vms; t_vms=$(now)
    record_timing "$results_dir" "run${run_number}_vms_running" $((t_vms - t_power_on)) || true

    echo "-1" > "$tmp"; wait_for_vm_http > "$tmp" || true
    local t_http; t_http=$(now)
    record_timing "$results_dir" "run${run_number}_vm_http_ready" $((t_http - t_power_on)) || true

    rm -f "$tmp"

    # Total time
    local total=$((t_http - t_power_on))
    record_timing "$results_dir" "run${run_number}_TOTAL" "$total" || true

    # Stop pod tracker before next prompt so output doesn't get mixed
    kill "$pod_tracker_pid" 2>/dev/null || true
    wait "$pod_tracker_pid" 2>/dev/null || true
    rm -f "$pod_tracker_pid_file"

    log_info "Run $run_number complete! Total startup time: ${total}s ($((total/60))m $((total%60))s)"

    log_info "Waiting ${BETWEEN_RUNS_WAIT}s before next run..."
    sleep "$BETWEEN_RUNS_WAIT"

    return 0
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    # Safety cleanup on exit
    trap 'pkill -f "kubectl get pods" 2>/dev/null || true; \
          rm -f /tmp/cs5_*.tmp 2>/dev/null || true' EXIT

    log_step "Scenario 5: Cluster Startup Time Measurement"
    log_info "This scenario measures how long the cluster takes to become"
    log_info "fully operational after a cold power-on."
    log_info ""
    log_info "Milestones measured (from power-on):"
    log_info "  1. k3s API server ready"
    log_info "  2. All 3 nodes Ready"
    log_info "  3. Longhorn storage healthy"
    log_info "  4. Prometheus ready"
    log_info "  5. Grafana ready"
    log_info "  6. Both VMs Running"
    log_info "  7. VM HTTP endpoints responding"
    log_info ""
    log_info "Repetitions: $REPETITIONS"
    log_warn ""
    log_warn "IMPORTANT: You will need to physically power the cluster"
    log_warn "off and on $REPETITIONS times during this test."
    log_warn ""
    read -p "Press ENTER to start, or Ctrl+C to cancel..."

    local results_dir
    results_dir=$(init_results_dir "05_cluster_startup")
    log_info "Results will be saved to: $results_dir"

    cat > "$results_dir/scenario_config.txt" << EOF
Scenario: Cluster Startup Time
Date: $(now_human)
Repetitions: $REPETITIONS
Milestones: api_server, all_nodes, longhorn, prometheus, grafana, vms_running, vm_http
EOF

    for i in $(seq 1 "$REPETITIONS"); do
        run_startup "$i" "$results_dir" || true
    done

    print_timing_summary "$results_dir"

    log_step "Average startup times across $REPETITIONS runs:"
    python3 -c "
import csv
from collections import defaultdict
import statistics

timings = defaultdict(list)
with open('$results_dir/timing_summary.csv') as f:
    for row in csv.DictReader(f):
        try:
            val = float(row['seconds'])
            if val < 0:
                continue
            parts = row['label'].split('_')
            milestone = '_'.join(parts[2:])
            timings[milestone].append(val)
        except (ValueError, KeyError):
            continue

milestones = [
    'api_server_ready',
    'all_nodes_ready',
    'longhorn_healthy',
    'prometheus_ready',
    'grafana_ready',
    'vms_running',
    'vm_http_ready',
    'TOTAL'
]

print(f'{\"Milestone\":<30} {\"Avg\":>8} {\"Min\":>8} {\"Max\":>8} {\"StdDev\":>8}')
print('-' * 70)
for m in milestones:
    if m in timings and timings[m]:
        vals = timings[m]
        avg = statistics.mean(vals)
        mn = min(vals)
        mx = max(vals)
        std = statistics.stdev(vals) if len(vals) > 1 else 0
        print(f'{m:<30} {avg:>7.1f}s {mn:>7.1f}s {mx:>7.1f}s {std:>7.1f}s')
" 2>/dev/null || true

    log_step "Cluster startup tests complete!"
    log_info "Results saved to: $results_dir"
}

main "$@"
